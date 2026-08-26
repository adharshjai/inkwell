import Foundation
import CoreGraphics

// MARK: - Expression tree

indirect enum MathNode {
    case row([MathNode])
    /// A run of characters sharing a style.
    case symbol(String, MathStyle)
    case frac(MathNode, MathNode)
    case sqrt(MathNode, index: MathNode?)
    case scripts(base: MathNode, sup: MathNode?, sub: MathNode?)
    /// ∫ ∑ ∏ ∮ with limits (∑/∏ set limits above/below; ∫/∮ beside).
    case bigOp(String, sup: MathNode?, sub: MathNode?, limitsAboveBelow: Bool)
    /// Parenthesized/bracketed content whose delimiters stretch to fit.
    case delimited(open: String, content: MathNode, close: String)
    /// Drawn accent above the base: \vec \hat \bar \dot \ddot \tilde.
    case accent(MathNode, AccentKind)
    /// Horizontal space in em units. Zero width = a "soft" space the user
    /// typed, which renders as a hair gap and bounds fraction grouping.
    case space(CGFloat)

    var isEmpty: Bool {
        if case .row(let items) = self { return items.isEmpty }
        return false
    }
}

enum MathStyle {
    case variable      // italic serif: x, ω, R
    case number        // upright: 0–9, .
    case upright       // function names, units, text
    case binary        // + − ± ⋅ ×  (medium spacing)
    case relation      // = ≠ ≈ ≤ →  (wide spacing)
    case punctuation   // , ;
}

enum AccentKind: String {
    case vec, hat, bar, dot, ddot, tilde
}

// MARK: - Casual input → LaTeX

/// Turns relaxed keyboard math ("w0 = 1/sqrt(LC)", "H2O", "theta ~= sin(theta)")
/// into LaTeX, which is both shown to the user and fed to the parser.
enum CasualMath {

    static let greekNames = [
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
        "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma",
        "tau", "upsilon", "phi", "chi", "psi", "omega",
        "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon",
        "Phi", "Psi", "Omega",
    ]

    static let functionNames = [
        "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
        "sin", "cos", "tan", "sec", "csc", "cot", "ln", "log", "exp", "lim",
    ]

    static func toLaTeX(_ input: String) -> String {
        var s = input

        // Multi-char operators first (longest match wins; <=> before <=).
        let opRewrites: [(String, String)] = [
            ("<=>", " \\rightleftharpoons "), ("<->", " \\leftrightarrow "),
            ("->", " \\to "), ("=>", " \\Rightarrow "),
            ("<=", " \\leq "), (">=", " \\geq "), ("!=", " \\neq "), ("~=", " \\approx "),
            ("+-", " \\pm "), ("-+", " \\mp "),
        ]
        for (from, to) in opRewrites {
            s = s.replacingOccurrences(of: from, with: to)
        }
        // `*` means multiplication dot; `**` would double up harmlessly.
        s = s.replacingOccurrences(of: "*", with: " \\cdot ")

        // sqrt(...) → \sqrt{...}, balanced.
        s = rewriteCall(in: s, name: "sqrt", command: "\\sqrt")
        s = rewriteCall(in: s, name: "abs", command: "\\abs")

        // Scientific notation: 6.022e23 → 6.022 \times 10^{23}.
        // (Before word/digit passes so the "e" isn't touched.)
        s = regexReplace(
            s,
            pattern: #"(?<![A-Za-z0-9_.])(\d+(?:\.\d+)?)[eE]([+-]?\d{1,3})(?![A-Za-z0-9.])"#,
            template: "$1 \\\\times 10^{$2}"
        )

        // Ion charges: SO4^2- → SO4^{2-}, Fe^3+ → Fe^{3+} (sign must end the token,
        // so x^2-1 is untouched).
        s = regexReplace(
            s,
            pattern: #"\^(\d{0,2})([+-])(?![0-9A-Za-z({\\])"#,
            template: "^{$1$2}"
        )

        // Bare word rewrites (word boundaries, not already backslashed).
        var wordMap: [String: String] = [:]
        for g in greekNames { wordMap[g] = "\\\(g)" }
        for f in functionNames { wordMap[f] = "\\\(f)" }
        wordMap["infinity"] = "\\infty"
        wordMap["inf"] = "\\infty"
        wordMap["deg"] = "\\degree"
        wordMap["degrees"] = "\\degree"
        wordMap["hbar"] = "\\hbar"
        wordMap["ohm"] = "\\Omega"
        wordMap["nabla"] = "\\nabla"
        wordMap["del"] = "\\nabla"
        wordMap["grad"] = "\\nabla"
        wordMap["partial"] = "\\partial"
        // Vector calculus (Calc 3 & E&M)
        wordMap["div"] = "\\nabla \\cdot"
        wordMap["curl"] = "\\nabla \\times"
        wordMap["dot"] = "\\cdot"
        wordMap["cross"] = "\\times"
        wordMap["vec"] = "\\vec"
        wordMap["hat"] = "\\hat"
        wordMap["ihat"] = "\\hat{i}"
        wordMap["jhat"] = "\\hat{j}"
        wordMap["khat"] = "\\hat{k}"
        wordMap["rhat"] = "\\hat{r}"
        wordMap["nhat"] = "\\hat{n}"
        // Big operators & limits
        wordMap["sum"] = "\\sum"
        wordMap["prod"] = "\\prod"
        wordMap["int"] = "\\int"
        wordMap["iint"] = "\\iint"
        wordMap["iiint"] = "\\iiint"
        wordMap["oint"] = "\\oint"
        wordMap["lim"] = "\\lim"
        // Misc operators
        wordMap["pm"] = "\\pm"
        wordMap["cdot"] = "\\cdot"
        wordMap["times"] = "\\times"
        wordMap["propto"] = "\\propto"
        wordMap["approx"] = "\\approx"
        wordMap["equiv"] = "\\equiv"
        wordMap["neq"] = "\\neq"
        wordMap["leq"] = "\\leq"
        wordMap["geq"] = "\\geq"
        // Chemistry
        wordMap["yields"] = "\\to"

        s = rewriteWords(in: s, map: wordMap)

        // letter+digits → letter_{digits}:  v0 → v_0, H2O → H_2O, \mu0 → \mu_0
        s = rewriteTrailingDigitSubscripts(in: s)

        // Collapse the padding spaces we introduced.
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func regexReplace(_ s: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        return regex.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template
        )
    }

