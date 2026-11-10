import XCTest
@testable import NX2Apple
@testable import NXCore

/// The names of a game whose app has no `DMTitleNames`, from its control data: a build folder's leftover `control.nacp`, else the
/// base package read by `PackageControl`. The packages are synthetic (`ControlPackageFixture`), with made-up keys.
@MainActor final class TitleNameLookupTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let titleID = "01008D7016438000"

    override func setUpWithError() throws {
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
}
