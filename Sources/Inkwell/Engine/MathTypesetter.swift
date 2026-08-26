import AppKit
import CoreText

/// Typesets a MathNode tree into positioned glyph outlines and rules
/// (fraction bars, radical vinculums, accents) — real textbook layout:
/// stacked fractions, radicals, scripts, big operators with limits.
///
/// Coordinates are y-UP with the origin at the left end of the baseline
/// (matches PDF page space; the SwiftUI preview flips).
enum TypesetMath {

    struct Output {
        var glyphs: [CGPath] = []   // filled outlines
        var rules: [CGRect] = []    // filled rectangles
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0    // positive, below baseline

        var height: CGFloat { ascent + descent }
        var isEmpty: Bool { glyphs.isEmpty && rules.isEmpty }
    }

    /// Plain multiline text as upright glyph outlines (no math parsing) —
    /// used for text placed on rotated pages, where FreeText can't rotate.
    static func layoutPlain(_ text: String, fontSize: CGFloat) -> Output? {
        let lines = text.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }
        let lineHeight = fontSize * 1.3
        var box = Box()
        var baseline: CGFloat = 0
        var maxWidth: CGFloat = 0
        for line in lines {
            let lineBox = typesetSymbols(line, style: .upright, size: fontSize)
            box.place(lineBox, dx: 0, dy: baseline)
            maxWidth = max(maxWidth, lineBox.width)
            baseline -= lineHeight
        }
        box.width = maxWidth
        guard !(box.glyphs.isEmpty && box.rules.isEmpty) else { return nil }
        var out = Output()
        out.glyphs = box.glyphs
        out.rules = box.rules
        out.width = box.width
        out.ascent = box.ascent
        out.descent = box.descent
        return out
    }

    /// Full pipeline: casual/LaTeX source → (layout, the LaTeX we derived).
    static func layout(_ source: String, fontSize: CGFloat) -> (output: Output, latex: String)? {
        let latex = CasualMath.toLaTeX(source)
        guard !latex.isEmpty else { return nil }
        let node = MathParser.parse(latex)
        let box = typeset(node, size: fontSize, level: 0)
        guard !(box.glyphs.isEmpty && box.rules.isEmpty) else { return nil }
        var out = Output()
        out.glyphs = box.glyphs
        out.rules = box.rules
        out.width = box.width
        out.ascent = box.ascent
        out.descent = box.descent
        return (out, latex)
    }

    // MARK: - Fonts

    private struct Fonts {
        let regular: CTFont
        let italic: CTFont

        init(size: CGFloat) {
            regular = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, size, nil)
            italic = CTFontCreateWithName("TimesNewRomanPS-ItalicMT" as CFString, size, nil)
        }

        /// Glyph path + advance for one character, with system font fallback
        /// for symbols Times lacks (∬, ⇌, …).
        func glyph(_ ch: Character, italicStyle: Bool) -> (path: CGPath?, advance: CGFloat) {
            let base = italicStyle ? italic : regular
            var units = Array(String(ch).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            var font = base
            if !CTFontGetGlyphsForCharacters(base, &units, &glyphs, units.count) || glyphs[0] == 0 {
                let str = String(ch) as CFString
                let fallback = CTFontCreateForString(base, str, CFRange(location: 0, length: units.count))
                font = fallback
                if !CTFontGetGlyphsForCharacters(fallback, &units, &glyphs, units.count) {
                    return (nil, CTFontGetSize(base) * 0.5)
                }
            }
            var g = glyphs[0]
            let path = CTFontCreatePathForGlyph(font, g, nil)
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &advance, 1)
            return (path, advance.width)
        }
    }

    // MARK: - Box model

    private struct Box {
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var glyphs: [CGPath] = []
        var rules: [CGRect] = []

        mutating func place(_ child: Box, dx: CGFloat, dy: CGFloat) {
            var transform = CGAffineTransform(translationX: dx, y: dy)
            for path in child.glyphs {
                if let moved = path.copy(using: &transform) { glyphs.append(moved) }
            }
            for rect in child.rules {
                rules.append(rect.offsetBy(dx: dx, dy: dy))
            }
            ascent = max(ascent, child.ascent + dy)
            descent = max(descent, child.descent - dy)
        }

        mutating func addRule(_ rect: CGRect) {
            rules.append(rect)
            ascent = max(ascent, rect.maxY)
            descent = max(descent, -rect.minY)
        }
    }

    private static func scriptSize(_ size: CGFloat, level: Int) -> CGFloat {
        max(size * (level == 0 ? 0.62 : 0.55), 6.5)
    }

    // MARK: - Node typesetting

    private static func typeset(_ node: MathNode, size: CGFloat, level: Int) -> Box {
        switch node {
        case .row(let items):
            return typesetRow(items, size: size, level: level)

        case .symbol(let text, let style):
            return typesetSymbols(text, style: style, size: size)

        case .space(let em):
            var box = Box()
            box.width = (em == 0 ? 0.09 : em) * size
            return box

        case .frac(let num, let den):
            return typesetFraction(num, den, size: size, level: level)

        case .sqrt(let content, let index):
            return typesetRadical(content, index: index, size: size, level: level)

        case .scripts(let base, let sup, let sub):
            let baseBox = typeset(base, size: size, level: level)
            return attachScripts(to: baseBox, sup: sup, sub: sub, size: size, level: level)

        case .bigOp(let glyph, let sup, let sub, let aboveBelow):
            return typesetBigOp(glyph, sup: sup, sub: sub, aboveBelow: aboveBelow, size: size, level: level)

        case .delimited(let open, let content, let close):
            return typesetDelimited(open: open, content: content, close: close, size: size, level: level)

        case .accent(let base, let kind):
            return typesetAccent(base, kind: kind, size: size, level: level)
        }
    }

    // MARK: Rows & spacing

    private static func spacingClass(_ node: MathNode) -> MathStyle? {
        switch node {
        case .symbol(_, let style): return style
        case .scripts(let base, _, _): return spacingClass(base)
        case .accent(let base, _): return spacingClass(base)
        case .row(let items): return items.count == 1 ? spacingClass(items[0]) : nil
        default: return nil
        }
    }

    private static func gap(between a: MathNode?, and b: MathNode, size: CGFloat) -> CGFloat {
        guard let a else { return 0 }
        if case .space = a { return 0 }
        if case .space = b { return 0 }
        let ca = spacingClass(a), cb = spacingClass(b)
        if ca == .binary || cb == .binary { return 0.19 * size }
        if ca == .relation || cb == .relation { return 0.26 * size }
        if ca == .punctuation { return 0.17 * size }
        // function name followed by argument: sinθ
        if case .symbol(let s, .upright) = a, s.count > 1 { return 0.12 * size }
        return 0.03 * size
    }

    private static func typesetRow(_ items: [MathNode], size: CGFloat, level: Int) -> Box {
        var box = Box()
        var x: CGFloat = 0
        var previous: MathNode?
        for item in items {
            let child = typeset(item, size: size, level: level)
            x += gap(between: previous, and: item, size: size)
            box.place(child, dx: x, dy: 0)
            x += child.width
            previous = item
        }
        box.width = x
        // A lone row of nothing still needs sane metrics.
        box.ascent = max(box.ascent, 0)
        box.descent = max(box.descent, 0)
        return box
    }

    // MARK: Symbol runs

    private static func typesetSymbols(_ text: String, style: MathStyle, size: CGFloat) -> Box {
        let fonts = Fonts(size: size)
        let italicStyle = (style == .variable)
        var box = Box()
        var x: CGFloat = 0
        for ch in text {
            let (path, advance) = fonts.glyph(ch, italicStyle: italicStyle)
            if let path {
                var transform = CGAffineTransform(translationX: x, y: 0)
                if let moved = path.copy(using: &transform) {
                    box.glyphs.append(moved)
                    let bb = moved.boundingBoxOfPath
                    box.ascent = max(box.ascent, bb.maxY)
                    box.descent = max(box.descent, -bb.minY)
                }
            }
            x += advance
        }
        box.width = x
        // Minimum metrics so pure-operator boxes don't collapse.
        box.ascent = max(box.ascent, size * 0.44)
        return box
    }

    // MARK: Scripts

    private static func attachScripts(to baseBox: Box, sup: MathNode?, sub: MathNode?, size: CGFloat, level: Int) -> Box {
        var box = baseBox
        let sSize = scriptSize(size, level: level)
        let x = baseBox.width + 0.02 * size
        var maxW: CGFloat = 0

        if let sup {
            let supBox = typeset(sup, size: sSize, level: level + 1)
            let shift = max(0.38 * size, baseBox.ascent - 0.42 * sSize)
            box.place(supBox, dx: x, dy: shift)
            maxW = max(maxW, supBox.width)
        }
        if let sub {
            let subBox = typeset(sub, size: sSize, level: level + 1)
            let shift = -max(0.16 * size, baseBox.descent + 0.28 * sSize)
            box.place(subBox, dx: x, dy: shift)
            maxW = max(maxW, subBox.width)
        }
        box.width = x + maxW
        return box
    }

    // MARK: Fractions

    private static func typesetFraction(_ num: MathNode, _ den: MathNode, size: CGFloat, level: Int) -> Box {
        let inner = level == 0 ? size * 0.86 : scriptSize(size, level: level)
        let numBox = typeset(num, size: inner, level: level)
        let denBox = typeset(den, size: inner, level: level)

        let axis = 0.26 * size
        let thickness = max(0.55, 0.048 * size)
        let clearance = 0.13 * size
        let barWidth = max(numBox.width, denBox.width) + 0.24 * size

        var box = Box()
        box.addRule(CGRect(x: 0, y: axis - thickness / 2, width: barWidth, height: thickness))
        let numBaseline = axis + thickness / 2 + clearance + numBox.descent
        let denBaseline = axis - thickness / 2 - clearance - denBox.ascent
        box.place(numBox, dx: (barWidth - numBox.width) / 2, dy: numBaseline)
        box.place(denBox, dx: (barWidth - denBox.width) / 2, dy: denBaseline)
        box.width = barWidth
        return box
    }

    // MARK: Radicals

    private static func typesetRadical(_ content: MathNode, index: MathNode?, size: CGFloat, level: Int) -> Box {
        let contentBox = typeset(content, size: size, level: level)
        let fonts = Fonts(size: size)
        let (surdPath, surdAdvance) = fonts.glyph("√", italicStyle: false)

        let thickness = max(0.55, 0.045 * size)
        let clearance = 0.12 * size
        let targetHeight = contentBox.ascent + contentBox.descent + clearance + thickness

        var box = Box()
        var surdWidth = surdAdvance
        var vinculumY = contentBox.ascent + clearance

        if let surdPath {
            let bb = surdPath.boundingBoxOfPath
            let sy = targetHeight / max(bb.height, 1)
            let sx = min(1.0, 0.55 + 0.45 / max(sy, 1))
            // Scale about the glyph's own box, then drop so its bottom sits at
            // the content's depth.
            var transform = CGAffineTransform(translationX: -bb.minX * sx, y: -contentBox.descent - bb.minY * sy)
                .scaledBy(x: sx, y: sy)
            if let scaled = surdPath.copy(using: &transform) {
                let sbb = scaled.boundingBoxOfPath
                box.glyphs.append(scaled)
                box.ascent = max(box.ascent, sbb.maxY)
                box.descent = max(box.descent, -sbb.minY)
                surdWidth = sbb.width
                vinculumY = sbb.maxY - thickness
            }
        }

        let start = surdWidth - 0.02 * size
        box.place(contentBox, dx: start + 0.06 * size, dy: 0)
        let end = start + 0.06 * size + contentBox.width + 0.1 * size
        box.addRule(CGRect(x: start, y: vinculumY, width: end - start, height: thickness))

        if let index {
            let idxBox = typeset(index, size: scriptSize(size, level: level + 1), level: level + 2)
            box.place(idxBox, dx: max(0, surdWidth * 0.1 - idxBox.width * 0.3), dy: box.ascent * 0.45)
        }
        box.width = end
        return box
    }

    // MARK: Big operators

    private static func typesetBigOp(_ glyph: String, sup: MathNode?, sub: MathNode?, aboveBelow: Bool, size: CGFloat, level: Int) -> Box {
        let opBox: Box
        if glyph == "lim" {
            opBox = typesetSymbols("lim", style: .upright, size: size)
        } else {
            let opSize = level == 0 ? size * 1.5 : size
            var b = typesetSymbols(glyph, style: .upright, size: opSize)
            // Center the tall operator on the math axis.
            let axis = 0.26 * size
            let mid = (b.ascent - b.descent) / 2
            let shift = axis - mid
            var shifted = Box()
            shifted.place(b, dx: 0, dy: shift)
            shifted.width = b.width
            b = shifted
            opBox = b
        }

        let sSize = scriptSize(size, level: level)
        var box = Box()

        if aboveBelow {
            let supBox = sup.map { typeset($0, size: sSize, level: level + 1) }
            let subBox = sub.map { typeset($0, size: sSize, level: level + 1) }
            let width = max(opBox.width, max(supBox?.width ?? 0, subBox?.width ?? 0))
            box.place(opBox, dx: (width - opBox.width) / 2, dy: 0)
            if let supBox {
                box.place(supBox, dx: (width - supBox.width) / 2,
                          dy: opBox.ascent + 0.16 * size + supBox.descent)
            }
            if let subBox {
                box.place(subBox, dx: (width - subBox.width) / 2,
                          dy: -(opBox.descent + 0.16 * size + subBox.ascent))
            }
            box.width = width
        } else {
            box = opBox
            var maxW: CGFloat = 0
            let x = opBox.width + 0.03 * size
            if let sup {
                let supBox = typeset(sup, size: sSize, level: level + 1)
                box.place(supBox, dx: x, dy: opBox.ascent - 0.3 * sSize)
                maxW = max(maxW, supBox.width)
            }
            if let sub {
                let subBox = typeset(sub, size: sSize, level: level + 1)
                box.place(subBox, dx: x - 0.08 * size, dy: -(opBox.descent + 0.28 * sSize))
                maxW = max(maxW, subBox.width)
            }
            box.width = x + maxW
        }
        return box
    }

    // MARK: Delimiters

    private static func typesetDelimited(open: String, content: MathNode, close: String, size: CGFloat, level: Int) -> Box {
        let contentBox = typeset(content, size: size, level: level)
        let tall = contentBox.ascent + contentBox.descent > 1.18 * size
        var box = Box()
        var x: CGFloat = 0

        func placeDelimiter(_ s: String) {
            guard !s.isEmpty else { return }
            if s == "|" {
                // Draw as a clean rule.
                let t = max(0.5, 0.045 * size)
                let over = 0.06 * size
                box.addRule(CGRect(
                    x: x + 0.05 * size, y: -contentBox.descent - over,
                    width: t, height: contentBox.ascent + contentBox.descent + 2 * over
                ))
                x += t + 0.16 * size
                return
            }
            var delim = typesetSymbols(s, style: .upright, size: size)
            if tall {
                let target = contentBox.ascent + contentBox.descent + 0.1 * size
                let scale = target / max(delim.ascent + delim.descent, 1)
                var stretched = Box()
                var transform = CGAffineTransform(scaleX: min(1.05, 0.75 + 0.25 * scale), y: scale)
                for p in delim.glyphs {
                    if let s2 = p.copy(using: &transform) { stretched.glyphs.append(s2) }
                }
                for p in stretched.glyphs {
                    let bb = p.boundingBoxOfPath
                    stretched.ascent = max(stretched.ascent, bb.maxY)
                    stretched.descent = max(stretched.descent, -bb.minY)
                    stretched.width = max(stretched.width, bb.maxX)
                }
                // Center on the content's vertical span.
                let contentMid = (contentBox.ascent - contentBox.descent) / 2
                let delimMid = (stretched.ascent - stretched.descent) / 2
                var recentered = Box()
                recentered.place(stretched, dx: 0, dy: contentMid - delimMid)
                recentered.width = stretched.width
                delim = recentered
            }
            box.place(delim, dx: x, dy: 0)
            x += delim.width + 0.04 * size
        }

        placeDelimiter(open)
        box.place(contentBox, dx: x, dy: 0)
        x += contentBox.width + 0.04 * size
        placeDelimiter(close)
        box.width = x
        return box
    }

    // MARK: Accents

    private static func typesetAccent(_ base: MathNode, kind: AccentKind, size: CGFloat, level: Int) -> Box {
        var box = typeset(base, size: size, level: level)
        let w = max(box.width, 0.3 * size)
        let y = box.ascent + 0.1 * size
        let t = max(0.5, 0.05 * size)

        switch kind {
        case .bar:
            box.addRule(CGRect(x: w * 0.08, y: y, width: w * 0.84, height: t))
        case .vec:
            let arrowW = w * 0.86
            let x0 = w * 0.07
            box.addRule(CGRect(x: x0, y: y, width: arrowW, height: t))
            // Arrowhead: small filled triangle.
            let tip = CGPoint(x: x0 + arrowW + 0.14 * size, y: y + t / 2)
            let head = CGMutablePath()
            head.move(to: tip)
            head.addLine(to: CGPoint(x: tip.x - 0.2 * size, y: tip.y + 0.09 * size))
            head.addLine(to: CGPoint(x: tip.x - 0.2 * size, y: tip.y - 0.09 * size))
            head.closeSubpath()
            box.glyphs.append(head)
            box.ascent = max(box.ascent, tip.y + 0.1 * size)
            box.width = max(box.width, tip.x)
        case .hat:
            let cx = w / 2
            let half = min(0.24 * size, w * 0.42)
            let rise = 0.14 * size
            box.glyphs.append(strokedSegment(
                from: CGPoint(x: cx - half, y: y), to: CGPoint(x: cx, y: y + rise), thickness: t))
            box.glyphs.append(strokedSegment(
                from: CGPoint(x: cx, y: y + rise), to: CGPoint(x: cx + half, y: y), thickness: t))
            box.ascent = max(box.ascent, y + rise + t)
        case .dot, .ddot:
            let r = 0.055 * size
            let cy = y + r
            let cx = w / 2
            if kind == .dot {
                box.glyphs.append(CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil))
            } else {
                for offset in [-0.09 * size, 0.09 * size] {
                    box.glyphs.append(CGPath(ellipseIn: CGRect(x: cx + offset - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil))
                }
            }
            box.ascent = max(box.ascent, cy + r)
        case .tilde:
            let fonts = Fonts(size: size)
            let (maybePath, _) = fonts.glyph("~", italicStyle: false)
            if let p = maybePath {
                let bb = p.boundingBoxOfPath
                var transform = CGAffineTransform(translationX: w / 2 - bb.midX, y: y - bb.minY)
                if let moved = p.copy(using: &transform) {
                    box.glyphs.append(moved)
                    box.ascent = max(box.ascent, y + bb.height)
                }
            }
        }
        return box
    }

    private static func strokedSegment(from a: CGPoint, to b: CGPoint, thickness: CGFloat) -> CGPath {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max((dx * dx + dy * dy).squareRoot(), 0.001)
        let nx = -dy / len * thickness / 2, ny = dx / len * thickness / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: a.x + nx, y: a.y + ny))
        path.addLine(to: CGPoint(x: b.x + nx, y: b.y + ny))
        path.addLine(to: CGPoint(x: b.x - nx, y: b.y - ny))
        path.addLine(to: CGPoint(x: a.x - nx, y: a.y - ny))
        path.closeSubpath()
        return path
    }

    // MARK: - Vector-ink conversion (scanline hatch fill)

    /// Converts a layout into ink-annotation bezier paths: each filled shape
    /// becomes its outline plus closely spaced horizontal fill strokes, so the
    /// equation is solid, resolution-independent ink in any PDF viewer.
    static func inkPaths(for output: Output, strokeWidth: CGFloat = 0.42) -> [NSBezierPath] {
        var result: [NSBezierPath] = []
        let spacing = strokeWidth * 0.78

        for glyphPath in output.glyphs {
            let rings = flatten(glyphPath)
            guard !rings.isEmpty else { continue }
            let path = NSBezierPath()
            path.lineWidth = strokeWidth
            for ring in rings where ring.count > 1 {
                path.move(to: ring[0])
                for p in ring.dropFirst() { path.line(to: p) }
                path.close()
            }
            for (a, b) in hatchSpans(rings: rings, spacing: spacing) {
                path.move(to: a)
                path.line(to: b)
            }
            result.append(path)
        }

        for rect in output.rules {
            let path = NSBezierPath()
            path.lineWidth = strokeWidth
            var y = rect.minY + strokeWidth / 2
            let last = rect.maxY - strokeWidth / 2
            while y <= last + 0.01 {
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.line(to: CGPoint(x: rect.maxX, y: y))
                y += spacing
                if y > last && y - spacing < last - 0.01 { y = last }
            }
            if path.isEmpty {
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.line(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
            result.append(path)
        }
        return result
    }

    private static func quadPoint(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
        let mt: CGFloat = 1 - t
        let a: CGFloat = mt * mt
        let b: CGFloat = 2 * mt * t
        let d: CGFloat = t * t
        let x: CGFloat = a * p0.x + b * c.x + d * p1.x
        let y: CGFloat = a * p0.y + b * c.y + d * p1.y
        return CGPoint(x: x, y: y)
    }

    private static func cubicPoint(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
        let mt: CGFloat = 1 - t
        let a: CGFloat = mt * mt * mt
        let b: CGFloat = 3 * mt * mt * t
        let c: CGFloat = 3 * mt * t * t
        let d: CGFloat = t * t * t
        let x: CGFloat = a * p0.x + b * c1.x + c * c2.x + d * p1.x
        let y: CGFloat = a * p0.y + b * c1.y + c * c2.y + d * p1.y
        return CGPoint(x: x, y: y)
    }

    /// Path → closed polygon rings (curves subdivided).
    private static func flatten(_ path: CGPath) -> [[CGPoint]] {
        var rings: [[CGPoint]] = []
        var current: [CGPoint] = []
        var start = CGPoint.zero
        var point = CGPoint.zero

        path.applyWithBlock { elementPtr in
            let e = elementPtr.pointee
            switch e.type {
            case .moveToPoint:
                if current.count > 1 { rings.append(current) }
                point = e.points[0]
                start = point
                current = [point]
            case .addLineToPoint:
                point = e.points[0]
                current.append(point)
            case .addQuadCurveToPoint:
                let c = e.points[0]
                let p1 = e.points[1]
                let p0 = point
                for i in 1...8 {
                    current.append(quadPoint(p0, c, p1, CGFloat(i) / 8))
                }
                point = p1
            case .addCurveToPoint:
                let c1 = e.points[0]
                let c2 = e.points[1]
                let p1 = e.points[2]
                let p0 = point
                for i in 1...12 {
                    current.append(cubicPoint(p0, c1, c2, p1, CGFloat(i) / 12))
                }
                point = p1
            case .closeSubpath:
                current.append(start)
                if current.count > 1 { rings.append(current) }
                current = []
                point = start
            @unknown default:
                break
            }
        }
        if current.count > 1 { rings.append(current) }
        return rings
    }

    /// Nonzero-winding scanline fill: horizontal spans covering the interior.
    private static func hatchSpans(rings: [[CGPoint]], spacing: CGFloat) -> [(CGPoint, CGPoint)] {
        struct Edge {
            let x1, y1, x2, y2: CGFloat
            let dir: Int
        }
        var edges: [Edge] = []
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for ring in rings {
            for i in 0..<ring.count - 1 {
                let a = ring[i], b = ring[i + 1]
                if a.y == b.y { continue }
                edges.append(Edge(x1: a.x, y1: a.y, x2: b.x, y2: b.y, dir: b.y > a.y ? 1 : -1))
                minY = min(minY, min(a.y, b.y))
                maxY = max(maxY, max(a.y, b.y))
            }
        }
        guard !edges.isEmpty else { return [] }

        var spans: [(CGPoint, CGPoint)] = []
        var y = minY + spacing / 2
        while y < maxY {
            var crossings: [(x: CGFloat, dir: Int)] = []
            for e in edges {
                let lo = min(e.y1, e.y2), hi = max(e.y1, e.y2)
                guard y >= lo, y < hi else { continue }
                let t = (y - e.y1) / (e.y2 - e.y1)
                crossings.append((e.x1 + t * (e.x2 - e.x1), e.dir))
            }
            crossings.sort { $0.x < $1.x }
            var winding = 0
            var spanStart: CGFloat?
            for c in crossings {
                let wasInside = winding != 0
                winding += c.dir
                let isInside = winding != 0
                if !wasInside, isInside {
                    spanStart = c.x
                } else if wasInside, !isInside, let s = spanStart {
                    if c.x - s > 0.05 {
                        spans.append((CGPoint(x: s, y: y), CGPoint(x: c.x, y: y)))
                    }
                    spanStart = nil
                }
            }
            y += spacing
        }
        return spans
    }
}
