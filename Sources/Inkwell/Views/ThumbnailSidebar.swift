import PDFKit
import SwiftUI

/// Sidebar with draggable page thumbnails and page-level operations.
struct ThumbnailSidebar: View {
    let appState: AppState
    @State private var selection: Int?

    var body: some View {
        List(selection: $selection) {
            // appState.pageCount (not document.pageCount) — it's the observable
            // mirror that bumpVersion() maintains, so rows track page edits.
            ForEach(0..<appState.pageCount, id: \.self) { index in
                ThumbnailRow(appState: appState, index: index)
                    .tag(index)
                    .contextMenu {
                        Button("Rotate Right", systemImage: "rotate.right") {
                            appState.rotatePage(at: index)
                        }
                        Button("Rotate Left", systemImage: "rotate.left") {
                            appState.rotatePage(at: index, clockwise: false)
                        }
                        Menu("Insert Paper After", systemImage: "plus.rectangle.portrait") {
                            ForEach(PaperTemplate.allCases) { template in
                                Button(template.displayName, systemImage: template.systemImage) {
                                    appState.currentPageIndex = index
                                    appState.insertPaper(template)
                                }
                            }
                        }
                        Divider()
                        Button("Delete Page", systemImage: "trash", role: .destructive) {
                            appState.removePage(at: index)
                        }
                    }
            }
            .onMove { source, destination in
                guard let first = source.first else { return }
                let target = destination > first ? destination - 1 : destination
                appState.movePage(from: first, to: target)
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selection) { _, new in
            if let new, new != appState.currentPageIndex {
                appState.goToPage(new)
            }
        }
        .onChange(of: appState.currentPageIndex) { _, new in
            if selection != new { selection = new }
        }
        .onAppear { selection = appState.currentPageIndex }
    }
}

private struct ThumbnailRow: View {
    let appState: AppState
    let index: Int
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .aspectRatio(0.77, contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)

            Text("\(index + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .task(id: taskKey) {
            // Coalesce bursts of edits; the first render is immediate.
            if thumbnail != nil {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            render()
        }
    }

    /// Changes only when THIS page changed (or pages were added, removed,
    /// reordered, rotated) — not on every edit anywhere in the document.
    private var taskKey: String {
        guard let page = appState.document?.page(at: index) else { return "\(index)-none-\(appState.structureVersion)" }
        let id = ObjectIdentifier(page)
        return "\(index)-\(id.hashValue)-\(appState.pageRevisions[id] ?? 0)-\(appState.structureVersion)"
    }

    private func render() {
        guard let page = appState.document?.page(at: index) else { return }
        let box = page.bounds(for: .cropBox)
        let scale = 150 / max(box.width, 1)
        thumbnail = appState.withOwnAnnotationsVisible(on: page) {
            page.thumbnail(
                of: CGSize(width: 150, height: max(box.height * scale, 40)),
                for: .cropBox
            )
        }
    }
}
