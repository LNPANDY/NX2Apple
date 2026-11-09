import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel

/// LNPANDY/NX2Apple#1012: the library finds a package whose name has no title ID by its NCA headers, with the header_key of the
/// keys saved in Settings. The packages are synthetic PFS0s whose NCAs hold only a header, and every key is made up for the test.
@MainActor final class PackageTitleIDTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let headerKey = (0..<32).map { UInt8(0xA0 ^ $0) }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-titleid-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    /// An NCA header of the given content type (1: meta, 0: program) and program ID, encrypted with `key`.
    private func nca(type: UInt8, programID: UInt64, key: [UInt8]? = nil) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: KeyCheck.headerBytes)
        h.replaceSubrange(0x200..<0x204, with: Array("NCA3".utf8))
        h[0x205] = type; h[0x220] = 3
        for i in 0..<8 { h[0x210 + i] = UInt8(programID >> (8 * UInt64(i)) & 0xFF) }
        return KeyCheck.xts(h, key: key ?? headerKey, encrypt: true)!
    }

    /// An NSP (a PFS0) at `path` under the temporary folder, of a program NCA and a meta NCA with these IDs.
    @discardableResult private func nsp(_ path: String, meta: UInt64, program: UInt64? = nil, key: [UInt8]? = nil) throws -> String {
        var files: [(String, [UInt8])] = []
        if let program { files.append(("0123.nca", nca(type: 0, programID: program, key: key))) }
        files.append(("4567.cnmt.nca", nca(type: 1, programID: meta, key: key)))
        var names: [UInt8] = [], entries: [UInt8] = [], data: [UInt8] = []
        func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(v >> (8 * $0) & 0xFF) } }
        for (file, bytes) in files {
            entries += le(data.count, 8) + le(bytes.count, 8) + le(names.count, 4) + le(0, 4)
            names += Array(file.utf8) + [0]
            data += bytes
        }
        while names.count % 0x20 != 0 { names.append(0) }
        let url = temporary.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(Array("PFS0".utf8) + le(files.count, 4) + le(names.count, 4) + le(0, 4) + entries + names + data))
        return url.path
    }

    private func scan(_ key: [UInt8]?) -> [LibraryGame] {
        GameLibrary.sourceGames(in: temporary.appendingPathComponent("Games"), repo: temporary.path, headerKey: key)
    }

    func testTheMetaNCANamesThePackageNotTheProgramNCA() throws {
        let path = try nsp("Games/Mario update.nsp", meta: 0x0100000000010800, program: 0x0100000000010000)
        XCTAssertEqual(PackageTitleID.read(path, headerKey: headerKey), 0x0100000000010800)
        XCTAssertNil(PackageTitleID.read(path, headerKey: (0..<32).map { UInt8($0) }), "a header_key that opens nothing")
    }

    func testARenamedGameWithItsRenamedUpdateAndDLCIsFoundWithTheKeys() throws {
        let base = try nsp("Games/Mario/Mario.nsp", meta: 0x0100000000010000, program: 0x0100000000010000)
        let update = try nsp("Games/Mario/Mario update.nsp", meta: 0x0100000000010800, program: 0x0100000000010800)
        let dlc = try nsp("Games/Mario/Mario extra.nsp", meta: 0x0100000000011001)
        let games = scan(headerKey)
        XCTAssertEqual(games.map(\.titleID), ["0100000000010000"], "one game: the update and the DLC are not games of their own")
        XCTAssertEqual(games.first?.name, "Mario")
        // The scan hands out /private/var/… for /var/…: compare the files, not the spelling.
        func real(_ paths: [String]?) -> [String] { (paths ?? []).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } }
        XCTAssertEqual(real(games.first?.inputs["base"]), real([base]))
        XCTAssertEqual(real(games.first?.inputs["update"]), real([update]))
        XCTAssertEqual(real(games.first?.inputs["dlc"]), real([dlc]))
    }

    func testWithoutKeysOrWithAWrongKeyOnlyNamesCount() throws {
        try nsp("Games/Mario.nsp", meta: 0x0100000000010000)
        try nsp("Games/Zelda [0100000000020000][v0].nsp", meta: 0x0100000000020000)
        XCTAssertEqual(scan(nil).map(\.titleID), ["0100000000020000"], "no saved keys: the scan reads names, as before")
        XCTAssertEqual(scan((0..<32).map { UInt8($0) }).map(\.titleID), ["0100000000020000"], "a header_key that opens nothing")
    }

    func testANameWithATitleIDWinsOverTheHeaderAndAnXCIIsNotRead() throws {
        try nsp("Games/Game [0100000000030000][v0].nsp", meta: 0x0100000000040000)
        try nsp("Games/Renamed.xci", meta: 0x0100000000050000)   // an XCI's NCAs sit behind a card header: never read here
        XCTAssertEqual(scan(headerKey).map(\.titleID), ["0100000000030000"])
    }

    func testTheHeaderKeyComesFromTheKeysFile() throws {
        let keys = temporary.appendingPathComponent("prod.keys").path
        let hex = headerKey.map { String(format: "%02x", $0) }.joined()
        try "master_key_00 = \(String(repeating: "5a", count: 16))\nheader_key = \(hex)\n".write(toFile: keys, atomically: true, encoding: .utf8)
        XCTAssertEqual(PackageTitleID.headerKey(keysFile: keys), headerKey)
        try "master_key_00 = \(String(repeating: "5a", count: 16))\n".write(toFile: keys, atomically: true, encoding: .utf8)
        XCTAssertNil(PackageTitleID.headerKey(keysFile: keys))
        XCTAssertNil(PackageTitleID.headerKey(keysFile: ""))
        XCTAssertNil(PackageTitleID.headerKey(keysFile: temporary.appendingPathComponent("gone.keys").path))
    }

    /// A build of a renamed game stays the scan's entry for it instead of adding one keyed by the file's path.
    func testTheLibraryScanUsesTheSavedKeysAndABuildOfARenamedGameKeepsItsEntry() throws {
        let base = try nsp("Games/Mario.nsp", meta: 0x0100000000010000)
        let keys = temporary.appendingPathComponent("prod.keys").path
        try "header_key = \(headerKey.map { String(format: "%02x", $0) }.joined())\n".write(toFile: keys, atomically: true, encoding: .utf8)
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        library.keysFile = { keys }
        let finished = expectation(description: "scan")
        let token = library.$scanning.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        library.setFolder(temporary.appendingPathComponent("Games"))
        wait(for: [finished], timeout: 10)
        token.cancel()
        let found = try XCTUnwrap(library.games.first)
        XCTAssertEqual(library.games.map(\.titleID), ["0100000000010000"], "found by its header with the saved keys")
        let stores = LauncherStores(defaults: testDefaults)
        stores.build.updateSlot("base") { $0.paths = [base] }
        XCTAssertNil(stores.build.gameTitleID, "the name has none")
        XCTAssertEqual(library.rememberInputs(stores.build), found.id)
        XCTAssertEqual(library.games.map(\.titleID), ["0100000000010000"])
    }
}
