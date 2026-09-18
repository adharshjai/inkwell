import AppKit
import Observation
import PDFKit
import SwiftUI

// MARK: - Tools

enum Tool: String, CaseIterable, Identifiable {
    case select, pen, highlighter, eraser, fill, text, line, arrow, doubleArrow, rect, ellipse, triangle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: "Select"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .fill: "Fill"
        case .text: "Text"
        case .line: "Line"
        case .arrow: "Arrow"
        case .doubleArrow: "Double Arrow"
        case .rect: "Rectangle"
        case .ellipse: "Ellipse"
        case .triangle: "Triangle"
        }
    }

    var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .fill: "drop.fill"
        case .text: "character.textbox"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .doubleArrow: "arrow.left.and.right"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .triangle: "triangle"
        }
    }

    /// Single-key shortcut shown in help and handled by the PDF view.
    var hotkey: Character? {
        switch self {
        case .select: "v"
        case .pen: "p"
        case .highlighter: "h"
        case .eraser: "e"
        case .fill: "b"
        case .text: "t"
        case .line: "l"
        case .arrow: "a"
        case .rect: "r"
        case .ellipse: "o"
        case .doubleArrow, .triangle: nil
        }
    }

    var isShape: Bool {
        switch self {
        case .line, .arrow, .doubleArrow, .rect, .ellipse, .triangle: true
        default: false
        }
    }
}

// MARK: - Pending placement (click-to-place)

enum PendingPlacement {
    case typesetMath(String, CGFloat)   // source, font size
    case mathText(String)
    case stamp(Stamp)
    case signature(Signature)
    case table(TableSpec)

    var hint: String {
        switch self {
        case .typesetMath: "Click the page to place your equation — Esc to cancel"
        case .mathText: "Click the page to place your equation — Esc to cancel"
        case .stamp(let s): "Click the page to place “\(s.name)” — Esc to cancel"
        case .signature: "Click the page to place your signature — Esc to cancel"
        case .table: "Click where the table’s top-left corner should go — Esc to cancel"
        }
    }
}

/// Momentary "hold a key, glide on the trackpad" drawing modes — no clicking,
/// no tool switching, instantly back to typing on release.
enum Quasimode: String {
    case ink = "F"
    case shape = "S"
    case wire = "W"
    case erase = "E"

    var label: String {
        switch self {
        case .ink: "Draw"
        case .shape: "Shape"
        case .wire: "Wire"
        case .erase: "Erase"
        }
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case math, stamps, sign
    var id: String { rawValue }
    var label: String {
        switch self {
        case .math: "Math"
        case .stamps: "Stamps"
        case .sign: "Sign"
        }
    }
    var systemImage: String {
        switch self {
        case .math: "x.squareroot"
        case .stamps: "seal"
        case .sign: "signature"
        }
    }
}

/// The space between two pages (or below the last / above the first) that
/// the cursor is hovering — where the insertion bar appears.
struct InsertionGap: Equatable {
    let index: Int        // page index a new page would take
    let viewRect: CGRect  // gap rect in PDFView coordinates
}

/// State for the Insert/Edit Table sheet.
struct TableRequest: Identifiable {
    let id = UUID()
    var text: String
    var header: Bool = true
    var style: TableStyle = .grid
    var editing: PDFAnnotation?
    var page: PDFPage?
}

// MARK: - App state

@MainActor
@Observable
final class AppState {
    // Document
    var document: PDFDocument?
    var documentURL: URL?
    var isDirty = false
    /// Bumped on any structural/page change so thumbnails and views refresh.
    var docVersion = 0

    var currentPageIndex = 0
    var pageCount = 0
    var zoomPercent: Int = 100

    // Tools — Select by default so a first click never marks the document.
    var tool: Tool = .select {
        didSet {
            if tool != .select { selectedAnnotations = []; selectedAnnotationPage = nil }
        }
    }
    var inkColor: NSColor = NSColor.inkSwatches[0].color
    var inkWidth: CGFloat = 1.6
    var highlightColor: NSColor = NSColor.highlightSwatches[0].color
    var highlightWidth: CGFloat = 14
    var fillColor: NSColor = NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.32, alpha: 0.85)
    /// Eraser reach in screen points (converted to page points at use).
    var eraserSize: CGFloat = 4
    var fontSize: CGFloat = 13
    var textBold = false
    var textItalic = false
    var textAlignment: NSTextAlignment = .left

