//
//  StampLibrary.swift
//  Inkwell
//
//  A library of stroke-only vector stamps for annotating STEM homework:
//  circuit schematic symbols, chemistry notation, physics diagram elements,
//  and math/geometry helpers. Paths are built in y-down screen coordinates
//  (origin top-left); the app flips them for PDF space.
//

import CoreGraphics
import Foundation

// MARK: - Category

enum StampCategory: String, CaseIterable, Identifiable {
    case circuit = "Circuit"
    case chem = "Chemistry"
    case physics = "Physics"
    case math = "Math & Geometry"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .circuit: return "bolt"
        case .chem: return "atom"
        case .physics: return "scalemass"
        case .math: return "angle"
        }
    }
}

// MARK: - Stamp

struct Stamp: Identifiable {
    let id: String
    let name: String
    let category: StampCategory

    /// Natural width/height ratio of the drawing.
    let aspect: CGFloat

    /// Builds the stamp's path fitted inside the given rect (y-down space).
    let build: (CGRect) -> CGPath
}

// MARK: - Library

enum StampLibrary {

    static let all: [Stamp] = circuitStamps + chemistryStamps + physicsStamps + mathStamps

    /// Stamps of one category, in definition order.
    static func stamps(in category: StampCategory) -> [Stamp] {
        all.filter { $0.category == category }
    }

    static func stamp(id: String) -> Stamp? { stampsByID[id] }

    private static let stampsByID: [String: Stamp] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    private static func make(
        _ id: String,
        _ name: String,
        _ category: StampCategory,
        aspect: CGFloat,
        draw: @escaping (Sketch) -> Void
    ) -> Stamp {
        Stamp(id: id, name: name, category: category, aspect: aspect) { rect in
            let sketch = Sketch(in: rect, aspect: aspect)
            draw(sketch)
            return sketch.path
        }
    }

    // MARK: Circuit

