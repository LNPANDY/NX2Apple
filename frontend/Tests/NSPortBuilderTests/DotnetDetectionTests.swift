import XCTest
@testable import NSPortBuilder

/// The .NET row looks for dotnet in the build's order and is ready with the first that lists an SDK 10, the one the build puts in front.
final class DotnetDetectionTests: XCTestCase {
    func testTheBuildsOrder() {
        // build_ipa_from_nsp.py's TOOL_PATHS: Homebrew, /usr/local/bin, the installer's folder, then ~/.dotnet
        XCTAssertEqual(BuildModel.dotnetCandidates(home: "/Users/p"),
                       ["/opt/homebrew/bin/dotnet", "/usr/local/bin/dotnet", "/usr/local/share/dotnet/dotnet", "/Users/p/.dotnet/dotnet"])
    }

    func testOnlyAnSDK10Counts() {
        XCTAssertFalse(BuildModel.hasSDK10("7.0.402 [/usr/local/share/dotnet/sdk]\n"))   // an Intel .NET 7 in front of ~/.dotnet
        XCTAssertFalse(BuildModel.hasSDK10(""))
        XCTAssertFalse(BuildModel.hasSDK10("8.0.318 [/x/sdk]\n9.0.100 [/x/sdk]"))
        XCTAssertTrue(BuildModel.hasSDK10("7.0.402 [/a/sdk]\n10.0.403 [/b/sdk]\n"))
        XCTAssertTrue(BuildModel.hasSDK10("11.0.100-preview.1 [/b/sdk]"))
    }

    func testTheFirstWithAnSDK10() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dotnet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func dotnet(_ name: String, _ sdks: String, exit code: Int = 0) throws -> String {
            let folder = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("dotnet")
            try "#!/bin/sh\nprintf '\(sdks)'\nexit \(code)\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return file.path
        }
        func pick(_ cands: [String]) -> String {
            let r = BuildModel.findDotnet(cands)
            return (r.ok ? "ready " : "missing ") + r.path
        }
        let old = try dotnet("share", "7.0.402 [/s/sdk]\\n"), home = try dotnet("home", "9.0.100 [/h/sdk]\\n10.0.403 [/h/sdk]\\n")
        let broken = try dotnet("broken", "10.0.403 [/b/sdk]\\n", exit: 1), absent = dir.appendingPathComponent("none/dotnet").path

        // an Intel .NET 7 in /usr/local/share/dotnet before the .NET 10 in ~/.dotnet: the build puts the second in front
        XCTAssertEqual(pick([absent, old, home]), "ready " + home)
        XCTAssertEqual(pick([home, old]), "ready " + home)
        XCTAssertEqual(pick([broken, home]), "ready " + home)
        // no SDK 10 anywhere: Install, as with no dotnet at all
        XCTAssertEqual(pick([absent, old]), "missing " + old)
        XCTAssertEqual(pick([absent]), "missing dotnet")
    }
}
