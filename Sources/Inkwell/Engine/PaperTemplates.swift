//
//  PaperTemplates.swift
//  Inkwell
//
//  Single-page US-Letter "paper" generators — ruled, quad, engineering,
//  Cartesian, semilog, log-log, and polar sheets — rendered as PDF data
//  that can be inserted into a homework document for extra work.
//

import Foundation
import CoreGraphics

enum PaperTemplate: String, CaseIterable, Identifiable {
    case blank, ruled, grid, engineering, cartesian, semilog, loglog, polar, canvas

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blank:       return "Blank"
        case .ruled:       return "College Ruled"
        case .grid:        return "Quad Grid"
        case .engineering: return "Engineering"
        case .cartesian:   return "Graph (Cartesian)"
        case .semilog:     return "Semilog (4 decades)"
        case .loglog:      return "Log-Log"
        case .polar:       return "Polar"
        case .canvas:      return "Infinite Canvas"
        }
    }

    var subtitle: String {
        switch self {
        case .blank:       return "A clean white sheet"
        case .ruled:       return "Notes & derivations"
        case .grid:        return "4 squares per inch"
        case .engineering: return "Classic green pad"
        case .cartesian:   return "Sketch functions & fields"
        case .semilog:     return "Bode plots & frequency response"
        case .loglog:      return "Power laws & scaling"
        case .polar:       return "Phasors & antenna patterns"
        case .canvas:      return "Landscape board — zoom forever"
        }
    }

    var systemImage: String {
        switch self {
        case .blank:       return "doc"
        case .ruled:       return "text.justify.left"
        case .grid:        return "grid"
        case .engineering: return "ruler"
        case .cartesian:   return "chart.xyaxis.line"
        case .semilog:     return "waveform.path.ecg"
        case .loglog:      return "chart.line.uptrend.xyaxis"
        case .polar:       return "circle.circle"
        case .canvas:      return "infinity"
        }
    }

    /// A complete single-page US-Letter (612 x 792 pt) PDF.
    func pageData() -> Data {
        PaperRenderer.render(self)
    }
}

// MARK: - Renderer

/// An RGB ink that hands out `CGColor`s at any opacity.
private struct Ink {
    var r: CGFloat, g: CGFloat, b: CGFloat
    func with(alpha: CGFloat) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: alpha)
    }
}

private enum PaperRenderer {

    static let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    /// The infinite-canvas board: landscape, near the PDF-viewer size cap,
    /// meant to be zoomed 0.05x-16x rather than scrolled page to page.
    static let canvasRect = CGRect(x: 0, y: 0, width: 10000, height: 6250)

    // Shared palette. Graph papers use the gray-blue family; the
    // engineering pad keeps its traditional greens.
    private static let grayBlue     = Ink(r: 0.55, g: 0.65, b: 0.80)
    private static let frameBlue    = Ink(r: 0.45, g: 0.55, b: 0.72)
    private static let ruleBlue     = Ink(r: 0.62, g: 0.76, b: 0.92)
    private static let marginRed    = Ink(r: 0.94, g: 0.55, b: 0.55)
    private static let faintGreen   = Ink(r: 0.55, g: 0.77, b: 0.58)
    private static let mediumGreen  = Ink(r: 0.33, g: 0.58, b: 0.39)
    private static let axisGray     = Ink(r: 0.30, g: 0.32, b: 0.36)

