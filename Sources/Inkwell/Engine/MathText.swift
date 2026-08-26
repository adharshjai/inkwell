//
//  MathText.swift
//  Inkwell
//
//  Best-effort conversion of LaTeX-ish math into plain Unicode text, so a
//  student can type `\omega_0 = 1/\sqrt{LC}` and stamp `ω₀ = 1/√(LC)` onto
//  a PDF page as an ordinary text annotation.
//

import Foundation

enum MathText {

    /// Converts LaTeX-ish input to Unicode text. Never throws. Commands the
    /// converter does not recognize are left verbatim — backslash included —
    /// so the user can see exactly what was not understood.
    static func render(_ input: String) -> String {
        var parser = Parser(input)
        return parser.parseSequence()
    }

    /// Curated demo pairs shown in the UI and asserted by the self-test:
    /// every entry satisfies `render(input) == output`.
    static let examples: [(input: String, output: String)] = [
        ("E = mc^2", "E = mc²"),
        ("v = v_0 + at", "v = v₀ + at"),
        ("v(t) = V_0 e^{-t/\\tau}, \\tau = RC", "v(t) = V₀ e^(-t/τ), τ = RC"),
        ("\\omega_0 = 1/\\sqrt{LC}", "ω₀ = 1/√(LC)"),
        ("\\Delta G = \\Delta H - T\\Delta S", "ΔG = ΔH - TΔS"),
        ("F = \\mu N", "F = μN"),
        ("\\int_0^\\infty e^{-x^2} dx", "∫₀^∞ e^(-x²) dx"),
        ("K_a", "Kₐ"),
        ("H_2SO_4", "H₂SO₄"),
        ("\\vec{F} = m\\vec{a}", "F\u{20D7} = ma\u{20D7}"),
        ("Z = R + j\\omega L", "Z = R + jωL"),
        ("\\theta \\approx \\sin\\theta", "θ ≈ sinθ"),
        ("n_1\\sin\\theta_1 = n_2\\sin\\theta_2", "n₁sinθ₁ = n₂sinθ₂"),
        ("2H_2 + O_2 \\rightleftharpoons 2H_2O", "2H₂ + O₂ ⇌ 2H₂O"),
        ("I = \\frac{V}{R}", "I = V\u{2215}R"),
        ("x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}", "x = (-b ± √(b² - 4ac))/(2a)"),
        ("E = \\hbar\\omega", "E = ℏω"),
        ("\\sqrt[3]{x} + \\sqrt{2}", "∛x + √2"),
    ]

    // MARK: - Parser

    /// A single forward pass over the input: plain characters are copied
    /// through, while `\commands`, `^`/`_` scripts, and `{…}` groups are
    /// parsed by recursive descent so nested braces stay balanced.
    private struct Parser {

        private let chars: [Character]
        private var index = 0

        init(_ text: String) {
            chars = Array(text)
        }

        // MARK: Sequence / groups

        /// Renders characters until the end of input — or, inside a `{…}`
        /// group, until the matching close brace (which is consumed).
        mutating func parseSequence(insideGroup: Bool = false) -> String {
            var out = ""
            while let c = peek() {
                switch c {
                case "\\":
                    out += parseCommand()
                case "^":
                    advance()
                    out += renderScript(marker: "^", map: Self.superscripts)
                case "_":
                    advance()
                    out += renderScript(marker: "_", map: Self.subscripts)
                case "{":
                    advance()
                    out += parseSequence(insideGroup: true)
                case "}":
                    if insideGroup { advance(); return out }
                    out.append(c)
                    advance()
                default:
                    out.append(c)
                    advance()
                }
            }
            return out
        }

        /// If positioned at `{`, consumes a balanced group and returns its
        /// rendered content (braces stripped); otherwise returns nil.
        private mutating func parseBracedGroup() -> String? {
            guard peek() == "{" else { return nil }
            advance()
            return parseSequence(insideGroup: true)
        }

        /// If positioned at `{`, consumes a balanced group and returns its
        /// raw text, braces included. Used to keep unknown commands verbatim.
        private mutating func rawBracedGroup() -> String? {
            guard peek() == "{" else { return nil }
            var depth = 0
            var raw = ""
            while let c = peek() {
                if c == "{" { depth += 1 }
                if c == "}" { depth -= 1 }
                raw.append(c)
                advance()
                if depth == 0 { break }
            }
            return raw
        }

        // MARK: Commands

