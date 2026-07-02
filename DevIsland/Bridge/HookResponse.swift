import Foundation

/// 훅 응답의 결정 값. provider 응답 JSON의 `response` 필드에 그대로 직렬화된다.
enum HookDecision: String {
    case approved
    case denied
    case pass
}

/// 앱 → 브리지 훅 응답 JSON의 단일 생성 지점.
/// `responseHandler: (String) -> Void` IPC 계약은 그대로 두고,
/// 흩어져 있던 `"{\"response\": …}"` 하드코딩 문자열 생성만 타입으로 승격한다.
/// (docs/refactoring-plan.md R1-b)
struct HookResponse {
    var decision: HookDecision
    var reason: String?
    var approvalScope: RuleScope?
    var toolInput: [String: AnyJSON]?

    init(
        _ decision: HookDecision,
        reason: String? = nil,
        approvalScope: RuleScope? = nil,
        toolInput: [String: AnyJSON]? = nil
    ) {
        self.decision = decision
        self.reason = reason
        self.approvalScope = approvalScope
        self.toolInput = toolInput
    }

    func jsonString() -> String {
        var payload: [String: Any] = ["response": decision.rawValue]
        if let reason {
            payload["reason"] = reason
        }
        if let approvalScope {
            payload["approval_scope"] = approvalScope.rawValue
        }
        if let toolInput {
            payload["tool_input"] = toolInput.mapValues { $0.rawValue }
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        // 위 payload 형태에서 직렬화는 실패하지 않지만, IPC 계약상 항상 유효한 응답을 보장한다.
        return "{\"response\":\"\(decision.rawValue)\"}"
    }
}
