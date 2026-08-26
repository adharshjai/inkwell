import AppKit
import PDFKit

enum Exporter {

    /// Renders every page (content + annotations, including filled form fields)
    /// into a brand-new PDF with no interactive layer — what you want for
    /// submitting homework: every grader sees exactly what you see.
    static func flattened(_ document: PDFDocument) -> Data? {
        // A locked document draws blank pages; refuse rather than emit garbage.
        guard !document.isLocked, document.pageCount > 0 else { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var probeBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &probeBox, nil) else { return nil }

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .cropBox)
            let rotated = abs(page.rotation) % 180 == 90
            let size = rotated
                ? CGSize(width: bounds.height, height: bounds.width)
                : bounds.size
            var mediaBox = CGRect(origin: .zero, size: size)
            let boxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            page.draw(with: .cropBox, to: ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data.length > 0 ? data as Data : nil
    }

    /// Human-readable file size.
    static func formatBytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }
}
