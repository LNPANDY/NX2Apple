import XCTest
@testable import NXCore

/// LNPANDY/NX2Apple#388, step 1: the language files are read from `frontend/l10n`, from the app's Resources, or from a folder named
/// in the environment, and a missing or broken file shows keys instead of stopping the app.
final class LocalizationFilesTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("l10n-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func write(_ name: String, _ text: String, in folder: URL? = nil) throws {
        let dir = folder ?? tmp!
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testTheCheckoutHasAllFiveLanguagesWithTheSameKeysInEnglishAndChinese() throws {
        let loaded = LocalizationFiles.load()
        for code in ["en", "zh", "sv", "de", "fr"] { XCTAssertFalse(loaded[code]?.isEmpty ?? true, "\(code).json was not read") }
        XCTAssertEqual(Set(loaded["en"]!.keys), Set(loaded["zh"]!.keys), "English and Chinese need every key")
        XCTAssertNil(loaded["en"]!["_language"], "_language is not a text")
        XCTAssertEqual(L10n.string("stale.go", Lang("de")), "Fortfahren")
        XCTAssertEqual(L10n.string("no.such.key", Lang("fr")), "no.such.key")
    }

    func testEnvironmentFolderComesFirstThenTheAppsResources() throws {
        let env = tmp.appendingPathComponent("env"), res = tmp.appendingPathComponent("Resources")
        try write("en.json", "{}", in: env)
        try write("en.json", "{}", in: res.appendingPathComponent("l10n"))
        XCTAssertEqual(LocalizationFiles.directory(environment: ["NX_L10N_DIR": env.path], resources: res, executable: nil)?.path, env.path)
        XCTAssertEqual(LocalizationFiles.directory(environment: [:], resources: res, executable: nil)?.path, res.appendingPathComponent("l10n").path)
    }

    func testWalkingUpFromTheExecutableFindsFrontendL10n() throws {
        let frontend = tmp.appendingPathComponent("repo/frontend")
        try write("en.json", "{}", in: frontend.appendingPathComponent("l10n"))
        let executable = frontend.appendingPathComponent(".build/arm64-apple-macosx/debug/NX2Apple")
        XCTAssertEqual(LocalizationFiles.directory(environment: [:], resources: nil, executable: executable, sourceFile: "/nowhere/a/b/c.swift")?.path,
                       frontend.appendingPathComponent("l10n").path)
    }

    func testNothingFoundAnswersNilAndLoadsNoTexts() {
        XCTAssertNil(LocalizationFiles.directory(environment: [:], resources: nil, executable: nil, sourceFile: "/nowhere/a/b/c.swift"))
        var reports: [String] = []
        XCTAssertTrue(LocalizationFiles.load(from: nil, report: { reports.append($0) }).isEmpty)
        XCTAssertEqual(reports.count, 1)
    }

    func testABrokenOrMissingFileLeavesThatLanguageOutAndReportsIt() throws {
        try write("en.json", #"{"_language": {"name": "English", "locales": ["en"]}, "a": "A", "n": 3}"#)
        try write("zh.json", "{ this is not json")
        var reports: [String] = []
        let loaded = LocalizationFiles.load(from: tmp, report: { reports.append($0) })
        XCTAssertEqual(loaded["en"], ["a": "A"])
        XCTAssertNil(loaded["zh"])
        XCTAssertNil(loaded["fr"])
        // A language with no file is not a language, so only the two problems are reported.
        XCTAssertEqual(reports.count, 2, "n is not a text and zh.json is broken: \(reports)")
    }
}
