import SwiftUI

/// Floating Liquid Glass tool palette pinned to the bottom of the PDF canvas.
struct ToolPalette: View {
    let appState: AppState
    @State private var showStyle = false

    private let mainTools: [Tool] = [.select, .pen, .highlighter, .eraser, .text]
    private let shapeTools: [Tool] = [.line, .arrow, .rect, .ellipse]

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(mainTools) { tool in
                    toolButton(tool)
                }

                shapeMenu

                Divider()
                    .frame(height: 22)
                    .padding(.horizontal, 4)

                styleButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
        }
    }

    // MARK: Pieces

    private func toolButton(_ tool: Tool) -> some View {
        Button {
            appState.tool = tool
            appState.pendingPlacement = nil
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(appState.tool == tool ? Color.white : Color.primary)
        .background {
            if appState.tool == tool {
                Capsule().fill(Color.accentColor)
            }
        }
        .help("\(tool.label)\(tool.hotkey.map { "  (\($0.uppercased()))" } ?? "")")
    }

    private var shapeMenu: some View {
        Menu {
            ForEach(shapeTools) { tool in
                Button {
                    appState.tool = tool
                    appState.pendingPlacement = nil
                } label: {
                    Label(tool.label, systemImage: tool.systemImage)
                }
            }
        } label: {
            Image(systemName: appState.tool.isShape ? appState.tool.systemImage : "square.on.circle")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        } primaryAction: {
            appState.tool = appState.tool.isShape ? appState.tool : .line
            appState.pendingPlacement = nil
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(appState.tool.isShape ? Color.white : Color.primary)
        .background {
            if appState.tool.isShape {
                Capsule().fill(Color.accentColor)
            }
        }
        .help("Shapes: Line (L), Arrow (A), Rectangle (R), Ellipse (O)")
    }

    private var styleButton: some View {
        Button {
            showStyle.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(Color(nsColor: appState.tool == .highlighter ? appState.highlightColor : appState.inkColor))
                    .frame(width: 18, height: 18)
                Circle()
                    .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                    .frame(width: 18, height: 18)
            }
            .frame(width: 34, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Ink color & stroke width")
        .popover(isPresented: $showStyle, arrowEdge: .top) {
            StylePopover(appState: appState)
        }
    }
}

// MARK: - Style popover

struct StylePopover: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ink")
                .font(.headline)
            HStack(spacing: 8) {
                ForEach(NSColor.inkSwatches, id: \.name) { swatch in
                    swatchButton(swatch.color, name: swatch.name, isSelected: appState.inkColor == swatch.color) {
                        appState.inkColor = swatch.color
                    }
                }
            }
            HStack {
                Image(systemName: "lineweight")
                    .foregroundStyle(.secondary)
                Slider(value: strokeWidthBinding, in: 0.5...6, step: 0.1)
                Text(String(format: "%.1f pt", appState.inkWidth))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Divider()

            Text("Highlighter")
                .font(.headline)
            HStack(spacing: 8) {
                ForEach(NSColor.highlightSwatches, id: \.name) { swatch in
                    swatchButton(swatch.color, name: swatch.name, isSelected: appState.highlightColor == swatch.color) {
                        appState.highlightColor = swatch.color
                    }
                }
                Spacer()
                Slider(value: highlightWidthBinding, in: 6...26, step: 1)
                    .frame(width: 90)
            }

            Divider()

            HStack {
                Text("Text size")
                    .font(.headline)
                Spacer()
                Stepper(value: fontSizeBinding, in: 8...36, step: 1) {
                    Text("\(Int(appState.fontSize)) pt")
                        .font(.body.monospacedDigit())
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var strokeWidthBinding: Binding<CGFloat> {
        Binding(get: { appState.inkWidth }, set: { appState.inkWidth = $0 })
    }

    private var highlightWidthBinding: Binding<CGFloat> {
        Binding(get: { appState.highlightWidth }, set: { appState.highlightWidth = $0 })
    }

    private var fontSizeBinding: Binding<CGFloat> {
        Binding(get: { appState.fontSize }, set: { appState.fontSize = $0 })
    }

    private func swatchButton(_ color: NSColor, name: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: color))
                    .frame(width: 24, height: 24)
                if isSelected {
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        .frame(width: 30, height: 30)
                }
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .help(name)
    }
}
