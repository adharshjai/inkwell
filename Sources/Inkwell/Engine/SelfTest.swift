import AppKit
import PDFKit

/// Headless verification run with `Inkwell --selftest`. Exercises the geometry
/// conventions this app depends on (ink path space, flattening) against the
/// installed PDFKit, plus the pure engine modules.
@MainActor
enum SelfTest {

    private static var failures = 0

    static func run() {
        print("Inkwell self-test\n=================")

        testMathText()
        testCasualTranslation()
        testTypesetLayout()
        testTypesetInk()
        testShapeRecognizer()
        testUndoRedo()
        testCrispVisibilityPolicy()
        testPaperTemplates()
        testStamps()
        testInkConvention()
        testFlatten()
        testSignaturePlacement()

        print(failures == 0 ? "\nAll self-tests passed." : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    /// `Inkwell --typeset-demo out.png` — renders a sheet of typeset equations
    /// (via the real annotation pipeline) for visual inspection.
    static func typesetDemo(to url: URL) {
        guard let doc = PDFDocument(data: PaperTemplate.blank.pageData()),
              let page = doc.page(at: 0) else { return }
        let samples = [
            "omega0 = 1/sqrt(LC)",
            "x = (-b +- sqrt(b^2 - 4ac))/2a",
            "int_0^inf e^-x^2 dx = sqrt(pi)/2",
            "lim_{h->0} (f(x+h) - f(x))/h",
            "div E = rho/epsilon0",
            "vec F = q vec E + q vec v cross vec B",
            "K_a = [H^+][A^-]/[HA]",
            "N2 + 3H2 <=> 2NH3",
            "sum_{n=1}^N n^2 = N(N+1)(2N+1)/6",
            "6.022e23",
        ]
        var y: CGFloat = 730
        for sample in samples {
            if let annotation = Annotations.makeTypesetMath(
                sample, fontSize: 22, centeredAt: CGPoint(x: 306, y: y), color: .black
            ) {
                page.addAnnotation(annotation)
            }
            y -= 68
        }
        let scale: CGFloat = 2
        let width = Int(612 * scale), height = Int(792 * scale)
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        guard let image = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            print("Typeset demo written to \(url.path)")
        }
    }

    private static func check(_ condition: Bool, _ name: String, _ detail: String = "") {
        if condition {
            print("  PASS \(name)")
        } else {
            failures += 1
            print("  FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    // MARK: Math

    private static func testMathText() {
        print("MathText:")
        var bad: [String] = []
        for example in MathText.examples {
            let got = MathText.render(example.input)
            if got != example.output {
                bad.append("\(example.input) → \(got) (expected \(example.output))")
            }
        }
        check(bad.isEmpty, "all \(MathText.examples.count) examples render", bad.joined(separator: "; "))
        check(MathText.render("plain text 123") == "plain text 123", "plain text passes through")
        check(!MathText.render("x^2 + y_1").contains("^"), "basic super/subscript conversion")
    }

    // MARK: Casual → LaTeX

    private static func testCasualTranslation() {
        print("CasualMath:")
        let contains: [(String, String)] = [
            ("sqrt(LC)", "\\sqrt{LC}"),
            ("mu0", "\\mu_0"),
            ("w0", "w_0"),
            ("H2O", "H_2O"),
            ("A <=> B", "\\rightleftharpoons"),
            ("6.022e23", "\\times 10^{23}"),
            ("SO4^2-", "^{2-}"),
            ("div E", "\\nabla \\cdot"),
            ("curl F", "\\nabla \\times"),
            ("theta ~= sin(theta)", "\\approx"),
            ("ihat", "\\hat{i}"),
            ("lim_{x->0}", "\\lim"),
        ]
        var bad: [String] = []
        for (input, expected) in contains {
            let got = CasualMath.toLaTeX(input)
            if !got.contains(expected) { bad.append("\(input) → \(got)") }
        }
        check(bad.isEmpty, "casual rewrites (\(contains.count) cases)", bad.joined(separator: "; "))
        check(CasualMath.toLaTeX("df/dx").contains("df/dx"), "plain slashes untouched")
    }

    // MARK: Typeset layout

    private static func heightOf(_ source: String) -> CGFloat {
        guard let (out, _) = TypesetMath.layout(source, fontSize: 18) else { return 0 }
        return out.ascent + out.descent
    }

    private static func testTypesetLayout() {
        print("TypesetMath layout:")
        check(heightOf("1/2") > heightOf("12") * 1.4, "fractions stack vertically",
              "frac h=\(heightOf("1/2")) plain h=\(heightOf("12"))")
        check(heightOf("df/dx") > heightOf("dx") * 1.4, "derivatives stack (df/dx)")
        if let (sqrtOut, _) = TypesetMath.layout("sqrt(x+1)", fontSize: 18) {
            check(!sqrtOut.rules.isEmpty, "radical has a vinculum")
        } else {
            check(false, "sqrt layout")
        }
        if let (a, _) = TypesetMath.layout("x^2", fontSize: 18),
           let (b, _) = TypesetMath.layout("x", fontSize: 18) {
            check(a.width > b.width && a.ascent > b.ascent, "superscripts raise and widen")
        } else {
            check(false, "scripts layout")
        }
        check(TypesetMath.layout("sum_{n=1}^N n^2", fontSize: 18) != nil, "big operator with limits")
        check(TypesetMath.layout("K_a = [H^+][A^-]/[HA]", fontSize: 18) != nil, "chem equilibrium expression")
        if let (latexed, latex) = TypesetMath.layout("omega0 = 1/sqrt(LC)", fontSize: 18) {
            check(!latexed.isEmpty && latex.contains("\\sqrt"), "flagship example lays out",
                  "latex=\(latex)")
        } else {
            check(false, "flagship example")
        }
        // Ink conversion produces real strokes.
        if let (out, _) = TypesetMath.layout("x = 1/2", fontSize: 24) {
            let paths = TypesetMath.inkPaths(for: out)
            check(!paths.isEmpty && paths.allSatisfy { !$0.isEmpty }, "ink conversion emits paths (\(paths.count))")
        }
    }

    // MARK: Typeset ink on the page

    private static func testTypesetInk() {
        print("TypesetMath ink placement:")
        guard let doc = PDFDocument(data: PaperTemplate.blank.pageData()),
              let page = doc.page(at: 0) else {
            check(false, "blank page")
            return
        }
        guard let annotation = Annotations.makeTypesetMath(
            "x = 1/2", fontSize: 28, centeredAt: CGPoint(x: 300, y: 400), color: .black
        ) else {
            check(false, "typeset annotation builds")
            return
        }
        page.addAnnotation(annotation)
        guard let render = renderGray(page) else {
            check(false, "render")
            return
        }
        var darkest = 255
        for x in stride(from: 260, to: 340, by: 2) {
            for y in stride(from: 380, to: 420, by: 2) {
                darkest = min(darkest, sample(render, x: x, y: y))
            }
        }
        check(darkest < 100, "typeset math renders solid on the page", "darkest=\(darkest)")

        // Survives save/reload.
        if let saved = doc.dataRepresentation(),
           let reloaded = PDFDocument(data: saved),
           let rpage = reloaded.page(at: 0),
           let rerender = renderGray(rpage) {
            var d2 = 255
            for x in stride(from: 260, to: 340, by: 2) {
                for y in stride(from: 380, to: 420, by: 2) {
                    d2 = min(d2, sample(rerender, x: x, y: y))
                }
            }
            check(d2 < 100, "typeset math survives save & reload", "darkest=\(d2)")
        } else {
            check(false, "typeset save/reload")
        }

        // Rotation compensation: a wide equation placed on a 90°-rotated page
        // must occupy a TALL page-space footprint (display rotates it back).
        if let wide = Annotations.makeTypesetMath(
            "abc + def = xyz", fontSize: 20, centeredAt: CGPoint(x: 300, y: 400),
            color: .black, pageRotation: 90
        ) {
            check(wide.bounds.height > wide.bounds.width,
                  "rotated-page compensation swaps the footprint",
                  "bounds=\(wide.bounds)")
        } else {
            check(false, "rotated typeset annotation")
        }
    }

    // MARK: Shape recognizer

    private static func testShapeRecognizer() {
        print("ShapeRecognizer:")

        // Shaky circle → ellipse close to the ideal.
        var circle: [CGPoint] = []
        for i in 0...48 {
            let angle = 2 * CGFloat.pi * CGFloat(i) / 48
            let radius = 50 + 2.2 * sin(7 * angle)
            circle.append(CGPoint(x: 200 + radius * cos(angle), y: 300 + radius * sin(angle)))
        }
        if case .ellipse(let frame) = ShapeRecognizer.recognize(circle) {
            check(abs(frame.width - 100) < 12 && abs(frame.height - 100) < 12,
                  "shaky circle becomes a circle", "frame=\(frame)")
        } else {
            check(false, "shaky circle becomes a circle", "got \(ShapeRecognizer.recognize(circle))")
        }

        // Shaky rectangle → rect.
        var rectStroke: [CGPoint] = []
        let corners = [CGPoint(x: 100, y: 100), CGPoint(x: 220, y: 100), CGPoint(x: 220, y: 170), CGPoint(x: 100, y: 170), CGPoint(x: 100, y: 100)]
        for edge in 0..<4 {
            let a = corners[edge], b = corners[edge + 1]
            for step in 0..<12 {
                let t = CGFloat(step) / 12
                let wobble = 1.3 * sin(CGFloat(step) * 1.7 + CGFloat(edge))
                rectStroke.append(CGPoint(
                    x: a.x + t * (b.x - a.x) + (edge % 2 == 1 ? wobble : 0),
                    y: a.y + t * (b.y - a.y) + (edge % 2 == 0 ? wobble : 0)
                ))
            }
        }
        rectStroke.append(corners[0])
        if case .rect(let frame) = ShapeRecognizer.recognize(rectStroke) {
            check(abs(frame.width - 120) < 14 && abs(frame.height - 70) < 14,
                  "wobbly box becomes a rectangle", "frame=\(frame)")
        } else {
            check(false, "wobbly box becomes a rectangle")
        }

        // Slightly crooked line → snapped straight.
        var lineStroke: [CGPoint] = []
        for i in 0...20 {
            let t = CGFloat(i) / 20
            lineStroke.append(CGPoint(x: 50 + t * 140, y: 50 + t * 8 + 1.1 * sin(CGFloat(i))))
        }
        if case .line(let a, let b) = ShapeRecognizer.recognize(lineStroke) {
            check(abs(a.y - b.y) < 0.5, "crooked line snaps horizontal", "a=\(a) b=\(b)")
        } else {
            check(false, "crooked line snaps horizontal")
        }

        // Triangle → 3-corner polygon.
        var triangle: [CGPoint] = []
        let tri = [CGPoint(x: 0, y: 0), CGPoint(x: 90, y: 4), CGPoint(x: 46, y: 78), CGPoint(x: 2, y: 2)]
        for edge in 0..<3 {
            let a = tri[edge], b = tri[edge + 1]
            for step in 0..<10 {
                let t = CGFloat(step) / 10
                triangle.append(CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y)))
            }
        }
        triangle.append(tri[3])
        if case .polygon(let pts) = ShapeRecognizer.recognize(triangle) {
            check(pts.count == 3, "triangle keeps 3 corners", "corners=\(pts.count)")
        } else {
            check(false, "triangle keeps 3 corners", "got \(ShapeRecognizer.recognize(triangle))")
        }

        check(ShapeRecognizer.beautify(circle) != nil, "beautify emits paths")

        // Rounded-corner square — circularity ≈ 0.8 fooled the old classifier
        // into calling this an ellipse.
        var rounded: [CGPoint] = []
        let r: CGFloat = 18
        let side: CGFloat = 140
        let o = CGPoint(x: 100, y: 100)
        func arc(_ cx: CGFloat, _ cy: CGFloat, _ from: CGFloat, _ to: CGFloat) {
            for i in 0...6 {
                let a = from + (to - from) * CGFloat(i) / 6
                rounded.append(CGPoint(x: cx + r * cos(a), y: cy + r * sin(a)))
            }
        }
        for i in 0...10 { rounded.append(CGPoint(x: o.x + r + (side - 2 * r) * CGFloat(i) / 10, y: o.y)) }
        arc(o.x + side - r, o.y + r, -.pi / 2, 0)
        for i in 0...10 { rounded.append(CGPoint(x: o.x + side, y: o.y + r + (side - 2 * r) * CGFloat(i) / 10)) }
        arc(o.x + side - r, o.y + side - r, 0, .pi / 2)
        for i in 0...10 { rounded.append(CGPoint(x: o.x + side - r - (side - 2 * r) * CGFloat(i) / 10, y: o.y + side)) }
        arc(o.x + r, o.y + side - r, .pi / 2, .pi)
        for i in 0...10 { rounded.append(CGPoint(x: o.x, y: o.y + side - r - (side - 2 * r) * CGFloat(i) / 10)) }
        arc(o.x + r, o.y + r, .pi, 3 * .pi / 2)
        if case .rect = ShapeRecognizer.recognize(rounded) {
            check(true, "rounded-corner square is a rectangle, not an ellipse")
        } else {
            check(false, "rounded-corner square is a rectangle, not an ellipse",
                  "got \(ShapeRecognizer.recognize(rounded))")
        }

        // Diamond (rotated square) must stay a 4-corner polygon.
        var diamond: [CGPoint] = []
        let dc = CGPoint(x: 300, y: 300)
        let verts = [CGPoint(x: dc.x, y: dc.y - 80), CGPoint(x: dc.x + 80, y: dc.y),
                     CGPoint(x: dc.x, y: dc.y + 80), CGPoint(x: dc.x - 80, y: dc.y),
                     CGPoint(x: dc.x, y: dc.y - 80)]
        for e in 0..<4 {
            let a = verts[e], b = verts[e + 1]
            for i in 0..<12 {
                let t = CGFloat(i) / 12
                diamond.append(CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y)))
            }
        }
        diamond.append(verts[4])
        if case .polygon(let pts) = ShapeRecognizer.recognize(diamond) {
            check(pts.count == 4, "diamond keeps 4 corners", "corners=\(pts.count)")
        } else {
            check(false, "diamond keeps 4 corners", "got \(ShapeRecognizer.recognize(diamond))")
        }
    }

