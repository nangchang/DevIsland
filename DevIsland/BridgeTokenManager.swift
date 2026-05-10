import Foundation

/// Manages the shared secret token used to authenticate bridge → app IPC connections.
///
/// Token file: ~/Library/Application Support/DevIsland/bridge-token  (chmod 0600)
///
/// Grace mode: if the token file does not exist on the app side, any incoming token
/// value (including nil) is accepted. This eases the transition from raw-JSON bridges
/// that have no token support yet.
final class BridgeTokenManager {
    static let shared = BridgeTokenManager()

    private let tokenURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("DevIsland/bridge-token")
    }()

    private var cachedToken: String?
    private var tokenFileExists = false

    private init() {}

    // MARK: - Public API

    /// Creates the token file the first time the app runs. Idempotent — does nothing
    /// if the file already exists, so in-flight hooks are not disrupted on restart.
    func generateIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: tokenURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            print("BridgeTokenManager: failed to create directory – \(error)")
            return
        }

        if FileManager.default.fileExists(atPath: tokenURL.path) {
            reload()
            return
        }

        let token = UUID().uuidString
        do {
            try token.write(to: tokenURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
            cachedToken = token
            tokenFileExists = true
            print("BridgeTokenManager: token generated")
        } catch {
            print("BridgeTokenManager: failed to write token – \(error)")
        }
    }

    /// Returns true if the incoming token is acceptable.
    ///
    /// - If no token file exists on the app side (grace mode), always returns true.
    /// - If a token file exists, the incoming token must match exactly.
    func validate(_ incoming: String?) -> Bool {
        guard tokenFileExists, let expected = cachedToken else {
            // Grace mode: token file absent, accept anything.
            return true
        }
        return incoming == expected
    }

    // MARK: - Private

    private func reload() {
        guard let token = try? String(contentsOf: tokenURL, encoding: .utf8) else { return }
        cachedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenFileExists = true
    }
}
