import AppKit
import Combine

/// UserDefaults-backed display preferences for the notch window.
///
/// AppState holds an instance; SwiftUI views that bind to this state must observe it
/// directly via @ObservedObject — SwiftUI does not propagate changes through a nested
/// ObservableObject automatically.
final class NotchDisplayPreferences: ObservableObject {
    enum Keys {
        static let notchDisplayTarget = "notchDisplayTarget"
        static let selectedDisplayId = "selectedDisplayId"
        static let showInFullScreenApps = "showInFullScreenApps"
        static let requestDisplayTarget = "requestDisplayTarget"
        static let legacyDisplayTarget = "displayTarget"
    }

    private let userDefaults: UserDefaults

    @Published var notchDisplayTarget: NotchDisplayTarget {
        didSet {
            if notchDisplayTarget == .specific {
                ensureSelectedDisplay()
            }
            userDefaults.set(notchDisplayTarget.rawValue, forKey: Keys.notchDisplayTarget)
        }
    }

    @Published var selectedDisplayId: UInt32 {
        didSet { userDefaults.set(Int(selectedDisplayId), forKey: Keys.selectedDisplayId) }
    }

    @Published var showInFullScreenApps: Bool {
        didSet { userDefaults.set(showInFullScreenApps, forKey: Keys.showInFullScreenApps) }
    }

    @Published var requestDisplayTarget: RequestDisplayTarget {
        didSet { userDefaults.set(requestDisplayTarget.rawValue, forKey: Keys.requestDisplayTarget) }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        if let rawTarget = userDefaults.string(forKey: Keys.legacyDisplayTarget),
           let target = NotchDisplayTarget(rawValue: rawTarget) {
            notchDisplayTarget = target
        } else if let rawTarget = userDefaults.string(forKey: Keys.notchDisplayTarget),
                  let target = NotchDisplayTarget(rawValue: rawTarget) {
            notchDisplayTarget = target
        } else {
            notchDisplayTarget = .automatic
        }

        selectedDisplayId = UInt32(userDefaults.integer(forKey: Keys.selectedDisplayId))

        if userDefaults.object(forKey: Keys.showInFullScreenApps) != nil {
            showInFullScreenApps = userDefaults.bool(forKey: Keys.showInFullScreenApps)
        } else {
            showInFullScreenApps = true
        }

        requestDisplayTarget = userDefaults.string(forKey: Keys.requestDisplayTarget)
            .flatMap(RequestDisplayTarget.init(rawValue:)) ?? .focused

        ensureSelectedDisplay()
    }

    func ensureSelectedDisplay() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.ensureSelectedDisplay() }
            return
        }
        guard !NSScreen.screens.isEmpty,
              !NSScreen.screens.contains(where: { $0.displayId == selectedDisplayId }) else {
            return
        }
        selectedDisplayId = NSScreen.main?.displayId ?? NSScreen.screens[0].displayId
    }
}
