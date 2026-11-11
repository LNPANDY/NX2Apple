import XCTest
@testable import NX2Apple
@testable import NXCore

/// The names of a game whose app has no `DMTitleNames`, from its control data: a build folder's leftover `control.nacp`, else the
/// base package read by `PackageControl`. The packages are synthetic (`ControlPackageFixture`), with made-up keys.
@MainActor final class TitleNameLookupTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let titleID = "01008D7016438000"

    override func setUpWithError() throws {
        TitleNameAttempts.shared.reset()
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-title-lookup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func nacp(_ titles: [Int: String]) -> Data {
        var t = [UInt8](repeating: 0, count: 0x4000)
        for (i, name) in titles { let b = Array(name.utf8); t.replaceSubrange((i * 0x300)..<(i * 0x300 + b.count), with: b) }
        return Data(t)
    }

    private func write(_ data: Data, _ path: String) throws -> URL {
        let url = temporary.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func game(base: String, keys: String? = nil) -> LibraryGame {
        var g = LibraryGame(titleID: titleID, name: "13기병방위권")
        g.inputs = ["base": [base], "keys": keys.map { [$0] } ?? []]
        return g
    }

    /// An earlier build's extraction is still there: its newest version's control data, no extractor needed.
    func testLeftoverControlDataOfTheNewestVersion() throws {
        let base = try write(Data(), "games/13 Sentinels.xci")
        _ = try write(nacp([12: "13기병방위권"]), "games/\(titleID)_build/extract/v0/control.nacp")
        _ = try write(nacp([12: "13기병방위권", 14: "十三机兵防卫圈"]), "games/\(titleID)_build/extract/v65536/control.nacp")
        XCTAssertEqual(TitleNameLookup.names(for: game(base: base.path)), ["ko": "13기병방위권", "zh-Hans": "十三机兵防卫圈"])
    }

    /// The base package with the keys: its Control NCA is read, no engine tool or .NET SDK is needed.
    func testControlDataFromThePackage() throws {
        typealias F = ControlPackageFixture
        let id = UInt64(titleID, radix: 16)!
        let names = [12: "13기병방위권", 13: "十三機兵防衛圈", 14: "十三机兵防卫圈"]
        let keys = try write(Data(F.keysFile().utf8), "keys/prod.keys")
        let xci = try write(Data(F.xci([("c.nca", F.controlNCA(programID: id, nacp: F.nacp(names), rightsID: nil))])), "games/13 Sentinels.xci")
        XCTAssertEqual(TitleNameLookup.names(for: game(base: xci.path, keys: keys.path)), ["ko": "13기병방위권", "zh-Hant": "十三機兵防衛圈", "zh-Hans": "十三机兵防卫圈"])
    }

    /// Nothing to read: no keys, a game folder instead of a package, a package the keys do not open.
    func testNoNamesWithoutWhatTheLookupNeeds() throws {
        let keys = try write(Data("keys".utf8), "keys/prod.keys"), base = try write(Data("nsp".utf8), "games/Game.nsp")
        XCTAssertNil(TitleNameLookup.packageInputs(of: game(base: base.path)))
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("games/Switch 2 game"), withIntermediateDirectories: true)
        XCTAssertNil(TitleNameLookup.packageInputs(of: game(base: temporary.appendingPathComponent("games/Switch 2 game").path, keys: keys.path)))
        XCTAssertNotNil(TitleNameLookup.packageInputs(of: game(base: base.path, keys: keys.path)))
        XCTAssertNil(TitleNameLookup.names(for: game(base: base.path, keys: keys.path)))
    }

    /// What the lookup found stays when the library reads the game's older app again, and an app packed with names replaces it.
    func testLookedUpNamesStayUntilAnAppHasItsOwn() throws {
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        func app(_ names: [String: String]?) throws -> URL {
            let app = temporary.appendingPathComponent("apps/\(UUID().uuidString)/\(titleID).app")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            for exe in ["nxnative", "dmhost"] {
                try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Contents/MacOS/" + exe), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
            }
            var info: [String: Any] = ["DMTitleID": titleID, "CFBundleDisplayName": "13기병방위권", "CFBundleExecutable": "nxnative"]
            if let names { info["DMTitleNames"] = names }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            return app
        }
        let id = try library.addApp(app(nil))
        library.setTitleNames(["ko": "13기병방위권", "zh-Hans": "十三机兵防卫圈"], for: id)
        _ = try library.addApp(app(nil))
        XCTAssertEqual(library.games.first?.displayName(.zh), "十三机兵防卫圈")
        library.setTitleNames(["zh-Hans": "Other"], for: id)   // a name it has is not looked up again
        XCTAssertEqual(library.games.first?.displayName(.zh), "十三机兵防卫圈")
        _ = try library.addApp(app(["ko": "13기병방위권", "zh-Hans": "十三机兵防卫圈 (packed)"]))
        XCTAssertEqual(library.games.first?.displayName(.zh), "十三机兵防卫圈 (packed)")
    }

    private func flushTitleNameLookups() {
        let queueDrained = expectation(description: "title lookup queue drained")
        TitleNameAttempts.queue.async {
            DispatchQueue.main.async {
                queueDrained.fulfill()
            }
        }
        wait(for: [queueDrained], timeout: 5)
    }

    /// Global saved keys are used when the game folder has no local keys or when local keys cannot decrypt the package.
    func testGlobalSavedKeysFallbackResolvesTitleNamesThroughLibrary() throws {
        typealias F = ControlPackageFixture
        let id = UInt64(titleID, radix: 16)!
        let names = [12: "13기병방위권", 14: "十三机兵防卫圈"]
        let savedKeys = try write(Data(F.keysFile().utf8), "global/prod.keys")
        let staleLocalKeys = try write(Data("header_key = 00\n".utf8), "games/stale.keys")
        let xci = try write(Data(F.xci([("c.nca", F.controlNCA(programID: id, nacp: F.nacp(names), rightsID: nil))])), "games/13 Sentinels.xci")

        XCTAssertEqual(
            TitleNameLookup.names(for: game(base: xci.path, keys: staleLocalKeys.path), fallbackKeys: savedKeys.path),
            ["ko": "13기병방위권", "zh-Hans": "十三机兵防卫圈"]
        )

        let library = GameLibrary(file: temporary.appendingPathComponent("library-fallback.json"))
        library.keysFile = { savedKeys.path }
        library.upsert(game(base: xci.path))
        library.fillMissingTitleNames()
        flushTitleNameLookups()

        XCTAssertEqual(library.games.first?.displayName(.zh), "十三机兵防卫圈")
    }

    /// An initial lookup before keys are configured or while a package copy is incomplete does not permanently blacklist the game.
    func testFailedTitleNameLookupRetriesWhenSavedKeysOrPackageChangesAndSkipsUnchangedInputs() throws {
        typealias F = ControlPackageFixture
        let id = UInt64(titleID, radix: 16)!
        let nacpNames = [12: "13기병방위권", 14: "十三机兵防卫圈"]
        let savedKeys = try write(Data(F.keysFile().utf8), "global/prod.keys")
        let validXCIData = Data(F.xci([("c.nca", F.controlNCA(programID: id, nacp: F.nacp(nacpNames), rightsID: nil))]))

        // Case 1: first lookup runs with no keys configured, then succeeds after savedKeys is set.
        let xci1 = try write(validXCIData, "case1/13 Sentinels.xci")
        let library1 = GameLibrary(file: temporary.appendingPathComponent("library-retry-keys.json"))
        var currentKeys = ""
        library1.keysFile = { currentKeys }
        library1.upsert(game(base: xci1.path))

        library1.fillMissingTitleNames()
        flushTitleNameLookups()
        XCTAssertEqual(library1.games.first?.titleNames, [:])

        let unchangedNoKeysSig = TitleNameLookup.attemptSignature(for: library1.games[0], fallbackKeys: "")
        XCTAssertFalse(TitleNameAttempts.shared.begin(unchangedNoKeysSig), "unchanged inputs must not trigger a duplicate lookup")

        currentKeys = savedKeys.path
        library1.fillMissingTitleNames()
        flushTitleNameLookups()
        XCTAssertEqual(library1.games.first?.displayName(.zh), "十三机兵防卫圈")

        // Case 2: first lookup runs against a partial package copy, then retries automatically once the full file lands.
        let otherID = "01007EF00011E000"
        let otherNum = UInt64(otherID, radix: 16)!
        let otherXCIData = Data(F.xci([("c.nca", F.controlNCA(programID: otherNum, nacp: F.nacp([0: "Breath of the Wild", 14: "旷野之息"]), rightsID: nil))]))
        let partialPath = try write(Data("partial-copy".utf8), "case2/BotW.xci")

        var partialGame = LibraryGame(titleID: otherID, name: otherID)
        partialGame.inputs = ["base": [partialPath.path]]
        let library2 = GameLibrary(file: temporary.appendingPathComponent("library-retry-pkg.json"))
        library2.keysFile = { savedKeys.path }
        library2.upsert(partialGame)

        library2.fillMissingTitleNames()
        flushTitleNameLookups()
        XCTAssertEqual(library2.games.first?.titleNames, [:])

        let partialSig = TitleNameLookup.attemptSignature(for: library2.games[0], fallbackKeys: savedKeys.path)
        XCTAssertFalse(TitleNameAttempts.shared.begin(partialSig), "unchanged broken package must not repeat subprocess or file reads")

        try otherXCIData.write(to: partialPath)
        library2.fillMissingTitleNames()
        flushTitleNameLookups()
        XCTAssertEqual(library2.games.first?.displayName(.zh), "旷野之息")
    }
}
