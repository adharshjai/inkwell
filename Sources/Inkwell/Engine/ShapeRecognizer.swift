import AppKit

/// Turns a shaky trackpad stroke into the shape the user meant:
/// circles become ellipses, wobbly boxes become rectangles, crooked lines
/// snap straight. Used by the hold-S "shape" quasimode.
enum ShapeRecognizer {

    enum Shape {
        case line(CGPoint, CGPoint)
        case polyline([CGPoint])
        case rect(CGRect)
        case ellipse(CGRect)
        case polygon([CGPoint])   // closed, e.g. triangle
        case none
    }

    // MARK: - Recognition

    /// Model selection by fit error, not thresholds-on-circularity (a square's
    /// circularity is 0.785 — treacherously "circular"). Each candidate shape
    /// is scored by the mean distance from the stroke to its outline.
    static func recognize(_ rawPoints: [CGPoint]) -> Shape {
        let points = NSBezierPath.decimate(rawPoints, epsilon: 1.0)
        guard points.count >= 3 else {
            if points.count == 2 { return .line(points[0], snapAngle(from: points[0], to: points[1])) }
            return .none
        }

        let box = boundingBox(points)
        let diagonal = max(hypot(box.width, box.height), 1)
        guard diagonal > 14 else { return .none }

        let perimeter = pathLength(points)
        let closed = points[0].distance(to: points[points.count - 1]) < max(perimeter * 0.2, 16)
        let tolerance = max(diagonal * 0.05, 3.5)

        if !closed {
            // Straight line: the whole stroke hugs its chord.
            let a = points[0], b = points[points.count - 1]
            let chordDeviation = points.map { perpendicularDistance($0, a, b) }.max() ?? 0
            if chordDeviation < tolerance {
                return .line(a, snapAngle(from: a, to: b))
            }
            let simplified = cleanCorners(ramerDouglasPeucker(points, epsilon: diagonal * 0.035))
            if simplified.count <= 6 {
                var snapped = [simplified[0]]
                for point in simplified.dropFirst() {
                    snapped.append(snapAngle(from: snapped[snapped.count - 1], to: point))
                }
                return .polyline(snapped)
            }
            return .none
        }

        // Closed stroke: score rectangle vs ellipse fits.
        let rectError = meanRectError(points, box)
        let ellipseError = meanEllipseError(points, box)
        let corners = cleanCorners(closedCorners(
            ramerDouglasPeucker(points, epsilon: diagonal * 0.035)
        ))

        if rectError < ellipseError, rectError < tolerance {
            return .rect(box)
        }
        if ellipseError <= rectError, ellipseError < tolerance {
            var frame = box
            let aspect = frame.width / max(frame.height, 1)
            if aspect > 0.82, aspect < 1.22 {
                let side = (frame.width + frame.height) / 2
                frame = CGRect(
                    x: frame.midX - side / 2, y: frame.midY - side / 2,
                    width: side, height: side
                )
            }
            return .ellipse(frame)
        }
        // Neither primitive fits well — trust the corners (triangle, diamond,
        // parallelogram, pentagon…).
        if (3...6).contains(corners.count) {
            return .polygon(corners)
        }
        // Blobby but closed: whichever primitive was less bad.
        if min(rectError, ellipseError) < tolerance * 1.8 {
            return rectError < ellipseError ? .rect(box) : .ellipse(box)
        }
        return .none
    }

    /// Mean distance from stroke points to the rectangle's outline.
    private static func meanRectError(_ points: [CGPoint], _ box: CGRect) -> CGFloat {
        let corners = [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
        ]
        var total: CGFloat = 0
        for p in points {
            var best = CGFloat.greatestFiniteMagnitude
            for i in 0..<4 {
                best = min(best, segmentDistance(p, corners[i], corners[(i + 1) % 4]))
            }
            total += best
        }
        return total / CGFloat(points.count)
    }

    /// Mean radial deviation from the ellipse inscribed in the bounding box.
    private static func meanEllipseError(_ points: [CGPoint], _ box: CGRect) -> CGFloat {
        let a = max(box.width / 2, 0.5), b = max(box.height / 2, 0.5)
        let cx = box.midX, cy = box.midY
        let meanRadius = (a + b) / 2
        var total: CGFloat = 0
        for p in points {
            let nx = (p.x - cx) / a, ny = (p.y - cy) / b
            let r = (nx * nx + ny * ny).squareRoot()
            total += abs(r - 1) * meanRadius
        }
        return total / CGFloat(points.count)
    }

