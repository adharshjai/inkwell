import AppKit
import PDFKit

/// All Inkwell-created annotations funnel through here so geometry conventions,
/// undo registration, and styling stay in one place.
///
/// Convention: callers hand ink paths in *page space* (PDF user space, origin
/// bottom-left); `makeInk` converts them to bounds-relative space, which is how
/// this OS's PDFKit interprets `PDFAnnotation.add(_:)` paths (verified
/// empirically by `Inkwell --selftest`, which renders and samples pixels).
/// A pleasant consequence: moving an ink annotation is a pure bounds shift.
@MainActor
enum Annotations {

    static let authorName = "Inkwell"

    // MARK: - Undoable add / remove

    static func add(_ annotation: PDFAnnotation, to page: PDFPage, state: AppState, actionName: String) {
        page.addAnnotation(annotation)
        state.applyDisplayPolicy(annotation, on: page)
        state.markDirty()
        state.bumpVersion()
        state.undoManager?.setActionName(actionName)
        state.undoManager?.registerUndo(withTarget: state) { st in
            Annotations.remove(annotation, from: page, state: st, actionName: actionName)
        }
    }

    static func remove(_ annotation: PDFAnnotation, from page: PDFPage, state: AppState, actionName: String) {
        page.removeAnnotation(annotation)
        if state.selectedAnnotations.contains(where: { $0 === annotation }) {
            state.selectedAnnotations.removeAll { $0 === annotation }
            if state.selectedAnnotations.isEmpty { state.selectedAnnotationPage = nil }
        }
        state.markDirty()
        state.bumpVersion()
        state.undoManager?.setActionName(actionName)
        state.undoManager?.registerUndo(withTarget: state) { st in
            Annotations.add(annotation, to: page, state: st, actionName: actionName)
        }
    }

    /// Registers undo for a move that already happened (call once, at drag end).
    static func registerMove(of annotation: PDFAnnotation, totalDelta: CGPoint, state: AppState) {
        guard totalDelta != .zero else { return }
        state.markDirty()
        state.bumpVersion()
        state.undoManager?.setActionName("Move")
        state.undoManager?.registerUndo(withTarget: state) { st in
            Annotations.translate(annotation, by: CGPoint(x: -totalDelta.x, y: -totalDelta.y))
            Annotations.registerMove(of: annotation, totalDelta: CGPoint(x: -totalDelta.x, y: -totalDelta.y), state: st)
        }
    }

    static func registerTextEdit(of annotation: PDFAnnotation, oldContents: String, oldBounds: CGRect, state: AppState) {
        state.markDirty()
        state.bumpVersion()
        state.undoManager?.setActionName("Edit Text")
        state.undoManager?.registerUndo(withTarget: state) { st in
            let current = annotation.contents ?? ""
            let currentBounds = annotation.bounds
            annotation.contents = oldContents
            annotation.bounds = oldBounds
            Annotations.registerTextEdit(of: annotation, oldContents: current, oldBounds: currentBounds, state: st)
        }
    }

    // MARK: - Movement

    /// Moves any Inkwell annotation. Ink paths are stored bounds-relative, so a
    /// bounds shift moves everything.
    static func translate(_ annotation: PDFAnnotation, by delta: CGPoint) {
        annotation.bounds = annotation.bounds.offsetBy(dx: delta.x, dy: delta.y)
    }

    /// One undo entry that moves a whole selection back together.
    static func registerGroupMove(of annotations: [PDFAnnotation], totalDelta: CGPoint, state: AppState) {
        guard totalDelta != .zero, !annotations.isEmpty else { return }
        state.markDirty()
        state.bumpVersion()
        state.undoManager?.setActionName("Move")
        state.undoManager?.registerUndo(withTarget: state) { st in
            let inverse = CGPoint(x: -totalDelta.x, y: -totalDelta.y)
            for annotation in annotations {
                Annotations.translate(annotation, by: inverse)
            }
            Annotations.registerGroupMove(of: annotations, totalDelta: inverse, state: st)
        }
    }

