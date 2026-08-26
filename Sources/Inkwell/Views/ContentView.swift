import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let appState: AppState
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if appState.hasDocument {
                editor
            } else {
                WelcomeView(appState: appState)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let message = appState.statusMessage {
                statusToast(message)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .sheet(isPresented: exportSheetBinding) {
            ExportSheet(appState: appState)
        }
        .sheet(isPresented: signatureSheetBinding) {
            SignatureSheet(appState: appState)
        }
        .navigationTitle(appState.displayName)
        .navigationSubtitle(appState.isDirty ? "Edited" : "")
        .frame(minWidth: 900, minHeight: 620)
    }

    // MARK: Editor

    private var editor: some View {
        NavigationSplitView {
            ThumbnailSidebar(appState: appState)
                .navigationSplitViewColumnWidth(min: 120, ideal: 168, max: 260)
        } detail: {
            ZStack(alignment: .bottom) {
                PDFContainerView(appState: appState)
                    .background(WindowBackgroundShapeStyle.windowBackground)

                ToolPalette(appState: appState)
                    .padding(.bottom, 18)
            }
            .overlay(alignment: .top) {
                if let placement = appState.pendingPlacement {
                    placementHint(placement)
                } else if appState.notesMode || appState.activeQuasimode != nil {
                    QuasimodeHUD(appState: appState)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .inspector(isPresented: inspectorBinding) {
            InspectorView(appState: appState)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .toolbar { toolbarContent }
        .onChange(of: appState.searchFocusTick) {
            searchFocused = true
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button("Undo", systemImage: "arrow.uturn.backward") {
                appState.performUndo()
            }
            .help("Undo (⌘Z)")
            Button("Redo", systemImage: "arrow.uturn.forward") {
                appState.performRedo()
            }
            .help("Redo (⇧⌘Z)")
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup {
            Button("Previous Page", systemImage: "chevron.up") {
                appState.goToPage(appState.currentPageIndex - 1)
            }
            .disabled(appState.currentPageIndex <= 0)

            Text("\(appState.currentPageIndex + 1) / \(max(appState.pageCount, 1))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 52)

            Button("Next Page", systemImage: "chevron.down") {
                appState.goToPage(appState.currentPageIndex + 1)
            }
            .disabled(appState.currentPageIndex >= appState.pageCount - 1)
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { appState.zoomOut() }
            Menu("\(appState.zoomPercent)%") {
                Button("Fit Width") { appState.zoomFit() }
                Button("Actual Size") { appState.zoomActual() }
            }
            .font(.callout.monospacedDigit())
            .menuIndicator(.hidden)
            .frame(minWidth: 52)
            Button("Zoom In", systemImage: "plus.magnifyingglass") { appState.zoomIn() }
        }

        ToolbarSpacer(.flexible)

        ToolbarItemGroup {
            searchField
            if !appState.searchResults.isEmpty {
                Button("Previous Match", systemImage: "chevron.backward") { appState.stepSearch(-1) }
                Text("\(appState.searchIndex + 1)/\(appState.searchResults.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Next Match", systemImage: "chevron.forward") { appState.stepSearch(1) }
            }
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup {
            Button {
                appState.toggleNotesMode()
            } label: {
                Label("Notes Mode", systemImage: "scribble.variable")
            }
            .foregroundStyle(appState.notesMode ? Color.accentColor : Color.primary)
            .help("Notes mode: click anywhere to type, hold F to draw, S for auto-shapes, W for wires, E to erase (⇧⌘N)")

            Menu {
                ForEach(PaperTemplate.allCases) { template in
                    Button {
                        appState.insertPaper(template)
                    } label: {
                        Label(template.displayName, systemImage: template.systemImage)
                    }
                }
                Divider()
                Button("Append Another PDF…", systemImage: "doc.on.doc") {
                    appState.appendPDFViaPanel()
                }
            } label: {
                Label("Add Paper", systemImage: "plus.rectangle.portrait")
            }
            .help("Insert graph, engineering, or ruled paper after the current page")

            Button("Highlight Selection", systemImage: "highlighter") {
                appState.highlightCurrentSelection()
            }
            .help("Highlight the selected text (⇧⌘H)")

            Button("Turn It In", systemImage: "paperplane.fill") {
                appState.showExportSheet = true
            }
            .help("Export a flattened, submission-ready PDF (⇧⌘E)")

            Button("Inspector", systemImage: "sidebar.right") {
                appState.showInspector.toggle()
            }
            .help("Math, stamps & signatures (⌥⌘I)")
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search", text: searchBinding)
                .textFieldStyle(.plain)
                .frame(width: 110)
                .focused($searchFocused)
                .onSubmit { appState.runSearch() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    // MARK: Overlays

    private func placementHint(_ placement: PendingPlacement) -> some View {
        Label(placement.hint, systemImage: "hand.point.up.left")
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular.tint(.blue.opacity(0.3)), in: .capsule)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Quasimode HUD

    private func statusToast(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .padding(.trailing, 16)
            .padding(.bottom, 70)
            .transition(.opacity)
    }

    // MARK: Bindings & drop

    private var inspectorBinding: Binding<Bool> {
        Binding(get: { appState.showInspector }, set: { appState.showInspector = $0 })
    }

    private var exportSheetBinding: Binding<Bool> {
        Binding(get: { appState.showExportSheet }, set: { appState.showExportSheet = $0 })
    }

    private var signatureSheetBinding: Binding<Bool> {
        Binding(get: { appState.showSignatureSheet }, set: { appState.showSignatureSheet = $0 })
    }

    private var searchBinding: Binding<String> {
        Binding(get: { appState.searchText }, set: { appState.searchText = $0 })
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                guard let url, url.pathExtension.lowercased() == "pdf" else { return }
                Task { @MainActor in
                    appState.openDocument(at: url)
                }
            }
            return true
        }
        return false
    }
}

// MARK: - Quasimode HUD

/// Floating glass legend for the hold-key drawing modes. Display only —
/// never intercepts clicks.
struct QuasimodeHUD: View {
    let appState: AppState

    private let modes: [Quasimode] = [.ink, .shape, .wire, .erase]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(modes, id: \.rawValue) { mode in
                HStack(spacing: 5) {
                    keycap(mode.rawValue, active: appState.activeQuasimode == mode)
                    Text(mode.label)
                        .font(.caption)
                        .foregroundStyle(appState.activeQuasimode == mode ? .primary : .secondary)
                }
            }

            if appState.notesMode {
                Divider().frame(height: 14)
                HStack(spacing: 5) {
                    keycap("T", active: appState.tool == .text)
                    Text("Type")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    keycap("G", active: false)
                    Text(appState.gridSnap ? "Grid ✓" : "Grid ✗")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("hold key + glide")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .allowsHitTesting(false)
    }

    private func keycap(_ letter: String, active: Bool) -> some View {
        Text(letter)
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .frame(width: 18, height: 18)
            .background(
                active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .foregroundStyle(active ? Color.white : Color.primary)
    }
}
