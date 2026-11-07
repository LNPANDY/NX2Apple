import XCTest
@testable import NX2Apple
@testable import NXCore

/// The names of a game whose app has no `DMTitleNames`, from its control data: a build folder's leftover `control.nacp`, else the
/// base package read by `nx_extract --control`. A stand-in `dotnet` "builds" a stand-in extractor, so no .NET, keys or game is needed.
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

    private func script(_ path: String, _ body: String) throws -> URL {
        let url = try write(Data(("#!/bin/sh\n" + body).utf8), path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
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
        let lookup = TitleNameLookup(engineRoot: temporary.appendingPathComponent("no-engine").path, cache: temporary.appendingPathComponent("cache"),
                                     findDotnet: { XCTFail("no extractor for a leftover"); return ("", false) })
        XCTAssertEqual(lookup.names(for: game(base: base.path)), ["ko": "13기병방위권", "zh-Hans": "十三机兵防卫圈"])
    }

    /// The base package with the keys: the extractor is built once into the cache, and asked for the control data alone.
    func testControlDataFromThePackage() throws {
        let engine = temporary.appendingPathComponent("engine")
        _ = try write(Data(#"if (a[1] == "--control") return Control();"#.utf8), "engine/dm/tools/nx_extract/Program.cs")
        _ = try write(Data("<Project/>".utf8), "engine/dm/tools/nx_extract/nx_extract.csproj")
        let control = try write(nacp([12: "13기병방위권", 13: "十三機兵防衛圈", 14: "十三机兵防卫圈"]), "fixture/control.nacp")
        // dotnet build <project> -c Release -o <dir> …: writes an nx_extract that copies the fixture to its fourth argument
        let builds = temporary.appendingPathComponent("builds.txt")
        let dotnet = try script("bin/dotnet", """
            [ "$1" = build ] || exit 0
            echo built >> '\(builds.path)'
            out="$6"; mkdir -p "$out"
            printf '#!/bin/sh\\n[ "$2" = --control ] && [ "$5" = --app ] && [ "$6" = \(titleID) ] || exit 9\\ncp "\(control.path)" "$4"\\n' > "$out/nx_extract"
            chmod +x "$out/nx_extract"
            """)
        let keys = try write(Data("keys".utf8), "keys/prod.keys"), base = try write(Data("xci".utf8), "games/13 Sentinels.xci")
        let cache = temporary.appendingPathComponent("cache")
        let expected = ["ko": "13기병방위권", "zh-Hant": "十三機兵防衛圈", "zh-Hans": "十三机兵防卫圈"]
        for _ in 0..<2 {   // a second lookup (the next launch) uses the cached extractor
            let lookup = TitleNameLookup(engineRoot: engine.path, cache: cache, findDotnet: { (dotnet.path, true) })
            XCTAssertEqual(lookup.names(for: game(base: base.path, keys: keys.path)), expected)
        }
        XCTAssertEqual(try String(contentsOf: builds, encoding: .utf8), "built\n")
    }

    /// Nothing to read: no keys, a game folder instead of a package, an engine whose extractor has no --control, no .NET SDK.
    func testNoNamesWithoutWhatTheLookupNeeds() throws {
        let keys = try write(Data("keys".utf8), "keys/prod.keys"), base = try write(Data("nsp".utf8), "games/Game.nsp")
        XCTAssertNil(TitleNameLookup.packageInputs(of: game(base: base.path)))
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("games/Switch 2 game"), withIntermediateDirectories: true)
        XCTAssertNil(TitleNameLookup.packageInputs(of: game(base: temporary.appendingPathComponent("games/Switch 2 game").path, keys: keys.path)))
        XCTAssertNotNil(TitleNameLookup.packageInputs(of: game(base: base.path, keys: keys.path)))
        _ = try write(Data("static int Main() {}".utf8), "old-engine/dm/tools/nx_extract/Program.cs")
        _ = try write(Data("<Project/>".utf8), "old-engine/dm/tools/nx_extract/nx_extract.csproj")
        let old = TitleNameLookup(engineRoot: temporary.appendingPathComponent("old-engine").path, cache: temporary.appendingPathComponent("cache"),
                                  findDotnet: { XCTFail("an extractor without --control is not built"); return ("", false) })
        XCTAssertNil(old.names(for: game(base: base.path, keys: keys.path)))
        _ = try write(Data(#""--control""#.utf8), "engine/dm/tools/nx_extract/Program.cs")
        _ = try write(Data("<Project/>".utf8), "engine/dm/tools/nx_extract/nx_extract.csproj")
        let noSDK = TitleNameLookup(engineRoot: temporary.appendingPathComponent("engine").path, cache: temporary.appendingPathComponent("cache"),
                                    findDotnet: { ("/usr/local/bin/dotnet", false) })
        XCTAssertNil(noSDK.names(for: game(base: base.path, keys: keys.path)))
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
