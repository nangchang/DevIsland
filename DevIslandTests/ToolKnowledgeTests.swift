import XCTest
@testable import DevIsland

final class ToolKnowledgeTests: XCTestCase {
    func testRiskLevels() {
        XCTAssertEqual(ToolKnowledge.risk(for: "bash"), .critical)
        XCTAssertEqual(ToolKnowledge.risk(for: "run_shell_command"), .critical)
        XCTAssertEqual(ToolKnowledge.risk(for: "edit"), .high)
        XCTAssertEqual(ToolKnowledge.risk(for: "replace_file_content"), .high)
        XCTAssertEqual(ToolKnowledge.risk(for: "view_file"), .safe)
        XCTAssertEqual(ToolKnowledge.risk(for: "ls"), .safe)
        XCTAssertEqual(ToolKnowledge.risk(for: "grep_search"), .safe)
    }
    
    func testFallbackRisk() {
        XCTAssertEqual(ToolKnowledge.risk(for: "unknown_read_tool"), .safe)
        XCTAssertEqual(ToolKnowledge.risk(for: "custom_write_action"), .high)
        XCTAssertEqual(ToolKnowledge.risk(for: "execute_something"), .critical)
        XCTAssertEqual(ToolKnowledge.risk(for: "some_random_tool"), .medium)
    }
    
    func testRiskLevelComparison() {
        XCTAssertTrue(ToolRiskLevel.safe < ToolRiskLevel.low)
        XCTAssertTrue(ToolRiskLevel.low < ToolRiskLevel.medium)
        XCTAssertTrue(ToolRiskLevel.medium < ToolRiskLevel.high)
        XCTAssertTrue(ToolRiskLevel.high < ToolRiskLevel.critical)
    }
}