    /// name( ... ) → command{ ... } with balanced parentheses.
    private static func rewriteCall(in text: String, name: String, command: String) -> String {
        var s = text
        while true {
            guard let range = findCall(in: s, name: name) else { return s }
            let inner = String(s[range.inner])
            s.replaceSubrange(range.whole, with: "\(command){\(inner)}")
        }
    }

    private static func findCall(in s: String, name: String) -> (whole: Range<String.Index>, inner: Range<String.Index>)? {
        var search = s.startIndex
        while let r = s.range(of: name + "(", range: search..<s.endIndex) {
            search = s.index(after: r.lowerBound)
            // must not be part of a longer word or a \command
            if r.lowerBound > s.startIndex {
                let prev = s[s.index(before: r.lowerBound)]
                if prev.isLetter || prev == "\\" { continue }
            }
            // find balanced close
            var depth = 1
            var i = r.upperBound
            while i < s.endIndex {
                let c = s[i]
                if c == "(" { depth += 1 }
                if c == ")" {
                    depth -= 1
                    if depth == 0 {
                        return (r.lowerBound..<s.index(after: i), r.upperBound..<i)
                    }
                }
                i = s.index(after: i)
            }
            return nil // unbalanced; leave as-is
        }
        return nil
    }

    private static func rewriteWords(in text: String, map: [String: String]) -> String {
        var out = ""
        var word = ""
        var afterBackslash = false
        func flush() {
            if word.isEmpty { return }
            if afterBackslash {
                out += word
            } else if let replacement = map[word] {
                out += replacement
            } else {
                out += word
            }
            word = ""
            afterBackslash = false
        }
        for c in text {
            if c.isLetter {
                word.append(c)
            } else {
                flush()
                if c == "\\" { afterBackslash = true }
                out.append(c)
                if c != "\\" && afterBackslash { afterBackslash = false }
            }
        }
        flush()
        return out
    }

