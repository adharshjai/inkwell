import Cocoa
import CoreText

// ---------------------------------------------------------------------------
// Inkwell app icon generator (macOS 26-era icon language)
//
// Renders the Inkwell icon programmatically at every pixel size required by
// an .iconset folder, plus a 1024 px human preview.
//
// Usage:
//   swift icongen.swift [iconset-dir] [preview-png]
// ---------------------------------------------------------------------------

let cliArgs = CommandLine.arguments
let iconsetPath = cliArgs.count > 1 ? cliArgs[1] : "Inkwell.iconset"
let previewPath = cliArgs.count > 2 ? cliArgs[2] : "icon_preview.png"

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - Color helpers

func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green:   CGFloat((hex >> 8)  & 0xFF) / 255.0,
            blue:    CGFloat( hex        & 0xFF) / 255.0,
            alpha:   a).cgColor
}

func white(_ a: CGFloat) -> CGColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: a).cgColor }
func black(_ a: CGFloat) -> CGColor { NSColor(srgbRed: 0, green: 0, blue: 0, alpha: a).cgColor }

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)!
}

// MARK: - Fountain-pen nib silhouette (local coords, y up, tip at bottom)

func nibPath(width W: CGFloat, height H: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let hw = 0.5 * W
    let hh = 0.5 * H
    p.move(to: CGPoint(x: 0, y: -hh))                       // tip
    p.addCurve(to: CGPoint(x: hw, y: 0.12 * H),             // right shoulder (widest)
               control1: CGPoint(x: 0.09 * W, y: -0.31 * H),
               control2: CGPoint(x: 0.36 * W, y: -0.06 * H))
    p.addCurve(to: CGPoint(x: 0, y: hh),                    // rounded arch
               control1: CGPoint(x: 0.54 * W, y: 0.30 * H),
               control2: CGPoint(x: 0.30 * W, y: hh))
    p.addCurve(to: CGPoint(x: -hw, y: 0.12 * H),            // left shoulder
               control1: CGPoint(x: -0.30 * W, y: hh),
               control2: CGPoint(x: -0.54 * W, y: 0.30 * H))
    p.addCurve(to: CGPoint(x: 0, y: -hh),                   // back to tip
               control1: CGPoint(x: -0.36 * W, y: -0.06 * H),
               control2: CGPoint(x: -0.09 * W, y: -0.31 * H))
    p.closeSubpath()
    return p
}

// MARK: - Watermark glyph drawing (CoreText, centered on a point)

func drawGlyph(_ str: String, fontSize: CGFloat, center: CGPoint, alpha: CGFloat,
               weight: NSFont.Weight, in ctx: CGContext) {
    let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
    let attr = NSAttributedString(string: str, attributes: [
        .font: font,
        .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha),
    ])
    let line = CTLineCreateWithAttributedString(attr)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// MARK: - Icon rendering

