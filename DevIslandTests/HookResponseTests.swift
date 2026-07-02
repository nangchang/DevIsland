import XCTest
@testable import DevIsland

final class HookResponseTests: XCTestCase {

    private func decoded(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - 단순 결정

    func testApprovedProducesResponseOnlyPayload() {
        let obj = decoded(HookResponse(.approved).jsonString())
        XCTAssertEqual(obj?["response"] as? String, "approved")
        XCTAssertEqual(obj?.count, 1)
    }

    func testDeniedProducesResponseOnlyPayload() {
        let obj = decoded(HookResponse(.denied).jsonString())
        XCTAssertEqual(obj?["response"] as? String, "denied")
        XCTAssertEqual(obj?.count, 1)
    }

    func testPassProducesResponseOnlyPayload() {
        let obj = decoded(HookResponse(.pass).jsonString())
        XCTAssertEqual(obj?["response"] as? String, "pass")
        XCTAssertEqual(obj?.count, 1)
    }

    // MARK: - 옵션 필드

    func testReasonIsIncludedWhenSet() {
        let obj = decoded(HookResponse(.denied, reason: "blocked by policy").jsonString())
        XCTAssertEqual(obj?["response"] as? String, "denied")
        XCTAssertEqual(obj?["reason"] as? String, "blocked by policy")
        XCTAssertEqual(obj?.count, 2)
    }

    func testApprovalScopeIsSerializedAsRawValue() {
        let obj = decoded(HookResponse(.approved, approvalScope: .session).jsonString())
        XCTAssertEqual(obj?["response"] as? String, "approved")
        XCTAssertEqual(obj?["approval_scope"] as? String, RuleScope.session.rawValue)
        XCTAssertEqual(obj?.count, 2)
    }

    func testToolInputIsSerializedAsNestedObject() {
        let toolInput: [String: AnyJSON] = ["answer": .string("option-1")]
        let obj = decoded(HookResponse(.approved, toolInput: toolInput).jsonString())
        XCTAssertEqual(obj?["response"] as? String, "approved")
        let nested = obj?["tool_input"] as? [String: Any]
        XCTAssertEqual(nested?["answer"] as? String, "option-1")
        XCTAssertEqual(obj?.count, 2)
    }

    // MARK: - 결정성

    func testJsonStringIsDeterministic() {
        let response = HookResponse(
            .approved,
            reason: "auto",
            approvalScope: .persistent,
            toolInput: ["a": .string("1"), "b": .string("2")]
        )
        XCTAssertEqual(response.jsonString(), response.jsonString())
    }
}
