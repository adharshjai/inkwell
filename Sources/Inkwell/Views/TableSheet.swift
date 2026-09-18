import PDFKit
import SwiftUI

/// Insert or edit a table: paste or type rows, pick a style, see it live.
struct TableSheet: View {
    let appState: AppState
    @State var request: TableRequest
    @Environment(\.dismiss) private var dismiss

    private var rows: [[String]]? { TableLayout.parse(request.text) }

    private var spec: TableSpec? {
        rows.map { TableSpec(rows: $0, header: request.header, style: request.style) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(request.editing == nil ? "Insert Table" : "Edit Table", systemImage: "tablecells")
                .font(.title2.weight(.semibold))

            Text("Paste from Sheets, Excel, or Numbers — or type one row per line with | or commas between cells.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $request.text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 140)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .overlay(alignment: .topLeading) {
                    if request.text.isEmpty {
                        Text("h (m) | Predicted t (s) | Measured t (s)\n0.5 | 0.319 | 0.323")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(11)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Picker("Style", selection: $request.style) {
                    ForEach(TableStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                Spacer()
                Toggle("First row is a header", isOn: $request.header)
            }

            GroupBox {
                Group {
                    if let spec {
                        TablePreview(spec: spec)
                    } else {
                        Text("Your table will appear here")
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150)
            } label: {
                Text(rows.map { "Preview — \($0.count) × \($0.first?.count ?? 0)" } ?? "Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(request.editing == nil ? "Place on Page" : "Update Table") {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(spec == nil)
            }
        }
        .padding(24)
        .frame(width: 580)
        .onChange(of: request.text) { old, new in
            // First paste into an empty editor: guess the header for them.
            if old.isEmpty, let rows = TableLayout.parse(new) {
                request.header = TableLayout.guessHeader(rows)
            }
        }
    }

    private func commit() {
        guard let spec else { return }
        if let editing = request.editing, let page = request.page {
            appState.replaceTable(editing, on: page, with: spec)
        } else {
            appState.pendingPlacement = .table(spec)
        }
        dismiss()
    }
}

/// Filled-outline render of a table layout, scaled to fit.
struct TablePreview: View {
    let spec: TableSpec

    var body: some View {
        Canvas { context, size in
            guard let geo = TableLayout.layout(spec, fontSize: 11), geo.width > 0, geo.height > 0 else { return }
            let scale = min(1.6, (size.width - 12) / geo.width, (size.height - 12) / geo.height)
            let originX = (size.width - geo.width * scale) / 2
            let originY = (size.height - geo.height * scale) / 2
            // Layout is y-up with the top at 0; flip into the canvas.
            let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: originX, ty: originY)
            var path = Path()
            for glyph in geo.glyphs { path.addPath(Path(glyph), transform: transform) }
            for rule in geo.rules { path.addRect(rule, transform: transform) }
            context.fill(path, with: .color(.primary))
        }
    }
}