func drawIcon(px: Int) -> CGImage {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // --- Plate geometry: rounded rect at 82% of canvas, radius 23% of plate
    let plate = s * 0.82
    let o = (s - plate) / 2
    let rect = CGRect(x: o, y: o, width: plate, height: plate)
    let radius = plate * 0.23
    let platePath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                           transform: nil)

    // --- Baked soft drop shadow + base fill
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.010), blur: s * 0.022,
                  color: black(0.30))
    ctx.addPath(platePath)
    ctx.setFillColor(rgba(0x2A2D6E))
    ctx.fillPath()
    ctx.restoreGState()

    // --- Everything else clipped to the plate
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()

    // Rich vertical gradient: violet (top) -> deep indigo (bottom)
    let bg = gradient([rgba(0x6C4FD8), rgba(0x2A2D6E)], [0, 1])
    ctx.drawLinearGradient(bg,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end:   CGPoint(x: rect.midX, y: rect.minY),
                           options: [])

    // Slight radial glow, top-center
    let glowCenter = CGPoint(x: rect.midX, y: rect.minY + 0.86 * plate)
    let glow = gradient([white(0.18), white(0.0)], [0, 1])
    ctx.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0,
                           endCenter: glowCenter, endRadius: 0.72 * plate, options: [])

    // Faint STEM watermarks (only at sizes where they read as texture)
    if px >= 64 {
        drawGlyph("\u{222B}", fontSize: 0.30 * plate,
                  center: CGPoint(x: rect.minX + 0.20 * plate, y: rect.minY + 0.68 * plate),
                  alpha: 0.13, weight: .light, in: ctx)
        drawGlyph("\u{03A9}", fontSize: 0.24 * plate,
                  center: CGPoint(x: rect.minX + 0.80 * plate, y: rect.minY + 0.26 * plate),
                  alpha: 0.11, weight: .light, in: ctx)
    }

    // Three thin ruled "paper" lines across the lower third
    // (dropped below 64 px so tiny sizes stay clean)
    if px >= 64 {
        let lw = max(0.75, s * 0.004)
        ctx.setStrokeColor(white(0.28))
        ctx.setLineWidth(lw)
        let fractions: [CGFloat] = [0.115, 0.205, 0.295]
        for f in fractions {
            let y = rect.minY + f * plate
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            ctx.strokePath()
        }
    }

    // --- Fountain-pen nib, centered, rotated -12 degrees
    let H = 0.58 * plate
    let W = 0.36 * plate
    ctx.saveGState()
    ctx.translateBy(x: s / 2 - 0.01 * plate, y: s / 2 + 0.01 * plate)
    ctx.rotate(by: -12 * .pi / 180)
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.016), blur: s * 0.032,
                  color: black(0.38))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    // Nib body: near-white with a whisper of vertical shading
    let nib = nibPath(width: W, height: H)
    ctx.saveGState()
    ctx.addPath(nib)
    ctx.clip()
    let nibGrad = gradient([white(1.0), rgba(0xDDD9F2)], [0, 1])
    ctx.drawLinearGradient(nibGrad, start: CGPoint(x: 0, y: H / 2),
                           end: CGPoint(x: 0, y: -H / 2), options: [])
    ctx.restoreGState()

    // Cutouts: center slit + circular breather hole (show gradient through)
    ctx.setBlendMode(.destinationOut)
    ctx.setFillColor(black(1.0))
    let slitW = 0.036 * W
    let holeR = 0.085 * W
    let holeY = -0.04 * H
    let slitRect = CGRect(x: -slitW / 2, y: -0.415 * H, width: slitW,
                          height: holeY + 0.415 * H)
    ctx.addPath(CGPath(roundedRect: slitRect, cornerWidth: slitW / 2,
                       cornerHeight: slitW / 2, transform: nil))
    ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: -holeR, y: holeY - holeR,
                              width: 2 * holeR, height: 2 * holeR))
    ctx.fillPath()
    ctx.setBlendMode(.normal)

    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Subtle inner hairline highlight on the plate edge
    ctx.addPath(platePath)
    ctx.setStrokeColor(white(0.10))
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()

    ctx.restoreGState() // plate clip

    return ctx.makeImage()!
}

// MARK: - PNG output

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed for \(url.path)")
    }
    do { try data.write(to: url) } catch {
        fatalError("Could not write \(url.path): \(error)")
    }
}

// MARK: - Main

let fm = FileManager.default
try? fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)
let previewDir = (previewPath as NSString).deletingLastPathComponent
if !previewDir.isEmpty {
    try? fm.createDirectory(atPath: previewDir, withIntermediateDirectories: true)
}

let entries: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),      ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),      ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),   ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),   ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),   ("icon_512x512@2x.png", 1024),
]

var rendered: [Int: CGImage] = [:]
for entry in entries {
    let img: CGImage
    if let cached = rendered[entry.px] {
        img = cached
    } else {
        img = drawIcon(px: entry.px)
        rendered[entry.px] = img
    }
    writePNG(img, to: URL(fileURLWithPath: iconsetPath).appendingPathComponent(entry.name))
}
writePNG(rendered[1024]!, to: URL(fileURLWithPath: previewPath))

print("Wrote \(entries.count) entries to \(iconsetPath)")
print("Wrote preview to \(previewPath)")