    // MARK: Undo / redo (through the app's own manager)

    /// NSUndoManager closes its per-event group when the runloop turns;
    /// headless code must turn it explicitly, like the app's event loop does.
    private static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    private static func testUndoRedo() {
        print("Undo/redo:")
        let state = AppState()
        guard let doc = PDFDocument(data: PaperTemplate.blank.pageData()),
              let page = doc.page(at: 0) else {
            check(false, "blank doc")
            return
        }
        state.document = doc

        let points = stride(from: 0, through: 60, by: 4).map { t in CGPoint(x: 100 + t, y: 200) }
        guard let stroke = Annotations.makeStroke(points: points, color: .black, width: 4) else {
            check(false, "stroke builds")
            return
        }
        Annotations.add(stroke, to: page, state: state, actionName: "Draw")
        settle()
        check(page.annotations.count == 1, "stroke lands on page")
        check(state.documentUndoManager.canUndo, "undo is registered on the app's own manager")

        state.performUndo()
        settle()
        check(page.annotations.isEmpty, "⌘Z removes the stroke")
        check(state.documentUndoManager.canRedo, "redo is available after undo")

        state.performRedo()
        settle()
        check(page.annotations.count == 1, "⇧⌘Z brings the stroke back")

        // Group move undo.
        let before = stroke.bounds.origin
        Annotations.translate(stroke, by: CGPoint(x: 30, y: -12))
        Annotations.registerGroupMove(of: [stroke], totalDelta: CGPoint(x: 30, y: -12), state: state)
        settle()
        state.performUndo()
        settle()
        check(
            abs(stroke.bounds.origin.x - before.x) < 0.01 && abs(stroke.bounds.origin.y - before.y) < 0.01,
            "move undo restores position"
        )

        // Resize undo.
        let geometry = Annotations.Geometry(of: stroke)
        let doubled = CGRect(
            x: stroke.bounds.minX, y: stroke.bounds.minY,
            width: stroke.bounds.width * 2, height: stroke.bounds.height * 2
        )
        Annotations.applyScale(stroke, from: geometry, to: doubled)
        Annotations.registerResize(of: stroke, before: geometry, state: state)
        settle()
        check(abs(stroke.bounds.width - doubled.width) < 0.01, "resize applies")
        if let original = geometry.lineWidth, let scaled = stroke.border?.lineWidth {
            check(abs(scaled - original * 2) < 0.05, "resize scales the stroke width",
                  "was \(original), now \(scaled)")
        } else {
            check(false, "resize scales the stroke width", "missing border width")
        }
        state.performUndo()
        settle()
        check(abs(stroke.bounds.width - geometry.bounds.width) < 0.01, "resize undo restores geometry")
    }