        private mutating func parseCommand() -> String {
            advance() // the backslash
            guard let first = peek() else { return "\\" }

            // \,  \;  \<space>  →  thin space
            if first == "," || first == ";" || first == " " {
                advance()
                return "\u{2009}"
            }

            // Non-letter escape such as \{ — leave verbatim.
            guard first.isASCII, first.isLetter else {
                advance()
                return "\\" + String(first)
            }

            var name = ""
            while let c = peek(), c.isASCII, c.isLetter {
                name.append(c)
                advance()
            }

            switch name {
            case "left", "right":
                skipSpaces() // strip the command, keep the delimiter
                return ""
            case "frac":
                return renderFraction()
            case "sqrt":
                return renderRadical()
            default:
                break
            }

            if let mark = Self.accents[name] {
                return renderAccent(named: name, mark: mark)
            }
            if let letter = Self.greek[name] {
                gobbleJuxtapositionSpace()
                return letter
            }
            if let symbol = Self.symbols[name] {
                return symbol
            }
            if Self.functionNames.contains(name) {
                return name
            }

            // Unknown command: keep it verbatim, along with any braced
            // arguments, so \text{hello} survives as \text{hello}.
            var verbatim = "\\" + name
            while let raw = rawBracedGroup() {
                verbatim += raw
            }
            return verbatim
        }

        /// `\Delta G` reads better as `ΔG`: after a Greek letter, consume a
        /// single space when a letter or digit follows (juxtaposition).
        private mutating func gobbleJuxtapositionSpace() {
            guard peek() == " ",
                  let next = peek(ahead: 1),
                  next.isLetter || next.isNumber
            else { return }
            advance()
        }

        // MARK: Scripts (^ and _)

        /// Called with the `^`/`_` marker already consumed. Converts the
        /// argument to super/subscript characters when every character has a
        /// form; otherwise falls back to `^x` / `^(xyz)` notation — never a
        /// half-converted group.
        private mutating func renderScript(marker: Character, map: [Character: Character]) -> String {
            guard let arg = parseScriptArgument(), !arg.isEmpty else {
                return String(marker)
            }
            if let converted = Self.convertAll(arg, using: map) {
                return converted
            }
            return arg.count == 1 ? "\(marker)\(arg)" : "\(marker)(\(arg))"
        }

        /// A script or accent argument: a balanced `{…}` group, a single
        /// `\command` token, or exactly one plain character.
        private mutating func parseScriptArgument() -> String? {
            if let group = parseBracedGroup() { return group }
            guard let c = peek() else { return nil }
            if c == "\\" { return parseCommand() }
            if c.isWhitespace || c == "}" || c == "^" || c == "_" { return nil }
            advance()
            return String(c)
        }

        // MARK: Accents

        private mutating func renderAccent(named name: String, mark: Character) -> String {
            let snapshot = index
            skipSpaces()
            guard let arg = parseScriptArgument(), !arg.isEmpty else {
                index = snapshot
                return "\\" + name
            }
            // A combining mark attaches to the preceding cluster, i.e. the
            // argument's last character.
            return arg + String(mark)
        }

        // MARK: \frac

        private mutating func renderFraction() -> String {
            let snapshot = index
            skipSpaces()
            guard let numerator = parseBracedGroup() else {
                index = snapshot
                return "\\frac"
            }
            skipSpaces()
            guard let denominator = parseBracedGroup() else {
                index = snapshot
                return "\\frac"
            }
            if (1...3).contains(numerator.count), (1...3).contains(denominator.count) {
                return numerator + "\u{2215}" + denominator // DIVISION SLASH
            }
            return "(" + numerator + ")/(" + denominator + ")"
        }

        // MARK: \sqrt

        private mutating func renderRadical() -> String {
            var prefix = "√"

            // Optional index: \sqrt[3]{x}
            let indexSnapshot = index
            skipSpaces()
            if peek() == "[" {
                advance()
                var raw = ""
                while let c = peek(), c != "]" {
                    raw.append(c)
                    advance()
                }
                if peek() == "]" {
                    advance()
                    prefix = Self.radicalPrefix(forIndex: raw)
                } else {
                    index = indexSnapshot // unterminated "[" is not an index
                }
            } else {
                index = indexSnapshot
            }

            let argSnapshot = index
            skipSpaces()
            guard let arg = parseBracedGroup(), !arg.isEmpty else {
                index = argSnapshot
                return prefix // bare \sqrt renders as the plain symbol
            }
            return arg.count == 1 ? prefix + arg : prefix + "(" + arg + ")"
        }

        private static func radicalPrefix(forIndex raw: String) -> String {
            let rendered = MathText.render(raw)
            switch rendered {
            case "": return "√"
            case "3": return "∛"
            case "4": return "∜"
            default:
                if let sup = convertAll(rendered, using: superscripts) {
                    return sup + "√"
                }
                return "[" + rendered + "]√"
            }
        }

        // MARK: Cursor

        private func peek(ahead offset: Int = 0) -> Character? {
            let i = index + offset
            return i < chars.count ? chars[i] : nil
        }

