import XCTest

/// LNPANDY/NX2Apple#387: no Swift file under frontend/Sources is above 800 lines. The files above it today are listed with their
/// size, so they may only shrink. When one drops to 800 lines or fewer, its entry goes (the test says so), and nothing grows back.
final class SourceSizeTests: XCTestCase {
    private static let limit = 800

    /// Path under frontend/Sources → its line count when the limit came in. Lower the number when the file shrinks.
    private static let aboveTheLimit: [String: Int] = [
        "NX2Apple/ContentView.swift": 2228,
        "NX2Apple/LauncherView.swift": 967,
        "NXCore/Localization.swift": 4237,
    ]

    private func sources() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }   // frontend/Tests/NX2AppleTests/<this file> -> frontend
        return url.appendingPathComponent("Sources")
    }

    private func lineCounts() throws -> [String: Int] {
        let root = sources()
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var counts: [String: Int] = [:]
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            counts[String(file.path.dropFirst(root.path.count + 1))] = text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
        }
        return counts
    }

    func testNoSwiftFileIsAboveTheLimit() throws {
        let counts = try lineCounts()
        XCTAssertFalse(counts.isEmpty, "found no Swift files under frontend/Sources")
        for (path, lines) in counts.sorted(by: { $0.key < $1.key }) where lines > Self.limit {
            guard let allowed = Self.aboveTheLimit[path] else {
                XCTFail("\(path) has \(lines) lines, the limit is \(Self.limit): split it, see frontend/ARCHITECTURE.md")
                continue
            }
            XCTAssertLessThanOrEqual(lines, allowed, "\(path) grew from \(allowed) to \(lines) lines: the listed files may only shrink")
        }
    }

    func testTheListHoldsOnlyFilesThatAreStillAboveTheLimit() throws {
        let counts = try lineCounts()
        for (path, allowed) in Self.aboveTheLimit.sorted(by: { $0.key < $1.key }) {
            guard let lines = counts[path] else { XCTFail("\(path) is gone: remove its entry from SourceSizeTests.aboveTheLimit"); continue }
            if lines <= Self.limit { XCTFail("\(path) is down to \(lines) lines: remove its entry from SourceSizeTests.aboveTheLimit") }
            else if lines < allowed { XCTFail("\(path) shrank to \(lines) lines: lower its entry from \(allowed) to \(lines)") }
        }
    }
}
