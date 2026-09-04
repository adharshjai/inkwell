import AppKit
import PDFKit

/// PDFView subclass that turns mouse/keyboard input into annotations according
/// to the active tool. Select mode passes through to PDFKit (text selection,
/// links, form filling); every other tool owns the mouse.
@MainActor
final class ToolPDFView: PDFView {

    weak var appState: AppState?

    // Freehand / shape drag state
    private var strokePoints: [CGPoint] = []
    private var strokePage: PDFPage?
    private var shapeStart: CGPoint?
    private var lastDragPoint: CGPoint?
    private var eraserGroupOpen = false

    // Annotation move / marquee / resize state (select tool)
    private var dragAnnotations: [PDFAnnotation] = []
    private var dragPage: PDFPage?
    private var dragLast: CGPoint = .zero
    private var dragTotal: CGPoint = .zero
    private var marqueeStartView: CGPoint?
    private var marqueePage: PDFPage?
    private var marqueeAdditive = false
    private var pendingShiftToggle: PDFAnnotation?
    private var resizeTargets: [(annotation: PDFAnnotation, original: Annotations.Geometry)] = []
    private var resizeUnionOriginal: CGRect = .zero
    private var resizeCorner: Int?

    // Inline text editing
    private var textEditor: InkwellTextView?
    private var editingAnnotation: PDFAnnotation?
    private var editingPage: PDFPage?
    private var editingIsNew = false
    private var editingOldContents = ""
    private var editingOldBounds: CGRect = .zero

    // Quasimode ("hold a key, glide") state
    private var quasiPoints: [CGPoint] = []
    private var quasiPage: PDFPage?
    private var quasiSmoothed: CGPoint?
    private var wireVertices: [CGPoint] = []
    private var wirePage: PDFPage?
    private var quasiStartTime: TimeInterval = 0
    private var quasiDidAct = false
    private var quasiTrackingArea: NSTrackingArea?

    private let selectionOverlay = SelectionOverlayView()
    private var overlayObservers: [NSObjectProtocol] = []
    private var observedClipView: NSClipView?
    private var isAutoExtending = false

    /// The inline editor's private typing-undo stack, when a session is open.
    var editingUndoManager: UndoManager? {
        textEditor?.undoManager
    }

    func closeEraserGroupIfOpen() {
        if eraserGroupOpen {
            appState?.undoManager?.endUndoGrouping()
            eraserGroupOpen = false
        }
    }

    /// ⌘Z while a quasimode key is held: undo *within* the gesture —
    /// pop the last wire vertex, or scrap the in-progress stroke.
    func handleQuasimodeUndo() -> Bool {
        guard let appState, let mode = appState.activeQuasimode else { return false }
        switch mode {
        case .wire:
            if !wireVertices.isEmpty {
                wireVertices.removeLast()
                if wireVertices.isEmpty {
                    clearPreview()
                } else if let page = wirePage, let last = wireVertices.last {
                    updateWirePreview(hover: last, on: page)
                }
            }
            return true
        case .ink, .shape:
            quasiPoints = []
            quasiSmoothed = nil
            clearPreview()
            return true
        case .erase:
            return false
        }
    }

    // MARK: - Setup

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        selectionOverlay.autoresizingMask = [.width, .height]
        selectionOverlay.frame = bounds
        selectionOverlay.crispContentDraw = { [weak self] ctx in
            self?.drawCrispAnnotations(in: ctx)
        }
        addSubview(selectionOverlay)

