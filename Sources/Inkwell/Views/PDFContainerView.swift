import PDFKit
import SwiftUI

struct PDFContainerView: NSViewRepresentable {
    let appState: AppState

    func makeNSView(context: Context) -> ToolPDFView {
        let view = ToolPDFView()
        view.appState = appState
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        // Extra bottom margin so the last page can scroll clear of the
        // floating tool palette.
        view.pageBreakMargins = NSEdgeInsets(top: 10, left: 10, bottom: 84, right: 10)
        view.pageShadowsEnabled = true
        view.interpolationQuality = .high
        view.minScaleFactor = 0.25
        view.maxScaleFactor = 8
        appState.pdfView = view

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        return view
    }

    func updateNSView(_ view: ToolPDFView, context: Context) {
        if view.document !== appState.document {
            view.document = appState.document
            view.autoScales = true
        }
        // Notes mode reads as one endless sheet: no page gaps, no shadows,
        // and a deep zoom range for the infinite canvas.
        let notesGap = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        let normalGap = NSEdgeInsets(top: 10, left: 10, bottom: 84, right: 10)
        let wantedMargins = appState.notesMode ? notesGap : normalGap
        if view.pageBreakMargins.top != wantedMargins.top {
            view.pageBreakMargins = wantedMargins
            view.pageShadowsEnabled = !appState.notesMode
            view.layoutDocumentView()
        }
        let wantedMax: CGFloat = appState.notesMode ? 16 : 8
        if view.maxScaleFactor != wantedMax {
            view.maxScaleFactor = wantedMax
            view.minScaleFactor = appState.notesMode ? 0.05 : 0.25
        }
        // The scroll view only exists once a document is installed.
        view.ensureScrollObserver()
        view.refreshSelectionOverlay()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    @MainActor
    final class Coordinator: NSObject {
        let appState: AppState

        init(appState: AppState) {
            self.appState = appState
        }

        @objc func pageChanged(_ note: Notification) {
            MainActor.assumeIsolated {
                guard let view = note.object as? ToolPDFView,
                      let page = view.currentPage,
                      let document = view.document else { return }
                appState.currentPageIndex = document.index(for: page)
                appState.syncZoom()
            }
        }
    }
}
