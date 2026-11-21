import Foundation

/// Recognizes math copied out of a chat or a paper — `$$…$$`, `$…$`, `\[…\]`,
/// `\(…\)`, `\begin{…}…\end{…}` — and hands back the LaTeX lines to typeset.
enum MathPaste {

    struct Block {
        var lines: [String]   // one typeset line each (split on \\)
        var display: Bool     // $$ / \[ / environment → bigger, standalone
    }

    /// The whole paste is math: one or more delimited blocks, or bare LaTeX.
    static func blocks(in text: String) -> [Block]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // If the paste uses delimiters at all, every chunk must be delimited —
        // otherwise a shell script full of $HOME reads as an equation.
        let delimited = hasDelimiters(trimmed)
        var found: [Block] = []
        var rest = Substring(trimmed)
        while !rest.isEmpty {
            rest = rest.drop { $0.isWhitespace }
            guard !rest.isEmpty else { break }
            guard let block = takeBlock(&rest, allowBare: !delimited) else { return nil }
            found.append(block)
        }
        guard !found.isEmpty else { return nil }

        // No delimiters anywhere: accept only if it reads as LaTeX, never prose.
        if found.count == 1, !found[0].display, !hasDelimiters(trimmed) {
            guard looksLikeBareLatex(trimmed) else { return nil }
        }
        return found
    }

    private static func hasDelimiters(_ text: String) -> Bool {
        text.contains("$") || text.contains("\\[") || text.contains("\\(") || text.contains("\\begin{")
    }

    /// Pulls one delimited block (or the whole remainder) off the front.
    private static func takeBlock(_ rest: inout Substring, allowBare: Bool) -> Block? {
        func consume(open: String, close: String, display: Bool) -> Block? {
            guard rest.hasPrefix(open) else { return nil }
            let body = rest.dropFirst(open.count)
            guard let end = body.range(of: close) else { return nil }
            let inner = String(body[body.startIndex..<end.lowerBound])
            rest = body[end.upperBound...]
            return Block(lines: split(inner), display: display)
        }
        if let block = consume(open: "$$", close: "$$", display: true) { return block }
        if let block = consume(open: "\\[", close: "\\]", display: true) { return block }
        if let block = consume(open: "\\(", close: "\\)", display: false) { return block }
        if rest.hasPrefix("\\begin{") {
            guard let nameEnd = rest.range(of: "}"),
                  let close = rest.range(of: "\\end{") else { return nil }
            let name = String(rest[rest.index(rest.startIndex, offsetBy: 7)..<nameEnd.lowerBound])
            let inner = String(rest[nameEnd.upperBound..<close.lowerBound])
            let after = rest[close.upperBound...]
            rest = after.drop { $0 != "}" }.dropFirst()
            _ = name
            return Block(lines: split(inner), display: true)
        }
        if rest.hasPrefix("$") {
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: "$") else { return nil }
            let inner = String(body[body.startIndex..<end])
            rest = body[body.index(after: end)...]
            return Block(lines: split(inner), display: false)
        }
        // Undelimited remainder: only valid when nothing was delimited.
        guard allowBare else { return nil }
        let inner = String(rest)
        rest = ""
        return Block(lines: split(inner), display: false)
    }

    /// Splits a block on `\\` row breaks and drops alignment/bookkeeping marks.
    static func split(_ latex: String) -> [String] {
        latex.components(separatedBy: "\\\\")
            .map { line in
                line.replacingOccurrences(of: "&", with: " ")
                    .replacingOccurrences(of: "\\nonumber", with: "")
                    .replacingOccurrences(of: "\\notag", with: "")
                    .replacingOccurrences(of: "\\displaystyle", with: "")
                    .replacingOccurrences(of: "\\label{[^}]*}", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    /// Worth typesetting: has an operator, a script, or a command in it.
    static func isMathy(_ latex: String) -> Bool {
        let trimmed = latex.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 160 else { return false }
        if trimmed.contains("\\") { return true }
        let signals: Set<Character> = ["^", "_", "=", "+", "/", "<", ">", "≤", "≥"]
        if trimmed.contains(where: { signals.contains($0) }) { return true }
        // A lone token like "81" or "x_1" is fine; "5 and " (from "$5 and $7")
        // is a price, not math.
        return trimmed.count <= 12 && !trimmed.contains(" ") && trimmed.contains(where: \.isNumber)
    }

    /// Undelimited text that is clearly LaTeX, not a sentence.
    static func looksLikeBareLatex(_ text: String) -> Bool {
        guard text.contains("\\") else { return false }
        // Prose giveaway: ordinary words outside of commands.
        let withoutCommands = text.replacingOccurrences(
            of: "\\\\[A-Za-z]+", with: " ", options: .regularExpression
        )
        let words = withoutCommands
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && $0.allSatisfy(\.isLetter) }
        return words.count <= 1
    }

    // MARK: Prose with inline math

    /// Prose containing `$…$` / `\(…\)` spans → the same prose with those
    /// spans converted to Unicode math, for a normal text box.
    static func proseWithInlineMath(_ text: String) -> String? {
        guard text.contains("$") || text.contains("\\(") else { return nil }
        var out = ""
        var rest = Substring(text)
        var converted = 0
        while let marker = rest.firstIndex(where: { $0 == "$" || $0 == "\\" }) {
            let isInline = rest[marker] == "$"
                ? true
                : rest[marker...].hasPrefix("\\(")
            guard isInline else {
                out.append(contentsOf: rest[...marker])
                rest = rest[rest.index(after: marker)...]
                continue
            }
            out.append(contentsOf: rest[..<marker])
            let open = rest[marker] == "$" ? "$" : "\\("
            let close = rest[marker] == "$" ? "$" : "\\)"
            let body = rest[marker...].dropFirst(open.count)
            guard let end = body.range(of: close) else {
                out.append(contentsOf: rest[marker...])
                rest = ""
                break
            }
            let latex = String(body[body.startIndex..<end.lowerBound])
            if isMathy(latex) {
                out += MathText.render(latex)
                converted += 1
            } else {
                // Not math — a shell variable, a price. Keep it verbatim.
                out += open + latex + close
            }
            rest = body[end.upperBound...]
        }
        out.append(contentsOf: rest)
        return converted > 0 ? out : nil
    }
}
