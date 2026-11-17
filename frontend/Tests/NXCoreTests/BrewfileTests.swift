import XCTest
@testable import NXCore

/// #111: the repo-root Brewfile is the one list of Homebrew tools, and the launcher's dependency check offers the same.
final class BrewfileTests: XCTestCase {
    private func brewfileLines() throws -> [String] {
        // frontend/Tests/NX2AppleTests/BrewfileTests.swift -> the repository root
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        let text = try String(contentsOf: url.appendingPathComponent("Brewfile"), encoding: .utf8)
        return text.split(separator: "\n").map { line in
            String(line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    private func entries(_ kind: String) throws -> [String] {
        try brewfileLines().compactMap { line in
            guard line.hasPrefix(kind + " \""), let a = line.firstIndex(of: "\""),
                  let b = line[line.index(after: a)...].firstIndex(of: "\"") else { return nil }
            return String(line[line.index(after: a)..<b])
        }
    }

    func testBrewfileFormulaeAreTheLaunchersDependencies() throws {
        let launcher = Set(Toolchain.brewDeps.map { $0.formula })
        XCTAssertEqual(Set(try entries("brew")), launcher)
        XCTAssertEqual(try entries("brew").count, launcher.count, "a formula is listed twice")
    }

    func testBrewfileCaskIsTheDotnetSdkTheNativeToolsAreRebuiltWith() throws {
        // Not a dependency of an nxnative build (#1404): S2Arm builds with it, and dm/tools/native_tools.sh publishes with it (net10.0).
        XCTAssertEqual(try entries("cask"), ["dotnet-sdk"])
    }
}
