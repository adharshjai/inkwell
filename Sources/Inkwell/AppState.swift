import AppKit
import Observation
import PDFKit
import SwiftUI

// MARK: - Tools

enum Tool: String, CaseIterable, Identifiable {
    case select, pen, highlighter, eraser, text, line, arrow, doubleArrow, rect, ellipse, triangle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: "Select"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
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

    var hint: String {
        switch self {
        case .typesetMath: "Click the page to place your equation — Esc to cancel"
        case .mathText: "Click the page to place your equation — Esc to cancel"
        case .stamp(let s): "Click the page to place “\(s.name)” — Esc to cancel"
        case .signature: "Click the page to place your signature — Esc to cancel"
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
    var fontSize: CGFloat = 13

    var pendingPlacement: PendingPlacement?

    // Notes mode & quasimodes
    var notesMode = false
    var gridSnap = true
    var activeQuasimode: Quasimode?
    /// Paper used when the endless notes canvas grows itself.
    var notesPaper: PaperTemplate = .grid

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
    }

    func performRedo() {
        guard activeQuasimode == nil else { return }
        guard let manager = pdfView?.editingUndoManager ?? undoManager else { return }
        pdfView?.closeEraserGroupIfOpen()
        guard manager.groupingLevel == 0 else { return }
        manager.redo()
    }

    func toggleNotesMode() {
        notesMode.toggle()
        if notesMode {
            tool = .select
            flash("Notes — drag to box-select · T to type · hold F to draw · S shapes · W wires · E erase", seconds: 4.5)
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

    func bumpVersion() {
        docVersion += 1
        pageCount = document?.pageCount ?? 0
    }

    /// The color/width the current drawing tool should use.
    var activeStrokeColor: NSColor {
        tool == .highlighter ? highlightColor.withAlphaComponent(0.45) : inkColor
    }

    var activeStrokeWidth: CGFloat {
        tool == .highlighter ? highlightWidth : inkWidth
    }
}
