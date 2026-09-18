import AppKit
import CoreText
import PDFKit

enum TableStyle: String, CaseIterable, Identifiable {
    case grid, lines, plain
    var id: String { rawValue }
    var label: String {
        switch self {
        case .grid: "Grid"
        case .lines: "Lines"
        case .plain: "Plain"
        }
    }
}

struct TableSpec: Equatable {
    var rows: [[String]]
    var header: Bool = true
    var style: TableStyle = .grid

    var columnCount: Int { rows.map(\.count).max() ?? 0 }
}

/// Glyph outlines and rule rectangles for a laid-out table. y-up, with the
/// table's top-left corner at the origin (everything lives at y ≤ 0).
struct TableGeometry {
    var glyphs: [CGPath] = []
    var rules: [CGRect] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
}

/// Parses pasted/typed tables and lays them out. Tables are stored as one
/// ink annotation (grid + hatch-filled glyphs) whose /Contents carries the
/// source, so a double-click can reopen and re-render it.
enum TableLayout {

    // MARK: Parsing

    /// Tabs (spreadsheets), Markdown pipes, or CSV. `strict` — used to decide
    /// whether a ⌘V is a table — refuses the loose runs-of-spaces fallback so
    /// ordinary prose never turns into a table.
    static func parse(_ text: String, strict: Bool = false) -> [[String]]? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return nil }

        var rows: [[String]]
        if lines.contains(where: { $0.contains("\t") }) {
            rows = lines.map { $0.components(separatedBy: "\t") }
        } else if lines.filter({ $0.contains("|") }).count >= max(1, (lines.count + 1) / 2) {
            rows = lines.compactMap { line -> [String]? in
                var cells = line.components(separatedBy: "|")
                if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
                if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
                let isSeparator = !cells.isEmpty && cells.allSatisfy { cell in
                    let t = cell.trimmingCharacters(in: .whitespaces)
                    return !t.isEmpty && t.allSatisfy { "-:".contains($0) }
                }
                return isSeparator || cells.isEmpty ? nil : cells
            }
        } else if let csv = consistentCSV(lines) {
            rows = csv
        } else if !strict {
            rows = lines.map {
                $0.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\\s{2,}", with: "\t", options: .regularExpression)
                    .components(separatedBy: "\t")
            }
        } else {
            return nil
        }

        rows = rows.map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
        let columns = rows.map(\.count).max() ?? 0
        guard !rows.isEmpty, columns >= 1 else { return nil }
        if strict, columns < 2 { return nil }
        return rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
    }

    private static func consistentCSV(_ lines: [String]) -> [[String]]? {
        guard lines.allSatisfy({ $0.contains(",") }) else { return nil }
        let rows = lines.map(parseCSVLine)
        let counts = Set(rows.map(\.count))
        guard counts.count == 1, let n = counts.first, n >= 2 else { return nil }
        return rows
    }

    static func parseCSVLine(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if inQuotes, i + 1 < chars.count, chars[i + 1] == "\"" {
                    current.append("\"")
                    i += 1
                } else {
                    inQuotes.toggle()
                }
            } else if c == ",", !inQuotes {
                cells.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        cells.append(current)
        return cells
    }

    // MARK: Cell classification

    private static let numberPattern = try? NSRegularExpression(
        pattern: #"^[+\-−±~≈<>]?\s*\$?(\d{1,3}(,\d{3})+|\d+)?(\.\d+)?([eE][+\-−]?\d+)?\s*(%|°|‰)?$"#
    )

    static func isNumeric(_ cell: String) -> Bool {
        let t = cell.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.contains(where: \.isNumber), let numberPattern else { return false }
        return numberPattern.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    /// A first row with no numbers above rows that have some reads as a header.
    static func guessHeader(_ rows: [[String]]) -> Bool {
        guard rows.count >= 2 else { return false }
        return !rows[0].contains(where: isNumeric)
    }

    /// Columns whose body cells are mostly numbers get right-aligned.
    static func numericColumns(_ spec: TableSpec) -> [Bool] {
        let body = spec.header ? Array(spec.rows.dropFirst()) : spec.rows
        return (0..<spec.columnCount).map { c in
            let values = body.map { c < $0.count ? $0[c] : "" }.filter { !$0.isEmpty }
            guard !values.isEmpty else { return false }
            return values.filter(isNumeric).count * 2 >= values.count
        }
    }

    // MARK: Layout

    static func layout(_ spec: TableSpec, fontSize: CGFloat) -> TableGeometry? {
        let columns = spec.columnCount
        guard columns > 0, !spec.rows.isEmpty, fontSize > 0 else { return nil }
        let regular = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let bold = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let padX = fontSize * 0.6
        let padY = fontSize * (spec.style == .lines ? 0.42 : 0.34)
        let ascent = CTFontGetAscent(regular)
        let descent = CTFontGetDescent(regular)
        let rowHeight = ascent + descent + padY * 2

        let shaped: [[(glyphs: [CGPath], width: CGFloat)]] = spec.rows.enumerated().map { r, row in
            let font = (spec.header && r == 0) ? bold : regular
            return row.map { shape($0, font: font) }
        }
        var colWidths = [CGFloat](repeating: 0, count: columns)
        for row in shaped {
            for (c, cell) in row.enumerated() { colWidths[c] = max(colWidths[c], cell.width) }
        }
        colWidths = colWidths.map { max($0, fontSize * 1.2) + padX * 2 }
        var starts: [CGFloat] = []
        var cursor: CGFloat = 0
        for w in colWidths {
            starts.append(cursor)
            cursor += w
        }
        let totalWidth = cursor
        let totalHeight = rowHeight * CGFloat(spec.rows.count)
        let numeric = numericColumns(spec)

        var geo = TableGeometry(width: totalWidth, height: totalHeight)
        for (r, row) in shaped.enumerated() {
            let baseline = -CGFloat(r) * rowHeight - padY - ascent
            let isHeader = spec.header && r == 0
            for (c, cell) in row.enumerated() where !cell.glyphs.isEmpty {
                let x: CGFloat
                if isHeader {
                    x = starts[c] + (colWidths[c] - cell.width) / 2
                } else if numeric[c] {
                    x = starts[c] + colWidths[c] - padX - cell.width
                } else {
                    x = starts[c] + padX
                }
                var t = CGAffineTransform(translationX: x, y: baseline)
                for g in cell.glyphs {
                    if let moved = g.copy(using: &t) { geo.glyphs.append(moved) }
                }
            }
        }

        let thin = max(fontSize * 0.05, 0.45)
        let thick = thin * 2.2
        func hRule(_ y: CGFloat, _ w: CGFloat) {
            geo.rules.append(CGRect(x: 0, y: y - w / 2, width: totalWidth, height: w))
        }
        func vRule(_ x: CGFloat, _ w: CGFloat) {
            geo.rules.append(CGRect(x: x - w / 2, y: -totalHeight, width: w, height: totalHeight))
        }
        let hasHeaderRule = spec.header && spec.rows.count > 1
        switch spec.style {
        case .grid:
            for r in 0...spec.rows.count {
                hRule(-CGFloat(r) * rowHeight, (hasHeaderRule && r == 1) ? thick : thin)
            }
            for x in starts + [totalWidth] { vRule(x, thin) }
        case .lines:
            hRule(0, thick)
            if hasHeaderRule { hRule(-rowHeight, thin) }
            hRule(-totalHeight, thick)
        case .plain:
            if hasHeaderRule { hRule(-rowHeight, thin) }
        }
        return geo
    }

    /// Glyph outlines for one cell (CoreText handles font fallback, so
    /// ±, °, Greek, and friends all render).
    private static func shape(_ text: String, font: CTFont) -> (glyphs: [CGPath], width: CGFloat) {
        guard !text.isEmpty else { return ([], 0) }
        let attributed = NSAttributedString(string: text, attributes: [.font: font as NSFont])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        var paths: [CGPath] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
            let runFont = (attributes[.font] as? NSFont).map { $0 as CTFont } ?? font
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for i in 0..<count {
                var t = CGAffineTransform(translationX: positions[i].x, y: positions[i].y)
                if let path = CTFontCreatePathForGlyph(runFont, glyphs[i], &t) {
                    paths.append(path)
                }
            }
        }
        return (paths, width)
    }

    /// Solid rule as parallel strokes along its long axis (ink annotations
    /// can only stroke).
    static func ruleStrokes(_ rect: CGRect, strokeWidth: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = strokeWidth
        let spacing = strokeWidth * 0.78
        if rect.width >= rect.height {
            var y = rect.minY + strokeWidth / 2
            repeat {
                path.move(to: CGPoint(x: rect.minX, y: min(y, rect.maxY)))
                path.line(to: CGPoint(x: rect.maxX, y: min(y, rect.maxY)))
                y += spacing
            } while y <= rect.maxY - strokeWidth / 2 + 0.01
        } else {
            var x = rect.minX + strokeWidth / 2
            repeat {
                path.move(to: CGPoint(x: min(x, rect.maxX), y: rect.minY))
                path.line(to: CGPoint(x: min(x, rect.maxX), y: rect.maxY))
                x += spacing
            } while x <= rect.maxX - strokeWidth / 2 + 0.01
        }
        return path
    }

    // MARK: Source round-trip (stored in the annotation's /Contents)

    static let marker = "[inkwell-table"

    struct Source {
        var spec: TableSpec
        var fontSize: CGFloat
        var height: CGFloat
    }

    static func encode(_ spec: TableSpec, fontSize: CGFloat, height: CGFloat) -> String {
        let head = "\(marker) v1 style=\(spec.style.rawValue) header=\(spec.header ? 1 : 0) fs=\(fontSize) h=\(height)]"
        let body = spec.rows.map { row in
            row.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t")
        }.joined(separator: "\n")
        return head + "\n" + body
    }

    static func decode(_ contents: String?) -> Source? {
        guard let contents, contents.hasPrefix(marker) else { return nil }
        let parts = contents.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let head = String(parts[0])
        let body = parts.count > 1 ? String(parts[1]) : ""
        var spec = TableSpec(rows: [])
        var fontSize: CGFloat = 11
        var height: CGFloat = 0
        for token in head.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: " ") {
            let kv = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "style": spec.style = TableStyle(rawValue: kv[1]) ?? .grid
            case "header": spec.header = kv[1] == "1"
            case "fs": fontSize = CGFloat(Double(kv[1]) ?? 11)
            case "h": height = CGFloat(Double(kv[1]) ?? 0)
            default: break
            }
        }
        let rows = body.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
        let columns = rows.map(\.count).max() ?? 0
        spec.rows = rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
        return Source(spec: spec, fontSize: fontSize, height: height)
    }

    static func isTable(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "Ink" && (annotation.contents?.hasPrefix(marker) ?? false)
    }

    /// Human-editable form for the table sheet (pipes read better than tabs).
    static func editableText(_ spec: TableSpec) -> String {
        spec.rows.map { $0.joined(separator: " | ") }.joined(separator: "\n")
    }
}
