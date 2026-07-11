import XCTest
@testable import DevIsland

@MainActor
final class AppStateTests: XCTestCase {
    var appState: AppState!
    var mockDefaults: UserDefaults!

    
    override func setUp() {
        super.setUp()
        // Use a clean UserDefaults for each test
        mockDefaults = UserDefaults(suiteName: "AppStateTests")
        mockDefaults.removePersistentDomain(forName: "AppStateTests")
        
        // Mock frontmostCheck to always return false to ensure requests go to the queue
        appState = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _ in false }
        )
    }
    
    override func tearDown() {
        appState = nil
        mockDefaults.removePersistentDomain(forName: "AppStateTests")
        mockDefaults = nil
        super.tearDown()
    }
    
    func parseResponse(_ response: String) -> [String: Any]? {
        guard let data = response.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func waitUntil(
        timeout: TimeInterval,
        expectation: XCTestExpectation,
        condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() {
                expectation.fulfill()
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    poll()
                }
            }
        }
        poll()
    }
    
}
