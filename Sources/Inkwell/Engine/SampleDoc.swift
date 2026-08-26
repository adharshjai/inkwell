import AppKit
import PDFKit

/// Generates a demo problem-set PDF (with real form fields) so you can try
/// Inkwell immediately: `Inkwell --make-sample <path>`.
@MainActor
enum SampleDoc {

    static func write(to url: URL) {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }

        // ---- Page 1
        ctx.beginPDFPage(nil)
        drawText("PHYS 2213 — Problem Set 3", at: CGPoint(x: 72, y: 720), size: 20, bold: true, in: ctx)
        drawText("Oscillations & RC Circuits · Due Friday 11:59 pm", at: CGPoint(x: 72, y: 698), size: 11, color: .darkGray, in: ctx)
        line(in: ctx, from: CGPoint(x: 72, y: 688), to: CGPoint(x: 540, y: 688))

        drawText("Name:", at: CGPoint(x: 72, y: 660), size: 12, bold: true, in: ctx)
        drawText("NetID:", at: CGPoint(x: 340, y: 660), size: 12, bold: true, in: ctx)

        drawText("1.  A capacitor C = 4.7 µF is charged to V₀ = 12 V and discharges through", at: CGPoint(x: 72, y: 610), size: 12, in: ctx)
        drawText("     R = 10 kΩ. Find the time constant τ and the voltage after 2τ.", at: CGPoint(x: 72, y: 594), size: 12, in: ctx)
        drawText("Show your work:", at: CGPoint(x: 90, y: 566), size: 10, color: .darkGray, in: ctx)

        drawText("2.  Sketch the circuit for an inverting op-amp amplifier with gain −10 and", at: CGPoint(x: 72, y: 330), size: 12, in: ctx)
        drawText("     label all component values.", at: CGPoint(x: 72, y: 314), size: 12, in: ctx)
        ctx.endPDFPage()

        // ---- Page 2
        ctx.beginPDFPage(nil)
        drawText("3.  A mass m = 0.50 kg on a spring (k = 200 N/m) oscillates with amplitude", at: CGPoint(x: 72, y: 720), size: 12, in: ctx)
        drawText("     A = 5.0 cm. Compute ω, the period T, and the maximum speed.", at: CGPoint(x: 72, y: 704), size: 12, in: ctx)

        drawText("4.  For the reaction N₂ + 3H₂ ⇌ 2NH₃, write the equilibrium expression", at: CGPoint(x: 72, y: 430), size: 12, in: ctx)
        drawText("     and predict the shift when pressure increases.", at: CGPoint(x: 72, y: 414), size: 12, in: ctx)

        drawText("I affirm this work is my own:", at: CGPoint(x: 72, y: 120), size: 11, bold: true, in: ctx)
        drawText("(sign here)", at: CGPoint(x: 300, y: 108), size: 9, color: .gray, in: ctx)
        line(in: ctx, from: CGPoint(x: 260, y: 104), to: CGPoint(x: 480, y: 104))
        ctx.endPDFPage()

        ctx.closePDF()

        // ---- Add interactive form fields with PDFKit
        guard let doc = PDFDocument(data: data as Data) else { return }
        if let p1 = doc.page(at: 0) {
            p1.addAnnotation(textField(name: "student_name", bounds: CGRect(x: 120, y: 652, width: 190, height: 22)))
            p1.addAnnotation(textField(name: "netid", bounds: CGRect(x: 388, y: 652, width: 130, height: 22)))
            p1.addAnnotation(answerBox(name: "q1_answer", bounds: CGRect(x: 90, y: 360, width: 440, height: 196)))
        }
        if let p2 = doc.page(at: 1) {
            p2.addAnnotation(answerBox(name: "q3_answer", bounds: CGRect(x: 90, y: 470, width: 440, height: 210)))
            p2.addAnnotation(answerBox(name: "q4_answer", bounds: CGRect(x: 90, y: 170, width: 440, height: 220)))
        }

        if doc.write(to: url) {
            print("Sample problem set written to \(url.path)")
        } else {
            print("Failed writing sample to \(url.path)")
        }
    }

    // MARK: Helpers

    private static func textField(name: String, bounds: CGRect) -> PDFAnnotation {
        let field = PDFAnnotation(bounds: bounds, forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = name
        field.backgroundColor = NSColor(calibratedRed: 0.93, green: 0.95, blue: 1.0, alpha: 1)
        field.font = NSFont.systemFont(ofSize: 12)
        return field
    }

    private static func answerBox(name: String, bounds: CGRect) -> PDFAnnotation {
        let field = PDFAnnotation(bounds: bounds, forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.isMultiline = true
        field.fieldName = name
        field.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1)
        field.font = NSFont.systemFont(ofSize: 12)
        let border = PDFBorder()
        border.lineWidth = 0.5
        field.border = border
        return field
    }

    private static func drawText(
        _ string: String, at point: CGPoint, size: CGFloat,
        bold: Bool = false, color: NSColor = .black, in ctx: CGContext
    ) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
        ]
        NSAttributedString(string: string, attributes: attributes).draw(at: point)
        NSGraphicsContext.current = previous
    }

    private static func line(in ctx: CGContext, from a: CGPoint, to b: CGPoint) {
        ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
        ctx.setLineWidth(0.8)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
    }
}