        overlayObservers.append(NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.commitTextEditing()
                self?.refreshSelectionOverlay()
                self?.appState?.syncZoom()
                self?.scheduleRenderNudge()
            }
        })
    }

    deinit {
        for token in overlayObservers { NotificationCenter.default.removeObserver(token) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        ensureScrollObserver()
    }

    /// One re-render nudge shortly after zooming settles — never per frame,
    /// which would re-rasterize the whole page continuously during a pinch.
    /// `annotationsChanged(on:)` is the critical call: without it PDFKit keeps
    /// upscaling its cached annotation bitmaps, so ink turns pixelated after
    /// any zoom.
    private var renderNudge: DispatchWorkItem?

    private func scheduleRenderNudge() {
        renderNudge?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for page in self.visiblePages {
                self.annotationsChanged(on: page)
            }
            self.documentView?.needsDisplay = true
        }
        renderNudge = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    /// Manual zoom must stick: leaving autoScales on lets any relayout
    /// (like the endless page growing) snap the zoom back to fit.
    override func magnify(with event: NSEvent) {
        autoScales = false
        super.magnify(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = quasiTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        quasiTrackingArea = area
    }

    /// The clip view only exists once a document is installed, so this is
    /// retried from updateNSView as well. Tracks the observed instance itself —
    /// PDFKit's clip view already posts bounds notifications, so that flag
    /// can't serve as an "already registered" sentinel.
    func ensureScrollObserver() {
        guard let clipView = documentView?.enclosingScrollView?.contentView,
              clipView !== observedClipView else { return }
        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        overlayObservers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.commitTextEditing()
                self?.refreshSelectionOverlay()
                self?.autoExtendIfNeeded()
                // Freshly scrolled-in tiles can carry stale low-res annotation
                // caches too — settle-invalidate just like after a zoom.
                self?.scheduleRenderNudge()
            }
        })
    }

    /// The "infinite page": in notes mode on letter paper, scrolling near the
    /// bottom quietly grows the document with another sheet. The canvas paper
    /// is one giant page instead — it grows by zooming, not appending.
    private func autoExtendIfNeeded() {
        guard let appState, appState.notesMode, !isAutoExtending,
              appState.isNotesDocument,
              !appState.notesPaper.isCanvas,
              let doc = document, doc === appState.document,
              let docView = documentView else { return }
        let visible = docView.visibleRect
        let height = docView.frame.height
        guard height > 0 else { return }
        let nearEnd = docView.isFlipped
            ? visible.maxY > height - 60
            : visible.minY < 60
        guard nearEnd else { return }
        isAutoExtending = true
        if let page = PDFDocument(data: appState.notesPaper.pageData())?.page(at: 0) {
            doc.insert(page, at: doc.pageCount)
            appState.markDirty()
            appState.bumpVersion()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.isAutoExtending = false
        }
    }

    /// Path-accurate manual hit test (PDFKit's annotation(at:) skips hidden
    /// annotations, and bounds-only testing made the mostly-empty bounding
    /// box of a long stroke swallow clicks — which is why ⇧-drag marquee
    /// "sometimes didn't work"). Generous ~8 screen px reach for selection.
    private func annotationHit(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        let tolerance = max(8 / max(scaleFactor, 0.25), 2.0)
        return Annotations.preciseHit(at: point, on: page, tolerance: tolerance)
    }

    // MARK: - Coordinate helpers

    private func pagePoint(for event: NSEvent) -> (PDFPage, CGPoint)? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return nil }
        var point = convert(viewPoint, to: page)
        let box = page.bounds(for: .cropBox)
        point.x = min(max(point.x, box.minX), box.maxX)
        point.y = min(max(point.y, box.minY), box.maxY)
        return (page, point)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let appState else { return super.mouseDown(with: event) }

        // Every click claims keyboard focus so Delete and the hold-to-draw
        // keys always work right after interacting with the canvas.
        if window?.firstResponder !== self, textEditor == nil {
            window?.makeFirstResponder(self)
        }

        // Any click while editing text commits the edit first.
        if textEditor != nil { commitTextEditing() }

        guard let (page, point) = pagePoint(for: event) else { return super.mouseDown(with: event) }

        if let mode = appState.activeQuasimode {
            handleQuasiClick(mode, at: point, on: page, event: event)
            return
        }

        if let placement = appState.pendingPlacement {
            place(placement, at: point, on: page, keepArmed: event.modifierFlags.contains(.shift))
            return
        }

        switch appState.tool {
        case .select:
            // 1. Corner handle of the selection's union box → group resize.
            if let union = resizableSelectionUnion(),
               appState.selectedAnnotationPage === page,
               let corner = handleIndex(at: point, bounds: union) {
                resizeTargets = appState.selectedAnnotations.map {
                    (annotation: $0, original: Annotations.Geometry(of: $0))
                }
                resizeUnionOriginal = union
                resizeCorner = corner
                return
            }
            // 2. Click on an annotation → select (⇧ toggles) and start moving.
            if let hit = annotationHit(at: point, on: page) {
                if event.clickCount == 2, hit.type == "FreeText" {
                    beginEditingText(annotation: hit, page: page, isNew: false)
                    return
                }
                if event.modifierFlags.contains(.shift) {
                    // Defer: release in place ⇒ toggle this item; drag ⇒
                    // additive marquee that starts here.
                    pendingShiftToggle = hit
                    marqueeStartView = convert(event.locationInWindow, from: nil)
                    marqueePage = page
                    marqueeAdditive = true
                    return
                }
                if !appState.selectedAnnotations.contains(where: { $0 === hit }) || appState.selectedAnnotationPage !== page {
                    appState.selectedAnnotations = [hit]
                    appState.selectedAnnotationPage = page
                }
                dragAnnotations = appState.selectedAnnotations
                dragPage = page
                dragLast = point
                dragTotal = .zero
                refreshSelectionOverlay()
            } else {
                // 3. Empty space: marquee box-select (default in notes;
                //    ⇧- or ⌘-drag anywhere). ⇧ keeps the current selection
                //    and adds what the box sweeps up.
                let additive = event.modifierFlags.contains(.shift)
                if !additive {
                    appState.selectedAnnotations = []
                    appState.selectedAnnotationPage = nil
                    refreshSelectionOverlay()
                }
                if appState.notesMode || additive || event.modifierFlags.contains(.command) {
                    marqueeStartView = convert(event.locationInWindow, from: nil)
                    marqueePage = page
                    marqueeAdditive = additive
                } else {
                    super.mouseDown(with: event)
                }
            }
        case .pen, .highlighter:
            strokePage = page
            strokePoints = [point]
        case .eraser:
            eraseAnnotation(at: point, on: page)
        case .fill:
            let window = convert(bounds, to: page)
            if BucketFill.fill(at: point, on: page, window: window, state: appState) {
                Haptics.thunk()
                appState.flash("Filled", seconds: 0.9)
            }
        case .text:
            // Font size tracks zoom: what you type reads the same size on
            // screen whether you're at 30% or 800%.
            let dynamicSize = min(max(appState.fontSize / max(scaleFactor, 0.05), 5), 96)
            let annotation = Annotations.makeFreeText(
                "", near: point, on: page,
                fontSize: dynamicSize, color: appState.inkColor
            )
            beginEditingText(annotation: annotation, page: page, isNew: true)
        case .line, .arrow, .doubleArrow, .rect, .ellipse, .triangle:
            strokePage = page
            shapeStart = point
            lastDragPoint = point
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let appState else { return super.mouseDragged(with: event) }

        if let mode = appState.activeQuasimode {
            handleQuasiMotion(mode, event: event)
            return
        }

        switch appState.tool {
        case .select:
            if !resizeTargets.isEmpty, let corner = resizeCorner,
               let page = appState.selectedAnnotationPage,
               let (eventPage, point) = pagePoint(for: event), eventPage === page {
                let newUnion = boundsForResize(original: resizeUnionOriginal, corner: corner, to: point)
                let sx = newUnion.width / max(resizeUnionOriginal.width, 0.01)
                let sy = newUnion.height / max(resizeUnionOriginal.height, 0.01)
                for target in resizeTargets {
                    let o = target.original.bounds
                    let memberBounds = CGRect(
                        x: newUnion.minX + (o.minX - resizeUnionOriginal.minX) * sx,
                        y: newUnion.minY + (o.minY - resizeUnionOriginal.minY) * sy,
                        width: o.width * sx,
                        height: o.height * sy
                    )
                    Annotations.applyScale(target.annotation, from: target.original, to: memberBounds)
                }
                refreshSelectionOverlay()
                return
            }
            if let start = marqueeStartView {
                let current = convert(event.locationInWindow, from: nil)
                selectionOverlay.marqueeRect = CGRect(corner: start, corner: current)
                return
            }
            guard !dragAnnotations.isEmpty, let page = dragPage,
                  let (eventPage, point) = pagePoint(for: event), eventPage === page else {
                return super.mouseDragged(with: event)
            }
            let delta = point - dragLast
            guard abs(delta.x) + abs(delta.y) > 0.05 else { return }
            for annotation in dragAnnotations {
                Annotations.translate(annotation, by: delta)
            }
            dragLast = point
            dragTotal = dragTotal + delta
            refreshSelectionOverlay()
        case .pen, .highlighter:
            guard let page = strokePage,
                  let (eventPage, point) = pagePoint(for: event), eventPage === page else { return }
            // ~1 screen pixel, in page points — a fixed page-space gate
            // swallows most of the stroke when zoomed far in.
            if let last = strokePoints.last,
               last.distance(to: point) < 1.0 / max(scaleFactor, 0.25) { return }
            strokePoints.append(point)
            updateStrokePreview(on: page)
        case .eraser:
            guard let (page, point) = pagePoint(for: event) else { return }
            eraseAnnotation(at: point, on: page)
        case .fill:
            break
        case .line, .arrow, .doubleArrow, .rect, .ellipse, .triangle:
            guard let start = shapeStart, let page = strokePage,
                  let (eventPage, rawPoint) = pagePoint(for: event), eventPage === page else { return }
            let point = constrained(rawPoint, from: start, tool: appState.tool, shift: event.modifierFlags.contains(.shift))
            lastDragPoint = point
            updateShapePreview(from: start, to: point, on: page)
        case .text:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let appState else { return super.mouseUp(with: event) }

        if appState.activeQuasimode != nil { return }

        switch appState.tool {
        case .select:
            if !resizeTargets.isEmpty {
                appState.undoManager?.beginUndoGrouping()
                for target in resizeTargets {
                    Annotations.registerResize(of: target.annotation, before: target.original, state: appState)
                }
                appState.undoManager?.endUndoGrouping()
                Haptics.snap()
                resizeTargets = []
                resizeCorner = nil
                refreshSelectionOverlay()
                return
            }
            if let start = marqueeStartView {
                finishMarquee(from: start, with: event)
                return
            }
            if !dragAnnotations.isEmpty {
                Annotations.registerGroupMove(of: dragAnnotations, totalDelta: dragTotal, state: appState)
                dragAnnotations = []
                dragPage = nil
            } else {
                super.mouseUp(with: event)
            }
        case .pen, .highlighter:
            clearPreview()
            // A plain click never commits ink — require a real stroke.
            let travel = zip(strokePoints, strokePoints.dropFirst())
                .reduce(CGFloat(0)) { $0 + $1.0.distance(to: $1.1) }
            // A tap (count == 1) is a deliberate dot; travel gate is in screen
            // terms so deep-zoom microstrokes aren't discarded.
            if let page = strokePage, !strokePoints.isEmpty,
               strokePoints.count == 1 || travel > 2.0 / max(scaleFactor, 0.25),
               let annotation = Annotations.makeStroke(
                   points: strokePoints,
                   color: appState.activeStrokeColor,
                   width: appState.activeStrokeWidth,
                   detail: 1.2 / max(scaleFactor, 0.25)
               ) {
                Annotations.add(annotation, to: page, state: appState,
                                actionName: appState.tool == .pen ? "Draw" : "Highlight")
                Haptics.tick()
            }
            strokePoints = []
            strokePage = nil
        case .line, .arrow, .doubleArrow, .rect, .ellipse, .triangle:
            clearPreview()
            if let start = shapeStart, let page = strokePage {
                // Use the release point when it's on the origin page; otherwise
                // fall back to the last valid drag point so the shape isn't lost.
                var point = lastDragPoint ?? start
                if let (eventPage, rawPoint) = pagePoint(for: event), eventPage === page {
                    point = constrained(rawPoint, from: start, tool: appState.tool, shift: event.modifierFlags.contains(.shift))
                }
                if let annotation = Annotations.makeShape(
                    tool: appState.tool, from: start, to: point,
                    color: appState.inkColor, width: appState.inkWidth
                ) {
                    Annotations.add(annotation, to: page, state: appState, actionName: appState.tool.label)
                    Haptics.tick()
                }
            }
            shapeStart = nil
            strokePage = nil
            lastDragPoint = nil
        case .eraser:
            if eraserGroupOpen {
                appState.undoManager?.endUndoGrouping()
                eraserGroupOpen = false
            }
        case .fill, .text:
            break
        }
    }

    // MARK: - Previews (drawn on the overlay — never touch the PDF while
    // dragging, so pages aren't re-rendered dozens of times per second)

    private func showPreview(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
        selectionOverlay.previewPath = path
        selectionOverlay.previewColor = color
        selectionOverlay.previewLineWidth = max(width * scaleFactor, 0.75)
    }

    private func viewPath(through pagePoints: [CGPoint], on page: PDFPage) -> NSBezierPath? {
        guard let first = pagePoints.first else { return nil }
        let path = NSBezierPath()
        path.move(to: convert(first, from: page))
        for p in pagePoints.dropFirst() { path.line(to: convert(p, from: page)) }
        return path
    }

    private func updateStrokePreview(on page: PDFPage) {
        guard let appState, let path = viewPath(through: strokePoints, on: page) else { return }
        showPreview(path, color: appState.activeStrokeColor, width: appState.activeStrokeWidth)
    }

    private func updateShapePreview(from a: CGPoint, to b: CGPoint, on page: PDFPage) {
        guard let appState else { return }
        let color = appState.inkColor.withAlphaComponent(0.75)
        let width = appState.inkWidth
        switch appState.tool {
        case .rect, .ellipse, .triangle:
            let viewRect = convert(CGRect(corner: a, corner: b), from: page)
            let path: NSBezierPath
            switch appState.tool {
            case .rect: path = NSBezierPath(rect: viewRect)
            case .ellipse: path = NSBezierPath(ovalIn: viewRect)
            default:
                path = NSBezierPath()
                path.move(to: CGPoint(x: viewRect.midX, y: viewRect.maxY))
                path.line(to: CGPoint(x: viewRect.maxX, y: viewRect.minY))
                path.line(to: CGPoint(x: viewRect.minX, y: viewRect.minY))
                path.close()
            }
            showPreview(path, color: color, width: width)
        case .line, .arrow, .doubleArrow:
            let va = convert(a, from: page), vb = convert(b, from: page)
            let path = NSBezierPath()
            path.move(to: va)
            path.line(to: vb)
            let angle = atan2(vb.y - va.y, vb.x - va.x)
            let head = max(9, width * 4.5) * scaleFactor
            let spread: CGFloat = .pi / 7
            if appState.tool != .line {
                for side in [angle + .pi - spread, angle + .pi + spread] {
                    path.move(to: vb)
                    path.line(to: CGPoint(x: vb.x + cos(side) * head, y: vb.y + sin(side) * head))
                }
            }
            if appState.tool == .doubleArrow {
                for side in [angle - spread, angle + spread] {
                    path.move(to: va)
                    path.line(to: CGPoint(x: va.x + cos(side) * head, y: va.y + sin(side) * head))
                }
            }
            showPreview(path, color: color, width: width)
        default:
            break
        }
    }

    private func clearPreview() {
        selectionOverlay.previewPath = nil
    }

    private func constrained(_ point: CGPoint, from start: CGPoint, tool: Tool, shift: Bool) -> CGPoint {
        guard shift else { return point }
        switch tool {
        case .line, .arrow, .doubleArrow:
            let delta = point - start
            let angle = atan2(delta.y, delta.x)
            let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
            let length = start.distance(to: point)
            return CGPoint(x: start.x + cos(snapped) * length, y: start.y + sin(snapped) * length)
        case .rect, .ellipse, .triangle:
            let dx = point.x - start.x, dy = point.y - start.y
            let side = max(abs(dx), abs(dy))
            return CGPoint(
                x: start.x + (dx < 0 ? -side : side),
                y: start.y + (dy < 0 ? -side : side)
            )
        default:
            return point
        }
    }

    // MARK: - Eraser

    @discardableResult
    private func eraseAnnotation(at point: CGPoint, on page: PDFPage) -> Bool {
        guard let appState else { return false }
        // Precise: you must touch the stroke itself, not just its bounding
        // box. Reach is the user's eraser size, in screen points.
        let tolerance = max(appState.eraserSize / max(scaleFactor, 0.25), 0.5)
        guard let hit = Annotations.preciseHit(at: point, on: page, tolerance: tolerance) else { return false }
        // One swipe = one undo group, opened lazily on the first hit.
        if !eraserGroupOpen {
            appState.undoManager?.beginUndoGrouping()
            eraserGroupOpen = true
        }
        Annotations.remove(hit, from: page, state: appState, actionName: "Erase")
        Haptics.tick()
        return true
    }

    // MARK: - Quasimodes (hold a key, glide on the trackpad — no clicking)

    func beginQuasimode(_ mode: Quasimode) {
        guard let appState, appState.hasDocument, appState.activeQuasimode == nil else { return }
        commitTextEditing()
        // Abort any in-progress tool drag so state can't wedge — an eraser
        // undo group left open would silently disable ⌘Z from then on.
        clearPreview()
        strokePoints = []
        strokePage = nil
        shapeStart = nil
        lastDragPoint = nil
        dragAnnotations = []
        dragPage = nil
        resizeTargets = []
        resizeCorner = nil
        marqueeStartView = nil
        marqueePage = nil
        pendingShiftToggle = nil
        selectionOverlay.marqueeRect = nil
        closeEraserGroupIfOpen()
        appState.activeQuasimode = mode
        quasiPoints = []
        quasiPage = nil
        quasiSmoothed = nil
        wireVertices = []
        wirePage = nil
        quasiDidAct = false
        quasiStartTime = Date.timeIntervalSinceReferenceDate
        NSCursor.crosshair.set()
    }

    func endQuasimode(cancelled: Bool = false) {
        guard let appState, let mode = appState.activeQuasimode else { return }
        let elapsed = Date.timeIntervalSinceReferenceDate - quasiStartTime

        if cancelled {
            clearPreview()
        } else {
            switch mode {
            case .ink:
                commitQuasiStroke(beautify: false)
            case .shape:
                commitQuasiStroke(beautify: true)
            case .wire:
                commitWire()
            case .erase:
                break
            }
        }
        if eraserGroupOpen {
            appState.undoManager?.endUndoGrouping()
            eraserGroupOpen = false
        }

        // A quick F tap dots the i (and the decimal): hover and tap
        // mid-handwriting without leaving the glide flow. Fires whenever the
        // short press didn't commit a stroke, so cursor jitter can't swallow
        // the dot. Other modes teach their gesture; E keeps tap-to-switch.
        if !cancelled, mode == .ink, elapsed < 0.35 {
            let travel = zip(quasiPoints, quasiPoints.dropFirst())
                .reduce(CGFloat(0)) { $0 + $1.0.distance(to: $1.1) }
            if quasiPoints.count < 2 || travel <= 2.5 {
                placeDotAtCursor()
            }
        } else if !cancelled, !quasiDidAct, elapsed < 0.35 {
            switch mode {
            case .ink: break
            case .shape: appState.flash("Hold S and sketch roughly — the shape snaps clean when you let go")
            case .wire: appState.flash("Hold W and click corner points to route a clean line")
            case .erase:
                appState.tool = .eraser
                appState.flash("Eraser", seconds: 0.9)
            }
        }

        appState.activeQuasimode = nil
        quasiPoints = []
        quasiPage = nil
        quasiSmoothed = nil
        wireVertices = []
        wirePage = nil
    }

    override func mouseMoved(with event: NSEvent) {
        guard let appState, let mode = appState.activeQuasimode else {
            return super.mouseMoved(with: event)
        }
        handleQuasiMotion(mode, event: event)
    }

    private func handleQuasiMotion(_ mode: Quasimode, event: NSEvent) {
        guard let (page, point) = pagePoint(for: event) else { return }
        switch mode {
        case .ink, .shape:
            appendQuasiPoint(point, on: page)
        case .erase:
            if eraseAnnotation(at: point, on: page) { quasiDidAct = true }
        case .wire:
            updateWirePreview(hover: point, on: page)
        }
    }

    private func handleQuasiClick(_ mode: Quasimode, at point: CGPoint, on page: PDFPage, event: NSEvent) {
        guard let appState else { return }
        switch mode {
        case .ink, .shape:
            appendQuasiPoint(point, on: page)
        case .erase:
            if eraseAnnotation(at: point, on: page) { quasiDidAct = true }
        case .wire:
            if wirePage == nil { wirePage = page }
            guard page === wirePage else { return }
            var vertex = point
            if event.modifierFlags.contains(.shift), let last = wireVertices.last {
                vertex = constrained(vertex, from: last, tool: .line, shift: true)
            } else {
                vertex = appState.snapIfEnabled(vertex)
            }
            wireVertices.append(vertex)
            quasiDidAct = true
            Haptics.tick()
            updateWirePreview(hover: vertex, on: page)
        }
    }

    /// Exponentially smoothed point collection — tuned so trackpad jitter
    /// disappears but deliberate curves survive.
    private func appendQuasiPoint(_ point: CGPoint, on page: PDFPage) {
        if quasiPage == nil { quasiPage = page }
        guard page === quasiPage else { return }
        let alpha: CGFloat = 0.42
        let smoothed = quasiSmoothed.map {
            CGPoint(x: $0.x + alpha * (point.x - $0.x), y: $0.y + alpha * (point.y - $0.y))
        } ?? point
        quasiSmoothed = smoothed
        if let last = quasiPoints.last, last.distance(to: smoothed) < 0.8 { return }
        quasiPoints.append(smoothed)
        if quasiPoints.count > 3 { quasiDidAct = true }
        updateQuasiPreview(on: page)
    }

    private func updateQuasiPreview(on page: PDFPage) {
        guard let appState, quasiPoints.count > 1,
              let path = viewPath(through: quasiPoints, on: page) else { return }
        showPreview(path, color: appState.inkColor, width: appState.inkWidth)
    }

    private func updateWirePreview(hover: CGPoint, on page: PDFPage) {
        guard let appState, let wirePage, page === wirePage, !wireVertices.isEmpty,
              let path = viewPath(through: wireVertices + [appState.snapIfEnabled(hover)], on: page)
        else { return }
        showPreview(path, color: appState.inkColor.withAlphaComponent(0.7), width: appState.inkWidth)
    }

    private func commitQuasiStroke(beautify: Bool) {
        clearPreview()
        guard let appState, let page = quasiPage, quasiPoints.count >= 2 else { return }
        let travel = zip(quasiPoints, quasiPoints.dropFirst())
            .reduce(CGFloat(0)) { $0 + $1.0.distance(to: $1.1) }
        guard travel > 2.5 else { return }

        if beautify,
           let paths = ShapeRecognizer.beautify(quasiPoints, gridSnap: { [weak appState] p in
               appState?.snapIfEnabled(p) ?? p
           }) {
            for p in paths { p.lineWidth = appState.inkWidth }
            if let annotation = Annotations.makeInk(paths: paths, color: appState.inkColor, width: appState.inkWidth) {
                Annotations.add(annotation, to: page, state: appState, actionName: "Shape")
                Haptics.snap()
            }
            return
        }

        if let annotation = Annotations.makeStroke(
            points: quasiPoints, color: appState.inkColor, width: appState.inkWidth,
            detail: 1.2 / max(scaleFactor, 0.25)
        ) {
            Annotations.add(annotation, to: page, state: appState, actionName: "Draw")
            Haptics.tick()
        }
    }

    private func commitWire() {
        clearPreview()
        guard let appState, let page = wirePage, wireVertices.count >= 2 else { return }
        let path = NSBezierPath()
        path.move(to: wireVertices[0])
        for v in wireVertices.dropFirst() { path.line(to: v) }
        path.lineWidth = appState.inkWidth
        if let annotation = Annotations.makeInk(paths: [path], color: appState.inkColor, width: appState.inkWidth) {
            Annotations.add(annotation, to: page, state: appState, actionName: "Wire")
            Haptics.snap()
        }
    }

    // MARK: - Click-to-place

    private func place(_ placement: PendingPlacement, at point: CGPoint, on page: PDFPage, keepArmed: Bool) {
        guard let appState else { return }
        let rotation = page.rotation
        // Placement sizes are "on-screen" sizes: divide by zoom so equations
        // and text land looking the size you chose, at any zoom level.
        let zoom = max(scaleFactor, 0.05)
        switch placement {
        case .typesetMath(let source, let fontSize):
            if let annotation = Annotations.makeTypesetMath(
                source, fontSize: min(max(fontSize / zoom, 5), 200), centeredAt: point,
                color: appState.inkColor, pageRotation: rotation
            ) {
                Annotations.add(annotation, to: page, state: appState, actionName: "Place Equation")
            } else {
                appState.flash("Couldn’t typeset that — check the input")
            }
        case .mathText(let text):
            let annotation = Annotations.makeFreeText(
                text, near: CGPoint(x: point.x, y: point.y), on: page,
                fontSize: min(max((appState.fontSize + 2) / zoom, 5), 96), color: appState.inkColor
            )
            Annotations.add(annotation, to: page, state: appState, actionName: "Place Equation")
        case .stamp(let stamp):
            let width: CGFloat = stamp.aspect >= 1 ? 96 : 96 * stamp.aspect
            if let annotation = Annotations.makeStamp(
                stamp, centeredAt: point, width: width,
                color: appState.inkColor, strokeWidth: max(1.2, appState.inkWidth),
                pageRotation: rotation
            ) {
                Annotations.add(annotation, to: page, state: appState, actionName: "Place \(stamp.name)")
            }
        case .signature(let signature):
            if let annotation = Annotations.makeSignature(
                signature, centeredAt: point, width: 160,
                color: appState.inkColor, pageRotation: rotation
            ) {
                Annotations.add(annotation, to: page, state: appState, actionName: "Sign")
            }
        }
        Haptics.thunk()
        if !keepArmed {
            appState.pendingPlacement = nil
        } else {
            appState.flash("Placed — shift-click places more", seconds: 1.2)
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let appState else { return super.keyDown(with: event) }

        let plainKey: Character? = {
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1
            else { return nil }
            return chars.first
        }()

        // Key autorepeat while holding a quasimode key: swallow it.
        if event.isARepeat, let mode = appState.activeQuasimode,
           let key = plainKey, String(key).uppercased() == mode.rawValue {
            return
        }

        // Quasimodes: hold F/S/W/E to draw/shape/wire/erase by gliding.
        if !event.isARepeat, appState.hasDocument, let key = plainKey {
            switch key {
            case "f": beginQuasimode(.ink); return
            case "s": beginQuasimode(.shape); return
            case "w": beginQuasimode(.wire); return
            case "e": beginQuasimode(.erase); return
            case "g":
                if appState.notesMode {
                    appState.gridSnap.toggle()
                    refreshSelectionOverlay()
                    appState.flash(appState.gridSnap ? "Grid on" : "Grid off", seconds: 1.2)
                    return
                }
            default:
                break
            }
        }

        // Esc
        if event.keyCode == 53 {
            if appState.activeQuasimode != nil {
                endQuasimode(cancelled: true)
                return
            }
            if appState.pendingPlacement != nil {
                appState.pendingPlacement = nil
                return
            }
            if !appState.selectedAnnotations.isEmpty {
                appState.selectedAnnotations = []
                appState.selectedAnnotationPage = nil
                refreshSelectionOverlay()
                return
            }
            if !appState.searchResults.isEmpty {
                appState.clearSearch()
                return
            }
            return super.keyDown(with: event)
        }

        // Delete key during a held W removes the last wire vertex.
        if event.keyCode == 51 || event.keyCode == 117,
           appState.activeQuasimode == .wire {
            _ = handleQuasimodeUndo()
            return
        }

        // Delete selected annotations
        if event.keyCode == 51 || event.keyCode == 117 {
            if !appState.selectedAnnotations.isEmpty {
                appState.deleteSelectedAnnotation()
                refreshSelectionOverlay()
                return
            }
        }

        // Arrow-key nudge for the selection
        if !appState.selectedAnnotations.isEmpty, (123...126).contains(event.keyCode) {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            var delta: CGPoint
            switch event.keyCode {
            case 123: delta = CGPoint(x: -step, y: 0)
            case 124: delta = CGPoint(x: step, y: 0)
            case 125: delta = CGPoint(x: 0, y: -step)
            default: delta = CGPoint(x: 0, y: step)
            }
            // Bounds live in unrotated page space; permute so the annotation
            // moves in the on-screen direction the user pressed.
            let rotation = (((appState.selectedAnnotationPage?.rotation ?? 0) % 360) + 360) % 360
            switch rotation {
            case 90: delta = CGPoint(x: -delta.y, y: delta.x)
            case 180: delta = CGPoint(x: -delta.x, y: -delta.y)
            case 270: delta = CGPoint(x: delta.y, y: -delta.x)
            default: break
            }
            for annotation in appState.selectedAnnotations {
                Annotations.translate(annotation, by: delta)
            }
            Annotations.registerGroupMove(of: appState.selectedAnnotations, totalDelta: delta, state: appState)
            refreshSelectionOverlay()
            return
        }

        // Single-letter tool hotkeys
        if let key = plainKey,
           let tool = Tool.allCases.first(where: { $0.hotkey == key }) {
            appState.tool = tool
            appState.flash(tool.label, seconds: 0.9)
            return
        }

        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if let appState, let mode = appState.activeQuasimode,
           let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1,
           chars.uppercased() == mode.rawValue {
            endQuasimode()
            return
        }
        super.keyUp(with: event)
    }

    private func placeDotAtCursor() {
        guard let appState, let window else { return }
        let viewPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(viewPoint),
              let page = page(for: viewPoint, nearest: true) else { return }
        var point = convert(viewPoint, to: page)
        guard page.bounds(for: .cropBox).insetBy(dx: -2, dy: -2).contains(point) else { return }
        point = appState.snapIfEnabled(point)
        if let dot = Annotations.makeStroke(
            points: [point], color: appState.inkColor, width: appState.inkWidth
        ) {
            Annotations.add(dot, to: page, state: appState, actionName: "Dot")
            Haptics.tick()
        }
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let appState, let (page, point) = pagePoint(for: event) else { return super.menu(for: event) }
        if let hit = annotationHit(at: point, on: page) {
            if !appState.selectedAnnotations.contains(where: { $0 === hit }) {
                appState.selectedAnnotations = [hit]
                appState.selectedAnnotationPage = page
            }
            refreshSelectionOverlay()
            let menu = NSMenu()
            if hit.type == "FreeText" {
                let edit = NSMenuItem(title: "Edit Text…", action: #selector(editSelectedText), keyEquivalent: "")
                edit.target = self
                menu.addItem(edit)
            }
            let count = appState.selectedAnnotations.count
            let delete = NSMenuItem(
                title: count > 1 ? "Delete \(count) Annotations" : "Delete Annotation",
                action: #selector(deleteSelected), keyEquivalent: ""
            )
            delete.target = self
            menu.addItem(delete)
            return menu
        }
        if let selection = currentSelection, !(selection.string ?? "").isEmpty {
            let menu = NSMenu()
            let highlight = NSMenuItem(title: "Highlight Selection", action: #selector(highlightSelection), keyEquivalent: "")
            highlight.target = self
            menu.addItem(highlight)
            if let defaultMenu = super.menu(for: event) {
                menu.addItem(.separator())
                for item in defaultMenu.items {
                    defaultMenu.removeItem(item)
                    menu.addItem(item)
                }
            }
            return menu
        }
        return super.menu(for: event)
    }

    @objc private func deleteSelected() {
        appState?.deleteSelectedAnnotation()
        refreshSelectionOverlay()
    }

    @objc private func highlightSelection() {
        appState?.highlightCurrentSelection()
    }

    @objc private func editSelectedText() {
        guard let annotation = appState?.selectedAnnotations.first,
              let page = appState?.selectedAnnotationPage else { return }
        beginEditingText(annotation: annotation, page: page, isNew: false)
    }

    // MARK: - Cursor

    override func cursorUpdate(with event: NSEvent) {
        guard let appState else { return super.cursorUpdate(with: event) }
        if appState.pendingPlacement != nil || (appState.tool != .select) {
            NSCursor.crosshair.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    // MARK: - Inline text editing

    func beginEditingText(annotation: PDFAnnotation, page: PDFPage, isNew: Bool) {
        commitTextEditing()
        guard let appState else { return }

        editingAnnotation = annotation
        editingPage = page
        editingIsNew = isNew
        editingOldContents = annotation.contents ?? ""
        editingOldBounds = annotation.bounds

        if !isNew {
            annotation.shouldDisplay = false
            setNeedsDisplay(bounds)
        }

        let viewRect = convert(annotation.bounds, from: page)
        let baseFont = annotation.font ?? NSFont.systemFont(ofSize: appState.fontSize)
        let scaledFont = NSFont.systemFont(ofSize: baseFont.pointSize * scaleFactor)

        let editor = InkwellTextView(frame: CGRect(
            x: viewRect.minX,
            y: viewRect.minY,
            width: max(viewRect.width, 160 * scaleFactor),
            height: max(viewRect.height, (baseFont.pointSize + 10) * scaleFactor)
        ))
        editor.string = editingOldContents
        editor.font = scaledFont
        // The editor floats over white paper — pin its colors so dark mode
        // never produces a black box with invisible text.
        editor.textColor = annotation.fontColor ?? .black
        editor.insertionPointColor = annotation.fontColor ?? .black
        editor.drawsBackground = true
        editor.backgroundColor = .white
        editor.isRichText = false
        editor.allowsUndo = true
        editor.wantsLayer = true
        editor.layer?.borderColor = NSColor.controlAccentColor.cgColor
        editor.layer?.borderWidth = 1.5
        editor.layer?.cornerRadius = 4
        editor.textContainerInset = CGSize(width: 3, height: 3)
        editor.onCommit = { [weak self, weak editor] in self?.commitTextEditing(from: editor) }
        editor.onCancel = { [weak self, weak editor] in self?.cancelTextEditing(from: editor) }
        addSubview(editor)
        window?.makeFirstResponder(editor)
        textEditor = editor
        appState.flash("Return for a new line · Esc to cancel · click away or ⌘Return to finish", seconds: 3.5)
    }

    /// Commits the active editing session, if any. Safe to call from menu
    /// actions (Save/Export/Quit) — those don't resign the editor's focus.
    func commitTextEditing() {
        commitTextEditing(from: textEditor)
    }

    /// Session-aware commit: a stale async commit from a torn-down editor
    /// (e.g. the resign-first-responder hop) must not touch the next session.
    private func commitTextEditing(from editor: InkwellTextView?) {
        guard let editor, editor === textEditor,
              let annotation = editingAnnotation,
              let page = editingPage,
              let appState else { return }
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        tearDownEditor()

        if editingIsNew {
            guard !text.isEmpty else { return }
            if page.rotation % 360 != 0 {
                // FreeText has no rotation of its own and would display sideways;
                // typeset the text as upright vector ink instead.
                let topLeft = CGPoint(x: annotation.bounds.minX, y: annotation.bounds.maxY)
                if let ink = Annotations.makePlainTextInk(
                    text, fontSize: annotation.font?.pointSize ?? appState.fontSize, topLeftAt: topLeft,
                    color: appState.inkColor, pageRotation: page.rotation
                ) {
                    Annotations.add(ink, to: page, state: appState, actionName: "Add Text")
                }
                return
            }
            annotation.contents = text
            Annotations.refitFreeText(annotation)
            Annotations.add(annotation, to: page, state: appState, actionName: "Add Text")
            // In notes, T is a one-shot: type the box, land back in select.
            if appState.notesMode, appState.tool == .text {
                appState.tool = .select
            }
        } else {
            if let page = editingPage ?? appState.selectedAnnotationPage {
                appState.applyDisplayPolicy(annotation, on: page)
            } else {
                annotation.shouldDisplay = true
            }
            if text.isEmpty {
                Annotations.remove(annotation, from: page, state: appState, actionName: "Delete Text")
            } else if text != editingOldContents {
                annotation.contents = text
                Annotations.refitFreeText(annotation)
                Annotations.registerTextEdit(
                    of: annotation, oldContents: editingOldContents,
                    oldBounds: editingOldBounds, state: appState
                )
                appState.bumpVersion()
            }
            setNeedsDisplay(bounds)
        }
    }

    private func cancelTextEditing(from editor: InkwellTextView?) {
        guard let editor, editor === textEditor, let annotation = editingAnnotation else { return }
        tearDownEditor()
        if !editingIsNew {
            if let appState, let page = editingPage {
                appState.applyDisplayPolicy(annotation, on: page)
            } else {
                annotation.shouldDisplay = true
            }
            setNeedsDisplay(bounds)
        }
    }

    private func tearDownEditor() {
        textEditor?.removeFromSuperview()
        textEditor = nil
        window?.makeFirstResponder(self)
    }

    // MARK: - Marquee & resize helpers

    private func finishMarquee(from startView: CGPoint, with event: NSEvent) {
        guard let appState else { return }
        let endView = convert(event.locationInWindow, from: nil)
        selectionOverlay.marqueeRect = nil
        marqueeStartView = nil
        guard let page = marqueePage else { return }
        marqueePage = nil
        let rect = CGRect(corner: convert(startView, to: page), corner: convert(endView, to: page))
        guard rect.width > 3 || rect.height > 3 else {
            // A ⇧-press that never became a drag: toggle the pressed item.
            if let toggle = pendingShiftToggle {
                if appState.selectedAnnotationPage === page {
                    if appState.selectedAnnotations.contains(where: { $0 === toggle }) {
                        appState.selectedAnnotations.removeAll { $0 === toggle }
                    } else {
                        appState.selectedAnnotations.append(toggle)
                    }
                } else {
                    appState.selectedAnnotations = [toggle]
                }
                appState.selectedAnnotationPage = appState.selectedAnnotations.isEmpty ? nil : page
                pendingShiftToggle = nil
            }
            refreshSelectionOverlay()
            return
        }
        pendingShiftToggle = nil
        let hits = page.annotations.filter {
            Annotations.isEditable($0) && $0.bounds.intersects(rect)
        }
        if marqueeAdditive, appState.selectedAnnotationPage === page {
            var merged = appState.selectedAnnotations
            for hit in hits where !merged.contains(where: { $0 === hit }) {
                merged.append(hit)
            }
            appState.selectedAnnotations = merged
        } else {
            appState.selectedAnnotations = hits
        }
        marqueeAdditive = false
        appState.selectedAnnotationPage = appState.selectedAnnotations.isEmpty ? nil : page
        refreshSelectionOverlay()
        let count = appState.selectedAnnotations.count
        if count > 0 {
            Haptics.thunk()
            appState.flash("\(count) selected — drag to move · corner handles resize · ⌫ deletes · ⇧-drag adds more", seconds: 2.4)
        }
    }

    /// Union bounds (page space) of a selection in which every member can be
    /// resized; nil when the selection is empty or mixed.
    private func resizableSelectionUnion() -> CGRect? {
        guard let appState, !appState.selectedAnnotations.isEmpty,
              appState.selectedAnnotations.allSatisfy({ Annotations.isResizable($0) })
        else { return nil }
        var union = appState.selectedAnnotations[0].bounds
        for a in appState.selectedAnnotations.dropFirst() { union = union.union(a.bounds) }
        return union
    }

    /// Which corner of `bounds` (page space) sits under the click, if any.
    /// 0 = bottom-left, 1 = bottom-right, 2 = top-left, 3 = top-right.
    private func handleIndex(at point: CGPoint, bounds: CGRect) -> Int? {
        let tolerance = 10 / max(scaleFactor, 0.05)
        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.minX, y: bounds.maxY),
            CGPoint(x: bounds.maxX, y: bounds.maxY),
        ]
        return corners.firstIndex { $0.distance(to: point) < tolerance }
    }

    /// New bounds keeping the corner opposite `corner` anchored.
    private func boundsForResize(original: CGRect, corner: Int, to point: CGPoint) -> CGRect {
        let anchor: CGPoint
        switch corner {
        case 0: anchor = CGPoint(x: original.maxX, y: original.maxY)
        case 1: anchor = CGPoint(x: original.minX, y: original.maxY)
        case 2: anchor = CGPoint(x: original.maxX, y: original.minY)
        default: anchor = CGPoint(x: original.minX, y: original.minY)
        }
        let width = max(abs(point.x - anchor.x), 8)
        let height = max(abs(point.y - anchor.y), 8)
        return CGRect(
            x: point.x >= anchor.x ? anchor.x : anchor.x - width,
            y: point.y >= anchor.y ? anchor.y : anchor.y - height,
            width: width,
            height: height
        )
    }

    // MARK: - Crisp annotation rendering

    /// Draws every hidden Inkwell annotation at full backing resolution —
    /// PDFKit's own annotation pass goes through a resolution-capped buffer
    /// on this OS and pixelates at zoom.
    func drawCrispAnnotations(in ctx: CGContext) {
        guard let appState, appState.hidesOwnAnnotations, let document else { return }
        // Visibility is computed manually — PDFKit's `visiblePages` is
        // unreliable mid-scroll on this OS, which dropped whole pages of ink
        // from the overlay while their thumbnails (PDFKit-rendered) were fine.
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), page.rotation % 360 == 0 else { continue }
            let pageRect = convert(page.bounds(for: .cropBox), from: page)
            guard pageRect.intersects(bounds) else { continue }
            let origin = convert(CGPoint.zero, from: page)
            ctx.saveGState()
            // Ink belongs to its page: never spill across the page break.
            ctx.clip(to: pageRect)
            ctx.translateBy(x: origin.x, y: origin.y)
            ctx.scaleBy(x: scaleFactor, y: scaleFactor)
            for annotation in page.annotations
            where annotation.userName == Annotations.authorName
                && !annotation.shouldDisplay
                && annotation !== editingAnnotation {
                let b = annotation.bounds
                if annotation.type == "Ink", let paths = annotation.paths {
                    ctx.saveGState()
                    ctx.translateBy(x: b.minX, y: b.minY)
                    annotation.color.setStroke()
                    let width = annotation.border?.lineWidth ?? 1.5
                    for path in paths {
                        path.lineWidth = width
                        path.lineCapStyle = .round
                        path.lineJoinStyle = .round
                        path.stroke()
                    }
                    ctx.restoreGState()
                } else if annotation.type == "FreeText", let text = annotation.contents {
                    let font = annotation.font ?? NSFont.systemFont(ofSize: 13)
                    let color = annotation.fontColor ?? .black
                    ctx.saveGState()
                    ctx.translateBy(x: b.minX, y: b.maxY)
                    ctx.scaleBy(x: 1, y: -1)
                    let previous = NSGraphicsContext.current
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                    NSAttributedString(
                        string: text,
                        attributes: [.font: font, .foregroundColor: color]
                    ).draw(
                        with: CGRect(x: 2, y: 2, width: max(b.width - 4, 4), height: max(b.height - 4, 4)),
                        options: [.usesLineFragmentOrigin, .usesFontLeading]
                    )
                    NSGraphicsContext.current = previous
                    ctx.restoreGState()
                }
            }
            ctx.restoreGState()
        }
    }

    // MARK: - Selection overlay

    func refreshSelectionOverlay() {
        guard let appState else { return }
        var rects: [CGRect] = []
        var handles: [CGRect] = []
        if let page = appState.selectedAnnotationPage {
            for annotation in appState.selectedAnnotations {
                rects.append(convert(annotation.bounds, from: page).insetBy(dx: -3, dy: -3))
            }
            if let union = resizableSelectionUnion() {
                let b = convert(union, from: page)
                let s: CGFloat = 7
                for c in [
                    CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                    CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY),
                ] {
                    handles.append(CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s))
                }
            }
        }
        selectionOverlay.highlightRects = rects
        selectionOverlay.handleRects = handles
        selectionOverlay.needsDisplay = true

        // Zoom-adaptive virtual grid — canvas boards only, never opened PDFs.
        if appState.notesMode, appState.isNotesDocument, appState.notesPaper.isCanvas, appState.gridSnap,
           let page = document?.page(at: 0) {
            selectionOverlay.gridOrigin = convert(CGPoint.zero, from: page)
            selectionOverlay.gridScale = scaleFactor
            selectionOverlay.gridPageRect = convert(page.bounds(for: .cropBox), from: page)
            selectionOverlay.gridVisible = true
        } else {
            selectionOverlay.gridVisible = false
        }
    }
}