    // MARK: - Resize

    /// Everything needed to restore (or rescale from) an annotation's geometry.
    struct Geometry {
        let bounds: CGRect
        let paths: [NSBezierPath]?   // deep copies, bounds-relative (ink)
        let fontSize: CGFloat?       // free text
        let lineWidth: CGFloat?      // ink stroke width

        @MainActor
        init(of annotation: PDFAnnotation) {
            bounds = annotation.bounds
            paths = annotation.paths.map { $0.map { $0.copy() as! NSBezierPath } }
            fontSize = annotation.font?.pointSize
            lineWidth = annotation.border?.lineWidth
        }
    }

    /// True when the annotation supports handle-resizing.
    static func isResizable(_ annotation: PDFAnnotation) -> Bool {
        guard isEditable(annotation) else { return false }
        switch annotation.type ?? "" {
        case "Ink", "Square", "Circle", "FreeText": return true
        default: return false
        }
    }

    /// Rescales an annotation from its captured original geometry into
    /// `newBounds` — idempotent, so live handle-drags never accumulate error.
    static func applyScale(_ annotation: PDFAnnotation, from original: Geometry, to newBounds: CGRect) {
        let sx = newBounds.width / max(original.bounds.width, 0.01)
        let sy = newBounds.height / max(original.bounds.height, 0.01)

        if annotation.type == "Ink", let originalPaths = original.paths {
            if let current = annotation.paths {
                for path in current { annotation.remove(path) }
            }
            let transform = AffineTransform(scaleByX: sx, byY: sy)
            for path in originalPaths {
                let copy = path.copy() as! NSBezierPath
                copy.transform(using: transform)
                annotation.add(copy)
            }
            // The stroke must scale with the geometry, or hatch-filled ink
            // (typeset math) opens visible gaps between its fill lines.
            if let width = original.lineWidth {
                let border = PDFBorder()
                border.lineWidth = max(0.1, width * (sx + sy) / 2)
                annotation.border = border
            }
        }
        if annotation.type == "FreeText", let size = original.fontSize {
            let scaled = max(4, size * min(sx, sy))
            annotation.font = NSFont.systemFont(ofSize: scaled)
        }
        annotation.bounds = newBounds
    }

    static func restore(_ annotation: PDFAnnotation, to geometry: Geometry) {
        if annotation.type == "Ink", let originalPaths = geometry.paths {
            if let current = annotation.paths {
                for path in current { annotation.remove(path) }
            }
            for path in originalPaths {
                annotation.add(path.copy() as! NSBezierPath)
            }
            if let width = geometry.lineWidth {
                let border = PDFBorder()
                border.lineWidth = width
                annotation.border = border
            }
        }
        if annotation.type == "FreeText", let size = geometry.fontSize {
            annotation.font = NSFont.systemFont(ofSize: size)
        }
        annotation.bounds = geometry.bounds
    }

    /// Registers undo for a resize that already happened.
    static func registerResize(of annotation: PDFAnnotation, before: Geometry, state: AppState) {
        state.markDirty()
        state.bumpVersion()
        state.undoManager?.setActionName("Resize")
        state.undoManager?.registerUndo(withTarget: state) { st in
            let current = Geometry(of: annotation)
            Annotations.restore(annotation, to: before)
            Annotations.registerResize(of: annotation, before: current, state: st)
            st.bumpVersion()
        }
    }

    /// True for annotations the user may select, move, and delete
    /// (form-field widgets and links belong to PDFKit's interaction).
    static func isEditable(_ annotation: PDFAnnotation) -> Bool {
        let t = annotation.type ?? ""
        return !["Widget", "Link"].contains(t)
    }

