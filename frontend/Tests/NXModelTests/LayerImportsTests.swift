import XCTest

/// LNPANDY/NX2Apple#387: the layers are kept apart by what each target imports. `NXCore` and `NXModel` never import SwiftUI or AppKit,
/// and a target never imports one above it. `Package.swift` lets any target link a system framework, so the compiler alone does not
/// stop a `Color` or an `NSImage` from slipping in. This reads the sources and fails the moment a wrong import is added, with the
/// file and the line.
final class LayerImportsTests: XCTestCase {
    private func sources(_ target: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }   // frontend/Tests/NXModelTests/<this file> -> frontend
        return url.appendingPathComponent("Sources").appendingPathComponent(target)
    }

    /// Every `import X` line of the target's Swift files, as "File.swift:line: module".
    private func imports(of target: String) throws -> [(where: String, module: String)] {
        let root = sources(target)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var found: [(String, String)] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
                guard words.first == "import" || (words.count > 1 && words.first == "@testable" && words[1] == "import") else { continue }
                found.append(("\(file.lastPathComponent):\(index + 1)", String(words.last ?? "")))
            }
        }
        XCTAssertFalse(found.isEmpty, "found no imports under Sources/\(target)")
        return found
    }

    private func assertNoImports(in target: String, of forbidden: Set<String>) throws {
        for (place, module) in try imports(of: target) where forbidden.contains(module) {
            XCTFail("\(place): \(target) imports \(module), which a \(target) file must not (frontend/ARCHITECTURE.md)")
        }
    }

    func testNXCoreImportsNoUIFramework() throws {
        try assertNoImports(in: "NXCore", of: ["SwiftUI", "AppKit", "Cocoa", "UIKit", "NXModel", "NXLauncher", "NX2Apple"])
    }

    func testNXModelImportsNoUIFramework() throws {
        try assertNoImports(in: "NXModel", of: ["SwiftUI", "AppKit", "Cocoa", "UIKit", "NXLauncher", "NX2Apple"])
    }

    func testNXLauncherImportsNoAppTarget() throws {
        try assertNoImports(in: "NXLauncher", of: ["NX2Apple"])
    }
}