    /// x2 → x_2, V12 → V_{12}, \mu0 → \mu_0. Skips existing scripts.
    private static func rewriteTrailingDigitSubscripts(in text: String) -> String {
        var out = ""
        let chars = Array(text)
        var i = 0

        func subscriptDigits(from j0: Int) -> Int {
            var digits = ""
            var j = j0
            while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
            out += digits.count == 1 ? "_\(digits)" : "_{\(digits)}"
            return j
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                // copy whole command, then subscript any digits glued to it (\mu0)
                out.append(c)
                i += 1
                var name = ""
                while i < chars.count, chars[i].isLetter {
                    name.append(chars[i]); out.append(chars[i]); i += 1
                }
                if greekNames.contains(name) || name == "hbar" || name == "ell",
                   i < chars.count, chars[i].isNumber,
                   out.dropLast(name.count + 1).last != "^",
                   out.dropLast(name.count + 1).last != "_" {
                    i = subscriptDigits(from: i)
                }
                continue
            }
            if c.isLetter, i + 1 < chars.count, chars[i + 1].isNumber {
                // not if this letter is itself a script argument (x^2, a_3)
                let prev: Character? = out.last
                if prev == "^" || prev == "_" {
                    out.append(c); i += 1; continue
                }
                out.append(c)
                i = subscriptDigits(from: i + 1)
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }
}

// MARK: - LaTeX (subset) parser

struct MathParser {

    // Symbol tables --------------------------------------------------------