    /// Path-accurate hit test: ink must actually pass near the point (within
    /// `tolerance` plus half its stroke width); other types use their bounds.
    /// Bounds-only testing makes a long diagonal stroke "erasable" from the
    /// whole empty rectangle around it.
    static func preciseHit(at point: CGPoint, on page: PDFPage, tolerance: CGFloat) -> PDFAnnotation? {
        for annotation in page.annotations.reversed() where isEditable(annotation) {
            let bounds = annotation.bounds.insetBy(dx: -tolerance, dy: -tolerance)
            guard bounds.contains(point) else { continue }
            if annotation.type == "Ink", let paths = annotation.paths {
                let local = CGPoint(
                    x: point.x - annotation.bounds.minX,
                    y: point.y - annotation.bounds.minY
                )
                let reach = tolerance + (annotation.border?.lineWidth ?? 1.5) / 2
                if paths.contains(where: { pathDistance($0, to: local) <= reach }) {
                    return annotation
                }
            } else {
                return annotation
            }
        }
        return nil
    }

    /// Repairs ink whose bounds and paths have DIVERGED (scar tissue from
    /// older versions that moved bounds without paths). PDFKit's rendering
    /// truth is `bounds.origin + paths` — keep the ink exactly where it
    /// draws and rebuild the bounds box around it, so hit testing, dragging,
    /// and the crisp overlay all agree with what's on screen.
    /// (Save/reload itself is verified clean: bounds-relative in, bounds-
    /// relative out.)
    static func normalizeInkPaths(_ annotation: PDFAnnotation) {
        guard annotation.type == "Ink", let paths = annotation.paths, !paths.isEmpty else { return }
        var bbox = paths[0].bounds
        for path in paths.dropFirst() { bbox = bbox.union(path.bounds) }
        let bounds = annotation.bounds
        // Consistent: the paths sit inside the bounds box (relative space).
        if CGRect(origin: .zero, size: bounds.size).insetBy(dx: -6, dy: -6).contains(bbox) { return }
        let pad = max(annotation.border?.lineWidth ?? 1.5, 1) + 4
        let drawn = bbox
            .offsetBy(dx: bounds.minX, dy: bounds.minY)
            .insetBy(dx: -pad, dy: -pad)
        let shift = AffineTransform(
            translationByX: bounds.minX - drawn.minX,
            byY: bounds.minY - drawn.minY
        )
        for path in paths { annotation.remove(path) }
        for path in paths {
            path.transform(using: shift)
            annotation.add(path)
        }
        annotation.bounds = drawn
    }

    /// Minimum distance from `point` to the path's stroked centerline.
    static func pathDistance(_ path: NSBezierPath, to point: CGPoint) -> CGFloat {
        let flat = path.flattened
        var best = CGFloat.greatestFiniteMagnitude
        var last = CGPoint.zero
        var start = CGPoint.zero
        var hasPoint = false
        var points = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<flat.elementCount {
            switch flat.element(at: i, associatedPoints: &points) {
            case .moveTo:
                last = points[0]; start = points[0]
                if !hasPoint { best = min(best, point.distance(to: last)) }
                hasPoint = true
            case .lineTo:
                best = min(best, segmentDistance(point, last, points[0]))
                last = points[0]
            case .closePath:
                best = min(best, segmentDistance(point, last, start))
                last = start
            default:
                best = min(best, segmentDistance(point, last, points[2]))
                last = points[2]
            }
        }
        return best
    }

