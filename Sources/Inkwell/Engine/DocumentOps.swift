import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - Document lifecycle & page operations

extension AppState {

    // MARK: Open / new

    /// If there are unsaved changes, asks before discarding them.
    /// Returns false when the user cancels.
    func confirmDiscardIfNeeded() -> Bool {
        pdfView?.commitTextEditing()
        guard isDirty, document != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "“\(displayName)” has unsaved changes"
        alert.informativeText = "Your annotations will be lost unless you save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return save()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func openDocument(at url: URL) {
        guard confirmDiscardIfNeeded() else { return }
        guard let doc = PDFDocument(url: url) else {
            flash("Couldn’t open \(url.lastPathComponent)")
            return
        }
        document = doc
        documentURL = url
        isDirty = false
        currentPageIndex = 0
        // Opening a PDF is homework mode — leave any notes-board state behind.
        notesMode = false
        activeQuasimode = nil
        isNotesDocument = false
        clearSearch()
        selectedAnnotations = []
        selectedAnnotationPage = nil
        noteRecent(url)
        bumpVersion()
        undoManager?.removeAllActions()
        if doc.isLocked {
            flash("This PDF is password-protected — unlock it to annotate")
        }
        NotificationCenter.default.addObserver(
            forName: .PDFDocumentDidUnlock, object: doc, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.bumpVersion() }
        }
    }

    func openViaPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a PDF to open"
        if panel.runModal() == .OK, let url = panel.url {
            openDocument(at: url)
        }
    }

    /// A fresh document made of `count` pages of the given paper.
    func newDocument(template: PaperTemplate, pages count: Int = 1) {
        guard confirmDiscardIfNeeded() else { return }
        notesPaper = template
        // Canvas boards ARE the notes experience — arrive with the adaptive
        // grid and hold-key tools live no matter which menu created them.
        notesMode = template.isCanvas
        activeQuasimode = nil
        isNotesDocument = true
        let doc = PDFDocument()
        for i in 0..<max(1, count) {
            if let page = PDFDocument(data: template.pageData())?.page(at: 0) {
                doc.insert(page, at: i)
            }
        }
        document = doc
        documentURL = nil
        isDirty = true
        currentPageIndex = 0
        clearSearch()
        selectedAnnotations = []
        selectedAnnotationPage = nil
        bumpVersion()
        undoManager?.removeAllActions()
        flash("New \(template.displayName) document")
        if template.isCanvas {
            // Land at 100% in the top-left of the big board, not zoomed to fit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, let view = self.pdfView,
                      let page = self.document?.page(at: 0) else { return }
                view.autoScales = false
                view.scaleFactor = 1.0
                view.go(to: PDFDestination(
                    page: page,
                    at: CGPoint(x: 0, y: page.bounds(for: .cropBox).maxY)
                ))
                self.syncZoom()
            }
        }
    }

    // MARK: Save

    /// PDFKit's write(to:) on a URL-loaded document APPENDS (incremental
    /// save) — the user's homework grew 248MB → 2.1GB in a handful of ⌘S
    /// presses, each one beachballing for ~40s. Rebuilding into a fresh
    /// document from page copies forces a from-scratch write of only
    /// reachable objects: 2.1GB → 1.8MB, sub-second, verified lossless.
    private func compactDocument() -> PDFDocument? {
        guard let document else { return nil }
        return withOwnAnnotationsVisible {
            let clean = PDFDocument()
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index),
                      let copy = page.copy() as? PDFPage else { return nil }
                clean.insert(copy, at: index)
            }
            return clean
        }
    }

    func writeCompact(to url: URL) -> Bool {
        compactDocument()?.write(to: url) ?? false
    }

    func compactData() -> Data? {
        compactDocument()?.dataRepresentation()
    }

    @discardableResult
    func save() -> Bool {
        pdfView?.commitTextEditing()
        guard let document else { return false }
        guard let url = documentURL else { return saveAs() }
        _ = document
        if writeCompact(to: url) {
            isDirty = false
            flash("Saved")
            return true
        }
        return offerSaveAsRecovery(failedURL: url)
    }

    @discardableResult
    func saveAs() -> Bool {
        pdfView?.commitTextEditing()
        guard let document else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = documentURL?.lastPathComponent ?? "\(displayName).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        _ = document
        if writeCompact(to: url) {
            documentURL = url
            isDirty = false
            noteRecent(url)
            flash("Saved to \(url.lastPathComponent)")
            return true
        }
        return offerSaveAsRecovery(failedURL: url)
    }

    /// A failed write gets a real alert with a way out, not a vanishing toast.
    private func offerSaveAsRecovery(failedURL: URL) -> Bool {
        let writable = FileManager.default.isWritableFile(atPath: failedURL.deletingLastPathComponent().path)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t save “\(failedURL.lastPathComponent)”"
        alert.informativeText = writable
            ? "The file could not be written. It may be locked or in use."
            : "You don’t have permission to write to that location."
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            return saveAs()
        }
        return false
    }

    // MARK: Page operations (all undoable)

    func insertPaper(_ template: PaperTemplate) {
        guard let document else { return }
        guard let page = PDFDocument(data: template.pageData())?.page(at: 0) else { return }
        let index = min(currentPageIndex + 1, document.pageCount)
        insertPage(page, at: index, actionName: "Insert \(template.displayName) Page")
        flash("\(template.displayName) page added after page \(index)")
    }

    func insertPage(_ page: PDFPage, at index: Int, actionName: String) {
        guard let document else { return }
        document.insert(page, at: index)
        clearSearch()
        markDirty()
        bumpVersion()
        undoManager?.setActionName(actionName)
        undoManager?.registerUndo(withTarget: self) { st in
            st.removePage(at: index, actionName: actionName)
        }
    }

    func removePage(at index: Int, actionName: String = "Delete Page") {
        guard let document, index >= 0, index < document.pageCount else { return }
        guard document.pageCount > 1 else {
            flash("A document needs at least one page")
            return
        }
        guard let page = document.page(at: index) else { return }
        if selectedAnnotationPage === page {
            selectedAnnotations = []
            selectedAnnotationPage = nil
        }
        document.removePage(at: index)
        clearSearch()
        if currentPageIndex >= document.pageCount { currentPageIndex = document.pageCount - 1 }
        markDirty()
        bumpVersion()
        undoManager?.setActionName(actionName)
        undoManager?.registerUndo(withTarget: self) { st in
            st.insertPage(page, at: index, actionName: actionName)
        }
    }

    func rotatePage(at index: Int, clockwise: Bool = true) {
        guard let document, let page = document.page(at: index) else { return }
        page.rotation += clockwise ? 90 : -90
        markDirty()
        bumpVersion()
        undoManager?.setActionName("Rotate Page")
        undoManager?.registerUndo(withTarget: self) { st in
            st.rotatePage(at: index, clockwise: !clockwise)
        }
    }

    func movePage(from source: Int, to destination: Int) {
        guard let document,
              source != destination,
              source >= 0, source < document.pageCount,
              destination >= 0, destination < document.pageCount,
              let page = document.page(at: source) else { return }
        document.removePage(at: source)
        document.insert(page, at: destination)
        clearSearch()
        markDirty()
        bumpVersion()
        undoManager?.setActionName("Reorder Pages")
        undoManager?.registerUndo(withTarget: self) { st in
            st.movePage(from: destination, to: source)
        }
    }

    /// Appends every page of another PDF (undoable as one step).
    func appendPDF(from url: URL) {
        guard let document, let other = PDFDocument(url: url) else {
            flash("Couldn’t read \(url.lastPathComponent)")
            return
        }
        let start = document.pageCount
        let count = other.pageCount
        for i in 0..<count {
            if let page = other.page(at: i) {
                document.insert(page, at: document.pageCount)
            }
        }
        clearSearch()
        markDirty()
        bumpVersion()
        // Appended pages may carry saved ink — normalize and hide it too.
        hideOwnAnnotationsFromPDFView()
        undoManager?.setActionName("Append PDF")
        undoManager?.registerUndo(withTarget: self) { st in
            st.removeAppendedRange(start: start, count: count)
        }
        flash("Appended \(count) page\(count == 1 ? "" : "s") from \(url.lastPathComponent)")
    }

    private func removeAppendedRange(start: Int, count: Int) {
        guard let document else { return }
        var removed: [PDFPage] = []
        for _ in 0..<count where start < document.pageCount {
            if let page = document.page(at: start) {
                removed.append(page)
                document.removePage(at: start)
            }
        }
        clearSearch()
        markDirty()
        bumpVersion()
        // Appended pages may carry saved ink — normalize and hide it too.
        hideOwnAnnotationsFromPDFView()
        undoManager?.setActionName("Append PDF")
        undoManager?.registerUndo(withTarget: self) { st in
            for (offset, page) in removed.enumerated() {
                st.document?.insert(page, at: start + offset)
            }
            st.clearSearch()
            st.markDirty()
            st.bumpVersion()
            st.undoManager?.setActionName("Append PDF")
            st.undoManager?.registerUndo(withTarget: st) { st2 in
                st2.removeAppendedRange(start: start, count: removed.count)
            }
        }
    }

    func appendPDFViaPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = "Choose a PDF to append to this document"
        if panel.runModal() == .OK, let url = panel.url {
            appendPDF(from: url)
        }
    }

    // MARK: Highlight current text selection

    func highlightCurrentSelection() {
        guard let pdfView, let selection = pdfView.currentSelection, !selection.string.isNilOrEmpty else {
            flash("Select some text first, then highlight")
            return
        }
        let pairs = Annotations.makeHighlights(for: selection, color: highlightColor.withAlphaComponent(0.45))
        guard !pairs.isEmpty else { return }
        for (page, annotation) in pairs {
            Annotations.add(annotation, to: page, state: self, actionName: "Highlight Text")
        }
        pdfView.clearSelection()
    }

    // MARK: Search

    func runSearch() {
        guard let document else { return }
        searchResults.forEach { _ in }
        guard !searchText.isEmpty else {
            clearSearch()
            return
        }
        let found = document.findString(searchText, withOptions: [.caseInsensitive])
        for sel in found { sel.color = NSColor.systemYellow.withAlphaComponent(0.85) }
        searchResults = found
        searchIndex = 0
        pdfView?.highlightedSelections = found.isEmpty ? nil : found
        if let first = found.first {
            focusSearchResult(first)
        }
        flash(found.isEmpty ? "No matches for “\(searchText)”" : "\(found.count) match\(found.count == 1 ? "" : "es")")
    }

    func stepSearch(_ delta: Int) {
        guard !searchResults.isEmpty else { return }
        searchIndex = (searchIndex + delta + searchResults.count) % searchResults.count
        focusSearchResult(searchResults[searchIndex])
    }

    private func focusSearchResult(_ selection: PDFSelection) {
        pdfView?.go(to: selection)
        pdfView?.setCurrentSelection(selection, animate: true)
    }

    func clearSearch() {
        searchText = ""
        searchResults = []
        searchIndex = 0
        pdfView?.highlightedSelections = nil
    }

    // MARK: Zoom & navigation

    func zoomIn() {
        pdfView?.autoScales = false
        pdfView?.zoomIn(nil)
        syncZoom()
    }

    func zoomOut() {
        pdfView?.autoScales = false
        pdfView?.zoomOut(nil)
        syncZoom()
    }
    func zoomFit() {
        guard let pdfView else { return }
        pdfView.autoScales = true
        syncZoom()
    }
    func zoomActual() {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.0
        syncZoom()
    }

    func syncZoom() {
        guard let pdfView else { return }
        zoomPercent = Int((pdfView.scaleFactor * 100).rounded())
    }

    func goToPage(_ index: Int) {
        guard let document, let page = document.page(at: index) else { return }
        pdfView?.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .cropBox).maxY)))
    }

    // MARK: Selected annotation actions

    // MARK: Clipboard (annotations)

    /// True when a text control (inline editor, search field, form field
    /// editor) owns the keyboard — clipboard verbs then belong to it.
    var textResponderActive: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    func performCopy() {
        if textResponderActive {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            return
        }
        if !selectedAnnotations.isEmpty {
            copySelectedAnnotations()
            return
        }
        // Fall through: copy selected page text, if any.
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
    }

    func performCut() {
        if textResponderActive {
            NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            return
        }
        guard !selectedAnnotations.isEmpty else { return }
        copySelectedAnnotations()
        deleteSelectedAnnotation()
        flash("Cut \(annotationClipboard.count) item\(annotationClipboard.count == 1 ? "" : "s")", seconds: 1.4)
    }

    func performPaste() {
        if textResponderActive {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            return
        }
        pasteAnnotations()
    }

    func copySelectedAnnotations() {
        guard !selectedAnnotations.isEmpty else { return }
        let clones = selectedAnnotations.compactMap { Annotations.clone($0) }
        guard !clones.isEmpty else { return }
        annotationClipboard = clones
        pasteCascade = 0
        // Also give the system pasteboard a vector PDF + PNG of the selection,
        // so it pastes as an image into Notes, Messages, docs…
        if let render = Annotations.pasteboardRender(clones) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(render.pdf, forType: .pdf)
            if let png = render.png {
                pasteboard.setData(png, forType: .png)
            }
        }
        flash("Copied \(clones.count) item\(clones.count == 1 ? "" : "s") — ⌘V pastes here, or paste as an image anywhere", seconds: 2.2)
    }

    func pasteAnnotations() {
        guard !annotationClipboard.isEmpty else { return }
        guard let page = pdfView?.currentPage ?? document?.page(at: currentPageIndex) else { return }
        pasteCascade += 1
        let offset = CGFloat(pasteCascade) * 16

        var pasted: [PDFAnnotation] = []
        for template in annotationClipboard {
            guard let clone = Annotations.clone(template) else { continue }
            Annotations.translate(clone, by: CGPoint(x: offset, y: -offset))
            pasted.append(clone)
        }
        guard !pasted.isEmpty else { return }

        // If the copied region doesn't land on this page (cross-page paste),
        // recenter the batch in the visible area.
        var union = pasted[0].bounds
        for a in pasted.dropFirst() { union = union.union(a.bounds) }
        let box = page.bounds(for: .cropBox)
        if !box.intersects(union) {
            let target = pdfView.map { view -> CGPoint in
                let visible = view.convert(view.bounds, to: page)
                return CGPoint(x: visible.midX, y: visible.midY)
            } ?? box.center
            let delta = CGPoint(x: target.x - union.midX, y: target.y - union.midY)
            for a in pasted { Annotations.translate(a, by: delta) }
        }

        undoManager?.beginUndoGrouping()
        for a in pasted {
            Annotations.add(a, to: page, state: self, actionName: "Paste")
        }
        undoManager?.endUndoGrouping()

        tool = .select
        selectedAnnotations = pasted
        selectedAnnotationPage = page
        pdfView?.refreshSelectionOverlay()
        Haptics.thunk()
    }

    /// ⌘D — copy + paste in one gesture, without touching the clipboard.
    func duplicateSelection() {
        guard !selectedAnnotations.isEmpty else { return }
        copySelectedAnnotations()
        pasteAnnotations()
    }

    func deleteSelectedAnnotation() {
        guard !selectedAnnotations.isEmpty, let page = selectedAnnotationPage else { return }
        let annotations = selectedAnnotations
        undoManager?.beginUndoGrouping()
        for annotation in annotations {
            Annotations.remove(annotation, from: page, state: self, actionName: "Delete")
        }
        undoManager?.endUndoGrouping()
    }

    // MARK: Find & print

    /// ⌘E — seed the search field from the current text selection and run it.
    func useSelectionForFind() {
        guard let text = pdfView?.currentSelection?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            flash("Select some text first")
            return
        }
        searchText = text
        runSearch()
    }

    func printDocument() {
        pdfView?.commitTextEditing()
        guard let document else { return }
        let info = NSPrintInfo.shared
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else {
            flash("Couldn’t start printing")
            return
        }
        // Synchronous run keeps our annotations visible for the whole print
        // session (the sheet variant returns before rendering happens).
        _ = withOwnAnnotationsVisible { operation.run() }
    }
}

extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        self?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}