        private mutating func advance() {
            index += 1
        }

        private mutating func skipSpaces() {
            while peek() == " " { advance() }
        }

        // MARK: Character conversion

        /// Maps every character of `text`, or returns nil if any character
        /// has no mapping (the all-or-nothing rule).
        private static func convertAll(_ text: String, using map: [Character: Character]) -> String? {
            guard !text.isEmpty else { return nil }
            var out = ""
            for ch in text {
                guard let mapped = map[ch] else { return nil }
                out.append(mapped)
            }
            return out
        }

        // MARK: Tables

        private static let superscripts: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
            "+": "⁺", "-": "⁻", "\u{2212}": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
            "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ",
            "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ",
            "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ",
            "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ",
            "z": "ᶻ",
            "A": "ᴬ", "B": "ᴮ", "D": "ᴰ", "E": "ᴱ", "G": "ᴳ", "H": "ᴴ",
            "I": "ᴵ", "J": "ᴶ", "K": "ᴷ", "L": "ᴸ", "M": "ᴹ", "N": "ᴺ",
            "O": "ᴼ", "P": "ᴾ", "R": "ᴿ", "T": "ᵀ", "U": "ᵁ", "V": "ⱽ",
            "W": "ᵂ",
        ]

        private static let subscripts: [Character: Character] = [
            "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
            "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
            "+": "₊", "-": "₋", "\u{2212}": "₋", "=": "₌", "(": "₍", ")": "₎",
            "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
            "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ",
            "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
        ]

        private static let greek: [String: String] = [
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
            "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
            "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
            "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
            "omicron": "ο", "pi": "π", "rho": "ρ", "sigma": "σ",
            "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "φ",
            "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
            "Alpha": "Α", "Beta": "Β", "Gamma": "Γ", "Delta": "Δ",
            "Epsilon": "Ε", "Zeta": "Ζ", "Eta": "Η", "Theta": "Θ",
            "Iota": "Ι", "Kappa": "Κ", "Lambda": "Λ", "Mu": "Μ",
            "Nu": "Ν", "Xi": "Ξ", "Omicron": "Ο", "Pi": "Π",
            "Rho": "Ρ", "Sigma": "Σ", "Tau": "Τ", "Upsilon": "Υ",
            "Phi": "Φ", "Chi": "Χ", "Psi": "Ψ", "Omega": "Ω",
        ]

        private static let symbols: [String: String] = [
            // Operators & relations
            "pm": "±", "mp": "∓", "times": "×", "cdot": "⋅", "div": "÷",
            "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡",
            "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥",
            "ll": "≪", "gg": "≫", "propto": "∝", "sim": "∼",
            "infty": "∞", "partial": "∂", "nabla": "∇",
            "int": "∫", "iint": "∬", "oint": "∮", "sum": "∑", "prod": "∏",
            "deg": "°", "degree": "°",
            // Arrows
            "to": "→", "rightarrow": "→", "leftarrow": "←",
            "leftrightarrow": "↔", "Rightarrow": "⇒", "Leftarrow": "⇐",
            "Leftrightarrow": "⇔", "uparrow": "↑", "downarrow": "↓",
            "rightleftharpoons": "⇌",
            // Sets & logic
            "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆",
            "cup": "∪", "cap": "∩", "forall": "∀", "exists": "∃",
            "emptyset": "∅", "varnothing": "∅", "therefore": "∴",
            "because": "∵", "implies": "⇒", "iff": "⇔", "angle": "∠",
            "perp": "⊥", "parallel": "∥", "triangle": "△",
            // Physics / ECE / chem extras
            "hbar": "ℏ", "ell": "ℓ", "AA": "Å", "micro": "µ", "ohm": "Ω",
            "prime": "′", "pprime": "″", "bullet": "•", "star": "⋆",
            "dagger": "†", "aleph": "ℵ",
        ]

        /// Function names rendered as plain words: `\sin\theta` → `sinθ`.
        private static let functionNames: Set<String> = [
            "sin", "cos", "tan", "cot", "sec", "csc",
            "sinh", "cosh", "tanh", "coth",
            "arcsin", "arccos", "arctan",
            "ln", "log", "exp", "lim", "min", "max", "det", "arg", "mod",
        ]

        /// Accent commands mapped to combining marks.
        private static let accents: [String: Character] = [
            "vec": "\u{20D7}",   // combining right arrow above
            "hat": "\u{0302}",   // combining circumflex
            "bar": "\u{0304}",   // combining macron
            "dot": "\u{0307}",   // combining dot above
            "ddot": "\u{0308}",  // combining diaeresis
            "tilde": "\u{0303}", // combining tilde
        ]
    }
}
