import Foundation

/// Gemini-specific global state extracted from AppState.
///
/// AppState holds an instance; SwiftUI views that bind to this state must observe it
/// directly via @ObservedObject — SwiftUI does not propagate changes through a nested
/// ObservableObject automatically.
final class GeminiSessionState: ObservableObject {
    private static let defaultsKey = "emulateGeminiInteractiveMode"
    private let userDefaults: UserDefaults

    @Published var emulateInteractiveMode: Bool {
        didSet { userDefaults.set(emulateInteractiveMode, forKey: Self.defaultsKey) }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        emulateInteractiveMode = userDefaults.bool(forKey: Self.defaultsKey)
    }
}
