import Foundation
import Observation

struct SigPoint: Codable, Hashable {
    var x: CGFloat
    var y: CGFloat
}

extension CGPoint {
    init(_ p: SigPoint) { self.init(x: p.x, y: p.y) }
}

/// A saved signature: strokes normalized to a [0,1] x [0,1] y-down box.
struct Signature: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var aspect: CGFloat            // width / height of the original drawing box
    var rawStrokes: [[SigPoint]]

    var strokes: [[CGPoint]] { rawStrokes.map { $0.map(CGPoint.init) } }
}

/// Persists signatures as JSON in Application Support.
@MainActor
@Observable
final class SignatureStore {
    private(set) var signatures: [Signature] = []

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Inkwell", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("signatures.json")
    }

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Signature].self, from: data) else { return }
        signatures = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(signatures) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func add(_ signature: Signature) {
        signatures.append(signature)
        save()
    }

    func remove(_ signature: Signature) {
        signatures.removeAll { $0.id == signature.id }
        save()
    }
}