    // MARK: Crisp-rendering visibility policy

    private static func testCrispVisibilityPolicy() {
        print("Crisp rendering visibility:")
        let state = AppState()
        state.hidesOwnAnnotations = true
        guard let doc = PDFDocument(data: PaperTemplate.blank.pageData()),
              let page = doc.page(at: 0) else {
            check(false, "blank doc")
            return
        }
        state.document = doc
        let points = stride(from: 0, through: 80, by: 4).map { t in CGPoint(x: 200 + t, y: 300) }
        guard let stroke = Annotations.makeStroke(points: points, color: .black, width: 5) else {
            check(false, "stroke builds")
            return
        }
        Annotations.add(stroke, to: page, state: state, actionName: "Draw")
        check(!stroke.shouldDisplay, "new ink is hidden from PDFKit's renderer")

        if let hiddenRender = renderGray(page) {
            check(darkestNear(hiddenRender, x: 240, y: 300) > 200, "hidden ink doesn't render via PDFKit")
        }
        state.withOwnAnnotationsVisible {
            if let visibleRender = renderGray(page) {
                check(darkestNear(visibleRender, x: 240, y: 300) < 128, "saves/exports see the ink")
            }
        }
        check(!stroke.shouldDisplay, "ink is re-hidden after the save window closes")
    }