// MARK: - Text editor view

/// NSTextView that grows with its content and reports commit/cancel.
/// Owns a private undo manager so typing undo never pollutes the document's
/// undo stack (the responder chain would otherwise hand it the window's).
final class InkwellTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    private let sessionUndoManager = UndoManager()
    override var undoManager: UndoManager? { sessionUndoManager }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        // ⌘Return commits.
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
        growToFit()
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { DispatchQueue.main.async { [weak self] in self?.onCommit?() } }
        return result
    }

    private func growToFit() {
        guard let container = textContainer, let manager = layoutManager else { return }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let needed = ceil(used.height) + 10
        if needed > frame.height {
            var f = frame
            let delta = needed - f.height
            f.size.height = needed
            // PDFView (the superview) is flipped, so growing height extends downward
            // already; only shift the origin when hosted in a non-flipped superview.
            if superview?.isFlipped == false { f.origin.y -= delta }
            frame = f
        }
    }
}

// MARK: - Selection ring overlay

/// Transparent overlay that draws a dashed ring around the selected annotation.
final class SelectionOverlayView: NSView {
    var highlightRects: [CGRect] = [] {
        didSet { needsDisplay = true }
    }
    var handleRects: [CGRect] = [] {
        didSet { needsDisplay = true }
    }
    var marqueeRect: CGRect? {
        didSet { needsDisplay = true }
    }
    // Live drawing preview (view coordinates) — strokes, shapes, wires.
    var previewPath: NSBezierPath? {
        didSet { needsDisplay = true }
    }
    var previewColor: NSColor = .black
    var previewLineWidth: CGFloat = 1.5