    private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else { return p.distance(to: a) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return p.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    // MARK: - Ink

    /// `paths` are in page space; they are re-based to the annotation's bounds
    /// origin before being attached (PDFKit treats attached paths as
    /// bounds-relative).
    static func makeInk(paths: [NSBezierPath], color: NSColor, width: CGFloat) -> PDFAnnotation? {
        guard !paths.isEmpty else { return nil }
        var union = paths[0].bounds
        for p in paths.dropFirst() { union = union.union(p.bounds) }
        let pad = width + 4
        let bounds = union.insetBy(dx: -pad, dy: -pad)
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.color = color
        let border = PDFBorder()
        border.lineWidth = width
        annotation.border = border
        annotation.userName = authorName
        annotation.shouldPrint = true
        let rebase = AffineTransform(translationByX: -bounds.minX, byY: -bounds.minY)
        for p in paths {
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.transform(using: rebase)
            annotation.add(p)
        }
        return annotation
    }

    /// Freehand stroke from raw drag points (page space), smoothed.
    /// `detail` is the jitter epsilon in page points — pass ~1.2/zoom so
    /// deep-zoom drawing keeps its fine structure.
    static func makeStroke(points: [CGPoint], color: NSColor, width: CGFloat, detail: CGFloat = 1.2) -> PDFAnnotation? {
        let cleaned = NSBezierPath.decimate(points, epsilon: max(detail, 0.02))
        guard let first = cleaned.first else { return nil }

        var travel: CGFloat = 0
        var previous = first
        for p in cleaned.dropFirst() {
            travel += previous.distance(to: p)
            previous = p
        }
        if travel < detail * 1.25 {
            // A tap. Zero-length capped strokes render as pixelated blobs in
            // PDFKit — emit a crisp solid disc instead (a circle stroked at
            // twice its radius fills itself completely).
            let diameter = max(width * 2.2, 3)
            let radius = diameter / 4
            let dot = NSBezierPath(ovalIn: CGRect(
                x: first.x - radius, y: first.y - radius,
                width: radius * 2, height: radius * 2
            ))
            dot.lineWidth = diameter / 2
            return makeInk(paths: [dot], color: color, width: diameter / 2)
        }

        let path = NSBezierPath.smoothPath(through: cleaned)
        path.lineWidth = width
        return makeInk(paths: [path], color: color, width: width)
    }

    // MARK: - Shapes

    static func makeShape(tool: Tool, from a: CGPoint, to b: CGPoint, color: NSColor, width: CGFloat) -> PDFAnnotation? {
        switch tool {
        case .rect, .ellipse:
            let rect = CGRect(corner: a, corner: b)
            guard rect.width > 1, rect.height > 1 else { return nil }
            let annotation = PDFAnnotation(
                bounds: rect.insetBy(dx: -width, dy: -width),
                forType: tool == .rect ? .square : .circle,
                withProperties: nil
            )
            annotation.color = color
            annotation.interiorColor = nil
            let border = PDFBorder()
            border.lineWidth = width
            annotation.border = border
            annotation.userName = authorName
            annotation.shouldPrint = true
            return annotation
        case .triangle:
            let rect = CGRect(corner: a, corner: b)
            guard rect.width > 1, rect.height > 1 else { return nil }
            let path = NSBezierPath()
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.line(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.line(to: CGPoint(x: rect.minX, y: rect.minY))
            path.close()
            path.lineWidth = width
            return makeInk(paths: [path], color: color, width: width)
        case .line:
            guard a.distance(to: b) > 1.2 else { return nil }
            let path = NSBezierPath()
            path.move(to: a)
            path.line(to: b)
            path.lineWidth = width
            return makeInk(paths: [path], color: color, width: width)
        case .arrow, .doubleArrow:
            guard a.distance(to: b) > 1.2 else { return nil }
            let path = NSBezierPath()
            path.move(to: a)
            path.line(to: b)
            let angle = atan2(b.y - a.y, b.x - a.x)
            let headLength = max(9, width * 4.5)
            let spread: CGFloat = .pi / 7
            // Open-V arrowhead at b.
            for side in [angle + .pi - spread, angle + .pi + spread] {
                path.move(to: b)
                path.line(to: CGPoint(x: b.x + cos(side) * headLength, y: b.y + sin(side) * headLength))
            }
            if tool == .doubleArrow {
                for side in [angle - spread, angle + spread] {
                    path.move(to: a)
                    path.line(to: CGPoint(x: a.x + cos(side) * headLength, y: a.y + sin(side) * headLength))
                }
            }
            path.lineWidth = width
            return makeInk(paths: [path], color: color, width: width)
        default:
            return nil
        }
    }

    // MARK: - Text

    static func makeFreeText(_ text: String, near point: CGPoint, on page: PDFPage, fontSize: CGFloat, color: NSColor) -> PDFAnnotation {
        let font = NSFont.systemFont(ofSize: fontSize)
        let size = TextMeasure.size(of: text, font: font, maxWidth: 420)
        var bounds = CGRect(
            x: point.x,
            y: point.y - size.height,
            width: max(size.width, 24),
            height: size.height
        )
        // Keep on the page.
        let pageBounds = page.bounds(for: .cropBox)
        if bounds.maxX > pageBounds.maxX { bounds.origin.x = pageBounds.maxX - bounds.width }
        if bounds.minY < pageBounds.minY { bounds.origin.y = pageBounds.minY }
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = font
        annotation.fontColor = color
        // NOT NSColor.clear — that's black at alpha 0, and PDFKit's appearance
        // generation can drop the alpha, rendering a solid black box.
        annotation.color = NSColor.white.withAlphaComponent(0.001)
        annotation.userName = authorName
        annotation.shouldPrint = true
        return annotation
    }

    /// Recomputes a free-text annotation's bounds after its contents changed,
    /// keeping the top-left corner fixed and staying on the page.
    static func refitFreeText(_ annotation: PDFAnnotation) {
        let font = annotation.font ?? NSFont.systemFont(ofSize: 13)
        let size = TextMeasure.size(of: annotation.contents ?? "", font: font, maxWidth: 420)
        let old = annotation.bounds
        var bounds = CGRect(
            x: old.minX,
            y: old.maxY - size.height,
            width: max(size.width, 24),
            height: size.height
        )
        if let pageBounds = annotation.page?.bounds(for: .cropBox) {
            if bounds.maxX > pageBounds.maxX { bounds.origin.x = pageBounds.maxX - bounds.width }
            if bounds.minY < pageBounds.minY { bounds.origin.y = pageBounds.minY }
        }
        annotation.bounds = bounds
    }

    // MARK: - Stamps, signatures & typeset math

    /// Rotates page-space paths by -pageRotation about `pivot`, so placed
    /// content reads upright on rotated pages (PDFKit rotates the whole page,
    /// annotations included, for display).
    static func compensateRotation(_ paths: [NSBezierPath], pageRotation: Int, about pivot: CGPoint) {
        let turns = ((pageRotation % 360) + 360) % 360
        guard turns != 0 else { return }
        var transform = AffineTransform(translationByX: pivot.x, byY: pivot.y)
        transform.rotate(byDegrees: CGFloat(turns))
        transform.translate(x: -pivot.x, y: -pivot.y)
        for path in paths { path.transform(using: transform) }
    }

    /// Places a stamp centered at `center` (page space). Stamp paths are authored
    /// y-down, so flip while mapping into the page.
    static func makeStamp(_ stamp: Stamp, centeredAt center: CGPoint, width: CGFloat, color: NSColor, strokeWidth: CGFloat, pageRotation: Int = 0) -> PDFAnnotation? {
        let height = width / max(stamp.aspect, 0.05)
        let local = CGRect(x: 0, y: 0, width: width, height: height)
        let cgPath = stamp.build(local)
        var flip = CGAffineTransform(translationX: center.x - width / 2, y: center.y + height / 2)
            .scaledBy(x: 1, y: -1)
        guard let placed = cgPath.copy(using: &flip) else { return nil }
        let bezier = NSBezierPath(cgPath: placed)
        bezier.lineWidth = strokeWidth
        compensateRotation([bezier], pageRotation: pageRotation, about: center)
        return makeInk(paths: [bezier], color: color, width: strokeWidth)
    }

    /// Places a saved signature centered at `center` (page space). Signature
    /// strokes are normalized [0,1] y-down.
    static func makeSignature(_ signature: Signature, centeredAt center: CGPoint, width: CGFloat, color: NSColor, pageRotation: Int = 0) -> PDFAnnotation? {
        let height = width / max(signature.aspect, 0.05)
        let origin = CGPoint(x: center.x - width / 2, y: center.y - height / 2)
        var paths: [NSBezierPath] = []
        for stroke in signature.strokes where !stroke.isEmpty {
            let points = stroke.map { p in
                CGPoint(x: origin.x + p.x * width, y: origin.y + (1 - p.y) * height)
            }
            let path = NSBezierPath.smoothPath(through: points)
            path.lineWidth = 1.6
            paths.append(path)
        }
        compensateRotation(paths, pageRotation: pageRotation, about: center)
        return makeInk(paths: paths, color: color, width: 1.6)
    }

    /// Plain text as upright vector ink (for rotated pages where FreeText
    /// would display sideways). Anchored at its top-left corner.
    static func makePlainTextInk(_ text: String, fontSize: CGFloat, topLeftAt topLeft: CGPoint, color: NSColor, pageRotation: Int = 0) -> PDFAnnotation? {
        guard let output = TypesetMath.layoutPlain(text, fontSize: fontSize), !output.isEmpty else {
            return nil
        }
        let paths = TypesetMath.inkPaths(for: output)
        guard !paths.isEmpty else { return nil }
        let shift = AffineTransform(translationByX: topLeft.x, byY: topLeft.y - output.ascent)
        for path in paths { path.transform(using: shift) }
        compensateRotation(paths, pageRotation: pageRotation, about: topLeft)
        return makeInk(paths: paths, color: color, width: paths.first?.lineWidth ?? 0.42)
    }

    /// Typesets casual/LaTeX math and places it as solid vector ink centered
    /// at `center` (page space, already y-up).
    static func makeTypesetMath(_ source: String, fontSize: CGFloat, centeredAt center: CGPoint, color: NSColor, pageRotation: Int = 0) -> PDFAnnotation? {
        guard let (output, _) = TypesetMath.layout(source, fontSize: fontSize), !output.isEmpty else {
            return nil
        }
        // Hatch density must scale with glyph size — fixed-width fill turns
        // small letters into solid blobs and leaves large ones striped.
        let hatchWidth = min(max(fontSize * 0.024, 0.26), 0.55)
        let paths = TypesetMath.inkPaths(for: output, strokeWidth: hatchWidth)
        guard !paths.isEmpty else { return nil }
        let origin = CGPoint(
            x: center.x - output.width / 2,
            y: center.y - (output.ascent - output.descent) / 2
        )
        let shift = AffineTransform(translationByX: origin.x, byY: origin.y)
        for path in paths { path.transform(using: shift) }
        compensateRotation(paths, pageRotation: pageRotation, about: center)
        let strokeWidth = paths.first?.lineWidth ?? 0.42
        return makeInk(paths: paths, color: color, width: strokeWidth)
    }

    // MARK: - Text-selection highlight

    /// One highlight markup annotation per selected line.
    static func makeHighlights(for selection: PDFSelection, color: NSColor) -> [(PDFPage, PDFAnnotation)] {
        var out: [(PDFPage, PDFAnnotation)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 1, bounds.height > 1 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = color
                annotation.userName = authorName
                annotation.shouldPrint = true
                annotation.quadrilateralPoints = [
                    NSValue(point: CGPoint(x: 0, y: bounds.height)),
                    NSValue(point: CGPoint(x: bounds.width, y: bounds.height)),
                    NSValue(point: .zero),
                    NSValue(point: CGPoint(x: bounds.width, y: 0)),
                ]
                out.append((page, annotation))
            }
        }
        return out
    }
}