    private static let circuitStamps: [Stamp] = [

        make("resistor", "Resistor", .circuit, aspect: 3.0) { s in
            s.move(0, 0.5)
            s.line(0.25, 0.5)
            for k in 0..<6 {
                let x = 0.25 + 0.5 * (CGFloat(k) + 0.5) / 6
                s.line(x, k.isMultiple(of: 2) ? 0.22 : 0.78)
            }
            s.line(0.75, 0.5)
            s.line(1, 0.5)
        },

        make("capacitor", "Capacitor", .circuit, aspect: 2.0) { s in
            s.segment(0, 0.5, 0.44, 0.5)
            s.segment(0.44, 0.14, 0.44, 0.86)
            s.segment(0.56, 0.14, 0.56, 0.86)
            s.segment(0.56, 0.5, 1, 0.5)
        },

        make("inductor", "Inductor", .circuit, aspect: 3.0) { s in
            s.move(0, 0.6)
            s.line(0.22, 0.6)
            for k in 0..<4 {
                let cx = 0.29 + 0.14 * CGFloat(k)
                s.arc(cx, 0.6, radius: 0.07 * s.w, from: .pi, to: 2 * .pi, screenClockwise: true)
            }
            s.line(1, 0.6)
        },

        make("battery", "Battery", .circuit, aspect: 2.0) { s in
            s.segment(0, 0.5, 0.38, 0.5)
            s.segment(0.38, 0.12, 0.38, 0.88)   // long plate (+)
            s.segment(0.46, 0.34, 0.46, 0.66)   // short plate (−)
            s.segment(0.54, 0.12, 0.54, 0.88)
            s.segment(0.62, 0.34, 0.62, 0.66)
            s.segment(0.62, 0.5, 1, 0.5)
        },

        make("ac-source", "AC Source", .circuit, aspect: 2.0) { s in
            let r = 0.42 * s.h
            let rx = r / s.w
            s.circle(0.5, 0.5, radius: r)
            s.segment(0, 0.5, 0.5 - rx, 0.5)
            s.segment(0.5 + rx, 0.5, 1, 0.5)
            s.move(0.5 - 0.62 * rx, 0.5)        // one sine cycle
            s.quad(to: 0.5, 0.5, control: 0.5 - 0.31 * rx, 0.14)
            s.quad(to: 0.5 + 0.62 * rx, 0.5, control: 0.5 + 0.31 * rx, 0.86)
        },

        make("voltage-source", "Voltage Source", .circuit, aspect: 0.5) { s in
            let r = 0.44 * s.w
            let ry = r / s.h
            s.circle(0.5, 0.5, radius: r)
            s.segment(0.5, 0, 0.5, 0.5 - ry)
            s.segment(0.5, 0.5 + ry, 0.5, 1)
            let ax = 0.30 * r / s.w
            let ay = 0.30 * r / s.h
            let yPlus = 0.5 - 0.5 * ry
            let yMinus = 0.5 + 0.5 * ry
            s.segment(0.5 - ax, yPlus, 0.5 + ax, yPlus)      // +
            s.segment(0.5, yPlus - ay, 0.5, yPlus + ay)
            s.segment(0.5 - ax, yMinus, 0.5 + ax, yMinus)    // −
        },

        make("current-source", "Current Source", .circuit, aspect: 0.5) { s in
            let r = 0.44 * s.w
            let ry = r / s.h
            s.circle(0.5, 0.5, radius: r)
            s.segment(0.5, 0, 0.5, 0.5 - ry)
            s.segment(0.5, 0.5 + ry, 0.5, 1)
            s.segment(0.5, 0.5 + 0.55 * ry, 0.5, 0.5 - 0.55 * ry)
            s.arrowhead(0.5, 0.5 - 0.55 * ry, angle: -.pi / 2, length: 0.45 * r)
        },

        make("ground", "Ground", .circuit, aspect: 1.0) { s in
            s.segment(0.5, 0, 0.5, 0.45)
            s.segment(0.18, 0.45, 0.82, 0.45)
            s.segment(0.30, 0.62, 0.70, 0.62)
            s.segment(0.42, 0.79, 0.58, 0.79)
        },

        make("diode", "Diode", .circuit, aspect: 2.0) { s in
            s.segment(0, 0.5, 0.36, 0.5)
            s.polyline([(0.36, 0.16), (0.36, 0.84), (0.64, 0.5)], closed: true)
            s.segment(0.64, 0.16, 0.64, 0.84)   // cathode bar
            s.segment(0.64, 0.5, 1, 0.5)
        },

        make("npn", "NPN Transistor", .circuit, aspect: 1.0) { s in
            s.segment(0, 0.5, 0.40, 0.5)                            // base lead
            s.segment(0.40, 0.28, 0.40, 0.72)                       // base bar
            s.polyline([(0.40, 0.42), (0.70, 0.20), (0.70, 0)])     // collector
            s.polyline([(0.40, 0.58), (0.70, 0.80), (0.70, 1)])     // emitter
            let a = s.angle(from: (0.40, 0.58), to: (0.70, 0.80))
            s.arrowhead(0.66, 0.77, angle: a, length: 0.11 * s.h)   // arrow out = NPN
        },

        make("mosfet-n", "NMOS Transistor", .circuit, aspect: 1.0) { s in
            s.segment(0, 0.5, 0.38, 0.5)                            // gate lead
            s.segment(0.38, 0.30, 0.38, 0.70)                       // gate bar
            s.segment(0.50, 0.22, 0.50, 0.38)                       // drain stub
            s.segment(0.50, 0.42, 0.50, 0.58)                       // body stub
            s.segment(0.50, 0.62, 0.50, 0.78)                       // source stub
            s.polyline([(0.50, 0.30), (0.74, 0.30), (0.74, 0)])     // drain
            s.polyline([(0.50, 0.70), (0.74, 0.70), (0.74, 1)])     // source
            s.polyline([(0.50, 0.50), (0.74, 0.50), (0.74, 0.70)])  // body tied to source
            s.arrowhead(0.52, 0.50, angle: .pi, length: 0.10 * s.h) // arrow in = N-channel
        },

        make("opamp", "Op-Amp", .circuit, aspect: 1.2) { s in
            s.polyline([(0.24, 0.10), (0.24, 0.90), (0.86, 0.5)], closed: true)
            s.segment(0, 0.28, 0.24, 0.28)                          // inverting input
            s.segment(0, 0.72, 0.24, 0.72)                          // non-inverting input
            s.segment(0.86, 0.5, 1, 0.5)                            // output
            let ax = 0.06 * s.h / s.w
            s.segment(0.335 - ax, 0.28, 0.335 + ax, 0.28)           // −
            s.segment(0.335 - ax, 0.72, 0.335 + ax, 0.72)           // +
            s.segment(0.335, 0.66, 0.335, 0.78)
        },

        make("switch-spst", "Switch (SPST)", .circuit, aspect: 2.5) { s in
            let dotR = 0.05 * s.h
            s.segment(0, 0.72, 0.28, 0.72)
            s.circle(0.30, 0.72, radius: dotR)                      // pivot
            s.segment(0.32, 0.66, 0.66, 0.24)                       // blade, ~30° up
            s.circle(0.70, 0.72, radius: dotR)                      // contact
            s.segment(0.72, 0.72, 1, 0.72)
        },
    ]