    /// Full-resolution render of Inkwell's annotations (set by ToolPDFView).
    var crispContentDraw: ((CGContext) -> Void)?

    // Zoom-adaptive virtual grid (canvas boards only).
    var gridVisible = false {
        didSet { needsDisplay = true }
    }
    var gridOrigin: CGPoint = .zero {
        didSet { needsDisplay = true }
    }
    var gridScale: CGFloat = 1 {
        didSet { needsDisplay = true }
    }
    var gridPageRect: CGRect = .zero

    // PDFView is NOT flipped on this OS (verified); since this overlay's frame
    // coincides with the PDFView's bounds, unflipped rects draw 1:1.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        drawAdaptiveGrid()
        if let ctx = NSGraphicsContext.current?.cgContext {
            crispContentDraw?(ctx)
        }
        if let preview = previewPath {
            previewColor.setStroke()
            preview.lineWidth = previewLineWidth
            preview.lineCapStyle = .round
            preview.lineJoinStyle = .round
            preview.stroke()
        }
        for rect in highlightRects {
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            path.setLineDash([5, 3], count: 2, phase: 0)
            path.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        for rect in handleRects {
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            NSColor.white.setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }
        if let marquee = marqueeRect {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            marquee.fill()
            let path = NSBezierPath(rect: marquee)
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.lineWidth = 1
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    /// Map-app grid: the finest pitch that reads at the current zoom, fading
    /// in as it arrives, with the ×5 coarser level always steady above it.
    private func drawAdaptiveGrid() {
        guard gridVisible, gridScale > 0 else { return }
        let clip = bounds.intersection(gridPageRect)
        guard !clip.isEmpty else { return }

        let minor = AppState.gridPitch(forScale: gridScale)
        let minorScreen = minor * gridScale
        let fade = min(1, max(0, (minorScreen - 14) / 50))
        let ink = NSColor(calibratedRed: 0.55, green: 0.65, blue: 0.80, alpha: 1)

        func strokeLines(pitch: CGFloat, alpha: CGFloat) {
            let step = pitch * gridScale
            guard step > 6, alpha > 0.02 else { return }
            ink.withAlphaComponent(alpha).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1
            var x = gridOrigin.x + ceil((clip.minX - gridOrigin.x) / step) * step
            while x <= clip.maxX {
                path.move(to: CGPoint(x: x, y: clip.minY))
                path.line(to: CGPoint(x: x, y: clip.maxY))
                x += step
            }
            var y = gridOrigin.y + ceil((clip.minY - gridOrigin.y) / step) * step
            while y <= clip.maxY {
                path.move(to: CGPoint(x: clip.minX, y: y))
                path.line(to: CGPoint(x: clip.maxX, y: y))
                y += step
            }
            path.stroke()
        }

        strokeLines(pitch: minor, alpha: 0.05 + 0.15 * fade)
        strokeLines(pitch: minor * 5, alpha: 0.28)
    }
}
