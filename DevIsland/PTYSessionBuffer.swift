import Foundation

/// Sliding-window buffer for PTY output, one entry per session.
///
/// Keeps the last 1 KB of output so patterns split across `os.read` chunks are
/// still matched. Thread-safe via an internal `NSLock`.
struct PTYSessionBuffer {
    private var buffers: [String: String] = [:]
    private let lock = NSLock()

    /// Appends `content` to the session buffer and returns the updated window.
    mutating func appendAndWindow(sessionId: String, content: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let combined = (buffers[sessionId] ?? "") + content
        let window = combined.count > 1024 ? String(combined.suffix(1024)) : combined
        buffers[sessionId] = window
        return window
    }

    /// Clears the buffer for `sessionId` after a pattern match so the same
    /// accumulated content cannot re-trigger injection on the next chunk.
    mutating func clearOnMatch(sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        buffers[sessionId] = ""
    }

    /// Removes the buffer entry for `sessionId` entirely (session end / dismiss).
    mutating func remove(sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        buffers.removeValue(forKey: sessionId)
    }
}
