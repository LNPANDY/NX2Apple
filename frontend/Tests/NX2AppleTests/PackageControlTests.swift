import XCTest
@testable import NX2Apple
@testable import NXCore

/// LNPANDY/NX2Apple#895: the control data of a game packed before `DMTitleNames`, read from its package without the engine's
/// extractor. Synthetic packages (`ControlPackageFixture`), made-up keys.
final class PackageControlTests: XCTestCase {
    private typealias F = ControlPackageFixture
    private var temporary: URL!
    private let titleID: UInt64 = 0x0100_8D70_1643_8000
    private let rightsID: [UInt8] = [0x01, 0x00, 0x8D, 0x70, 0x16, 0x43, 0x80, 0x00] + [UInt8](repeating: 0, count: 7) + [0x02]
    private let names: [Int: String] = [0: "13 Sentinels", 12: "13기병방위권", 14: "十三机兵防卫圈"]

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-control-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func write(_ bytes: [UInt8], _ name: String) throws -> String {
        let url = temporary.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url.path
    }

    private func read(_ path: String, keys: [String: [UInt8]] = F.keys, titleID: UInt64? = nil) -> [String: String]? {
        PackageControl.read(package: path, keys: keys, titleID: titleID ?? self.titleID).map { GameTitleNames.names(nacp: $0) }
    }

    private var expected: [String: String] { ["en-US": "13 Sentinels", "ko": "13기병방위권", "zh-Hans": "十三机兵防卫圈"] }

    /// An NSP: the Control NCA's key is the title key of the common ticket for its rights ID, its section AES-CTR.
    func testNSPWithACommonTicket() throws {
        let rid = rightsID.map { String(format: "%02x", $0) }.joined()
        let nsp = try write(F.partition([("aaaa.cnmt.nca", [UInt8](repeating: 1, count: 0x10)), ("0000.tik", F.ticket(rightsID: Array(rightsID.reversed()))),
                                         (rid + ".tik", F.ticket(rightsID: rightsID)), ("cccc.nca", F.controlNCA(programID: titleID, nacp: F.nacp(names), rightsID: rightsID))]),
                            "Game.nsp")
        XCTAssertEqual(read(nsp), expected)
        XCTAssertEqual(read(nsp, titleID: 0x0100_0000_0001_0000), expected, "a package whose Control NCA has another ID still names its game")
        let keysFile = try write(Array(F.keysFile().utf8), "prod.keys")
        XCTAssertEqual(PackageControl.read(package: nsp, keysFile: keysFile, titleID: titleID).map { GameTitleNames.names(nacp: $0) }, expected)
    }

    /// An XCI (with and without the key area in front): the NCAs are in the secure partition and carry their key in the key area.
    func testXCIWithTheKeyArea() throws {
        for keyArea in [false, true] {
            let xci = try write(F.xci([("cccc.nca", F.controlNCA(programID: titleID, nacp: F.nacp(names), rightsID: nil))], keyArea: keyArea), "Game\(keyArea).xci")
            XCTAssertEqual(read(xci), expected)
        }
    }

    /// A cartridge with two games: the Control NCA of the game asked for.
    func testTheControlDataOfTheTitleAskedFor() throws {
        let other: UInt64 = 0x0100_0000_0001_0000
        let xci = try write(F.xci([("1111.nca", F.controlNCA(programID: other, nacp: F.nacp([0: "Other"]), rightsID: nil)),
                                   ("2222.nca", F.controlNCA(programID: titleID, nacp: F.nacp(names), rightsID: nil))]), "Two.xci")
        XCTAssertEqual(read(xci), expected)
        XCTAssertEqual(read(xci, titleID: other), ["en-US": "Other"])
    }

    /// Keys that list only master_key_XX and the sources: titlekek_XX and the key area key are derived as LibHac derives them.
    func testDerivedKeys() throws {
        let master = (0..<16).map { UInt8(0x90 &+ $0) }, kekSource = (0..<16).map { UInt8(0xB0 &+ $0) }
        // titlekek_02 = AES-ECB-decrypt(titlekek_source, master_key_02): the source is the titlekek encrypted under the master key
        let titlekekSource = KeyCheck.ecb(F.titlekek, key: master, encrypt: true)!
        // key_area_key = dec(key_source, dec(area_source, dec(kek_source, master))): the sources are chosen to give the fixture's key
        let kek = KeyCheck.ecb(kekSource, key: master, encrypt: false)!
        let wantedSourceKek = (0..<16).map { UInt8(0xD0 &+ $0) }
        let keySourceForArea = KeyCheck.ecb(F.keyAreaKey, key: wantedSourceKek, encrypt: true)!   // dec(this, sourceKek) = key area key
        let areaSource = KeyCheck.ecb(wantedSourceKek, key: kek, encrypt: true)!                   // dec(this, kek) = sourceKek
        let keys = ["header_key": F.headerKey, "master_key_02": master, "titlekek_source": titlekekSource, "aes_kek_generation_source": kekSource,
                    "aes_key_generation_source": keySourceForArea, "key_area_key_application_source": areaSource]
        let nsp = try write(F.partition([("t.tik", F.ticket(rightsID: rightsID)), ("c.nca", F.controlNCA(programID: titleID, nacp: F.nacp(names), rightsID: rightsID))]), "Derived.nsp")
        let xci = try write(F.xci([("c.nca", F.controlNCA(programID: titleID, nacp: F.nacp(names), rightsID: nil))]), "Derived.xci")
        XCTAssertEqual(read(nsp, keys: keys), expected)
        XCTAssertEqual(read(xci, keys: keys), expected)
        XCTAssertNil(read(nsp, keys: ["header_key": F.headerKey, "master_key_02": master]), "no source to derive from")
    }

