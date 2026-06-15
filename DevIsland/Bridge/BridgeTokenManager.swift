import Foundation

/// Manages the shared secret token used to authenticate bridge → app IPC connections.
///
/// Token file: ~/Library/Application Support/DevIsland/bridge-token  (chmod 0600)
///
/// Grace mode: if the token file does not exist on the app side, any incoming token
/// value (including nil) is accepted. This eases the transition from raw-JSON bridges
/// that have no token support yet.
///
/// `@unchecked Sendable`: mutable state is protected by `lock`.
final class BridgeTokenManager: @unchecked Sendable {
    static let shared = BridgeTokenManager()

    private let tokenURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("DevIsland/bridge-token")
    }()

    private let lock = NSLock()
    private var _cachedToken: String?
    private var _tokenFileExists = false

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
            lock.lock()
            reloadLocked()
            lock.unlock()
            return
        }

        let token = UUID().uuidString
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        guard FileManager.default.createFile(atPath: tokenURL.path, contents: Data(token.utf8), attributes: attributes) else {
            print("BridgeTokenManager: failed to write token")
            return
        }
        lock.lock()
        _cachedToken = token
        _tokenFileExists = true
        lock.unlock()
        print("BridgeTokenManager: token generated")
    }

    /// Returns true if the incoming token is acceptable.
    ///
    /// - If no token file exists on the app side (grace mode), always returns true.
    /// - If a token file exists, the incoming token must match exactly.
    func validate(_ incoming: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // If the cache hasn't been populated yet but the file exists on disk, reload before
        // deciding — prevents accepting arbitrary tokens when generateIfNeeded was never called.
        if !_tokenFileExists && FileManager.default.fileExists(atPath: tokenURL.path) {
            reloadLocked()
        }
        guard _tokenFileExists, let expected = _cachedToken else {
            // Grace mode: token file genuinely absent on disk, accept anything.
            return true
        }
        return incoming == expected
    }

    // MARK: - Private

    /// Must be called while holding `lock`.
    private func reloadLocked() {
        guard let token = try? String(contentsOf: tokenURL, encoding: .utf8) else { return }
        _cachedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        _tokenFileExists = true
    }
}
