import XCTest
@testable import NXCore

/// The IPA's zip command, run for real. ditto wrote IPAs over 4 GB with 32-bit offsets that wrap, so `unzip -t` and
/// sideloading tools rejected them. zip writes ZIP64 records when an archive needs them.
final class IPAZipTests: XCTestCase {
    private var temporary: URL!
    private let fm = FileManager.default
    private let tool = SystemProcessRunner()

    override func setUpWithError() throws {
        temporary = fm.temporaryDirectory.appendingPathComponent("IPAZipTests-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary.appendingPathComponent("stage/Payload/Game.app"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: temporary) }

    private var app: URL { temporary.appendingPathComponent("stage/Payload/Game.app") }
    private var ipa: String { temporary.appendingPathComponent("Game.ipa").path }

    private func zip() {
        let payload = temporary.appendingPathComponent("stage/Payload").path
        let result = tool.capture(ProcessLaunch(BuildCommands.ipaCommand(payload: payload, ipa: ipa), mergesErrors: true))
        XCTAssertTrue(result.ok, result.out)
    }

    private func listing() -> String {
        tool.capture(ProcessLaunch(["/usr/bin/zipinfo", ipa], mergesErrors: true)).out
    }

    func testTheIPAHasPayloadAsItsRootAndKeepsLinks() throws {
        try Data("main".utf8).write(to: app.appendingPathComponent("Game"))
        try fm.createSymbolicLink(atPath: app.appendingPathComponent("Current").path, withDestinationPath: "Game")
        zip()
        let names = tool.capture(ProcessLaunch(["/usr/bin/zipinfo", "-1", ipa], mergesErrors: true)).out
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(Set(names), ["Payload/", "Payload/Game.app/", "Payload/Game.app/Game", "Payload/Game.app/Current"])
        let link = try XCTUnwrap(listing().split(separator: "\n").first { $0.hasSuffix("Payload/Game.app/Current") })
        XCTAssertTrue(link.hasPrefix("l"), String(link))   // stored as a link, not as a copy of its target
    }

    func testAnIPAIsWrittenAgainNotAddedTo() throws {
        try Data("old".utf8).write(to: app.appendingPathComponent("Old"))
        zip()
        try fm.removeItem(at: app.appendingPathComponent("Old"))
        try Data("new".utf8).write(to: app.appendingPathComponent("New"))
        zip()
        let names = tool.capture(ProcessLaunch(["/usr/bin/zipinfo", "-1", ipa], mergesErrors: true)).out
        XCTAssertTrue(names.contains("Payload/Game.app/New"))
        XCTAssertFalse(names.contains("Payload/Game.app/Old"))
    }

    /// Writes about 4.2 GB of data that does not compress, and takes a few minutes, so it runs only when asked for.
    func testAnIPAOver4GBPassesUnzipTest() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NX2APPLE_LARGE_IPA_TEST"] == "1", "Opt in to writing a 4.2 GB IPA")
        var block = Data(count: 64 << 20)
        let status = block.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        XCTAssertEqual(status, errSecSuccess)
        for name in ["a", "b"] {   // a repeated 64 MB random block: deflate's 32 KB window cannot shrink it
            let url = app.appendingPathComponent(name)
            XCTAssertTrue(fm.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            for _ in 0..<33 { try handle.write(contentsOf: block) }
            try handle.close()
        }
        try Data("last".utf8).write(to: app.appendingPathComponent("z"))
        zip()
        let size = try XCTUnwrap(fm.attributesOfItem(atPath: ipa)[.size] as? NSNumber).int64Value
        XCTAssertGreaterThan(size, Int64(UInt32.max))
        let test = tool.capture(ProcessLaunch(["/usr/bin/unzip", "-tq", ipa], mergesErrors: true))
        XCTAssertTrue(test.ok, test.out)
    }
}