    static let commandSymbols: [String: (String, MathStyle)] = {
        var m: [String: (String, MathStyle)] = [:]
        let greek: [String: String] = [
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
            "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
            "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
            "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ",
            "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
            "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
            "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        ]
        for (k, v) in greek { m[k] = (v, .variable) }

        let binary: [String: String] = [
            "pm": "±", "mp": "∓", "times": "×", "cdot": "⋅", "div": "÷",
            "cup": "∪", "cap": "∩", "oplus": "⊕", "otimes": "⊗",
        ]
        for (k, v) in binary { m[k] = (v, .binary) }

        let relation: [String: String] = [
            "neq": "≠", "approx": "≈", "equiv": "≡", "leq": "≤", "geq": "≥",
            "ll": "≪", "gg": "≫", "propto": "∝", "sim": "∼",
            "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔",
            "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔",
            "implies": "⇒", "iff": "⇔", "rightleftharpoons": "⇌",
            "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆",
            "perp": "⊥", "parallel": "∥",
        ]
        for (k, v) in relation { m[k] = (v, .relation) }

        let ordinary: [String: String] = [
            "infty": "∞", "partial": "∂", "nabla": "∇", "hbar": "ℏ", "ell": "ℓ",
            "degree": "°", "circ": "°", "prime": "′", "angle": "∠", "triangle": "△",
            "forall": "∀", "exists": "∃", "emptyset": "∅", "therefore": "∴",
            "because": "∵", "aleph": "ℵ", "AA": "Å", "micro": "µ",
            "uparrow": "↑", "downarrow": "↓", "bullet": "•", "star": "⋆", "dagger": "†",
        ]
        for (k, v) in ordinary { m[k] = (v, .upright) }
        return m
    }()

    static let bigOps: Set<String> = ["int", "oint", "iint", "iiint", "sum", "prod", "lim"]
    static let bigOpGlyphs: [String: String] = [
        "int": "∫", "oint": "∮", "iint": "∬", "iiint": "∭",
        "sum": "∑", "prod": "∏", "lim": "lim",
    ]
    /// ∑ ∏ lim put their limits above/below; integrals put them beside.
    static let aboveBelowOps: Set<String> = ["∑", "∏", "lim"]

    // Tokenizer ------------------------------------------------------------

    private enum Token: Equatable {
        case command(String)
        case char(Character)
        case openBrace, closeBrace
        case superscriptMark, subscriptMark
    }

    private static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                var name = ""
                var j = i + 1
                while j < chars.count, chars[j].isLetter { name.append(chars[j]); j += 1 }
                if name.isEmpty, j < chars.count {
                    // \, \; etc.
                    name = String(chars[j]); j += 1
                }
                tokens.append(.command(name))
                i = j
            } else if c == "{" {
                tokens.append(.openBrace); i += 1
            } else if c == "}" {
                tokens.append(.closeBrace); i += 1
            } else if c == "^" {
                tokens.append(.superscriptMark); i += 1
            } else if c == "_" {
                tokens.append(.subscriptMark); i += 1
            } else {
                tokens.append(.char(c)); i += 1
            }
        }
        return tokens
    }

    // Parser ---------------------------------------------------------------

    static func parse(_ latex: String) -> MathNode {
        var tokens = tokenize(latex)[...]
        let row = parseRow(&tokens, until: nil)
        return foldFractions(row)
    }

    private static func parseRow(_ tokens: inout ArraySlice<Token>, until terminator: Token?) -> [MathNode] {
        var items: [MathNode] = []
        while let t = tokens.first {
            if let terminator, t == terminator {
                tokens.removeFirst()
                return items
            }
            if case .char(let c) = t, c == ")" || c == "]", terminator == nil {
                // leave for enclosing delimiter parser
                return items
            }
            if let node = parseFactor(&tokens) {
                items.append(node)
            }
        }
        return items
    }

    /// atom + attached scripts
    private static func parseFactor(_ tokens: inout ArraySlice<Token>) -> MathNode? {
        guard let base = parseAtom(&tokens) else { return nil }

        var supNode: MathNode?
        var subNode: MathNode?
        while let t = tokens.first, t == .superscriptMark || t == .subscriptMark {
            tokens.removeFirst()
            let arg = parseScriptArg(&tokens)
            if t == .superscriptMark { supNode = merge(supNode, arg) } else { subNode = merge(subNode, arg) }
        }

        if supNode != nil || subNode != nil {
            if case .bigOp(let glyph, _, _, let aboveBelow) = base {
                return .bigOp(glyph, sup: supNode, sub: subNode, limitsAboveBelow: aboveBelow)
            }
            return .scripts(base: base, sup: supNode, sub: subNode)
        }
        return base
    }

    private static func merge(_ a: MathNode?, _ b: MathNode) -> MathNode {
        guard let a else { return b }
        return .row([a, b])
    }

    private static func skipSpaces(_ tokens: inout ArraySlice<Token>) {
        while case .char(let c)? = tokens.first, c == " " || c == "\t" || c == "\n" {
            tokens.removeFirst()
        }
    }

    private static func parseScriptArg(_ tokens: inout ArraySlice<Token>) -> MathNode {
        skipSpaces(&tokens)
        guard let t = tokens.first else { return .row([]) }
        if t == .openBrace {
            tokens.removeFirst()
            return .row(foldFractionsList(parseRow(&tokens, until: .closeBrace)))
        }
        // single token; a leading sign grabs the next atom too: e^-x
        if case .char(let c) = t, c == "-" || c == "+" {
            tokens.removeFirst()
            let next = parseFactor(&tokens) ?? .row([])
            return .row([.symbol(c == "-" ? "−" : "+", .binary), next])
        }
        return parseAtom(&tokens) ?? .row([])
    }

    private static func parseAtom(_ tokens: inout ArraySlice<Token>) -> MathNode? {
        guard let t = tokens.first else { return nil }
        switch t {
        case .openBrace:
            tokens.removeFirst()
            return .row(foldFractionsList(parseRow(&tokens, until: .closeBrace)))

        case .closeBrace:
            tokens.removeFirst() // stray; skip
            return parseAtom(&tokens)

        case .superscriptMark, .subscriptMark:
            // stray script mark with no base
            tokens.removeFirst()
            return parseAtom(&tokens)

        case .command(let name):
            tokens.removeFirst()
            return parseCommand(name, &tokens)

        case .char(let c):
            tokens.removeFirst()
            switch c {
            case " ", "\t", "\n":
                // Soft space: hair gap visually, and a boundary for `/` grouping.
                skipSpaces(&tokens)
                return .space(0)
            case "(", "[":
                let close: Character = (c == "(") ? ")" : "]"
                let inner = parseRow(&tokens, until: nil)
                if case .char(let cc)? = tokens.first, cc == close {
                    tokens.removeFirst()
                }
                return .delimited(open: String(c), content: .row(foldFractionsList(inner)), close: String(close))
            case ")", "]":
                // unmatched close — render literally
                return .symbol(String(c), .upright)
            case ",", ";":
                return .symbol(String(c), .punctuation)
            case "+", "−", "±", "⋅", "×":
                return .symbol(String(c), .binary)
            case "-":
                return .symbol("−", .binary)
            case "=", "<", ">", "≈", "≠", "→", "⇒", "⇌":
                return .symbol(String(c), .relation)
            case "/":
                return .symbol("/", .binary) // folded into frac later
            case "'":
                return .symbol("′", .upright)
            default:
                if c.isNumber || c == "." {
                    // group a full number
                    var num = String(c)
                    while case .char(let d)? = tokens.first, d.isNumber || d == "." {
                        num.append(d)
                        tokens.removeFirst()
                    }
                    return .symbol(num, .number)
                }
                if c.isLetter {
                    return .symbol(String(c), .variable)
                }
                return .symbol(String(c), .upright)
            }
        }
    }

    private static func parseCommand(_ name: String, _ tokens: inout ArraySlice<Token>) -> MathNode? {
        switch name {
        case "frac":
            let a = parseScriptArg(&tokens)
            let b = parseScriptArg(&tokens)
            return .frac(a, b)
        case "lim":
            return .bigOp("lim", sup: nil, sub: nil, limitsAboveBelow: true)
        case "sqrt":
            var index: MathNode?
            if case .char("[")? = tokens.first {
                tokens.removeFirst()
                let inner = parseRow(&tokens, until: nil)
                if case .char("]")? = tokens.first { tokens.removeFirst() }
                index = .row(inner)
            }
            return .sqrt(parseScriptArg(&tokens), index: index)
        case "abs":
            let inner = parseScriptArg(&tokens)
            return .delimited(open: "|", content: inner, close: "|")
        case "left", "right":
            return parseAtom(&tokens) // delimiter char follows; auto-stretch handles it
        case "vec", "hat", "bar", "dot", "ddot", "tilde":
            let arg = parseScriptArg(&tokens)
            return .accent(arg, AccentKind(rawValue: name) ?? .bar)
        case ",", ";", " ":
            return .space(0.18)
        case "quad":
            return .space(1.0)
        default:
            if bigOps.contains(name) {
                let glyph = bigOpGlyphs[name] ?? "∫"
                return .bigOp(glyph, sup: nil, sub: nil, limitsAboveBelow: aboveBelowOps.contains(glyph))
            }
            if let (glyph, style) = commandSymbols[name] {
                return .symbol(glyph, style)
            }
            if CasualMath.functionNames.contains(name) {
                return .symbol(name, .upright)
            }
            // Unknown command: show the raw name so the user notices.
            return .symbol("\\" + name, .upright)
        }
    }

    // `/` folding: a/b → frac(a, b). Numerator and denominator are the maximal
    // runs of "ordinary" factors adjacent to the slash, so df/dx, 1/RC, and
    // [H^+][A^-]/[HA] group the way a student means them. Runs stop at spaces
    // and operators, so "1/2 mv^2" keeps the ½ tight.

    private static func foldFractions(_ items: [MathNode]) -> MathNode {
        let folded = foldFractionsList(items)
        return folded.count == 1 ? folded[0] : .row(folded)
    }

    /// A node that can participate in a fraction run.
    private static func isOrdish(_ node: MathNode) -> Bool {
        switch node {
        case .symbol(_, let style):
            return style == .variable || style == .number || style == .upright
        case .scripts, .sqrt, .accent, .delimited, .row:
            return true
        default:
            return false
        }
    }

    private static func isSoftSpace(_ node: MathNode) -> Bool {
        if case .space = node { return true }
        return false
    }

    private static func runNode(_ items: [MathNode]) -> MathNode {
        if items.count == 1 {
            if case .delimited(let open, let content, _) = items[0], open == "(" {
                return content
            }
            return items[0]
        }
        return .row(items)
    }

    static func foldFractionsList(_ items: [MathNode]) -> [MathNode] {
        var out: [MathNode] = []
        var i = 0
        while i < items.count {
            let item = items[i]
            if case .symbol("/", _) = item {
                // Spaces touching the slash are cosmetic — eat them.
                while let last = out.last, isSoftSpace(last) { out.removeLast() }
                var numItems: [MathNode] = []
                while let last = out.last, isOrdish(last) {
                    numItems.insert(out.removeLast(), at: 0)
                }
                var j = i + 1
                while j < items.count, isSoftSpace(items[j]) { j += 1 }
                var denItems: [MathNode] = []
                while j < items.count, isOrdish(items[j]) {
                    denItems.append(items[j])
                    j += 1
                }
                if numItems.isEmpty || denItems.isEmpty {
                    // Not a fraction after all — restore and keep the slash.
                    out.append(contentsOf: numItems)
                    out.append(item)
                    i += 1
                    continue
                }
                out.append(.frac(runNode(numItems), runNode(denItems)))
                i = j
                continue
            }
            out.append(item)
            i += 1
        }
        return out
    }
}
