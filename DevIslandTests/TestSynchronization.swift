import Foundation

final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    var value: Value {
        withValue { $0 }
    }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

actor AsyncGate {
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiter: CheckedContinuation<Void, Never>?
    private var didEnter = false
    private var didResume = false

    func enterAndWaitForResume() async {
        didEnter = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()

        guard !didResume else { return }
        await withCheckedContinuation { continuation in
            resumeWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func resume() {
        didResume = true
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}
