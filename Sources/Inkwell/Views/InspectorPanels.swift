import PDFKit
import SwiftUI

// MARK: - Inspector root

struct InspectorView: View {
    let appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: tabBinding) {
                ForEach(InspectorTab.allCases) { tab in
                    Label(tab.label, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            ScrollView {
                switch appState.inspectorTab {
                case .math: MathPanel(appState: appState)
                case .stamps: StampPanel(appState: appState)
                case .sign: SignPanel(appState: appState)
                }
            }
        }
    }

    private var tabBinding: Binding<InspectorTab> {
        Binding(get: { appState.inspectorTab }, set: { appState.inspectorTab = $0 })
    }
}

// MARK: - Math panel

struct MathPanel: View {
    let appState: AppState
    @State private var input = "omega0 = 1/sqrt(LC)"
    @State private var typesetMode = true
    @State private var typesetSize: CGFloat = 18

    /// Curated for Calc 3, calc-based physics, and general chemistry.
    private static let typesetExamples: [String] = [
        "omega0 = 1/sqrt(LC)",
        "x = (-b +- sqrt(b^2 - 4ac))/2a",
        "int_0^inf e^-x^2 dx = sqrt(pi)/2",
        "lim_{h->0} (f(x+h) - f(x))/h",
        "F = m dv/dt",
        "div E = rho/epsilon0",
        "curl vec F = 0",
        "vec F = q vec E + q vec v cross vec B",
        "K_a = [H^+][A^-]/[HA]",
        "N2 + 3H2 <=> 2NH3",
        "Delta G = Delta H - T Delta S",
        "6.022e23",
        "PV = nRT",
        "theta ~= sin(theta)",
    ]

    /// Letters with arrows/hats — inserted as `vec u` syntax in Typeset mode
    /// (drawn accents), or as combining-mark Unicode in Plain mode.
    private static let vectorSymbols: [(display: String, casual: String)] = [
        ("u⃗", "vec u"), ("v⃗", "vec v"), ("w⃗", "vec w"), ("a⃗", "vec a"), ("r⃗", "vec r"),
        ("F⃗", "vec F"), ("E⃗", "vec E"), ("B⃗", "vec B"), ("T⃗", "vec T"), ("p⃗", "vec p"),
        ("î", "ihat"), ("ĵ", "jhat"), ("k̂", "khat"), ("r̂", "rhat"), ("n̂", "nhat"),
    ]

