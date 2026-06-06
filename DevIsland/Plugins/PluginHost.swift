import Combine
import Foundation

@MainActor
final class PluginHost: ObservableObject {
    @Published private(set) var contributions: [PluginUISlot: [PluginUIContribution]] = [:]

    nonisolated let isEnabled: Bool

    nonisolated init(enablePlugins: Bool = true) {
        self.isEnabled = enablePlugins
    }

    func enqueue(_ event: PluginEvent) {
        guard isEnabled else { return }
    }
}