    /// Text boxes the formatting controls act on: the one being edited, else
    /// the selected ones. Changes register as one undoable step.
    var styleTargetTextBoxes: [PDFAnnotation] {
        if let editing = pdfView?.editingTextAnnotation { return [editing] }
        return selectedAnnotations.filter { $0.type == "FreeText" }
    }

    func applyTextStyle(size: CGFloat? = nil, bold: Bool? = nil, italic: Bool? = nil, alignment: NSTextAlignment? = nil) {
        if let bold { textBold = bold }
        if let italic { textItalic = italic }
        if let alignment { textAlignment = alignment }
        let targets = styleTargetTextBoxes
        guard !targets.isEmpty else {
            if let size { fontSize = size }
            return
        }
        restyle(targets) { Annotations.styleText($0, size: size, bold: bold, italic: italic, alignment: alignment) }
    }

    // MARK: Text size (Word-style bigger / smaller)

    static let textSizeLadder: [CGFloat] = [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 16, 18, 20, 22, 24, 28, 32, 36, 40, 48, 56, 64, 72, 96]

    static func steppedSize(from size: CGFloat, direction: Int) -> CGFloat {
        if direction > 0 {
            return textSizeLadder.first { $0 > size + 0.01 } ?? min(size * 1.25, 240)
        }
        return textSizeLadder.last { $0 < size - 0.01 } ?? max(size * 0.8, 4)
    }

    static func formatSize(_ size: CGFloat) -> String {
        abs(size - size.rounded()) < 0.05 ? "\(Int(size.rounded()))" : String(format: "%.1f", size)
    }

    /// Point size of the box the text controls act on (nil = none selected).
    var currentTextSize: CGFloat? { styleTargetTextBoxes.first?.font?.pointSize }

    /// ⌘] / ⌘[ — each targeted box steps along the size ladder from its own
    /// size; with nothing targeted, the default for new boxes steps.
    func stepTextSize(_ direction: Int) {
        let targets = styleTargetTextBoxes
        guard !targets.isEmpty else {
            fontSize = Self.steppedSize(from: fontSize, direction: direction)
            textStyleTick += 1
            flash("New text boxes: \(Self.formatSize(fontSize)) pt", seconds: 1.2)
            return
        }
        restyle(targets) { box in
            let current = box.font?.pointSize ?? 13
            Annotations.styleText(box, size: Self.steppedSize(from: current, direction: direction))
        }
    }

    func setTextSize(_ size: CGFloat) {
        let targets = styleTargetTextBoxes
        guard !targets.isEmpty else {
            fontSize = size
            textStyleTick += 1
            return
        }
        restyle(targets) { Annotations.styleText($0, size: size) }
    }

    /// Applies a style change to boxes as one undo step. A box still being
    /// created isn't on a page yet — its creation is the undo step, so
    /// styling it mid-edit registers nothing of its own.
    private func restyle(_ targets: [PDFAnnotation], _ change: (PDFAnnotation) -> Void) {
        let registering = targets.contains { $0.page != nil }
        if registering { undoManager?.beginUndoGrouping() }
        for box in targets {
            let before = Annotations.Geometry(of: box)
            change(box)
            if box.page != nil {
                Annotations.registerResize(of: box, before: before, state: self, actionName: "Format Text")
            }
        }
        if registering { undoManager?.endUndoGrouping() }
        textStyleTick += 1
        pdfView?.restyleTextEditor()
        pdfView?.refreshSelectionOverlay()
    }

    var pendingPlacement: PendingPlacement?
    var insertionGap: InsertionGap?
    /// Bumped when text styling changes so formatting controls refresh.
    var textStyleTick = 0
    /// Per-page edit counters and a structural counter: thumbnails re-render
    /// only the page that changed (and everything on page add/remove/reorder).
    var pageRevisions: [ObjectIdentifier: Int] = [:]
    var structureVersion = 0
    /// The Insert/Edit Table sheet, when open.
    var tableRequest: TableRequest?
    /// Pasteboard generation our own annotation copy wrote — anything newer
    /// on the system clipboard (text, a table) wins on ⌘V.
    @ObservationIgnored var ownPasteboardChangeCount = -1

