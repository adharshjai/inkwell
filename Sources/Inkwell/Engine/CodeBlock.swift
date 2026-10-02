import AppKit
import PDFKit

/// One syntax-colored span of a code line.
struct CodeRun: Equatable {
    var text: String
    var color: NSColor
    var bold = false
    var italic = false
}

/// A pasted code block: lines of colored runs in a monospaced face.
struct CodeBlockSpec {
    var lines: [[CodeRun]]
    var fontName: String
    var longestLine: Int
}

/// Turns code copied from an editor (VS Code, Xcode, a web code block) into a
/// spec Inkwell can lay out: the syntax colors and the monospaced font are
/// kept, dark-theme colors are darkened so they read on white paper.
enum CodeBlock {

    static let tabWidth = 4

    // MARK: Reading the pasteboard

    /// Rich text from the clipboard, if any — editors put RTF and/or HTML
    /// beside the plain string.
    static func attributedText(from pasteboard: NSPasteboard) -> NSAttributedString? {
        if let data = pasteboard.data(forType: .rtf),
           let text = NSAttributedString(rtf: data, documentAttributes: nil), text.length > 0 {
            return text
        }
        if let data = pasteboard.data(forType: .rtfd),
           let text = NSAttributedString(rtfd: data, documentAttributes: nil), text.length > 0 {
            return text
        }
        if let data = pasteboard.data(forType: .html),
           let text = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.html,
                         .characterEncoding: String.Encoding.utf8.rawValue],
               documentAttributes: nil
           ), text.length > 0 {
            return text
        }
        return nil
    }

    static func isMonospaced(_ font: NSFont) -> Bool {
        if font.isFixedPitch { return true }
        let name = font.fontName.lowercased()
        return ["mono", "menlo", "consol", "courier", "code", "hack", "inconsolata", "jetbrains", "andale"]
            .contains { name.contains($0) }
    }

    /// Share of characters set in a monospaced face — the "is this code?" test
    /// for rich text.
    static func monospaceRatio(_ text: NSAttributedString) -> CGFloat {
        guard text.length > 0 else { return 0 }
        var mono = 0
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont, isMonospaced(font) { mono += range.length }
        }
        return CGFloat(mono) / CGFloat(text.length)
    }

    /// Conservative check for plain text that is obviously source code (used
    /// only after the table check, so spreadsheet pastes are never stolen).
    static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return false }
        let keywords = ["func ", "def ", "class ", "import ", "return", "const ", "let ", "var ", "if ", "for ",
                        "while ", "public ", "private ", "void ", "int ", "float ", "double ", "print(", "#include",
                        "function", "struct ", "enum ", "else", "self.", "this.", "</", "/>"]
        var hits = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indented = line.hasPrefix("    ") || line.hasPrefix("\t")
            let punctuation = trimmed.hasSuffix(";") || trimmed.hasSuffix("{") || trimmed.hasSuffix("}")
                || trimmed.hasSuffix("):") || trimmed.hasPrefix("//") || trimmed.hasPrefix("#")
            let keyword = keywords.contains { trimmed.hasPrefix($0) || trimmed.contains(" \($0)") }
            if punctuation || keyword || (indented && trimmed.contains("(")) { hits += 1 }
        }
        return CGFloat(hits) / CGFloat(lines.count) >= 0.4
    }

    // MARK: Building a spec

    static func spec(from attributed: NSAttributedString) -> CodeBlockSpec? {
        var lines: [[CodeRun]] = [[]]
        var fontName: String?
        let string = attributed.string as NSString
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            let font = attributes[.font] as? NSFont
            if fontName == nil, let font, isMonospaced(font) { fontName = font.fontName }
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let color = (attributes[.foregroundColor] as? NSColor) ?? .black
            let pieces = string.substring(with: range).components(separatedBy: "\n")
            for (index, piece) in pieces.enumerated() {
                if index > 0 { lines.append([]) }
                guard !piece.isEmpty else { continue }
                lines[lines.count - 1].append(CodeRun(
                    text: expandTabs(piece),
                    color: color,
                    bold: traits.contains(.boldFontMask),
                    italic: traits.contains(.italicFontMask)
                ))
            }
        }
        return finish(lines, fontName: fontName ?? "Menlo")
    }

    static func spec(fromPlain text: String) -> CodeBlockSpec? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { [CodeRun(text: expandTabs($0), color: NSColor(white: 0.16, alpha: 1))] }
        return finish(lines, fontName: "Menlo")
    }

    private static func expandTabs(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: tabWidth))
    }

    private static func finish(_ rawLines: [[CodeRun]], fontName: String) -> CodeBlockSpec? {
        var lines = rawLines
        while let first = lines.first, first.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
            lines.removeFirst()
        }
        while let last = lines.last, last.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return nil }
        lines = adaptedToPaper(lines)
        let longest = lines.map { $0.reduce(0) { $0 + $1.text.count } }.max() ?? 0
        guard longest > 0 else { return nil }
        return CodeBlockSpec(lines: lines, fontName: fontName, longestLine: longest)
    }

    // MARK: Colors that read on paper

    static func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    /// Keeps the hue, drops the brightness: a dark-theme palette stays
    /// recognizable but legible on a white page.
    static func readableOnPaper(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.12 { return NSColor(white: 0.16, alpha: a) }
        return NSColor(hue: h, saturation: min(1, max(s, 0.6)), brightness: min(b, 0.62), alpha: a)
    }

    /// Dark-theme source (light text) gets its palette darkened.
    private static func adaptedToPaper(_ lines: [[CodeRun]]) -> [[CodeRun]] {
        let visible = lines.flatMap { $0 }.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !visible.isEmpty else { return lines }
        let average = visible.reduce(CGFloat(0)) { $0 + luminance($1.color) } / CGFloat(visible.count)
        guard average > 0.5 else { return lines }
        return lines.map { $0.map { run in
            var adapted = run
            adapted.color = readableOnPaper(run.color)
            return adapted
        } }
    }

    /// Hard-wraps lines that are still too wide after shrinking, keeping runs
    /// intact where possible.
    static func wrap(_ lines: [[CodeRun]], at maxCharacters: Int) -> [[CodeRun]] {
        guard maxCharacters > 8 else { return lines }
        var wrapped: [[CodeRun]] = []
        for line in lines {
            var current: [CodeRun] = []
            var column = 0
            for run in line {
                var remaining = Substring(run.text)
                while !remaining.isEmpty {
                    let room = maxCharacters - column
                    if room <= 0 {
                        wrapped.append(current)
                        current = []
                        column = 0
                        continue
                    }
                    let take = min(room, remaining.count)
                    let piece = String(remaining.prefix(take))
                    remaining = remaining.dropFirst(take)
                    current.append(CodeRun(text: piece, color: run.color, bold: run.bold, italic: run.italic))
                    column += take
                }
            }
            wrapped.append(current)
        }
        return wrapped
    }
}
