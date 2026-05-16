import XCTest
@testable import DevIsland

final class OpenPeonManifestTests: XCTestCase {
    func testValidManifestDecode() throws {
        let json = """
        {
          "cesp_version": "1.0",
          "name": "sample-pack",
          "display_name": "Sample Pack",
          "version": "1.0.0",
          "categories": {
            "input.required": {
              "sounds": [
                { "file": "sounds/approval.mp3", "label": "Approval needed" }
              ]
            }
          }
        }
        """

        let manifest = try JSONDecoder().decode(CESPManifest.self, from: Data(json.utf8))

        XCTAssertEqual(manifest.cespVersion, "1.0")
        XCTAssertEqual(manifest.name, "sample-pack")
        XCTAssertEqual(manifest.displayName, "Sample Pack")
        XCTAssertEqual(manifest.categories["input.required"]?.sounds.first?.file, "sounds/approval.mp3")
    }
}
