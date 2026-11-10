import XCTest
@testable import NXCore

final class PostBuildCleanupTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("nxnative-post-cleanup-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ rel: String, _ text: String = "payload") throws -> String {
        let url = root.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    func testPlaceImageMovesSourceReplacesExistingAndRemovesSourceArtifacts() throws {
        let src = try write("work/extract/v65536/RomFS.img", "new-image-bytes")
        _ = try write("work/extract/v65536/RomFS.img.id", "{\"title\":\"0100535012974000\"}\n")
        _ = try write("work/extract/v65536/RomFS.img.formats", "astc\n")
        let dst = try write("games/0100535012974000/romfs.img", "old")
        _ = try write("games/0100535012974000/romfs.img.id", "old-id")

        let placement = try PostBuildCleanup.placeImage(from: src, to: dst)
        XCTAssertEqual(placement, .moved)
        XCTAssertEqual(try String(contentsOfFile: dst, encoding: .utf8), "new-image-bytes")
        XCTAssertEqual(try String(contentsOfFile: dst + ".id", encoding: .utf8), "{\"title\":\"0100535012974000\"}\n")
        XCTAssertFalse(fm.fileExists(atPath: src))
        XCTAssertFalse(fm.fileExists(atPath: src + ".id"))
        XCTAssertFalse(fm.fileExists(atPath: src + ".formats"))
    }

    func testPlaceImageReusesMatchingDestinationAndStillRemovesSource() throws {
        let src = try write("work/extract/v0/RomFS.img", "same-size")
        _ = try write("work/extract/v0/RomFS.img.id", "{\"version\":\"v0\"}\n")
        let dst = try write("games/0100535012974000/romfs.img", "same-size")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: src)
        try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: dst)

        let placement = try PostBuildCleanup.placeImage(from: src, to: dst)
        XCTAssertEqual(placement, .reused)
        XCTAssertEqual(try String(contentsOfFile: dst + ".id", encoding: .utf8), "{\"version\":\"v0\"}\n")
        XCTAssertFalse(fm.fileExists(atPath: src))
        XCTAssertFalse(fm.fileExists(atPath: src + ".id"))
    }

    func testPlaceImageFailureLeavesExistingDestinationIntactAndNoPartialFile() throws {
        let dst = try write("games/0100535012974000/romfs.img", "intact")
        let missing = root.appendingPathComponent("work/extract/v0/RomFS.img").path
        XCTAssertThrowsError(try PostBuildCleanup.placeImage(from: missing, to: dst))
        XCTAssertEqual(try String(contentsOfFile: dst, encoding: .utf8), "intact")
        let siblings = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("games/0100535012974000").path)
        XCTAssertEqual(siblings, ["romfs.img"])
    }

    func testPlaceAddOnContentMovesDirectoryReplacesOldAndRemovesKey() throws {
        _ = try write("work/aoc/0.img", "dlc0")
        _ = try write("work/aoc/1.img", "dlc1")
        _ = try write("work/aoc.key", "fingerprint")
        _ = try write("games/id/aoc/stale.img", "stale")

        let count = PostBuildCleanup.placeAddOnContent(
            from: root.appendingPathComponent("work/aoc").path,
            to: root.appendingPathComponent("games/id/aoc").path
        )
        XCTAssertEqual(count, 2)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("work/aoc").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("work/aoc.key").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("games/id/aoc/stale.img").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("games/id/aoc/0.img").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("games/id/aoc/1.img").path))
    }

    func testCleanWorkDirectoryReclaimsIntermediatesWhileKeepingIncrementalCaches() throws {
        let work = root.appendingPathComponent("0100535012974000_build").path
        for rel in [
            "nsp/base.nsp",
            "nsp.partial/tmp.nsp",
            "extract/v0/RomFS.img",
            "extract/v0/RomFS.img.id",
            "extract/v0/RomFS.img.formats",
            "extract/v0/ExeFS/main",
            "extract/v65536/RomFS.img",
            "extract/v65536/ExeFS/main",
            "extract/v65536/control.nacp",
            "extract/v65536/html/index.html",
            "extract/v65536.partial/RomFS.img",
            "aoc/0.img",
            "aoc.key",
            "pso/mac/game.mtl4a",
            "pso/mac-work/key.applegpu_g15g",
            "pso/mac-work/batches.applegpu_g15g/0/batch.mtl4a",
            "ipa/build/ios/pso/bundle/game.mtl4a",
            "ipa/build/ios/pso/work/key.applegpu_g17p",
            "ipa/build/ios/pso/work/batches.applegpu_g17p/0/batch.mtl4a",
            "ipa/build/ios/pkg/dd/Build/Products/Release-iphoneos/DmGame0100535012974000.framework/DmGame0100535012974000",
            "ipa/build/ios/pkg/dd/Build/Intermediates.noindex/DmIOS.build/main.o",
            "patched_v65536/main.patched.bin",
            "shader/cache/b-f3ceca86cac5/lib.metallib",
            "shell-framework/DmGame0100535012974000.framework/game.manifest.json",
            "logs/extract_v0.log",
        ] {
            _ = try write("0100535012974000_build/" + rel)
        }

        PostBuildCleanup.cleanWorkDirectory(work, removeExtractedRomFS: true, removeShellFramework: false)

        for gone in [
            "nsp",
            "nsp.partial",
            "extract/v0/RomFS.img",
            "extract/v0/RomFS.img.id",
            "extract/v0/RomFS.img.formats",
            "extract/v65536/RomFS.img",
            "extract/v65536.partial",
            "aoc",
            "aoc.key",
            "pso/mac-work/batches.applegpu_g15g",
            "ipa/build/ios/pso/work/batches.applegpu_g17p",
            "ipa/build/ios/pkg/dd/Build/Products",
        ] {
            XCTAssertFalse(fm.fileExists(atPath: work + "/" + gone), gone)
        }

        for kept in [
            "extract/v0/ExeFS/main",
            "extract/v65536/ExeFS/main",
            "extract/v65536/control.nacp",
            "extract/v65536/html/index.html",
            "pso/mac/game.mtl4a",
            "pso/mac-work/key.applegpu_g15g",
            "ipa/build/ios/pso/bundle/game.mtl4a",
            "ipa/build/ios/pso/work/key.applegpu_g17p",
            "ipa/build/ios/pkg/dd/Build/Intermediates.noindex/DmIOS.build/main.o",
            "patched_v65536/main.patched.bin",
            "shader/cache/b-f3ceca86cac5/lib.metallib",
            "shell-framework/DmGame0100535012974000.framework/game.manifest.json",
            "logs/extract_v0.log",
        ] {
            XCTAssertTrue(fm.fileExists(atPath: work + "/" + kept), kept)
        }
    }

    func testCleanShellExportProductsKeepsSignedInstallDerivedDataAndMirroredFrameworks() throws {
        let shellRoot = root.appendingPathComponent("NX2Apple-shell").path
        _ = try write("NX2Apple-shell/derived-data/Build/Products/Release-iphoneos/DmShell.app/Info.plist")
        _ = try write("NX2Apple-shell/derived-data/Build/Products/Release-iphoneos/DmShell.app/embedded.mobileprovision")
        _ = try write("NX2Apple-shell/export/derived-data/Build/Products/Release-iphoneos/DmShell.app/Info.plist")
        _ = try write("NX2Apple-shell/export/derived-data/Build/Intermediates.noindex/DmShell.build/main.o")
        let mirrored = try write("NX2Apple-shell/frameworks/DmGame0100535012974000.framework/game.manifest.json")
        let staged = try write("work/shell-framework/DmGame0100535012974000.framework/game.manifest.json")

        PostBuildCleanup.cleanShellExportProducts(root: shellRoot)
        XCTAssertFalse(fm.fileExists(atPath: shellRoot + "/export/derived-data/Build/Products"))
        XCTAssertTrue(fm.fileExists(atPath: shellRoot + "/export/derived-data/Build/Intermediates.noindex/DmShell.build/main.o"))
        XCTAssertTrue(fm.fileExists(atPath: shellRoot + "/derived-data/Build/Products/Release-iphoneos/DmShell.app/embedded.mobileprovision"))

        PostBuildCleanup.cleanBuiltFrameworkContainer((mirrored as NSString).deletingLastPathComponent)
        XCTAssertTrue(fm.fileExists(atPath: mirrored), "mirrored framework under <shellRoot>/frameworks must never be removed")

        PostBuildCleanup.cleanBuiltFrameworkContainer((staged as NSString).deletingLastPathComponent)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("work/shell-framework").path))
    }
}