    // MARK: Chemistry

    private static let chemistryStamps: [Stamp] = [

        make("rxn-arrow", "Reaction Arrow", .chem, aspect: 4.0) { s in
            s.segment(0, 0.5, 1, 0.5)
            s.arrowhead(1, 0.5, angle: 0, length: 0.55 * s.h)
        },

        make("equilibrium", "Equilibrium", .chem, aspect: 3.0) { s in
            s.segment(0.04, 0.36, 0.96, 0.36)
            s.harpoon(0.96, 0.36, angle: 0, length: 0.5 * s.h)      // barb up
            s.segment(0.96, 0.64, 0.04, 0.64)
            s.harpoon(0.04, 0.64, angle: .pi, length: 0.5 * s.h)    // barb down
        },

        make("benzene", "Benzene Ring", .chem, aspect: 1.0) { s in
            s.polygon(0.5, 0.5, radius: 0.46 * s.h, sides: 6, startAngle: -.pi / 2)
            s.circle(0.5, 0.5, radius: 0.27 * s.h)
        },

        make("hexagon", "Cyclohexane", .chem, aspect: 1.0) { s in
            s.polygon(0.5, 0.5, radius: 0.46 * s.h, sides: 6, startAngle: -.pi / 2)
        },

        make("heat-arrow", "Heat Arrow", .chem, aspect: 2.5) { s in
            s.segment(0, 0.70, 1, 0.70)
            s.arrowhead(1, 0.70, angle: 0, length: 0.45 * s.h)
            let hw = 0.19 * s.h / s.w                               // Δ above the shaft
            s.polyline([(0.5, 0.15), (0.5 - hw, 0.47), (0.5 + hw, 0.47)], closed: true)
        },

        make("curved-arrow", "Curved Arrow", .chem, aspect: 1.0) { s in
            let r = 0.42 * s.h
            s.arc(0.5, 0.6, radius: r, from: -.pi, to: 0, screenClockwise: true)
            s.arrowhead(0.5 + r / s.w, 0.6, angle: .pi / 2, length: 0.13 * s.h)
        },
    ]

    // MARK: Physics

    private static let physicsStamps: [Stamp] = [

        make("vector-arrow", "Vector", .physics, aspect: 3.0) { s in
            let back = 1 - 0.85 * s.h / s.w
            s.segment(0, 0.5, back, 0.5)
            s.polyline([(1, 0.5), (back, 0.14), (back, 0.86)], closed: true)
        },

        make("spring", "Spring", .physics, aspect: 3.0) { s in
            s.move(0, 0.5)
            s.line(0.16, 0.5)
            for k in 0..<8 {
                let x = 0.16 + 0.68 * (CGFloat(k) + 0.5) / 8
                s.line(x, k.isMultiple(of: 2) ? 0.15 : 0.85)
            }
            s.line(0.84, 0.5)
            s.line(1, 0.5)
        },

        make("pulley", "Pulley", .physics, aspect: 0.8) { s in
            let wheelR = 0.32 * s.w
            let ropeR = 0.39 * s.w
            let rx = ropeR / s.w
            s.segment(0.28, 0.05, 0.72, 0.05)                       // ceiling
            s.segment(0.5, 0.05, 0.5, 0.42 - wheelR / s.h)          // mount
            s.circle(0.5, 0.42, radius: wheelR)
            s.circle(0.5, 0.42, radius: 0.045 * s.w)                // axle
            s.move(0.5 - rx, 0.98)                                  // rope: down, over, down
            s.line(0.5 - rx, 0.42)
            s.arc(0.5, 0.42, radius: ropeR, from: -.pi, to: 0, screenClockwise: true)
            s.line(0.5 + rx, 0.98)
        },

        make("incline", "Inclined Plane", .physics, aspect: 1.6) { s in
            s.polyline([(0.03, 0.94), (0.97, 0.94), (0.97, 0.14)], closed: true)
            let a = s.angle(from: (0.03, 0.94), to: (0.97, 0.14))
            s.arc(0.03, 0.94, radius: 0.22 * s.w, from: 0, to: a, screenClockwise: false)
        },

        make("axes-2d", "Axes", .physics, aspect: 1.0) { s in
            s.segment(0.10, 0.90, 0.97, 0.90)
            s.arrowhead(0.97, 0.90, angle: 0, length: 0.08 * s.h)
            s.segment(0.10, 0.90, 0.10, 0.03)
            s.arrowhead(0.10, 0.03, angle: -.pi / 2, length: 0.08 * s.h)
        },

        make("angle-arc", "Angle", .physics, aspect: 1.3) { s in
            s.segment(0.06, 0.88, 0.97, 0.88)
            s.segment(0.06, 0.88, 0.75, 0.10)
            let a = s.angle(from: (0.06, 0.88), to: (0.75, 0.10))
            s.arc(0.06, 0.88, radius: 0.30 * s.w, from: 0, to: a, screenClockwise: false)
        },
    ]