    /// A section without encryption is read as it is.
    func testUnencryptedSection() throws {
        let nsp = try write(F.partition([("c.nca", F.controlNCA(programID: titleID, nacp: F.nacp(names), rightsID: nil, encrypted: false))]), "Plain.nsp")
        XCTAssertEqual(read(nsp), expected)
    }

    /// Nothing to read: another header_key, no ticket, a personalized ticket, keys too old, no Control NCA, not a package.
    func testNothingToRead() throws {
        let nca = F.controlNCA(programID: titleID, nacp: F.nacp(names), rightsID: rightsID)
        let nsp = try write(F.partition([("t.tik", F.ticket(rightsID: rightsID)), ("c.nca", nca)]), "Game.nsp")
        var wrong = F.keys; wrong["header_key"] = (0..<32).map { UInt8($0) }
        XCTAssertNil(read(nsp, keys: wrong))
        var old = F.keys; old["titlekek_02"] = nil
        XCTAssertNil(read(nsp, keys: old))
        XCTAssertNil(read(try write(F.partition([("c.nca", nca)]), "NoTicket.nsp")))
        XCTAssertNil(read(try write(F.partition([("t.tik", F.ticket(rightsID: rightsID, type: 1)), ("c.nca", nca)]), "Personal.nsp")))
        XCTAssertNil(read(try write(F.partition([("a.cnmt.nca", [UInt8](repeating: 0, count: 0x20))]), "Meta.nsp")))
        XCTAssertNil(read(try write(Array("not a package".utf8), "Text.nsp")))
        XCTAssertNil(PackageControl.read(package: nsp, keysFile: temporary.appendingPathComponent("missing.keys").path, titleID: titleID))
    }

    /// Malformed 64-bit offsets in a package, NCA header or RomFS header return nil instead of trapping on overflow.
    func testOverflowingOffsetsAndShortKeySourcesReturnNil() throws {
        var xci = F.xci([("c.nca", F.controlNCA(programID: titleID, nacp: F.nacp(names), rightsID: nil))], keyArea: true)
        xci.replaceSubrange((0x1000 + 0x130)..<(0x1000 + 0x138), with: F.le(UInt64.max, 8))
        XCTAssertNil(read(try write(xci, "OverflowCard.xci")))

        var pfs0 = F.partition([("c.nca", F.controlNCA(programID: titleID, nacp: F.nacp(names), rightsID: nil, encrypted: false))])
        pfs0.replaceSubrange(0x10..<0x18, with: F.le(UInt64.max, 8))
        XCTAssertNil(read(try write(pfs0, "OverflowEntry.nsp")))

        var nca = F.controlNCA(programID: titleID, nacp: F.nacp(names), rightsID: nil, encrypted: false)
        // Corrupt the unencrypted RomFS dirMeta offset (at 0xC00 + 0x200 + 0x18) to UInt64.max.
        nca.replaceSubrange((0xE00 + 0x18)..<(0xE00 + 0x20), with: F.le(UInt64.max, 8))
        XCTAssertNil(read(try write(F.partition([("c.nca", nca)]), "OverflowRomFS.nsp")))

        var ncaFileOff = F.controlNCA(programID: titleID, nacp: F.nacp(names), rightsID: nil, encrypted: false)
        // Corrupt the second RomFS file entry's data offset to UInt64.max.
        let controlName = Array("control.nacp".utf8)
        if let range = ncaFileOff.firstRange(of: controlName) {
            let entryStart = range.lowerBound - 0x20
            ncaFileOff.replaceSubrange((entryStart + 8)..<(entryStart + 16), with: F.le(UInt64.max, 8))
        }
        XCTAssertNil(read(try write(F.partition([("c.nca", ncaFileOff)]), "OverflowFileData.nsp")))

        let shortKeys: [String: [UInt8]] = [
            "header_key": F.headerKey,
            "master_key_02": [UInt8](repeating: 1, count: 16),
            "key_area_key_application_source": [UInt8](repeating: 2, count: 16),
            "aes_kek_generation_source": [1, 2, 3],
            "aes_key_generation_source": [UInt8](repeating: 4, count: 16),
        ]
        let validXCI = try write(F.xci([("c.nca", F.controlNCA(programID: titleID, nacp: F.nacp(names), rightsID: nil))]), "ShortSource.xci")
        XCTAssertNil(read(validXCI, keys: shortKeys))
    }
}
