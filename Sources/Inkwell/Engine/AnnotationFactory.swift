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
    static func makeStroke(points: [CGPoint], color: NSColor, width: CGFloat) -> PDFAnnotation? {
        let cleaned = NSBezierPath.decimate(points)
        guard !cleaned.isEmpty else { return nil }
        let path = NSBezierPath.smoothPath(through: cleaned)
        path.lineWidth = width
        return makeInk(paths: [path], color: color, width: width)
    }

    // MARK: - Shapes

    static func makeShape(tool: Tool, from a: CGPoint, to b: CGPoint, color: NSColor, width: CGFloat) -> PDFAnnotation? {
        switch tool {
        case .rect, .ellipse:
            let rect = CGRect(corner: a, corner: b)
            guard rect.width > 2, rect.height > 2 else { return nil }
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
        case .line:
            guard a.distance(to: b) > 3 else { return nil }
            let path = NSBezierPath()
            path.move(to: a)
            path.line(to: b)
            path.lineWidth = width
            return makeInk(paths: [path], color: color, width: width)
        case .arrow:
            guard a.distance(to: b) > 3 else { return nil }
            let path = NSBezierPath()
            path.move(to: a)
            path.line(to: b)
            // Open-V arrowhead at b.
            let angle = atan2(b.y - a.y, b.x - a.x)
            let headLength = max(9, width * 4.5)
            let spread: CGFloat = .pi / 7
            for side in [angle + .pi - spread, angle + .pi + spread] {
                path.move(to: b)
                path.line(to: CGPoint(x: b.x + cos(side) * headLength, y: b.y + sin(side) * headLength))
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
        let paths = TypesetMath.inkPaths(for: output)
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