    // MARK: Paper

    private static func testPaperTemplates() {
        print("PaperTemplates:")
        for template in PaperTemplate.allCases {
            let data = template.pageData()
            guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else {
                check(false, template.rawValue, "not a loadable PDF")
                continue
            }
            let expected: CGSize
            switch template {
            case .canvas: expected = CGSize(width: 10000, height: 6250)
            case .canvasPortrait: expected = CGSize(width: 6250, height: 10000)
            default: expected = CGSize(width: 612, height: 792)
            }
            let bounds = page.bounds(for: .mediaBox)
            check(
                doc.pageCount == 1
                    && abs(bounds.width - expected.width) < 1
                    && abs(bounds.height - expected.height) < 1,
                template.rawValue,
                "pages=\(doc.pageCount) bounds=\(bounds)"
            )
        }
    }

    // MARK: Stamps

    private static func testStamps() {
        print("StampLibrary:")
        check(!StampLibrary.all.isEmpty, "library not empty (\(StampLibrary.all.count) stamps)")
        for category in StampCategory.allCases {
            check(!StampLibrary.stamps(in: category).isEmpty, "category \(category.rawValue) has stamps")
        }
        var badStamps: [String] = []
        for stamp in StampLibrary.all {
            let rect = CGRect(x: 0, y: 0, width: 120, height: 120 / max(stamp.aspect, 0.05))
            let path = stamp.build(rect)
            let box = path.boundingBoxOfPath
            if path.isEmpty || box.isNull || box.width < 2 {
                badStamps.append(stamp.id)
            }
        }
        check(badStamps.isEmpty, "every stamp builds a real path", badStamps.joined(separator: ", "))
    }

