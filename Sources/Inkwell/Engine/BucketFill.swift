import AppKit
import PDFKit

/// Paint-bucket fill: renders the region around the click (page content plus
/// the user's own ink), flood-fills from the clicked pixel, and converts the
/// filled mask back into vector ink — dense horizontal scanline strokes that
/// move, erase, undo, and flatten like everything else.
@MainActor
enum BucketFill {

    /// How far a pixel may differ (per channel, 0–255) and still be "the same
    /// region" as the clicked pixel.
    private static let tolerance = 55

    /// Fills the enclosed region around `pagePoint`. `window` bounds the
    /// search (typically the visible page rect). Returns false when the
    /// region leaks out of the window (not enclosed) or something failed.
    @discardableResult
    static func fill(
        at pagePoint: CGPoint,
        on page: PDFPage,
        window: CGRect,
        state: AppState
    ) -> Bool {
        let cropBox = page.bounds(for: .cropBox)
        var region = window.intersection(cropBox)
        guard !region.isEmpty else { return false }

        // Keep the render bounded: at most ~1000pt on a side, centered on the click.
        let maxSide: CGFloat = 1000
        if region.width > maxSide {
            region.origin.x = min(max(pagePoint.x - maxSide / 2, region.minX), region.maxX - maxSide)
            region.size.width = maxSide
        }
        if region.height > maxSide {
            region.origin.y = min(max(pagePoint.y - maxSide / 2, region.minY), region.maxY - maxSide)
            region.size.height = maxSide
        }
        guard region.insetBy(dx: 1, dy: 1).contains(pagePoint) else { return false }

        // Render scale: fine enough for smooth fills, capped for big regions.
        let scale = min(2.0, 1600 / max(region.width, region.height))
        let width = Int(region.width * scale)
        let height = Int(region.height * scale)
        guard width > 4, height > 4,
              let ctx = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return false }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -region.minX, y: -region.minY)
        state.withOwnAnnotationsVisible {
            page.draw(with: .cropBox, to: ctx)
        }

        guard let data = ctx.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        func channel(_ x: Int, _ y: Int, _ c: Int) -> Int {
            Int(pixels[(y * width + x) * 4 + c])
        }

        let startX = Int((pagePoint.x - region.minX) * scale)
        let startYPage = Int((pagePoint.y - region.minY) * scale)
        // Bitmap row 0 is the TOP of the image; page y grows upward.
        let startY = height - 1 - startYPage
        guard startX > 0, startX < width - 1, startY > 0, startY < height - 1 else { return false }

        let r0 = channel(startX, startY, 0)
        let g0 = channel(startX, startY, 1)
        let b0 = channel(startX, startY, 2)

        func similar(_ x: Int, _ y: Int) -> Bool {
            abs(channel(x, y, 0) - r0) <= tolerance
                && abs(channel(x, y, 1) - g0) <= tolerance
                && abs(channel(x, y, 2) - b0) <= tolerance
        }

        // Scanline flood fill.
        var mask = [Bool](repeating: false, count: width * height)
        var stack: [(Int, Int)] = [(startX, startY)]
        var filledCount = 0
        var touchedBorder = false

        while let (sx, sy) = stack.popLast() {
            if mask[sy * width + sx] || !similar(sx, sy) { continue }
            // Expand the run left and right.
            var left = sx
            while left > 0, !mask[sy * width + left - 1], similar(left - 1, sy) { left -= 1 }
            var right = sx
            while right < width - 1, !mask[sy * width + right + 1], similar(right + 1, sy) { right += 1 }
            if left == 0 || right == width - 1 { touchedBorder = true }
            if sy == 0 || sy == height - 1 { touchedBorder = true }
            for x in left...right {
                mask[sy * width + x] = true
                filledCount += 1
            }
            for ny in [sy - 1, sy + 1] where ny >= 0 && ny < height {
                var x = left
                while x <= right {
                    if !mask[ny * width + x], similar(x, ny) {
                        stack.append((x, ny))
                        // Skip to the end of this similar run to keep the stack small.
                        while x <= right, similar(x, ny) { x += 1 }
                    } else {
                        x += 1
                    }
                }
            }
            if touchedBorder { break }
        }

        if touchedBorder {
            state.flash("That area isn’t enclosed — the fill would leak out. Close the shape or zoom to frame it.", seconds: 3.5)
            return false
        }
        guard filledCount > 8 else { return false }

        // Mask → horizontal ink segments (page space, y-up).
        let rowHeight = 1.0 / scale
        let strokeWidth = rowHeight * 1.35
        let path = NSBezierPath()
        for y in 0..<height {
            let pageY = region.minY + (CGFloat(height - 1 - y) + 0.5) * rowHeight
            var x = 0
            while x < width {
                if mask[y * width + x] {
                    let runStart = x
                    while x < width, mask[y * width + x] { x += 1 }
                    let x0 = region.minX + CGFloat(runStart) * rowHeight
                    let x1 = region.minX + CGFloat(x) * rowHeight
                    path.move(to: CGPoint(x: x0, y: pageY))
                    path.line(to: CGPoint(x: x1, y: pageY))
                } else {
                    x += 1
                }
            }
        }
        guard !path.isEmpty else { return false }
        path.lineWidth = strokeWidth

        guard let annotation = Annotations.makeInk(
            paths: [path], color: state.fillColor, width: strokeWidth
        ) else { return false }
        Annotations.add(annotation, to: page, state: state, actionName: "Fill")
        return true
    }
}
