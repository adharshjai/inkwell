import AppKit
import SwiftUI

@main
enum Boot {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            MainActor.assumeIsolated { SelfTest.run() }
            return
        }
        if let flagIndex = args.firstIndex(of: "--make-sample"), args.indices.contains(flagIndex + 1) {
            MainActor.assumeIsolated { SampleDoc.write(to: URL(fileURLWithPath: args[flagIndex + 1])) }
            return
        }
        if let flagIndex = args.firstIndex(of: "--diagnose"), args.indices.contains(flagIndex + 1) {
            MainActor.assumeIsolated { SelfTest.diagnose(url: URL(fileURLWithPath: args[flagIndex + 1])) }
            return
        }
        if let flagIndex = args.firstIndex(of: "--render-compare"), args.indices.contains(flagIndex + 2) {
            MainActor.assumeIsolated {
                SelfTest.renderCompare(
                    url: URL(fileURLWithPath: args[flagIndex + 1]),
                    outDir: URL(fileURLWithPath: args[flagIndex + 2])
                )
            }
            return
        }
        if let flagIndex = args.firstIndex(of: "--typeset-demo"), args.indices.contains(flagIndex + 1) {
            MainActor.assumeIsolated { SelfTest.typesetDemo(to: URL(fileURLWithPath: args[flagIndex + 1])) }
            return
        }
        InkwellApp.main()
    }
}

struct InkwellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var appState = AppState()

    var body: some Scene {
        Window("Inkwell", id: "main") {
            ContentView(appState: appState)
                .onAppear { delegate.appState = appState }
        }
        .defaultSize(width: 1180, height: 800)
        .commands {
            AppCommands(appState: appState)
        }
    }
}

// MARK: - Menu commands

struct AppCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { appState.openViaPanel() }
                .keyboardShortcut("o")

            Menu("New From Paper") {
                ForEach(PaperTemplate.allCases) { template in
                    Button(template.displayName) { appState.newDocument(template: template) }
                }
            }

            if !appState.recents.isEmpty {
                Menu("Open Recent") {
                    ForEach(appState.recents, id: \.path) { url in
                        Button(url.lastPathComponent) { appState.openDocument(at: url) }
                    }
                }
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
            Button("Save") { appState.save() }
                .keyboardShortcut("s")
                .disabled(!appState.hasDocument)
            Button("Save As…") { appState.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!appState.hasDocument)
            Divider()
            Button("Turn It In (Export)…") { appState.showExportSheet = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!appState.hasDocument)
            Button("Append Another PDF…") { appState.appendPDFViaPanel() }
                .disabled(!appState.hasDocument)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { appState.performCut() }
                .keyboardShortcut("x")
            Button("Copy") { appState.performCopy() }
                .keyboardShortcut("c")
            Button("Paste") { appState.performPaste() }
                .keyboardShortcut("v")
            Button("Duplicate") { appState.duplicateSelection() }
                .keyboardShortcut("d")
                .disabled(appState.selectedAnnotations.isEmpty)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { appState.performUndo() }
                .keyboardShortcut("z")
                .disabled(!appState.hasDocument)
            Button("Redo") { appState.performRedo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!appState.hasDocument)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") { appState.printDocument() }
                .keyboardShortcut("p")
                .disabled(!appState.hasDocument)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find") { appState.searchFocusTick += 1 }
                .keyboardShortcut("f")
                .disabled(!appState.hasDocument)
            Button("Find Next") { appState.stepSearch(1) }
                .keyboardShortcut("g")
                .disabled(appState.searchResults.isEmpty)
            Button("Find Previous") { appState.stepSearch(-1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(appState.searchResults.isEmpty)
            Button("Use Selection for Find") { appState.useSelectionForFind() }
                .keyboardShortcut("e")
                .disabled(!appState.hasDocument)
        }

        CommandMenu("Annotate") {
            Button(appState.notesMode ? "Exit Notes Mode" : "Notes Mode") {
                appState.toggleNotesMode()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!appState.hasDocument)
            Divider()
            ForEach([Tool.select, .pen, .highlighter, .eraser, .fill, .text]) { tool in
                Button(tool.label) { appState.tool = tool }
            }
            Menu("Shape") {
                ForEach([Tool.line, .arrow, .doubleArrow, .rect, .ellipse, .triangle]) { tool in
                    Button(tool.label) { appState.tool = tool }
                }
            }
            Divider()
            Button("Highlight Selected Text") { appState.highlightCurrentSelection() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!appState.hasDocument)
            Button("Delete Selected Annotation") { appState.deleteSelectedAnnotation() }
                .disabled(appState.selectedAnnotations.isEmpty)
            Divider()
            Button("Math & Symbols") {
                appState.inspectorTab = .math
                appState.showInspector = true
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Stamps") {
                appState.inspectorTab = .stamps
                appState.showInspector = true
            }
            Button("Signatures") {
                appState.inspectorTab = .sign
                appState.showInspector = true
            }
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { appState.zoomIn() }
                .keyboardShortcut("+")
            Button("Zoom Out") { appState.zoomOut() }
                .keyboardShortcut("-")
            Button("Actual Size") { appState.zoomActual() }
                .keyboardShortcut("0")
            Button("Zoom to Fit") { appState.zoomFit() }
                .keyboardShortcut("9")
            Divider()
            Button("Toggle Inspector") { appState.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return }
        appState?.openDocument(at: url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        appState.pdfView?.commitTextEditing()
        guard appState.isDirty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(appState.displayName)”?"
        alert.informativeText = "Your annotations will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if appState.save() { return .terminateNow }
            reopenMainWindowIfNeeded()
            return .terminateCancel
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            // Quit may have been triggered by closing the last window; bring
            // it back so Cancel doesn't strand a windowless app.
            reopenMainWindowIfNeeded()
            return .terminateCancel
        }
    }

    private func reopenMainWindowIfNeeded() {
        guard NSApp.windows.allSatisfy({ !$0.isVisible }) else { return }
        if let window = appState?.pdfView?.window ?? NSApp.windows.first(where: { $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