    // MARK: Math & Geometry

    private static let mathStamps: [Stamp] = [

        make("axes-grid", "Axes with Ticks", .math, aspect: 1.0) { s in
            let headLen = 0.07 * s.h
            s.segment(0.03, 0.5, 0.97, 0.5)
            s.arrowhead(0.97, 0.5, angle: 0, length: headLen)
            s.arrowhead(0.03, 0.5, angle: .pi, length: headLen)
            s.segment(0.5, 0.03, 0.5, 0.97)
            s.arrowhead(0.5, 0.03, angle: -.pi / 2, length: headLen)
            s.arrowhead(0.5, 0.97, angle: .pi / 2, length: headLen)
            for k in 1...7 where k != 4 {                           // ticks every 1/8
                let t = CGFloat(k) / 8
                s.segment(t, 0.478, t, 0.522)
                s.segment(0.478, t, 0.522, t)
            }
        },

        make("number-line", "Number Line", .math, aspect: 5.0) { s in
            s.segment(0.02, 0.5, 0.98, 0.5)
            s.arrowhead(0.98, 0.5, angle: 0, length: 0.5 * s.h)
            s.arrowhead(0.02, 0.5, angle: .pi, length: 0.5 * s.h)
            for k in 1...9 {                                        // ticks every 1/10
                let t = CGFloat(k) / 10
                s.segment(t, 0.3, t, 0.7)
            }
        },

        make("unit-circle", "Unit Circle", .math, aspect: 1.0) { s in
            s.circle(0.5, 0.5, radius: 0.38 * s.h)
            s.segment(0.02, 0.5, 0.98, 0.5)
            s.segment(0.5, 0.02, 0.5, 0.98)
        },

        make("right-angle", "Right Angle", .math, aspect: 1.0) { s in
            s.polyline([(0.20, 0.12), (0.20, 0.80), (0.88, 0.80)])
        },

        make("check", "Checkmark", .math, aspect: 1.2) { s in
            s.move(0.10, 0.55)
            s.quad(to: 0.36, 0.86, control: 0.24, 0.62)
            s.quad(to: 0.92, 0.10, control: 0.58, 0.46)
        },

        make("cross-x", "Cross", .math, aspect: 1.0) { s in
            s.segment(0.14, 0.14, 0.86, 0.86)
            s.segment(0.86, 0.14, 0.14, 0.86)
        },
    ]
}

// MARK: - Sketch

/// A small path builder working in unit coordinates (0...1 on each axis,
/// y growing downward) mapped into a sub-rect of the target rect that is
/// aspect-fitted to the stamp's natural proportions. Positions are unit
/// coordinates; lengths (radii, arrowhead sizes) are absolute — derive
/// them from `w` and `h`.
private struct Sketch {
    let path = CGMutablePath()
    private let frame: CGRect

