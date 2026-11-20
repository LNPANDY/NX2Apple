import Foundation
import XCTest

/// One way to nxb (#1460): the old experimental builder (nxb under the NSP script's arguments, the switch NX2APPLE_NXBUILD, its Settings row) is gone.
final class ExperimentalBuilderRemovalTests: XCTestCase {
    func testNoReferenceIsLeft() throws {
        let frontend = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let words = ["ExperimentalBuilder", "experimentalBuilder", "NX2APPLE_NXBUILD", "DM_EXPERIMENTAL_BUILDER", "NXB_ENGINE", "nxbRun", "msg.builderOn"]
        var hits: [String] = []
        for folder in ["Sources", "l10n"] {
            let root = frontend.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            for file in files where ["swift", "json"].contains(file.pathExtension) {
                let text = try String(contentsOf: file, encoding: .utf8)
                for word in words where text.contains(word) { hits.append(file.lastPathComponent + ": " + word) }
            }
        }
        XCTAssertEqual(hits, [])
        let en = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: frontend.appendingPathComponent("l10n/en.json"))) as? [String: Any])
        XCTAssertTrue(en.keys.filter { $0.hasPrefix("builder.") }.isEmpty, "the experimental builder row's texts")
    }
}