    static func render(_ template: PaperTemplate) -> Data {
        let rect = template == .canvas ? canvasRect : pageRect
        var mediaBox = rect
        guard
            let data = CFDataCreateMutable(nil, 0),
            let consumer = CGDataConsumer(data: data),
            let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return Data() }

        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        draw(template, in: ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    private static func draw(_ template: PaperTemplate, in ctx: CGContext) {
        switch template {
        case .blank:       break
        case .ruled:       drawRuled(ctx)
        case .grid:        drawQuad(ctx)
        case .engineering: drawEngineering(ctx)
        case .cartesian:   drawCartesian(ctx)
        case .semilog:     drawSemilog(ctx)
        case .loglog:      drawLogLog(ctx)
        case .polar:       drawPolar(ctx)
        case .canvas:      drawCanvas(ctx)
        }
    }

    // MARK: Templates

    /// Two-level grid that stays legible from 0.05x (whole board) to 16x
    /// (deep zoom): minors every 100 pt, majors every 500 pt.
    private static func drawCanvas(_ ctx: CGContext) {
        let rect = canvasRect
        var minors: [(CGPoint, CGPoint)] = []
        var majors: [(CGPoint, CGPoint)] = []
        var x: CGFloat = 0
        while x <= rect.maxX {
            let seg = (CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY))
            if x.truncatingRemainder(dividingBy: 500) == 0 { majors.append(seg) } else { minors.append(seg) }
            x += 100
        }
        var y: CGFloat = 0
        while y <= rect.maxY {
            let seg = (CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y))
            if y.truncatingRemainder(dividingBy: 500) == 0 { majors.append(seg) } else { minors.append(seg) }
            y += 100
        }
        setStroke(ctx, grayBlue, alpha: 0.20, width: 1.0)
        strokeSegments(ctx, minors)
        setStroke(ctx, grayBlue, alpha: 0.38, width: 1.6)
        strokeSegments(ctx, majors)
    }


    private static func drawRuled(_ ctx: CGContext) {
        // Rules descend from 84 pt below the top edge; nothing below y = 54.
        setStroke(ctx, ruleBlue, alpha: 0.9, width: 0.7)
        var rules: [(CGPoint, CGPoint)] = []
        var y: CGFloat = 708
        while y >= 54 {
            rules.append(hLine(y, from: 0, to: pageRect.width))
            y -= 23
        }
        strokeSegments(ctx, rules)

        setStroke(ctx, marginRed, alpha: 1, width: 0.9)
        strokeSegments(ctx, [vLine(90, from: 0, to: pageRect.height)])
    }

    private static func drawQuad(_ ctx: CGContext) {
        let area = pageRect.insetBy(dx: 36, dy: 36)
        drawGrid(ctx, in: area, step: 18, ink: grayBlue,
                 pale: (alpha: 0.38, width: 0.75),
                 strong: (alpha: 0.65, width: 1.0),
                 strongEvery: 4)
    }

    private static func drawEngineering(_ ctx: CGContext) {
        // Traditional pale green tint over the whole sheet.
        ctx.setFillColor(CGColor(red: 0.955, green: 0.985, blue: 0.955, alpha: 1))
        ctx.fill(pageRect)

        // 5-per-inch grid confined to the working area, heavier at each inch.
        let working = CGRect(x: 54, y: 36, width: 576 - 54, height: 712 - 36)
        drawGrid(ctx, in: working, step: 14.4, ink: faintGreen,
                 pale: (alpha: 0.42, width: 0.7),
                 strong: (alpha: 0.85, width: 0.6),
                 strongEvery: 5)

        // Frame, full-height margin line, and three-cell header band.
        setStroke(ctx, mediumGreen, alpha: 1, width: 1.0)
        ctx.stroke(working)
        strokeSegments(ctx, [
            vLine(54, from: 0, to: pageRect.height),
            hLine(712, from: 0, to: pageRect.width),
            hLine(738, from: 0, to: pageRect.width),
            vLine(204, from: 712, to: 738),
            vLine(408, from: 712, to: 738),
        ])
    }

    private static func drawCartesian(_ ctx: CGContext) {
        let area = pageRect.insetBy(dx: 36, dy: 36)
        drawGrid(ctx, in: area, step: 18, ink: grayBlue,
                 pale: (alpha: 0.36, width: 0.75),
                 strong: (alpha: 0.7, width: 0.6),
                 strongEvery: 5)

        // Centered axes; arrow tips reach just past the grid on all four ends.
        let cx: CGFloat = 306, cy: CGFloat = 396
        let overshoot: CGFloat = 9
        setStroke(ctx, axisGray, alpha: 1, width: 1.2)
        ctx.setFillColor(axisGray.with(alpha: 1))
        strokeSegments(ctx, [
            hLine(cy, from: area.minX, to: area.maxX),
            vLine(cx, from: area.minY, to: area.maxY),
        ])
        arrowhead(ctx, tip: CGPoint(x: area.maxX + overshoot, y: cy), direction: CGVector(dx: 1, dy: 0))
        arrowhead(ctx, tip: CGPoint(x: area.minX - overshoot, y: cy), direction: CGVector(dx: -1, dy: 0))
        arrowhead(ctx, tip: CGPoint(x: cx, y: area.maxY + overshoot), direction: CGVector(dx: 0, dy: 1))
        arrowhead(ctx, tip: CGPoint(x: cx, y: area.minY - overshoot), direction: CGVector(dx: 0, dy: -1))
    }

    private static func drawSemilog(_ ctx: CGContext) {
        let plot = pageRect.insetBy(dx: 54, dy: 54)

        // Linear x: fine line every 18 pt, heavier every 90 pt.
        var fine: [(CGPoint, CGPoint)] = []
        var heavy: [(CGPoint, CGPoint)] = []
        for i in 0...gridCount(plot.width, step: 18) {
            let seg = vLine(plot.minX + CGFloat(i) * 18, from: plot.minY, to: plot.maxY)
            if i.isMultiple(of: 5) { heavy.append(seg) } else { fine.append(seg) }
        }
        setStroke(ctx, grayBlue, alpha: 0.4, width: 0.5)
        strokeSegments(ctx, fine)
        setStroke(ctx, grayBlue, alpha: 0.75, width: 0.7)
        strokeSegments(ctx, heavy)

        // Logarithmic y: four decades.
        drawLogScale(ctx, .vertical, in: plot, decades: 4)
        frame(ctx, plot)
    }

    private static func drawLogLog(_ ctx: CGContext) {
        let plot = pageRect.insetBy(dx: 54, dy: 54)
        drawLogScale(ctx, .horizontal, in: plot, decades: 3)
        drawLogScale(ctx, .vertical, in: plot, decades: 4)
        frame(ctx, plot)
    }

    private static func drawPolar(_ ctx: CGContext) {
        let area = pageRect.insetBy(dx: 36, dy: 36)
        let center = CGPoint(x: area.midX, y: area.midY)
        let ringStep: CGFloat = 27
        let ringCount = Int(min(area.width, area.height) / 2 / ringStep)
        let maxRadius = CGFloat(ringCount) * ringStep

        // Concentric rings: pale, with every 3rd ring stronger.
        for strongPass in [false, true] {
            if strongPass { setStroke(ctx, grayBlue, alpha: 0.8, width: 0.7) }
            else          { setStroke(ctx, grayBlue, alpha: 0.45, width: 0.5) }
            for i in 1...ringCount where i.isMultiple(of: 3) == strongPass {
                let r = CGFloat(i) * ringStep
                ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r,
                                             width: 2 * r, height: 2 * r))
            }
        }

        // Radial spokes every 15 degrees, stronger every 45.
        var pale: [(CGPoint, CGPoint)] = []
        var strong: [(CGPoint, CGPoint)] = []
        for deg in stride(from: 0, to: 360, by: 15) {
            let theta = CGFloat(deg) * .pi / 180
            let end = CGPoint(x: center.x + cos(theta) * maxRadius,
                              y: center.y + sin(theta) * maxRadius)
            if deg % 45 == 0 { strong.append((center, end)) } else { pale.append((center, end)) }
        }
        setStroke(ctx, grayBlue, alpha: 0.45, width: 0.5)
        strokeSegments(ctx, pale)
        setStroke(ctx, grayBlue, alpha: 0.8, width: 0.7)
        strokeSegments(ctx, strong)

        // Tiny center dot.
        ctx.setFillColor(grayBlue.with(alpha: 1))
        ctx.fillEllipse(in: CGRect(x: center.x - 1.6, y: center.y - 1.6, width: 3.2, height: 3.2))
    }

    // MARK: Shared drawing helpers

    private static func setStroke(_ ctx: CGContext, _ ink: Ink, alpha: CGFloat, width: CGFloat) {
        ctx.setStrokeColor(ink.with(alpha: alpha))
        ctx.setLineWidth(width)
    }

    private static func strokeSegments(_ ctx: CGContext, _ segments: [(CGPoint, CGPoint)]) {
        guard !segments.isEmpty else { return }
        for (a, b) in segments {
            ctx.move(to: a)
            ctx.addLine(to: b)
        }
        ctx.strokePath()
    }

    private static func hLine(_ y: CGFloat, from x0: CGFloat, to x1: CGFloat) -> (CGPoint, CGPoint) {
        (CGPoint(x: x0, y: y), CGPoint(x: x1, y: y))
    }

    private static func vLine(_ x: CGFloat, from y0: CGFloat, to y1: CGFloat) -> (CGPoint, CGPoint) {
        (CGPoint(x: x, y: y0), CGPoint(x: x, y: y1))
    }

    /// Number of whole grid steps that fit in `span` (tolerant of FP dust).
    private static func gridCount(_ span: CGFloat, step: CGFloat) -> Int {
        Int(span / step + 0.001)
    }

    /// A uniform grid over `rect`, with every `strongEvery`-th line emphasized.
    private static func drawGrid(
        _ ctx: CGContext, in rect: CGRect, step: CGFloat, ink: Ink,
        pale: (alpha: CGFloat, width: CGFloat),
        strong: (alpha: CGFloat, width: CGFloat),
        strongEvery: Int
    ) {
        var paleSegs: [(CGPoint, CGPoint)] = []
        var strongSegs: [(CGPoint, CGPoint)] = []

        for i in 0...gridCount(rect.width, step: step) {
            let seg = vLine(rect.minX + CGFloat(i) * step, from: rect.minY, to: rect.maxY)
            if i.isMultiple(of: strongEvery) { strongSegs.append(seg) } else { paleSegs.append(seg) }
        }
        for j in 0...gridCount(rect.height, step: step) {
            let seg = hLine(rect.minY + CGFloat(j) * step, from: rect.minX, to: rect.maxX)
            if j.isMultiple(of: strongEvery) { strongSegs.append(seg) } else { paleSegs.append(seg) }
        }

        setStroke(ctx, ink, alpha: pale.alpha, width: pale.width)
        strokeSegments(ctx, paleSegs)
        setStroke(ctx, ink, alpha: strong.alpha, width: strong.width)
        strokeSegments(ctx, strongSegs)
    }

    private enum Axis { case horizontal, vertical }

    /// Logarithmic ruling along one axis of `plot`: pale lines at log10(2...9)
    /// within each decade, strong lines at every decade boundary.
    private static func drawLogScale(_ ctx: CGContext, _ axis: Axis, in plot: CGRect, decades: Int) {
        let origin = (axis == .vertical) ? plot.minY : plot.minX
        let decadeSpan = ((axis == .vertical) ? plot.height : plot.width) / CGFloat(decades)

        func segment(at p: CGFloat) -> (CGPoint, CGPoint) {
            axis == .vertical
                ? hLine(p, from: plot.minX, to: plot.maxX)
                : vLine(p, from: plot.minY, to: plot.maxY)
        }

        var pale: [(CGPoint, CGPoint)] = []
        for d in 0..<decades {
            let base = origin + CGFloat(d) * decadeSpan
            for k in 2...9 {
                pale.append(segment(at: base + decadeSpan * CGFloat(log10(Double(k)))))
            }
        }
        let boundaries = (0...decades).map { segment(at: origin + CGFloat($0) * decadeSpan) }

        setStroke(ctx, grayBlue, alpha: 0.45, width: 0.5)
        strokeSegments(ctx, pale)
        setStroke(ctx, grayBlue, alpha: 0.9, width: 0.9)
        strokeSegments(ctx, boundaries)
    }

    private static func frame(_ ctx: CGContext, _ rect: CGRect) {
        setStroke(ctx, frameBlue, alpha: 1, width: 1.0)
        ctx.stroke(rect)
    }

    /// A filled arrowhead whose point sits at `tip`, aimed along unit vector `d`.
    private static func arrowhead(_ ctx: CGContext, tip: CGPoint, direction d: CGVector) {
        let length: CGFloat = 11
        let halfWidth: CGFloat = 4
        let base = CGPoint(x: tip.x - d.dx * length, y: tip.y - d.dy * length)
        let perp = CGVector(dx: -d.dy, dy: d.dx)
        ctx.beginPath()
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: base.x + perp.dx * halfWidth, y: base.y + perp.dy * halfWidth))
        ctx.addLine(to: CGPoint(x: base.x - perp.dx * halfWidth, y: base.y - perp.dy * halfWidth))
        ctx.closePath()
        ctx.fillPath()
    }
}
