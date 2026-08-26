import AppKit
import SwiftUI

// MARK: - Geometry helpers

extension CGPoint {
    static func + (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x + r.x, y: l.y + r.y) }
    static func - (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x - r.x, y: l.y - r.y) }

    func distance(to p: CGPoint) -> CGFloat {
        let dx = x - p.x, dy = y - p.y
        return (dx * dx + dy * dy).squareRoot()
    }

    func midpoint(_ p: CGPoint) -> CGPoint { CGPoint(x: (x + p.x) / 2, y: (y + p.y) / 2) }
}

extension CGRect {
    /// Rect spanned by two corner points, normalized.
    init(corner a: CGPoint, corner b: CGPoint) {
        self.init(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

// MARK: - Bezier paths

extension NSBezierPath {
    /// A smoothed freehand path through the given points (midpoint quadratic smoothing).
    static func smoothPath(through points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else {
            path.line(to: first) // dot
            return path
        }
        if points.count == 2 {
            path.line(to: points[1])
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = points[i].midpoint(points[i + 1])
            path.curve(to: mid, controlPoint1: points[i], controlPoint2: points[i])
        }
        path.line(to: points[points.count - 1])
        return path
    }

    /// Drop points closer than `epsilon` to their predecessor (jitter reduction).
    static func decimate(_ points: [CGPoint], epsilon: CGFloat = 1.2) -> [CGPoint] {
        guard var last = points.first else { return [] }
        var out = [last]
        for p in points.dropFirst() where p.distance(to: last) >= epsilon {
            out.append(p)
            last = p
        }
        if let tail = points.last, out.last != tail { out.append(tail) }
        return out
    }
}

// MARK: - Colors

extension NSColor {
    /// Ink swatches offered in the tool palette.
    static let inkSwatches: [(name: String, color: NSColor)] = [
        ("Black", NSColor(calibratedWhite: 0.08, alpha: 1)),
        ("Blue", NSColor(calibratedRed: 0.10, green: 0.32, blue: 0.85, alpha: 1)),
        ("Red", NSColor(calibratedRed: 0.85, green: 0.15, blue: 0.15, alpha: 1)),
        ("Green", NSColor(calibratedRed: 0.05, green: 0.55, blue: 0.25, alpha: 1)),
        ("Purple", NSColor(calibratedRed: 0.48, green: 0.25, blue: 0.85, alpha: 1)),
        ("Orange", NSColor(calibratedRed: 0.95, green: 0.52, blue: 0.08, alpha: 1)),
    ]

    static let highlightSwatches: [(name: String, color: NSColor)] = [
        ("Yellow", NSColor(calibratedRed: 1.00, green: 0.86, blue: 0.15, alpha: 1)),
        ("Green", NSColor(calibratedRed: 0.45, green: 0.90, blue: 0.40, alpha: 1)),
        ("Pink", NSColor(calibratedRed: 1.00, green: 0.45, blue: 0.70, alpha: 1)),
        ("Cyan", NSColor(calibratedRed: 0.35, green: 0.80, blue: 0.95, alpha: 1)),
    ]
}

// MARK: - Text measurement

enum TextMeasure {
    static func attributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    /// Size needed to draw `text` at `font`, optionally wrapped to `width`.
    static func size(of text: String, font: NSFont, maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        let attr = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font])
        let rect = attr.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: ceil(rect.width) + 4, height: ceil(rect.height) + 4)
    }
}
