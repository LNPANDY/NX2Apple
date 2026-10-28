import XCTest
@testable import NSPortBuilder

/// #111: the repo-root Brewfile is the one list of Homebrew tools, and the launcher's dependency check offers the same.
final class BrewfileTests: XCTestCase {
    private func brewfileLines() throws -> [String] {
        // frontend/Tests/NSPortBuilderTests/BrewfileTests.swift -> the repository root
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
        let launcher = Set(BuildModel.brewDeps.map { $0.formula })
        XCTAssertEqual(Set(try entries("brew")), launcher)
        XCTAssertEqual(try entries("brew").count, launcher.count, "a formula is listed twice")
    }

    func testBrewfileCaskIsTheDotnetSdkTheLauncherNeeds() throws {
        // The launcher checks for an SDK (`dotnet --list-sdks`) and installs channel 10.0; the cask is Homebrew's SDK.
        XCTAssertEqual(try entries("cask"), ["dotnet-sdk"])
    }
}
