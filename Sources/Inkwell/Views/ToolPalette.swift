import SwiftUI

/// Floating Liquid Glass tool palette pinned to the bottom of the PDF canvas.
struct ToolPalette: View {
    let appState: AppState
    @State private var showStyle = false

    private let mainTools: [Tool] = [.select, .pen, .highlighter, .eraser, .fill, .text]
    private let shapeTools: [Tool] = [.line, .arrow, .doubleArrow, .rect, .ellipse, .triangle]

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
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .foregroundStyle(appState.tool.isShape ? Color.white : Color.primary)
        .background {
            if appState.tool.isShape {
                Capsule().fill(Color.accentColor)
            }
        }
        .help("Shapes: line, arrows, rectangle, ellipse, triangle — hotkeys L, A, R, O")
    }

    private var styleDotColor: NSColor {
        switch appState.tool {
        case .highlighter: appState.highlightColor
        case .fill: appState.fillColor
        default: appState.inkColor
        }
    }

    private var styleButton: some View {
        Button {
            showStyle.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(Color(nsColor: styleDotColor))
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
            HStack {
                Text("Ink")
                    .font(.headline)
                Spacer()
                ColorPicker("Ink color", selection: nsColorBinding(\.inkColor), supportsOpacity: true)
                    .labelsHidden()
            }
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

            HStack {
                Text("Highlighter")
                    .font(.headline)
                Spacer()
                ColorPicker("Highlighter color", selection: nsColorBinding(\.highlightColor), supportsOpacity: true)
                    .labelsHidden()
            }
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
                Image(systemName: "eraser")
                    .foregroundStyle(.secondary)
                Text("Eraser size")
                    .font(.subheadline)
                Slider(value: eraserSizeBinding, in: 1...20, step: 0.5)
                Text("\(Int(appState.eraserSize)) px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }

            Divider()

            HStack {
                Text("Bucket fill")
                    .font(.headline)
                Spacer()
                ColorPicker("Fill color", selection: nsColorBinding(\.fillColor), supportsOpacity: true)
                    .labelsHidden()
            }
            Text("Pick the Fill tool (B), then click inside any closed shape — yours or the page's.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()

            HStack {
                Text("Text")
                    .font(.headline)
                Spacer()
                Button {
                    appState.stepTextSize(-1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .help("Smaller text (⌘[)")
                Text("\(AppState.formatSize(currentSize)) pt")
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 50)
                Button {
                    appState.stepTextSize(1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .help("Bigger text (⌘])")
            }
            HStack(spacing: 8) {
                Toggle(isOn: boldBinding) { Image(systemName: "bold") }
                    .toggleStyle(.button)
                    .help("Bold (⌘B while typing)")
                Toggle(isOn: italicBinding) { Image(systemName: "italic") }
                    .toggleStyle(.button)
                    .help("Italic (⌘I while typing)")
                Spacer()
                Picker("Alignment", selection: alignmentBinding) {
                    Image(systemName: "text.alignleft").tag(NSTextAlignment.left)
                    Image(systemName: "text.aligncenter").tag(NSTextAlignment.center)
                    Image(systemName: "text.alignright").tag(NSTextAlignment.right)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }
            Text(appState.styleTargetTextBoxes.isEmpty
                 ? "Applies to new text boxes. Select a box (or edit one) to restyle it."
                 : "Restyling \(appState.styleTargetTextBoxes.count) text box\(appState.styleTargetTextBoxes.count == 1 ? "" : "es").")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()

            Toggle(isOn: hapticsBinding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Trackpad haptics")
                    Text("Feel strokes land, shapes snap, and fills thunk.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var hapticsBinding: Binding<Bool> {
        Binding(
            get: { Haptics.enabled },
            set: { on in
                Haptics.enabled = on
                if on { Haptics.snap() }
            }
        )
    }

    /// Full-spectrum picker binding (the system panel: wheel, sliders,
    /// eyedropper, opacity) for any NSColor property.
    private func nsColorBinding(_ keyPath: ReferenceWritableKeyPath<AppState, NSColor>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: appState[keyPath: keyPath]) },
            set: { appState[keyPath: keyPath] = NSColor($0) }
        )
    }

    private var strokeWidthBinding: Binding<CGFloat> {
        Binding(get: { appState.inkWidth }, set: { appState.inkWidth = $0 })
    }

    private var eraserSizeBinding: Binding<CGFloat> {
        Binding(get: { appState.eraserSize }, set: { appState.eraserSize = $0 })
    }

    private var highlightWidthBinding: Binding<CGFloat> {
        Binding(get: { appState.highlightWidth }, set: { appState.highlightWidth = $0 })
    }

    private var currentSize: CGFloat {
        _ = appState.textStyleTick
        _ = appState.docVersion
        return appState.currentTextSize ?? appState.fontSize
    }

    private var fontSizeBinding: Binding<CGFloat> {
        Binding(get: { appState.fontSize }, set: { appState.applyTextStyle(size: $0) })
    }

    private var boldBinding: Binding<Bool> {
        Binding(
            get: { appState.styleTargetTextBoxes.first.map(Annotations.textIsBold) ?? appState.textBold },
            set: { appState.applyTextStyle(bold: $0) }
        )
    }

    private var italicBinding: Binding<Bool> {
        Binding(
            get: { appState.styleTargetTextBoxes.first.map(Annotations.textIsItalic) ?? appState.textItalic },
            set: { appState.applyTextStyle(italic: $0) }
        )
    }

    private var alignmentBinding: Binding<NSTextAlignment> {
        Binding(
            get: { appState.styleTargetTextBoxes.first?.alignment ?? appState.textAlignment },
            set: { appState.applyTextStyle(alignment: $0) }
        )
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
