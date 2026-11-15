import Darwin
import Foundation
import XCTest
@testable import NXCore

final class RomfsTrailerPipelineTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private let titleA = "0100111100001111"
    private let titleB = "0100222200002222"

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("nxnative-trailer-pipe-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func path(_ rel: String) -> String { root.appendingPathComponent(rel).path }

    private func write(_ rel: String, _ text: String = "x") throws -> String {
        let p = path(rel)
        try fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: p), options: .atomic)
        return p
    }

    private func hardLinkCount(_ filePath: String) -> UInt16 {
        var sb = Darwin.stat()
        guard Darwin.lstat(filePath, &sb) == 0 else { return 0 }
        return sb.st_nlink
    }

    private func makeRomfsBase(payloadByte: UInt8 = 0x33, size: Int = 64) -> Data {
        func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }
        let headerSize = 32
        let ioff = UInt64(headerSize + 16)
        let isz = UInt64(max(16, size - headerSize - 16))
        var out = Data("DMROMFS1".utf8)
        out.append(contentsOf: le64(ioff))
        out.append(contentsOf: le64(isz))
        out.append(contentsOf: le64(0))
        out.append(Data(repeating: 0x11, count: 16))
        out.append(Data(repeating: payloadByte, count: Int(isz)))
        return out
    }

    private func makeRomfsWithTrailer(base: Data, mslPayload: [UInt8], chain: String = "b-3f9a2c", gfxAPI: UInt8 = 1) -> Data {
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
        func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }

        let baseEnd = UInt64(base.count)
        let mslOffset = (baseEnd + 16_383) & ~16_383
        var out = base
        out.append(Data(count: Int(mslOffset - baseEnd)))
        out.append(contentsOf: mslPayload)
        let alignedFooter = ((UInt64(out.count)) + 7) & ~7
        out.append(Data(count: Int(alignedFooter - UInt64(out.count))))

        let chainBytes = Array(chain.utf8.prefix(24))
        var footer = [UInt8](repeating: 0, count: 64)
        let magic = Array("DMMSLTR1".utf8)
        footer.replaceSubrange(0..<8, with: magic)
        footer.replaceSubrange(8..<12, with: le32(1))
        footer[12] = gfxAPI
        footer[13] = 0
        footer.replaceSubrange(14..<16, with: le16(UInt16(chainBytes.count)))
        footer.replaceSubrange(16..<24, with: le64(baseEnd))
        footer.replaceSubrange(24..<32, with: le64(mslOffset))
        footer.replaceSubrange(32..<40, with: le64(UInt64(mslPayload.count)))
        footer.replaceSubrange(40..<(40 + chainBytes.count), with: chainBytes)
        out.append(contentsOf: footer)
        return out
    }

    func testSanitizeGameNameAndCollisionSuffixes() throws {
        XCTAssertEqual(RomFSArchive.sanitizeGameName("  Zelda: Tears / Wild?*  ", fallback: titleA), "Zelda Tears Wild")
        XCTAssertEqual(RomFSArchive.sanitizeGameName("...   ..", fallback: titleA), titleA)
        XCTAssertEqual(RomFSArchive.sanitizeGameName("<>\"\\|", fallback: titleA), titleA)

        let gamesRoot = path("out/games")
        try fm.createDirectory(atPath: gamesRoot, withIntermediateDirectories: true)

        XCTAssertEqual(RomFSArchive.archiveDirectoryName(gameName: "Shared Name", titleID: titleA, gamesRoot: gamesRoot), "Shared Name")
        _ = try write("out/games/Shared Name/.titleid", titleA + "\n")
        XCTAssertEqual(RomFSArchive.archiveDirectoryName(gameName: "Shared Name", titleID: titleA, gamesRoot: gamesRoot), "Shared Name")
        XCTAssertEqual(RomFSArchive.archiveDirectoryName(gameName: "Shared Name", titleID: titleB, gamesRoot: gamesRoot), "Shared Name (\(titleB))")
    }

    func testHardlinkUnsharingBreaksSharedLinksBeforeInPlaceTrailerMutation() throws {
        let base = makeRomfsBase()
        let msl = [UInt8](repeating: 0x42, count: 64)
        let srcData = makeRomfsWithTrailer(base: base, mslPayload: msl, chain: "b-new001")
        let srcPath = path("archive/Hero/Hero.img")
        let peerPath = path("cache/peer.img")
        let dstPath = path("usb/Hero/Hero.img")

        try fm.createDirectory(atPath: (srcPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: (peerPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: (dstPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        try srcData.write(to: URL(fileURLWithPath: srcPath))
        let oldData = makeRomfsWithTrailer(base: base, mslPayload: [UInt8](repeating: 0x21, count: 64), chain: "b-old001")
        try oldData.write(to: URL(fileURLWithPath: dstPath))
        XCTAssertEqual(link(dstPath, peerPath), 0)
        XCTAssertGreaterThan(hardLinkCount(dstPath), 1)

        try DriveCopy.copy(archive: path("archive/Hero"), files: ["Hero.img": Int64(srcData.count)], to: path("usb/Hero"),
                           name: "Hero", titleID: titleA, progress: { _, _ in })

        XCTAssertEqual(hardLinkCount(dstPath), 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dstPath)), srcData)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: peerPath)), oldData, "peer hardlink must never be mutated")
    }

    func testPartialTrailerOverwriteCancelTruncatesToBaseSizeAndInspectLeavesLegacyUntouched() throws {
        let base = makeRomfsBase()
        // Exceed 4096-byte minimum step so multiple chunks run inside overwriteTrailer.
        let largePayload = [UInt8](repeating: 0x55, count: 12 * 1024)
        let srcData = makeRomfsWithTrailer(base: base, mslPayload: largePayload, chain: "b-cur111")
        let oldData = makeRomfsWithTrailer(base: base, mslPayload: [UInt8](repeating: 0x12, count: 64), chain: "b-old111")

        let archDir = path("out/games/Mario")
        let srcImg = archDir + "/Mario.img"
        _ = try write("out/games/Mario/.titleid", titleA + "\n")
        try srcData.write(to: URL(fileURLWithPath: srcImg))

        let usbRoot = path("usb")
        let legacyDir = usbRoot + "/\(titleA)"
        let legacyImg = legacyDir + "/romfs.img"
        try fm.createDirectory(atPath: legacyDir, withIntermediateDirectories: true)
        try oldData.write(to: URL(fileURLWithPath: legacyImg))

        // inspectTransfer must report partial trailer delta without renaming or modifying legacy folders.
        let inspection = DriveCopy.inspectTransfer(archive: archDir, name: "Mario", titleID: titleA, inFolder: usbRoot)
        XCTAssertEqual(inspection.destination, usbRoot + "/Mario")
        XCTAssertLessThan(inspection.bytesToCopy, Int64(srcData.count))
        XCTAssertTrue(fm.fileExists(atPath: legacyImg))
        XCTAssertFalse(fm.fileExists(atPath: usbRoot + "/Mario"))

        // Upgrade happens on actual copy setup; interrupt after first 4 KiB chunk -> truncates to exact base.count.
        let upgradedDest = DriveCopy.upgradeLegacyFolder(folder: usbRoot, name: "Mario", titleID: titleA)
        XCTAssertEqual(upgradedDest, usbRoot + "/Mario")
        let targetImg = upgradedDest + "/Mario.img"
        XCTAssertTrue(fm.fileExists(atPath: targetImg))

        var cancelNow = false
        let transfer = DriveCopy.transferFiles(archive: archDir, name: "Mario", titleID: titleA, destination: upgradedDest)
        XCTAssertThrowsError(try DriveCopy.copy(archive: archDir, files: transfer.sizes, origins: transfer.origins,
                                                to: upgradedDest, name: "Mario", titleID: titleA, chunk: 4096,
                                                progress: { done, _ in if done > 0 { cancelNow = true } },
                                                cancelled: { cancelNow })) { err in
            XCTAssertEqual(err as? DriveCopy.CopyError, .cancelled)
        }

        let afterAbort = try Data(contentsOf: URL(fileURLWithPath: targetImg))
        XCTAssertEqual(afterAbort.count, base.count, "interrupted trailer overwrite must ftruncate back to baseSize")
        XCTAssertEqual(afterAbort, base)

        // Resuming copy completes full trailer injection from base-sized image.
        let deltaAfterAbort = DriveCopy.compareImages(source: srcImg, destination: targetImg)
        guard case .partialOverwrite(let baseSz, _, _) = deltaAfterAbort else {
            return XCTFail("expected partialOverwrite after abort truncation, got \(deltaAfterAbort)")
        }
        XCTAssertEqual(baseSz, UInt64(base.count))

        try DriveCopy.copy(archive: archDir, files: transfer.sizes, origins: transfer.origins,
                           to: upgradedDest, name: "Mario", titleID: titleA, chunk: 4096, progress: { _, _ in })
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: targetImg)), srcData)
        XCTAssertEqual(DriveCopy.compareImages(source: srcImg, destination: targetImg), .identical)
    }
}
