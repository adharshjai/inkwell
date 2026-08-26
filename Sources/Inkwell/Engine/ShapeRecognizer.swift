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

    static func recognize(_ rawPoints: [CGPoint]) -> Shape {
        let points = NSBezierPath.decimate(rawPoints, epsilon: 1.0)
        guard points.count >= 3 else {
            if points.count == 2 { return .line(points[0], snapAngle(from: points[0], to: points[1])) }
            return .none
        }

        let box = boundingBox(points)
        let diagonal = max(hypot(box.width, box.height), 1)
        guard diagonal > 14 else { return .none }

        let simplified = ramerDouglasPeucker(points, epsilon: diagonal * 0.05)
        let perimeter = pathLength(points)
        let closed = points[0].distance(to: points[points.count - 1]) < max(perimeter * 0.18, 14)

        if closed {
            let area = abs(shoelaceArea(points))
            let circularity = 4 * .pi * area / max(perimeter * perimeter, 1)
            // Ellipses are smooth: high circularity or many gentle corners.
            if circularity > 0.72, simplified.count >= 5 {
                var frame = box
                let aspect = frame.width / max(frame.height, 1)
                if aspect > 0.82, aspect < 1.22 {
                    // Close enough to a circle — make it one.
                    let side = (frame.width + frame.height) / 2
                    frame = CGRect(
                        x: frame.midX - side / 2, y: frame.midY - side / 2,
                        width: side, height: side
                    )
                }
                return .ellipse(frame)
            }
            let corners = closedCorners(simplified)
            if corners.count == 4 {
                // Quadrilateral: if it fills its bounding box, call it a rect.
                let quadArea = abs(shoelaceArea(corners + [corners[0]]))
                if quadArea / max(box.width * box.height, 1) > 0.72 {
                    return .rect(box)
                }
                return .polygon(corners)
            }
            if corners.count == 3 {
                return .polygon(corners)
            }
            if circularity > 0.6 {
                return .ellipse(box)
            }
            return .none
        }

        // Open strokes.
        if simplified.count == 2 {
            return .line(simplified[0], snapAngle(from: simplified[0], to: simplified[1]))
        }
        if simplified.count <= 6 {
            // A deliberate multi-segment path (V, Z, step) — keep its corners,
            // gently straightening each segment.
            var snapped = [simplified[0]]
            for point in simplified.dropFirst() {
                snapped.append(snapAngle(from: snapped[snapped.count - 1], to: point))
            }
            return .polyline(snapped)
        }
        return .none
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