    private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else { return p.distance(to: a) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return p.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// Drops corners that are nearly collinear (< 25° turn) or nearly on top
    /// of a neighbor — hand-drawn rounded corners produce both.
    private static func cleanCorners(_ corners: [CGPoint]) -> [CGPoint] {
        guard corners.count > 2 else { return corners }
        var out: [CGPoint] = [corners[0]]
        for i in 1..<corners.count {
            let candidate = corners[i]
            if let last = out.last, last.distance(to: candidate) < 6 { continue }
            out.append(candidate)
        }
        // Collinearity pass (endpoints kept).
        guard out.count > 2 else { return out }
        var cleaned: [CGPoint] = [out[0]]
        for i in 1..<(out.count - 1) {
            let prev = cleaned[cleaned.count - 1], here = out[i], next = out[i + 1]
            let a1 = atan2(here.y - prev.y, here.x - prev.x)
            let a2 = atan2(next.y - here.y, next.x - here.x)
            var turn = abs(a2 - a1)
            if turn > .pi { turn = 2 * .pi - turn }
            if turn > (25 * .pi / 180) { cleaned.append(here) }
        }
        cleaned.append(out[out.count - 1])
        return cleaned
    }

    /// Beautified page-space paths for a recognized shape (nil = keep raw ink).
    static func beautify(_ rawPoints: [CGPoint], gridSnap: ((CGPoint) -> CGPoint)? = nil) -> [NSBezierPath]? {
        var shape = recognize(rawPoints)
        if let snap = gridSnap {
            shape = applySnap(shape, snap)
        }
        switch shape {
        case .line(let a, let b):
            let path = NSBezierPath()
            path.move(to: a)
            path.line(to: b)
            return [path]
        case .polyline(let pts):
            guard pts.count >= 2 else { return nil }
            let path = NSBezierPath()
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.line(to: p) }
            return [path]
        case .rect(let frame):
            return [NSBezierPath(rect: frame)]
        case .ellipse(let frame):
            return [NSBezierPath(ovalIn: frame)]
        case .polygon(let pts):
            guard pts.count >= 3 else { return nil }
            let path = NSBezierPath()
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.line(to: p) }
            path.close()
            return [path]
        case .none:
            return nil
        }
    }

    private static func applySnap(_ shape: Shape, _ snap: (CGPoint) -> CGPoint) -> Shape {
        switch shape {
        case .line(let a, let b): return .line(snap(a), snap(b))
        case .polyline(let pts): return .polyline(pts.map(snap))
        case .polygon(let pts): return .polygon(pts.map(snap))
        case .rect(let f):
            let o = snap(f.origin)
            let c = snap(CGPoint(x: f.maxX, y: f.maxY))
            return .rect(CGRect(corner: o, corner: c))
        case .ellipse, .none: return shape
        }
    }

    // MARK: - Geometry helpers

    /// Snaps the segment a→b to the nearest 45° when it's within ~8°.
    static func snapAngle(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let step = CGFloat.pi / 4
        let snapped = (angle / step).rounded() * step
        guard abs(angle - snapped) < (8 * .pi / 180) else { return b }
        let length = a.distance(to: b)
        return CGPoint(x: a.x + cos(snapped) * length, y: a.y + sin(snapped) * length)
    }

    static func ramerDouglasPeucker(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            var maxDist: CGFloat = 0
            var index = start
            for i in (start + 1)..<end {
                let d = perpendicularDistance(points[i], points[start], points[end])
                if d > maxDist { maxDist = d; index = i }
            }
            if maxDist > epsilon {
                keep[index] = true
                stack.append((start, index))
                stack.append((index, end))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    private static func perpendicularDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else { return p.distance(to: a) }
        let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return p.distance(to: proj)
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    private static func shoelaceArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 2 else { return 0 }
        var sum: CGFloat = 0
        for i in 0..<points.count - 1 {
            sum += points[i].x * points[i + 1].y - points[i + 1].x * points[i].y
        }
        return sum / 2
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Corner points of a closed simplified stroke (drops the duplicated
    /// endpoint pair if the start/end sit on top of each other).
    private static func closedCorners(_ simplified: [CGPoint]) -> [CGPoint] {
        var corners = simplified
        if corners.count > 1, corners[0].distance(to: corners[corners.count - 1]) < 12 {
            corners.removeLast()
        }
        return corners
    }
}
