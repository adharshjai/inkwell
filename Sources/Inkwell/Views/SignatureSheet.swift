import SwiftUI

/// Sheet for capturing a reusable signature with the trackpad/mouse.
struct SignatureSheet: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var strokes: [[CGPoint]] = []
    @State private var currentStroke: [CGPoint] = []
    @State private var name = "My signature"

    var body: some View {
        VStack(spacing: 16) {
            Text("Draw Your Signature")
                .font(.title3.weight(.semibold))

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .textBackgroundColor))
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.separator, lineWidth: 1)

                // Baseline guide
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(.quaternary)
                        .frame(height: 1)
                        .padding(.horizontal, 30)
                        .padding(.bottom, 44)
                }

                Canvas { context, _ in
                    var path = Path()
                    for stroke in strokes + [currentStroke] where stroke.count > 1 {
                        path.move(to: stroke[0])
                        for p in stroke.dropFirst() { path.addLine(to: p) }
                    }
                    context.stroke(
                        path,
                        with: .color(.primary),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                    )
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in currentStroke.append(value.location) }
                        .onEnded { _ in
                            if currentStroke.count > 1 { strokes.append(currentStroke) }
                            currentStroke = []
                        }
                )
            }
            .frame(width: 460, height: 200)

            HStack {
                TextField("Signature name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Spacer()
                Button("Clear") {
                    strokes = []
                    currentStroke = []
                }
                .disabled(strokes.isEmpty)
            }
            .frame(width: 460)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Signature") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(strokes.isEmpty)
            }
            .frame(width: 460)
        }
        .padding(24)
    }

    private func save() {
        // Normalize strokes into a [0,1] box around their bounds (y-down).
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for stroke in strokes {
            for p in stroke {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        let width = max(maxX - minX, 1)
        let height = max(maxY - minY, 1)
        let normalized = strokes.map { stroke in
            stroke.map { SigPoint(x: ($0.x - minX) / width, y: ($0.y - minY) / height) }
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        appState.signatures.add(Signature(
            name: trimmed.isEmpty ? "My signature" : trimmed,
            aspect: width / height,
            rawStrokes: normalized
        ))
        appState.flash("Signature saved — find it in the Sign panel")
    }
}
