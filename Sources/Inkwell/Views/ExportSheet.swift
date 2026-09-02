import PDFKit
import SwiftUI

/// "Turn It In" — submission-ready export with a filename builder and pre-flight checks.
struct ExportSheet: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    @AppStorage("inkwell.export.course") private var course = ""
    @AppStorage("inkwell.export.assignment") private var assignment = ""
    @AppStorage("inkwell.export.student") private var student = ""
    @State private var flatten = true
    @State private var useBuilder = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Turn It In", systemImage: "paperplane.circle.fill")
                .font(.title2.weight(.semibold))

            // Pre-flight
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    preflightRow(
                        icon: "doc.on.doc",
                        text: "\(appState.pageCount) page\(appState.pageCount == 1 ? "" : "s")"
                    )
                    let unfilled = unfilledFieldCount
                    if unfilled > 0 {
                        preflightRow(
                            icon: "exclamationmark.triangle.fill",
                            text: "\(unfilled) form field\(unfilled == 1 ? "" : "s") still empty",
                            color: .orange
                        )
                    } else if hasFormFields {
                        preflightRow(icon: "checkmark.circle.fill", text: "All form fields filled", color: .green)
                    }
                    if appState.isDirty {
                        preflightRow(icon: "pencil.circle", text: "Unsaved changes (export includes them)", color: .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Pre-flight").font(.caption).foregroundStyle(.secondary)
            }

            // Filename builder
            Toggle("Build a submission filename", isOn: $useBuilder)
            if useBuilder {
                Grid(alignment: .leading, verticalSpacing: 8) {
                    GridRow {
                        Text("Course")
                        TextField("PHYS 2213", text: $course)
                    }
                    GridRow {
                        Text("Assignment")
                        TextField("PS3", text: $assignment)
                    }
                    GridRow {
                        Text("Name")
                        TextField("Last, First", text: $student)
                    }
                }
                .textFieldStyle(.roundedBorder)

                Text(suggestedFilename)
                    .font(.system(.callout, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            Toggle(isOn: $flatten) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Flatten annotations & form fields")
                    Text("Burns your ink, text, and answers into the page so every grader and viewer sees them. Recommended for submissions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export PDF…") {
                    export()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func preflightRow(icon: String, text: String, color: Color = .primary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.callout)
        }
    }

    private var suggestedFilename: String {
        let parts = [course, assignment, student]
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "") }
            .filter { !$0.isEmpty }
        let base = parts.isEmpty ? appState.displayName : parts.joined(separator: "_")
        return base + ".pdf"
    }

    private var hasFormFields: Bool {
        guard let doc = appState.document else { return false }
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), page.annotations.contains(where: { $0.widgetFieldType == .text }) {
                return true
            }
        }
        return false
    }

    private var unfilledFieldCount: Int {
        guard let doc = appState.document else { return 0 }
        var count = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for annotation in page.annotations where annotation.widgetFieldType == .text {
                if (annotation.widgetStringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    count += 1
                }
            }
        }
        return count
    }

    private func export() {
        appState.pdfView?.commitTextEditing()
        guard let document = appState.document else { return }
        if document.isLocked {
            let alert = NSAlert()
            alert.messageText = "This PDF is locked"
            alert.informativeText = "Unlock it with its password (click the page and enter it) before exporting, or the export would be blank."
            alert.runModal()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = useBuilder ? suggestedFilename : "\(appState.displayName).pdf"
        panel.message = "Export your submission PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let data: Data? = flatten
            ? appState.withOwnAnnotationsVisible { Exporter.flattened(document) }
            : appState.compactData()
        guard let data else {
            appState.flash("Export failed")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            appState.flash("Exported \(url.lastPathComponent) (\(Exporter.formatBytes(data.count)))", seconds: 4)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            dismiss()
        } catch {
            appState.flash("Export failed: \(error.localizedDescription)")
        }
    }
}
