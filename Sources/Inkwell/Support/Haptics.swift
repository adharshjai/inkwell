import AppKit

/// Force Touch trackpad feedback for drawing moments. Three levels:
/// `tick` for a stroke landing or an eraser bite, `snap` for recognition
/// and alignment (a sketch becoming a clean shape, a wire completing),
/// `thunk` for bigger commits (fill, placement, box-selection).
@MainActor
enum Haptics {
    private static let key = "inkwell.haptics"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func tick() {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
    }

    static func snap() {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    static func thunk() {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    }
}