    init(in rect: CGRect, aspect: CGFloat) {
        var r = rect.standardized
        if !(r.width > 0) { r.size.width = 1 }
        if !(r.height > 0) { r.size.height = 1 }
        let a = (aspect.isFinite && aspect > 0) ? aspect : 1
        if r.width / r.height > a {
            let w = r.height * a
            frame = CGRect(x: r.midX - w / 2, y: r.minY, width: w, height: r.height)
        } else {
            let h = r.width / a
            frame = CGRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h)
        }
    }

    var w: CGFloat { frame.width }
    var h: CGFloat { frame.height }

    /// Absolute point for unit coordinates.
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: frame.minX + x * frame.width, y: frame.minY + y * frame.height)
    }

    func move(_ x: CGFloat, _ y: CGFloat) { path.move(to: p(x, y)) }
    func line(_ x: CGFloat, _ y: CGFloat) { path.addLine(to: p(x, y)) }

    func segment(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
        move(x0, y0)
        line(x1, y1)
    }

    func polyline(_ points: [(CGFloat, CGFloat)], closed: Bool = false) {
        guard let first = points.first else { return }
        move(first.0, first.1)
        for pt in points.dropFirst() { line(pt.0, pt.1) }
        if closed { path.closeSubpath() }
    }

    func quad(to x: CGFloat, _ y: CGFloat, control cx: CGFloat, _ cy: CGFloat) {
        path.addQuadCurve(to: p(x, y), control: p(cx, cy))
    }

    /// Circle centered at a unit point, with absolute radius.
    func circle(_ cx: CGFloat, _ cy: CGFloat, radius: CGFloat) {
        let c = p(cx, cy)
        path.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius,
                                   width: 2 * radius, height: 2 * radius))
    }

    /// Circular arc around a unit-coordinate center with absolute radius.
    /// Angles are radians in y-down space (0 = right, π/2 = down, -π/2 = up);
    /// `screenClockwise` is the sweep direction as seen on screen.
    func arc(_ cx: CGFloat, _ cy: CGFloat, radius: CGFloat,
             from start: CGFloat, to end: CGFloat, screenClockwise: Bool) {
        // CGPath's `clockwise` flag refers to y-up math space, so it is
        // inverted relative to what the eye sees in y-down coordinates.
        path.addArc(center: p(cx, cy), radius: radius,
                    startAngle: start, endAngle: end, clockwise: !screenClockwise)
    }

    /// Regular polygon (closed) around a unit-coordinate center.
    func polygon(_ cx: CGFloat, _ cy: CGFloat, radius: CGFloat, sides: Int, startAngle: CGFloat) {
        let c = p(cx, cy)
        for i in 0..<sides {
            let a = startAngle + 2 * .pi * CGFloat(i) / CGFloat(sides)
            let vertex = CGPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a))
            if i == 0 { path.move(to: vertex) } else { path.addLine(to: vertex) }
        }
        path.closeSubpath()
    }

    /// Open-V arrowhead. `angle` is the direction of travel toward the tip;
    /// `length` is the absolute barb length.
    func arrowhead(_ x: CGFloat, _ y: CGFloat, angle: CGFloat, length: CGFloat,
                   spread: CGFloat = .pi / 7) {
        let tip = p(x, y)
        path.move(to: barb(tip, angle: angle + spread, length: length))
        path.addLine(to: tip)
        path.addLine(to: barb(tip, angle: angle - spread, length: length))
    }

    /// Single-barb (harpoon) head, barb on the left of the direction of travel.
    func harpoon(_ x: CGFloat, _ y: CGFloat, angle: CGFloat, length: CGFloat,
                 spread: CGFloat = .pi / 6) {
        let tip = p(x, y)
        path.move(to: tip)
        path.addLine(to: barb(tip, angle: angle + spread, length: length))
    }

    /// Angle of the absolute segment between two unit points, in y-down radians.
    func angle(from a: (CGFloat, CGFloat), to b: (CGFloat, CGFloat)) -> CGFloat {
        let p0 = p(a.0, a.1)
        let p1 = p(b.0, b.1)
        return atan2(p1.y - p0.y, p1.x - p0.x)
    }

    private func barb(_ tip: CGPoint, angle: CGFloat, length: CGFloat) -> CGPoint {
        CGPoint(x: tip.x - length * cos(angle), y: tip.y - length * sin(angle))
    }
}