    // MARK: Rendering helpers

    private static func renderGray(_ page: PDFPage) -> (ctx: CGContext, width: Int, height: Int)? {
        let bounds = page.bounds(for: .cropBox)
        let width = Int(bounds.width), height = Int(bounds.height)
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        page.draw(with: .cropBox, to: ctx)
        return (ctx, width, height)
    }

    /// Gray value (0–255) at a PDF page point.
    private static func sample(_ render: (ctx: CGContext, width: Int, height: Int), x: Int, y: Int) -> Int {
        guard let data = render.ctx.data else { return -1 }
        let row = render.height - 1 - y
        guard row >= 0, row < render.height, x >= 0, x < render.width else { return -1 }
        return Int(data.load(fromByteOffset: row * render.ctx.bytesPerRow + x, as: UInt8.self))
    }

    /// Darkest value found in a small box around a PDF point.
    private static func darkestNear(_ render: (ctx: CGContext, width: Int, height: Int), x: Int, y: Int, radius: Int = 6) -> Int {
        var darkest = 255
        for dx in -radius...radius {
            for dy in -radius...radius {
                let v = sample(render, x: x + dx, y: y + dy)
                if v >= 0 { darkest = min(darkest, v) }
            }
        }
        return darkest
    }

    // MARK: Ink coordinate convention

