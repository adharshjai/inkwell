import SwiftUI

/// Floating Word-style formatting bar for the selected (or edited) text box:
/// smaller / size menu / bigger, bold, italic, alignment.
struct TextFormatBar: View {
    let appState: AppState

    var body: some View {
        let _ = appState.textStyleTick
        let _ = appState.docVersion
        let target = appState.styleTargetTextBoxes.first
        let size = target?.font?.pointSize ?? appState.fontSize
        let bold = target.map(Annotations.textIsBold) ?? appState.textBold
        let italic = target.map(Annotations.textIsItalic) ?? appState.textItalic
        let alignment = target?.alignment ?? appState.textAlignment

        HStack(spacing: 2) {
            iconButton("textformat.size.smaller", help: "Smaller text (⌘[)") {
                appState.stepTextSize(-1)
            }
            Menu {
                ForEach(AppState.textSizeLadder, id: \.self) { s in
                    Button("\(AppState.formatSize(s)) pt") { appState.setTextSize(s) }
                }
            } label: {
                Text("\(AppState.formatSize(size)) pt")
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 44)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Text size")
            iconButton("textformat.size.larger", help: "Bigger text (⌘])") {
                appState.stepTextSize(1)
            }

            Divider().frame(height: 16).padding(.horizontal, 3)

            iconButton("bold", active: bold, help: "Bold (⌘B while typing)") {
                appState.applyTextStyle(bold: !bold)
            }
            iconButton("italic", active: italic, help: "Italic (⌘I while typing)") {
                appState.applyTextStyle(italic: !italic)
            }

            Divider().frame(height: 16).padding(.horizontal, 3)

            iconButton("text.alignleft", active: alignment == .left, help: "Align left") {
                appState.applyTextStyle(alignment: .left)
            }
            iconButton("text.aligncenter", active: alignment == .center, help: "Center") {
                appState.applyTextStyle(alignment: .center)
            }
            iconButton("text.alignright", active: alignment == .right, help: "Align right") {
                appState.applyTextStyle(alignment: .right)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .glassEffect(.regular, in: .capsule)
        .padding(4)
        .fixedSize()
    }

    private func iconButton(_ symbol: String, active: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.white : Color.primary)
        .background {
            if active {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
            }
        }
        .help(help)
    }
}