    private static let quickSymbols: [(String, [String])] = [
        ("Greek", ["α", "β", "γ", "δ", "ε", "θ", "λ", "μ", "π", "ρ", "σ", "τ", "φ", "ω", "Δ", "Γ", "Θ", "Λ", "Σ", "Φ", "Ψ", "Ω"]),
        ("Operators", ["±", "×", "⋅", "÷", "√", "∞", "∂", "∇", "∫", "∮", "∑", "∏", "≈", "≠", "≤", "≥", "∝", "≡"]),
        ("Arrows & Logic", ["→", "←", "↔", "⇒", "⇔", "⇌", "↑", "↓", "∴", "∵", "∀", "∃", "∈", "⊥", "∥", "∠"]),
        ("Units & Misc", ["°", "Ω", "µ", "Å", "ℏ", "ℓ", "′", "″", "•", "½", "⅓", "¼"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Type it casually — sqrt(), df/dx, omega, H2O, <=> — and place it beautifully")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Mode", selection: $typesetMode) {
                Text("Typeset").tag(true)
                Text("Plain text").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("e.g. w0 = 1/sqrt(LC)", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .font(.system(.body, design: .monospaced))
                .onSubmit { placeCurrent() }

            GroupBox {
                if typesetMode {
                    VStack(alignment: .leading, spacing: 8) {
                        TypesetPreview(source: input)
                            .frame(maxWidth: .infinity, minHeight: 56)
                        if let latex = TypesetMath.layout(input, fontSize: 12)?.latex, latex != input {
                            Text("LaTeX: \(latex)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                    .padding(4)
                } else {
                    Text(rendered.isEmpty ? " " : rendered)
                        .font(.system(size: 16))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .textSelection(.enabled)
                }
            } label: {
                Text("Preview").font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Place on Page", systemImage: "plus.viewfinder") {
                    placeCurrent()
                }
                .buttonStyle(.borderedProminent)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()

                Menu("Examples") {
                    if typesetMode {
                        ForEach(Self.typesetExamples, id: \.self) { example in
                            Button(example) { input = example }
                        }
                    } else {
                        ForEach(MathText.examples.prefix(12), id: \.input) { example in
                            Button(example.output) { input = example.input }
                        }
                    }
                }
                .frame(width: 110)
            }

            if typesetMode {
                HStack {
                    Text("Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $typesetSize, in: 12...36, step: 1)
                    Text("\(Int(typesetSize)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                Text("Typeset places textbook-style vector math (movable, erasable ink). Plain text places editable text.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Vectors")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 4)], spacing: 4) {
                    ForEach(Self.vectorSymbols, id: \.display) { item in
                        Button {
                            if typesetMode {
                                let needsSpace = !(input.isEmpty || input.hasSuffix(" "))
                                input += (needsSpace ? " " : "") + item.casual + " "
                            } else {
                                input += item.display
                            }
                        } label: {
                            Text(item.display)
                                .font(.system(size: 15))
                                .frame(width: 30, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .help(typesetMode ? item.casual : String(item.display))
                    }
                }
            }

            ForEach(Self.quickSymbols, id: \.0) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 4)], spacing: 4) {
                        ForEach(section.1, id: \.self) { symbol in
                            Button {
                                input += symbol
                            } label: {
                                Text(symbol)
                                    .font(.system(size: 15))
                                    .frame(width: 30, height: 26)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            Text("Tip: shift-click while placing to stamp multiple copies.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
    }

    private var rendered: String {
        MathText.render(input).trimmingCharacters(in: .whitespaces)
    }

    private func placeCurrent() {
        if typesetMode {
            guard TypesetMath.layout(input, fontSize: typesetSize) != nil else {
                appState.flash("Nothing to typeset yet")
                return
            }
            appState.pendingPlacement = .typesetMath(input, typesetSize)
        } else {
            guard !rendered.isEmpty else { return }
            appState.pendingPlacement = .mathText(rendered)
        }
    }
}

/// Live preview of the typeset layout, drawn with filled glyph outlines
/// (the placed version uses the same layout converted to vector ink).
struct TypesetPreview: View {
    let source: String

    var body: some View {
        Canvas { context, size in
            guard let (output, _) = TypesetMath.layout(source, fontSize: 19), !output.isEmpty else {
                context.draw(
                    Text("…").font(.system(size: 14)).foregroundColor(.secondary),
                    at: CGPoint(x: size.width / 2, y: size.height / 2)
                )
                return
            }
            // Fit if wider than the panel.
            let scale = min(1, (size.width - 12) / max(output.width, 1))
            let x = (size.width - output.width * scale) / 2
            // The layout is y-up around its baseline; flip into Canvas space.
            let baselineY = (size.height + (output.ascent - output.descent) * scale) / 2
            var transform = CGAffineTransform(translationX: x, y: baselineY)
                .scaledBy(x: scale, y: -scale)
            for glyph in output.glyphs {
                if let moved = glyph.copy(using: &transform) {
                    context.fill(Path(moved), with: .color(.primary))
                }
            }
            for rule in output.rules {
                context.fill(Path(rule.applying(transform)), with: .color(.primary))
            }
        }
    }
}

// MARK: - Stamp panel

struct StampPanel: View {
    let appState: AppState
    @State private var category: StampCategory = .circuit

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Category", selection: $category) {
                ForEach(StampCategory.allCases) { cat in
                    Text(cat.rawValue).tag(cat)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 8)], spacing: 8) {
                ForEach(StampLibrary.stamps(in: category)) { stamp in
                    Button {
                        appState.pendingPlacement = .stamp(stamp)
                    } label: {
                        VStack(spacing: 4) {
                            StampPreview(stamp: stamp)
                                .frame(width: 64, height: 40)
                            Text(stamp.name)
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .help("Place \(stamp.name) — shift-click on the page for multiples")
                }
            }

            Text("Stamps are drawn in your current ink color. Click a stamp, then click the page.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
    }
}

/// Renders a stamp's vector path (authored y-down, which matches SwiftUI).
struct StampPreview: View {
    let stamp: Stamp

    var body: some View {
        GeometryReader { proxy in
            let fitted = fittedRect(in: proxy.size)
            Path(stamp.build(fitted))
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let aspect = max(stamp.aspect, 0.05)
        var w = size.width
        var h = w / aspect
        if h > size.height {
            h = size.height
            w = h * aspect
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

// MARK: - Sign panel

struct SignPanel: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appState.signatures.signatures.isEmpty {
                ContentUnavailableView {
                    Label("No signatures yet", systemImage: "signature")
                } description: {
                    Text("Draw a signature once, reuse it on every assignment.")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
            } else {
                ForEach(appState.signatures.signatures) { signature in
                    HStack {
                        Button {
                            appState.pendingPlacement = .signature(signature)
                        } label: {
                            HStack(spacing: 10) {
                                SignatureStrokesView(signature: signature)
                                    .frame(width: 110, height: 40)
                                Text(signature.name)
                                    .font(.callout)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            appState.signatures.remove(signature)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this signature")
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Button("New Signature…", systemImage: "plus") {
                appState.showSignatureSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
    }
}

/// Draws saved signature strokes (normalized y-down coordinates).
struct SignatureStrokesView: View {
    let signature: Signature

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for stroke in signature.strokes where stroke.count > 1 {
                path.move(to: CGPoint(x: stroke[0].x * size.width, y: stroke[0].y * size.height))
                for p in stroke.dropFirst() {
                    path.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height))
                }
            }
            context.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}