    private static func testInkConvention() {
        print("Ink annotation coordinate convention:")
        guard let doc = PDFDocument(data: PaperTemplate.blank.pageData()),
              let page = doc.page(at: 0) else {
            check(false, "blank page for ink test")
            return
        }
        let points = stride(from: 0, through: 100, by: 5).map { t in
            CGPoint(x: 100 + t, y: 100 + t)
        }
        guard let ink = Annotations.makeStroke(points: points, color: .black, width: 6) else {
            check(false, "stroke creation")
            return
        }
        page.addAnnotation(ink)
        guard let render = renderGray(page) else {
            check(false, "render page")
            return
        }
        let atDrawnLocation = darkestNear(render, x: 150, y: 150)
        print("    darkness where the user drew: \(atDrawnLocation) (0=black, 255=white)")
        check(
            atDrawnLocation < 128,
            "ink renders where the user drew it",
            "PDFKit drew elsewhere — convention mismatch"
        )

        // A pen tap must land as a solid dot, not a zero-length stroke.
        if let dot = Annotations.makeStroke(points: [CGPoint(x: 400, y: 500)], color: .black, width: 1.6) {
            page.addAnnotation(dot)
            if let dotRender = renderGray(page) {
                check(darkestNear(dotRender, x: 400, y: 500, radius: 4) < 128, "pen tap renders a solid dot")
            }
            page.removeAnnotation(dot)
        } else {
            check(false, "pen tap builds an annotation")
        }

        // Move it and confirm the stroke follows the bounds.
        Annotations.translate(ink, by: CGPoint(x: 120, y: 0))
        if let moved = renderGray(page) {
            check(
                darkestNear(moved, x: 270, y: 150) < 128 && darkestNear(moved, x: 150, y: 150) > 128,
                "moving an ink annotation moves its stroke"
            )
        }
        Annotations.translate(ink, by: CGPoint(x: -120, y: 0))

        // Round-trip through PDF serialization.
        if let saved = doc.dataRepresentation(),
           let reloaded = PDFDocument(data: saved),
           let reloadedPage = reloaded.page(at: 0),
           let rerender = renderGray(reloadedPage) {
            check(
                darkestNear(rerender, x: 150, y: 150) < 128,
                "ink survives save & reload at the same place"
            )
        } else {
            check(false, "save/reload round-trip")
        }
    }

    // MARK: Flatten

    private static func testFlatten() {
        print("Flatten export:")
        guard let doc = PDFDocument(data: PaperTemplate.blank.pageData()),
              let page = doc.page(at: 0) else {
            check(false, "blank doc")
            return
        }
        let points = stride(from: 0, through: 100, by: 5).map { t in
            CGPoint(x: 300 + t, y: 400)
        }
        if let ink = Annotations.makeStroke(points: points, color: .black, width: 8) {
            page.addAnnotation(ink)
        }
        let text = Annotations.makeFreeText(
            "Answer: 42", near: CGPoint(x: 100, y: 600), on: page, fontSize: 24, color: .black
        )
        page.addAnnotation(text)

        guard let data = Exporter.flattened(doc),
              let flat = PDFDocument(data: data),
              let flatPage = flat.page(at: 0) else {
            check(false, "flattened output loads")
            return
        }
        check(flat.pageCount == 1, "page count preserved")
        check(flatPage.annotations.isEmpty, "no interactive annotations remain (\(flatPage.annotations.count))")
        guard let render = renderGray(flatPage) else {
            check(false, "render flattened page")
            return
        }
        check(darkestNear(render, x: 350, y: 400) < 128, "ink stroke burned into page")
        // Text sits below the click point; scan a generous box.
        var textDark = 255
        for x in stride(from: 100, to: 240, by: 4) {
            for y in stride(from: 560, to: 605, by: 3) {
                textDark = min(textDark, sample(render, x: x, y: y))
            }
        }
        check(textDark < 128, "free text burned into page", "darkest=\(textDark)")
    }

    // MARK: Signature placement

    private static func testSignaturePlacement() {
        print("Signature placement:")
        let signature = Signature(
            name: "test", aspect: 3,
            rawStrokes: [[SigPoint(x: 0, y: 0.5), SigPoint(x: 0.5, y: 0.2), SigPoint(x: 1, y: 0.8)]]
        )
        let annotation = Annotations.makeSignature(
            signature, centeredAt: CGPoint(x: 300, y: 300), width: 150, color: .black
        )
        check(annotation != nil, "signature annotation builds")
        if let annotation {
            check(
                annotation.bounds.contains(CGPoint(x: 300, y: 300)),
                "signature centered at target",
                "bounds=\(annotation.bounds)"
            )
        }
    }
}
