import XCTest
import SwiftUI
@testable import NSPortBuilder

/// prod.keys against the game files before a build (issue #63). Every key here is made up for the test.
final class KeyCheckTests: XCTestCase {
    private var temporary: URL!
    private let headerKey = (0..<32).map { UInt8(0xA0 ^ $0) }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-keycheck-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    /// An NCA header as a game's has it, encrypted with `key`: NCA3, the key generation in the newer field, a rights ID or the key area index.
    private func ncaHeader(generation: UInt8, rightsID: Bool = true, keyArea: UInt8 = 0, key: [UInt8]? = nil) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 0xC00)
        h.replaceSubrange(0x200..<0x204, with: Array("NCA3".utf8))
        h[0x206] = 2; h[0x207] = keyArea; h[0x220] = generation
        if rightsID { h[0x230] = 0x01; h[0x23F] = generation }
        return KeyCheck.xts(h, key: key ?? headerKey, encrypt: true)!
    }

    /// A PFS0 (an NSP) of the given files.
    private func pfs0(_ files: [(String, [UInt8])], name: String = "Game [0100000000010800][v65536].nsp") throws -> String {
        var names: [UInt8] = [], entries: [UInt8] = [], data: [UInt8] = []
        func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(v >> (8 * $0) & 0xFF) } }
        for (file, bytes) in files {
            entries += le(data.count, 8) + le(bytes.count, 8) + le(names.count, 4) + le(0, 4)
            names += Array(file.utf8) + [0]
            data += bytes
        }
        while names.count % 0x20 != 0 { names.append(0) }
        let out = Array("PFS0".utf8) + le(files.count, 4) + le(names.count, 4) + le(0, 4) + entries + names + data
        let path = temporary.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data(out))
        return path
    }

    private func keysFile(_ lines: [String]) throws -> String {
        let path = temporary.appendingPathComponent("prod.keys").path
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func key(_ name: String, _ byte: UInt8 = 0x5A) -> String { name + " = " + hex([UInt8](repeating: byte, count: 16)) }

    // MARK: AES-XTS

    func testXTSMatchesTheIEEE1619Vectors() {
        // Vector 1: both keys zero, data unit 0, 32 zero bytes
        XCTAssertEqual(KeyCheck.xtsSector([UInt8](repeating: 0, count: 32), dataKey: [UInt8](repeating: 0, count: 16), tweakKey: [UInt8](repeating: 0, count: 16),
                                          tweak: [UInt8](repeating: 0, count: 16), encrypt: true).map(hex),
                       "917cf69ebd68b2ec9b9fe9a3eadda692cd43d2f59598ed858c02c2652fbf922e")
        // Vector 2: keys 11… and 22…, data unit 0x3333333333 (little-endian in the standard's tweak), 32 bytes of 0x44
        let tweak: [UInt8] = [0x33, 0x33, 0x33, 0x33, 0x33] + [UInt8](repeating: 0, count: 11)
        let cipher = KeyCheck.xtsSector([UInt8](repeating: 0x44, count: 32), dataKey: [UInt8](repeating: 0x11, count: 16),
                                        tweakKey: [UInt8](repeating: 0x22, count: 16), tweak: tweak, encrypt: true)
        XCTAssertEqual(cipher.map(hex), "c454185e6a16936e39334038acef838bfb186fff7480adc4289382ecd6d394f0")
        XCTAssertEqual(KeyCheck.xtsSector(cipher!, dataKey: [UInt8](repeating: 0x11, count: 16), tweakKey: [UInt8](repeating: 0x22, count: 16),
                                          tweak: tweak, encrypt: false), [UInt8](repeating: 0x44, count: 32))
    }

    func testXTSTakesTheSectorNumberBigEndianAsNintendoDoes() throws {
        // Reference from Python's cryptography (AES-XTS with the tweak 1 and 2 as 16 big-endian bytes)
        let key = (0..<32).map { UInt8($0) }
        let plain = (0..<1024).map { UInt8($0 & 0xFF) }
        let cipher = try XCTUnwrap(KeyCheck.xts(plain, key: key, sector: 1, encrypt: true))
        XCTAssertEqual(hex(Array(cipher[0..<32])), "b3a5829f75001e33a3e33d96293537271839b0f42b2193fe6b6639f25fce3dc9")
        XCTAssertEqual(hex(Array(cipher[512..<544])), "e6c87ee3b2bf1279e40ce226185a4e4b65d1b98ecc430fc229f63e1f75705f2c")
        XCTAssertEqual(hex(Array(cipher[992...])), "82142b94e8152ad255c70f932fd60e476bf7d1e01ec121147c775085bcb4bdc9")
        XCTAssertEqual(KeyCheck.xts(cipher, key: key, sector: 1, encrypt: false), plain)
        XCTAssertNil(KeyCheck.xts(plain, key: Array(key[0..<16]), encrypt: true), "a 16-byte key is not an XTS key")
    }

    // MARK: NCA headers

    func testASyntheticHeaderDecryptsWithTheTestHeaderKey() throws {
        let plain = try XCTUnwrap(KeyCheck.xts(Array(ncaHeader(generation: 0x13)[0..<KeyCheck.headerBytes]), key: headerKey, encrypt: false))
        XCTAssertEqual(KeyCheck.needs(header: plain)?.revision, 0x12, "the larger generation field, minus one")
        XCTAssertEqual(KeyCheck.needs(header: plain)?.key, "titlekek_12")
        let area = try XCTUnwrap(KeyCheck.xts(Array(ncaHeader(generation: 0, rightsID: false, keyArea: 1)[0..<KeyCheck.headerBytes]), key: headerKey, encrypt: false))
        XCTAssertEqual(KeyCheck.needs(header: area)?.key, "key_area_key_ocean_01", "the old field (2) when the new one is 0; no rights ID: the key area")

        let nsp = try pfs0([("0123.nca", ncaHeader(generation: 0x13)), ("0123.tik", [UInt8](repeating: 0, count: 0x2C0))])
        let keys = try keysFile(["; a comment", "header_key = " + hex(headerKey), key("titlekek_12"), "", "not a key line"])
        XCTAssertEqual(KeyCheck.run(.init(keys: keys, files: ["", nsp])), .fits)
    }

    func testMissingGenerationKeysAreDetected() throws {
        let base = try pfs0([("a.nca", ncaHeader(generation: 0x0C)), ("b.cnmt.nca", ncaHeader(generation: 0x0C, rightsID: false))], name: "Game [0100000000010000].nsp")
        let update = try pfs0([("c.nca", ncaHeader(generation: 0x13)), ("d.nca", ncaHeader(generation: 0x11))])
        let keys = try keysFile(["header_key = " + hex(headerKey), key("titlekek_0b"), key("key_area_key_application_0b"), key("titlekek_10")])
        let outcome = KeyCheck.run(.init(keys: keys, files: [base, update]))
        XCTAssertEqual(outcome, .tooOld(part: .update, generation: 0x13, missing: "titlekek_12"), "the newest generation that is missing")
        let text = KeyCheck.message(outcome) { L10n.string($0, .en) }
        XCTAssertTrue(text.contains("the update") && !text.contains("generation 19") && text.contains("titlekek_12") && text.contains("19.0.0"), text)
        XCTAssertFalse(text.contains(hex(headerKey)) || text.contains("5a5a"), "never a key value")
        XCTAssertEqual(KeyCheck.run(.init(keys: keys, files: [base, ""])), .fits)

        // a dump that lists only the master keys: the extractor derives the rest from them
        let master = try keysFile(["header_key = " + hex(headerKey), key("master_key_0b"), key("master_key_10"), key("master_key_12")])
        XCTAssertEqual(KeyCheck.run(.init(keys: master, files: [base, update])), .fits)
    }

    func testAWrongHeaderKeyIsRejected() throws {
        let nsp = try pfs0([("a.nca", ncaHeader(generation: 0x13))])
        let other = (0..<32).map { UInt8(0x30 + $0) }
        let keys = try keysFile(["header_key = " + hex(other), key("titlekek_12")])
        XCTAssertEqual(KeyCheck.run(.init(keys: keys, files: [nsp])), .wrongHeaderKey(file: (nsp as NSString).lastPathComponent))
        let short = try keysFile(["header_key = " + hex(Array(headerKey[0..<16])), key("titlekek_12")])
        XCTAssertEqual(KeyCheck.run(.init(keys: short, files: [nsp])), .wrongHeaderKey(file: (nsp as NSString).lastPathComponent))
        let none = try keysFile([key("titlekek_12")])
        XCTAssertEqual(KeyCheck.run(.init(keys: none, files: [nsp])), .noHeaderKey)
        XCTAssertEqual(KeyCheck.run(.init(keys: temporary.appendingPathComponent("absent.keys").path, files: [nsp])), .unreadableKeys)
    }

    func testFormatsThatCannotBeCheckedSaySo() throws {
        var card = [UInt8](repeating: 0, count: 0x200)
        card.replaceSubrange(0x100..<0x104, with: Array("HEAD".utf8))
        let xci = temporary.appendingPathComponent("Game [0100000000010000].xci").path
        FileManager.default.createFile(atPath: xci, contents: Data(card))
        let keys = try keysFile(["header_key = " + hex(headerKey), key("titlekek_12")])
        XCTAssertEqual(KeyCheck.run(.init(keys: keys, files: [xci])), .cannotCheck(file: "Game [0100000000010000].xci"))
        // an NCZ whose first bytes are not the NCA's header is not taken as a wrong key
        let nsz = try pfs0([("a.ncz", [UInt8](repeating: 0x77, count: 0x4000))], name: "Game [0100000000010000].nsz")
        XCTAssertEqual(KeyCheck.run(.init(keys: keys, files: [nsz])), .cannotCheck(file: "Game [0100000000010000].nsz"))
        // one whose header is the NCA's own is checked like an NSP
        let good = try pfs0([("a.ncz", ncaHeader(generation: 0x13) + [UInt8](repeating: 0, count: 0x3400))], name: "Good [0100000000010000].nsz")
        XCTAssertEqual(KeyCheck.run(.init(keys: keys, files: [good])), .fits)
        // a problem with the keys outranks a file that could not be checked
        let old = try pfs0([("a.nca", ncaHeader(generation: 0x13))], name: "Update [0100000000010800].nsp")
        let olderKeys = try keysFile(["header_key = " + hex(headerKey)])
        XCTAssertEqual(KeyCheck.run(.init(keys: olderKeys, files: [xci, old])), .tooOld(part: .update, generation: 0x13, missing: "titlekek_12"))
    }

    func testNoLineUntilTheBaseGameAndTheKeysAreChosen() async {
        let none = await KeyCheck.runDetached(.init(keys: "", files: ["/x.nsp"]))
        XCTAssertNil(none)
        let noBase = await KeyCheck.runDetached(.init(keys: "/prod.keys", files: ["", "/update.nsp"]))
        XCTAssertNil(noBase)
    }

    func testEveryMessageHasBothLanguages() {
        let outcomes: [KeyCheck.Outcome] = [.fits, .unreadableKeys, .noHeaderKey, .wrongHeaderKey(file: "a.nsp"), .cannotCheck(file: "a.xci"),
                                            .tooOld(part: .base, generation: 0x13, missing: "titlekek_12"), .tooOld(part: .dlc, generation: 0x30, missing: "titlekek_2f")]
        for lang in [Lang.zh, .en] {
            for o in outcomes {
                let text = KeyCheck.message(o) { L10n.string($0, lang) }
                XCTAssertFalse(text.contains("keycheck."), text)
            }
        }
        XCTAssertTrue(KeyCheck.message(.tooOld(part: .base, generation: 0x13, missing: "titlekek_12")) { L10n.string($0, .zh) }.contains("titlekek_12"))
        XCTAssertFalse(KeyCheck.message(.tooOld(part: .dlc, generation: 0x30, missing: "titlekek_2f")) { L10n.string($0, .en) }.contains("firmware"),
                       "no firmware named past the table")
    }

    // MARK: Visual QA (matched by --filter testRenderLauncherForVisualQA)

    @MainActor func testRenderLauncherForVisualQAKeyCheck() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let oldOutput = UserDefaults.standard.object(forKey: "buildOutputDirectory")
        defer { UserDefaults.standard.set(oldOutput, forKey: "buildOutputDirectory") }
        let model = BuildModel()
        model.lang = CaptureLanguage.current(.en)
        model.outDir = temporary.path
        model.depsChecked = true
        model.deps = [BuildModel.Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])]
        let library = GameLibrary(file: temporary.appendingPathComponent("preview.json"))
        let base = try pfs0([("a.nca", ncaHeader(generation: 0x0C))], name: "Metroid Dread [010093801237C000].nsp")
        let update = try pfs0([("b.nca", ncaHeader(generation: 0x13))], name: "Metroid Dread [010093801237C800][v327680].nsp")
        func capture(_ name: String, keys: [String], withUpdate: Bool) throws {
            model.slots[0].paths = [base]
            model.slots[1].paths = withUpdate ? [update] : []
            model.slots[3].paths = [try keysFile(keys)]
            let host = NSHostingView(rootView: ContentView(model: model, library: library, initialPage: .builds, performStartupChecks: false))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 1024), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        try capture("build-keys-fit", keys: ["header_key = " + hex(headerKey), key("titlekek_0b")], withUpdate: false)
        try capture("build-keys-old", keys: ["header_key = " + hex(headerKey), key("titlekek_0b")], withUpdate: true)
    }
}