    // Notes mode & quasimodes
    var notesMode = false
    var gridSnap = true
    var activeQuasimode: Quasimode?
    /// Paper used when the endless notes canvas grows itself.
    var notesPaper: PaperTemplate = .grid
    /// True only for documents created as notes (New Notes / New From Paper).
    /// Opened PDFs are homework: no virtual grid, no page auto-extend — ever.
    var isNotesDocument = false

    /// PDFKit renders annotations through a resolution-capped buffer on this
    /// OS (page content stays sharp; annotations pixelate at zoom). When the
    /// app UI is running, Inkwell's own ink/text annotations are hidden from
    /// PDFKit and drawn crisply by the overlay instead. They are temporarily
    /// re-shown for saving, exporting, printing, and thumbnails.
    @ObservationIgnored var hidesOwnAnnotations = false

    /// Marks every Inkwell ink/text annotation on unrotated pages as hidden
    /// so the overlay (not PDFKit) draws it.
    func hideOwnAnnotationsFromPDFView() {
        guard hidesOwnAnnotations, let document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), page.rotation % 360 == 0 else { continue }
            for annotation in page.annotations
            where annotation.userName == Annotations.authorName
                && ["Ink", "FreeText"].contains(annotation.type ?? "") {
                // Reloaded ink arrives with page-space paths — rebase before
                // the overlay draws or hit-tests it.
                Annotations.normalizeInkPaths(annotation)
                annotation.shouldDisplay = false
            }
        }
    }

    /// Runs `body` with every hidden Inkwell annotation made visible — so
    /// writes, flattening, printing, and thumbnail renders include the ink.
    func withOwnAnnotationsVisible<T>(_ body: () -> T) -> T {
        guard hidesOwnAnnotations, let document else { return body() }
        var hidden: [PDFAnnotation] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations
            where annotation.userName == Annotations.authorName && !annotation.shouldDisplay {
                annotation.shouldDisplay = true
                hidden.append(annotation)
            }
        }
        defer {
            for annotation in hidden { annotation.shouldDisplay = false }
        }
        return body()
    }

    /// Page-scoped version for thumbnails: toggling every annotation in the
    /// document for each thumbnail made every edit cost ~180 ms.
    func withOwnAnnotationsVisible<T>(on page: PDFPage, _ body: () -> T) -> T {
        guard hidesOwnAnnotations else { return body() }
        var hidden: [PDFAnnotation] = []
        for annotation in page.annotations
        where annotation.userName == Annotations.authorName && !annotation.shouldDisplay {
            annotation.shouldDisplay = true
            hidden.append(annotation)
        }
        defer {
            for annotation in hidden { annotation.shouldDisplay = false }
        }
        return body()
    }

    /// The display state an Inkwell annotation should have while in the view.
    func applyDisplayPolicy(_ annotation: PDFAnnotation, on page: PDFPage) {
        let ours = annotation.userName == Annotations.authorName
            && ["Ink", "FreeText"].contains(annotation.type ?? "")
            && page.rotation % 360 == 0
        annotation.shouldDisplay = !(hidesOwnAnnotations && ours)
    }

    /// Undo/redo that respects an active inline text editor (its typing has a
    /// private undo stack; the document has the real one). During a held W,
    /// ⌘Z removes the last wire vertex instead.
    func performUndo() {
        if pdfView?.handleQuasimodeUndo() == true { return }
        guard let manager = pdfView?.editingUndoManager ?? undoManager else { return }
        pdfView?.closeEraserGroupIfOpen()
        // NSUndoManager refuses to undo while any group is open — never wedge.
        guard manager.groupingLevel == 0 else { return }
        manager.undo()
        pdfView?.refreshSelectionOverlay()
    }

    func performRedo() {
        guard activeQuasimode == nil else { return }
        guard let manager = pdfView?.editingUndoManager ?? undoManager else { return }
        pdfView?.closeEraserGroupIfOpen()
        guard manager.groupingLevel == 0 else { return }
        manager.redo()
        pdfView?.refreshSelectionOverlay()
    }

    func toggleNotesMode() {
        notesMode.toggle()
        if notesMode {
            tool = .select
            flash("Notes — drag to box-select · T to type · hold F to draw (tap F = dot) · S shapes · W wires · E erase", seconds: 4.5)
        } else {
            tool = .select
            activeQuasimode = nil
            flash("Notes mode off", seconds: 1.2)
        }
    }

    /// Grid levels for the canvas: ×5 apart, so zooming in reveals finer
    /// rulings and zooming out consolidates them (map-app style).
    static let gridPitches: [CGFloat] = [2, 10, 50, 250, 1250]

    /// The finest pitch that still reads on screen (≥ ~18 screen pt apart).
    static func gridPitch(forScale scale: CGFloat) -> CGFloat {
        for pitch in gridPitches where pitch * scale >= 18 { return pitch }
        return gridPitches[gridPitches.count - 1]
    }

    /// Snaps a page point to the grid the user currently sees.
    func snapIfEnabled(_ point: CGPoint) -> CGPoint {
        guard notesMode, gridSnap else { return point }
        let pitch: CGFloat = notesPaper.isCanvas
            ? AppState.gridPitch(forScale: pdfView?.scaleFactor ?? 1)
            : 18
        return CGPoint(
            x: (point.x / pitch).rounded() * pitch,
            y: (point.y / pitch).rounded() * pitch
        )
    }

    /// New Notes: ask which way the board should face, then open it.
    func newNotesFlow() {
        let alert = NSAlert()
        alert.messageText = "New Notes Board"
        alert.informativeText = "One huge zoomable page either way — pinch out to see everything, pinch in to work on a detail."
        alert.addButton(withTitle: "Landscape")
        alert.addButton(withTitle: "Portrait")
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal()
        let template: PaperTemplate
        switch choice {
        case .alertFirstButtonReturn: template = .canvas
        case .alertSecondButtonReturn: template = .canvasPortrait
        default: return
        }
        newDocument(template: template)
        if !notesMode { toggleNotesMode() }
    }

    // Selection (annotation editing in Select mode)
    var selectedAnnotations: [PDFAnnotation] = []
    var selectedAnnotationPage: PDFPage?

    // Annotation clipboard (internal; the system pasteboard gets an image render)
    @ObservationIgnored var annotationClipboard: [PDFAnnotation] = []
    @ObservationIgnored var pasteCascade = 0

    // Search
    var searchText = ""
    var searchResults: [PDFSelection] = []
    var searchIndex = 0
    /// Bumped by ⌘F to move keyboard focus into the toolbar search field.
    var searchFocusTick = 0

    // UI
    var showInspector = false
    var inspectorTab: InspectorTab = .math
    var statusMessage: String?
    var showExportSheet = false
    var showSignatureSheet = false

    // Wiring
    @ObservationIgnored weak var pdfView: ToolPDFView?
    /// The document's own undo stack. Owned here — never borrowed from the
    /// window — so registrations and ⌘Z always talk to the same manager.
    @ObservationIgnored let documentUndoManager = UndoManager()
    var undoManager: UndoManager? { documentUndoManager }

    let signatures = SignatureStore()

    // MARK: Recents (observable stored property, persisted to UserDefaults)

    private static let recentsKey = "inkwell.recents"

    private(set) var recents: [URL] = (UserDefaults.standard.stringArray(forKey: AppState.recentsKey) ?? [])
        .map { URL(fileURLWithPath: $0) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }

    func noteRecent(_ url: URL) {
        var urls = recents
        urls.removeAll { $0.path == url.path }
        urls.insert(url, at: 0)
        recents = Array(urls.prefix(8))
        UserDefaults.standard.set(recents.map(\.path), forKey: Self.recentsKey)
    }

    // MARK: Status toast

    @ObservationIgnored private var statusTask: Task<Void, Never>?

    func flash(_ message: String, seconds: Double = 2.5) {
        statusMessage = message
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.statusMessage = nil }
        }
    }

    // MARK: Convenience

    var hasDocument: Bool { document != nil }

    var displayName: String {
        documentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    func markDirty() {
        isDirty = true
    }

    func bumpVersion(page: PDFPage? = nil) {
        docVersion += 1
        pageCount = document?.pageCount ?? 0
        if let page {
            pageRevisions[ObjectIdentifier(page), default: 0] += 1
        } else {
            structureVersion += 1
        }
        // The crisp overlay repaints on interaction; mutations that arrive
        // through the keyboard (⌘Z!) must repaint it explicitly.
        pdfView?.refreshSelectionOverlay()
    }

    /// The color/width the current drawing tool should use.
    var activeStrokeColor: NSColor {
        tool == .highlighter ? highlightColor.withAlphaComponent(0.45) : inkColor
    }

    var activeStrokeWidth: CGFloat {
        tool == .highlighter ? highlightWidth : inkWidth
    }
}
