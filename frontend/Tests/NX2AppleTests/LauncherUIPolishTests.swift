import AppKit
import CoreText
import CryptoKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
import NXModel

@MainActor final class LauncherUIPolishTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let titleID = "01008D7016438000"

    override func setUpWithError() throws {
        TitleNameAttempts.shared.reset()
        SupportedCovers.Tried.shared.ids = []
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nx-ui-polish-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    // MARK: - Helpers

    private func makeNACP(titles: [Int: String] = [0: "Sample Game", 14: "示例游戏"], version: String?) -> [UInt8] {
        var bytes = ControlPackageFixture.nacp(titles)
        if let version {
            let vBytes = Array(version.utf8.prefix(15))
            bytes.replaceSubrange(0x3060..<(0x3060 + vBytes.count), with: vBytes)
        }
        return bytes
    }

    private func write(_ data: Data, _ relative: String) throws -> URL {
        let url = temporary.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// Builds a valid v1 `.nup` container matching `engine/scripts/pack_nup.py` (`SUPER`, `TOC`, `PKG`, `TLV` with `T_NACP = 2`).
    private func makeNupContainer(packages: [(kind: UInt8, version: UInt32, nacp: [UInt8])]) -> Data {
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
        func pad16(_ b: [UInt8]) -> [UInt8] { b + [UInt8](repeating: 0, count: (16 - b.count % 16) % 16) }

        let npkg = UInt32(packages.count)
        let tocHeaderSize = 0x30
        let pkgTableSize = Int(npkg) * 0x40
        let dirEntrySize = 0x18   // 1 empty root dir
        let rawTocLen = tocHeaderSize + pkgTableSize + dirEntrySize
        let blobOffset = UInt64(0x80 + ((rawTocLen + 15) & ~15))

        var blob: [UInt8] = []
        var pkgRecords: [UInt8] = []
        for pkg in packages {
            let tlv = le16(2) + le16(0) + le32(UInt32(pkg.nacp.count)) + pkg.nacp
            let metaOff = blobOffset + UInt64(blob.count)
            let metaSize = UInt32(tlv.count)
            blob += pad16(tlv)
            // PKG = '<QIIIIBBHIQI20x' (64 bytes)
            var rec: [UInt8] = []
            rec += le64(UInt64(titleID, radix: 16)!)
            rec += le32(0)              // root dir
            rec += le32(0xFFFF_FFFF)    // exefs
            rec += le32(0xFFFF_FFFF)    // romfs
            rec += le32(pkg.version)    // version
            rec += [pkg.kind, 0]        // kind, flags
            rec += le16(0)              // r1
            rec += le32(0)              // r2
            rec += le64(metaOff)        // meta_off (offset 32)
            rec += le32(metaSize)       // meta_size (offset 40)
            rec += [UInt8](repeating: 0, count: 20)
            assert(rec.count == 0x40)
            pkgRecords += rec
        }

        var toc: [UInt8] = []
        toc += [0x54, 0x4F, 0x43, 0x01]   // "TOC\x01"
        toc += le32(npkg)
        toc += le64(1)                    // ndirs = 1
        toc += le64(0)                    // nfiles = 0
        toc += le64(UInt64(rawTocLen))    // pool_off
        toc += le64(0)                    // pool_size
        toc += le64(0)                    // reserved
        assert(toc.count == 0x30)
        toc += pkgRecords
        toc += [UInt8](repeating: 0, count: 0x18)   // 1 empty DIR
        let tocPadded = pad16(toc)
        let tocSha = Array(SHA256.hash(data: Data(toc)))
        let totalSize = blobOffset + UInt64(blob.count)

        // SUPER = '<4sHHQQ32sQQII16s32s' (0x80 = 128 bytes)
        var sb: [UInt8] = []
        sb += [0x4E, 0x55, 0x50, 0x01]    // "NUP\x01"
        sb += le16(0x80)                  // hsize
        sb += le16(0)                     // reserved
        sb += le64(0x80)                  // toc_off
        sb += le64(UInt64(toc.count))     // toc_size
        sb += tocSha                      // toc_sha (32)
        sb += le64(blobOffset)            // blob (offset 56)
        sb += le64(totalSize)             // fsize (offset 64)
        sb += le32(npkg)                  // npkg (offset 72)
        sb += le32(0)                     // flags (offset 76)
        sb += [UInt8](repeating: 0, count: 48)
        assert(sb.count == 0x80)
        return Data(sb + tocPadded + blob)
    }

    private func flushTitleNameLookups() {
        let drained = expectation(description: "title lookup queue drained")
        TitleNameAttempts.queue.async {
            DispatchQueue.main.async { drained.fulfill() }
        }
        wait(for: [drained], timeout: 5)
    }

    private func texts(in view: NSView) -> Set<String> {
        var labels: Set<String> = []
        func visit(_ node: NSObject) {
            for selector in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                let sel = NSSelectorFromString(selector)
                if node.responds(to: sel), let value = node.perform(sel)?.takeUnretainedValue() as? String { labels.insert(value) }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if node.responds(to: children), let next = node.perform(children)?.takeUnretainedValue() as? [NSObject] { next.forEach(visit) }
        }
        visit(view.window ?? view)
        return labels
    }

    // MARK: - 1. Unbuilt Game Version Extraction & Hero Display

    func testNACPDisplayVersionValidationAndBoundsSafety() {
        XCTAssertNil(GameTitleNames.displayVersion(nacp: Data()))
        XCTAssertNil(GameTitleNames.displayVersion(nacp: Data(repeating: 0, count: 0x306F)), "Truncated NACP must return nil")
        XCTAssertNil(GameTitleNames.displayVersion(nacp: Data(makeNACP(version: nil))))
        XCTAssertNil(GameTitleNames.displayVersion(nacp: Data(makeNACP(version: "v0"))), "Non-digit display version must be rejected")
        XCTAssertNil(GameTitleNames.displayVersion(nacp: Data(makeNACP(version: "1.0\u{0007}"))))
        XCTAssertEqual(GameTitleNames.displayVersion(nacp: Data(makeNACP(version: "1.0.0"))), "1.0.0")
        XCTAssertEqual(GameTitleNames.displayVersion(nacp: Data(makeNACP(version: "1.0.0.2"))), "1.0.0.2")
    }

    func testUnbuiltSourceVersionPrefersUpdateOverBaseAndReadsNupAndRejectsCorruptOffsets() throws {
        typealias F = ControlPackageFixture
        let id = UInt64(titleID, radix: 16)!
        let keys = try write(Data(F.keysFile().utf8), "keys/prod.keys")
        let baseNSP = try write(Data(F.partition([("base.nca", F.controlNCA(programID: id, nacp: makeNACP(version: "1.0.0"), rightsID: nil))])),
                                "games/Game [01008D7016438000][v0].nsp")
        let updNSP = try write(Data(F.partition([("upd.nca", F.controlNCA(programID: id | 0x800, nacp: makeNACP(version: "2.1.0"), rightsID: nil))])),
                               "games/Game [UPD][v131072].nsp")

        var game = LibraryGame(titleID: titleID, name: "Sample Game")
        game.inputs = ["base": [baseNSP.path]]
        XCTAssertEqual(TitleNameLookup.sourceVersion(for: game, fallbackKeys: keys.path), "1.0.0")

        // Adding an update package upgrades the extracted version.
        game.inputs["update"] = [updNSP.path]
        XCTAssertEqual(TitleNameLookup.sourceVersion(for: game, fallbackKeys: keys.path), "2.1.0")

        // Multi-NCA XCI containing both Base and Update Control NCAs picks the Update Control NCA.
        let comboXCI = try write(Data(F.xci([
            ("base.nca", F.controlNCA(programID: id, nacp: makeNACP(version: "1.0.0"), rightsID: nil)),
            ("upd.nca", F.controlNCA(programID: id | 0x800, nacp: makeNACP(version: "3.0.4"), rightsID: nil)),
        ])), "games/Combo.xci")
        var comboGame = LibraryGame(titleID: titleID, name: "Combo")
        comboGame.inputs = ["base": [comboXCI.path]]
        XCTAssertEqual(TitleNameLookup.sourceVersion(for: comboGame, fallbackKeys: keys.path), "3.0.4")

        // NUP container with both Base (1.0.0) and Update (1.4.2) picks Update without needing keys.
        let nupData = makeNupContainer(packages: [
            (kind: 0, version: 0, nacp: makeNACP(titles: [14: "塞尔达传说"], version: "1.0.0")),
            (kind: 1, version: 65536, nacp: makeNACP(titles: [14: "塞尔达传说"], version: "1.4.2")),
        ])
        let nupURL = try write(nupData, "nup/Zelda.nup")
        var nupGame = LibraryGame(titleID: titleID, name: titleID)
        nupGame.inputs = ["base": [nupURL.path]]
        XCTAssertEqual(TitleNameLookup.sourceVersion(for: nupGame), "1.4.2")
        XCTAssertEqual(TitleNameLookup.names(for: nupGame)?["zh-Hans"], "塞尔达传说")

        // Overflowing meta_off in a crafted NUP returns nil safely without crashing.
        var overflowNup = [UInt8](nupData)
        let firstPkgMetaOff = 0x80 + 0x30 + 32
        overflowNup.replaceSubrange(firstPkgMetaOff..<(firstPkgMetaOff + 8), with: F.le(UInt64.max - 4, 8))
        let secondPkgMetaOff = 0x80 + 0x30 + 0x40 + 32
        overflowNup.replaceSubrange(secondPkgMetaOff..<(secondPkgMetaOff + 8), with: F.le(UInt64.max - 4, 8))
        let badNupURL = try write(Data(overflowNup), "nup/Corrupt.nup")
        var badGame = LibraryGame(titleID: titleID, name: titleID)
        badGame.inputs = ["base": [badNupURL.path]]
        XCTAssertNil(TitleNameLookup.sourceVersion(for: badGame))
    }

    func testHeroShowsUnbuiltPackageVersionBesideSetUpBuildAndHidesWhenOnDevice() throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous ?? false, forAttribute: enhanced) }

        typealias F = ControlPackageFixture
        let id = UInt64(titleID, radix: 16)!
        let keys = try write(Data(F.keysFile().utf8), "keys/prod.keys")
        let baseNSP = try write(Data(F.partition([("c.nca", F.controlNCA(programID: id, nacp: makeNACP(version: "2.0.6"), rightsID: nil))])),
                                "games/Unbuilt.nsp")

        let libFile = temporary.appendingPathComponent("library.json")
        let library = GameLibrary(file: libFile)
        library.keysFile = { keys.path }
        var unbuilt = LibraryGame(titleID: titleID, name: "Sample Game")
        unbuilt.inputs = ["base": [baseNSP.path]]
        library.upsert(unbuilt)
        library.selectedID = library.games.first?.id
        library.fillMissingTitleNames()
        flushTitleNameLookups()

        XCTAssertEqual(library.games.first?.unbuiltVersion, "2.0.6")

        for code in ["en", "zh", "es", "ja"] {
            let stores = LauncherStores(localizer: Localizer(Lang(code)), defaults: testDefaults)
            stores.dependencies.checked = true
            stores.repo.path = temporary.path
            let view = LauncherView(stores: stores, library: library, performStartupChecks: false)
            let host = NSHostingView(rootView: view)
            let window = OffscreenWindow(size: NSSize(width: 960, height: 680))
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            let expected = String(format: stores.localizer.t("console.version"), "2.0.6")
            let deadline = Date().addingTimeInterval(1.5)
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                host.layoutSubtreeIfNeeded()
            } while !texts(in: host).contains(expected) && Date() < deadline
            let visible = texts(in: host)
            XCTAssertTrue(visible.contains(stores.localizer.t("library.setUpBuild")), "Set Up Build in \(code)")
            XCTAssertTrue(visible.contains(expected), "Unbuilt version in \(code): \(visible.sorted())")
        }

        // When installed on a paired device (`primary == .openOnDevice`), `unbuiltVersion` must be nil.
        var onDevice = try XCTUnwrap(library.games.first)
        let iosDir = temporary.appendingPathComponent("Mounted.app")
        try FileManager.default.createDirectory(at: iosDir, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "1.0"], format: .xml, options: 0)
            .write(to: iosDir.appendingPathComponent("Info.plist"))
        onDevice.iosAppPath = iosDir.path
        onDevice.installedDevice = "DEVICE-UDID"
        XCTAssertEqual(onDevice.primary, .openOnDevice)
        XCTAssertNil(onDevice.unbuiltVersion)
    }

    // MARK: - 2. Supported Games Compact Covers & Static Index

    func testSupportedBannersAreValidAllowedHTTPSLinksAndUpgradeOnOwnership() async throws {
        XCTAssertGreaterThanOrEqual(SupportedBanners.urls.count, 150)
        for (tid, raw) in SupportedBanners.urls {
            XCTAssertNotNil(tid.range(of: "^[0-9A-F]{16}$", options: .regularExpression), "Invalid title ID \(tid)")
            let url = try XCTUnwrap(URL(string: raw), "Malformed URL for \(tid)")
            XCTAssertEqual(url.scheme, "https", "Must use HTTPS for \(tid)")
            XCTAssertTrue(ArtworkStore.imageHosts.contains(url.host ?? ""), "Host \(url.host ?? "") not in allowlist for \(tid)")
        }
        XCTAssertEqual(CleanArt.compact("https://www.nintendo.com/eu/art_image1600w.jpg"),
                       "https://www.nintendo.com/eu/art_image500w.jpg")

        // Lightweight fetch saves `_image500w.jpg`; regular owned-game fetch upgrades it to the full-size original.
        let smallImg = NSImage(size: NSSize(width: 50, height: 25))
        smallImg.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 50, height: 25).fill(); smallImg.unlockFocus()
        let fullImg = NSImage(size: NSSize(width: 200, height: 100))
        fullImg.lockFocus(); NSColor.systemGreen.setFill(); NSRect(x: 0, y: 0, width: 200, height: 100).fill(); fullImg.unlockFocus()

        let smallURL = try write(XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(smallImg.tiffRepresentation))?.representation(using: .jpeg, properties: [:])),
                                 "cdn/hero_image500w.jpg")
        let largeURL = try write(XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(smallImg.tiffRepresentation))?.representation(using: .jpeg, properties: [:])),
                                 "cdn/hero_image1600w.jpg")
        let origURL = try write(XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(fullImg.tiffRepresentation))?.representation(using: .jpeg, properties: [:])),
                                "cdn/hero.jpg")
        let emptyList = try write(Data("{}".utf8), "list.json")
        let artDir = temporary.appendingPathComponent("art")

        let store = ArtworkStore(directory: artDir, titleList: emptyList, fallbacks: [:], catalogue: { _, _ in
            [self.titleID: largeURL.absoluteString]
        })

        // 1. Supported list browse (lightweight): saves _image500w without touching hero.jpg.
        let addedLight = await store.fetchMissing([titleID], language: "en", waits: true, lightweight: true)
        XCTAssertEqual(addedLight, [titleID])
        let sourcesAfterLight = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: artDir.appendingPathComponent("sources.json")))
        XCTAssertEqual(sourcesAfterLight[titleID], smallURL.absoluteString)

        // 2. Player later adds the game to Library (lightweight: false): upgrades automatically to `hero.jpg` (original).
        let addedOwned = await store.fetchMissing([titleID], language: "en", waits: false, lightweight: false)
        XCTAssertEqual(addedOwned, [titleID])
        let sourcesAfterOwned = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: artDir.appendingPathComponent("sources.json")))
        XCTAssertEqual(sourcesAfterOwned[titleID], origURL.absoluteString)
    }

    // MARK: - 3. Settings Compact Segmented Controls & Sticky Scroll Memory

    func testSettingsSegmentedControlsFitWithoutTruncationInEveryLanguage() throws {
        let ct = try XCTUnwrap(Typography.manropeFont(size: 12.5, weight: .bold))
        func singleLineWidth(_ s: String) -> CGFloat {
            let attr = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: ct])
            return ceil(CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(attr), []).width)
        }

        for lang in Lang.all {
            let loc = Localizer(lang)
            let appearanceLabels = LauncherAppearance.allCases.map { loc.t($0.labelKey) }
            let appWidth = LauncherSegmented.compactWidth(labels: appearanceLabels, minWidth: 276)
            let appCellRoom = (appWidth - 10) / 3 - 24
            for label in appearanceLabels {
                XCTAssertLessThanOrEqual(singleLineWidth(label), appCellRoom, "Appearance '\(label)' truncated in \(lang.code)")
            }

            let displayLabels = [loc.t("launch.display.window"), loc.t("launch.display.fullscreen")]
            let dispWidth = LauncherSegmented.compactWidth(labels: displayLabels, minWidth: LauncherControl.width)
            let dispCellRoom = (dispWidth - 8) / 2 - 24
            for label in displayLabels {
                XCTAssertLessThanOrEqual(singleLineWidth(label), dispCellRoom, "Display '\(label)' truncated in \(lang.code)")
            }
            if ["en", "zh"].contains(lang.code) {
                XCTAssertEqual(appWidth, 276)
                XCTAssertEqual(dispWidth, LauncherControl.width)
            }
        }
    }

    func testStickyScrollMemoryKeepsHeaderStableAcrossCategorySwitches() {
        final class FlippedDoc: NSView { override var isFlipped: Bool { true } }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scroll.documentView = FlippedDoc(frame: NSRect(x: 0, y: 0, width: 800, height: 2400))
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()

        var pinnedStates: [Bool] = []
        let coordinator = ScrollMemory.Coordinator()
        coordinator.pinnedOffset = 132
        coordinator.onPinChange = { pinnedStates.append($0) }
        coordinator.attach(scroll)
        coordinator.restore("settings.general")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0)
        XCTAssertEqual(pinnedStates.last, false)

        // Unpinned partial scroll (y = 28): switching category keeps y = 28 so the selector bar does not jump.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 28))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        coordinator.restore("settings.controls")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 28)

        // Pinned scroll (y = 320 >= 132): switching to an unvisited category lands at the pin line (132), keeping the bar pinned.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 320))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(pinnedStates.last, true)
        coordinator.restore("settings.tools")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 132)
        XCTAssertEqual(pinnedStates.last, true)
    }

    // MARK: - 4. Light Mode Contrast & Shadow Tokens

    func testLightModeDropdownShadowAndDestructiveContrast() {
        var lightShadow = NSColor.clear, darkShadow = NSColor.clear
        var lightRed = NSColor.clear, lightFill = NSColor.clear
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            lightShadow = NSColor(LauncherPalette.dropdownShadow).usingColorSpace(.sRGB)!
            lightRed = NSColor(DeleteGameSheet.red).usingColorSpace(.sRGB)!
            lightFill = NSColor(DeleteGameSheet.fill).usingColorSpace(.sRGB)!
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            darkShadow = NSColor(LauncherPalette.dropdownShadow).usingColorSpace(.sRGB)!
        }
        XCTAssertEqual(Double(lightShadow.alphaComponent), 0.12, accuracy: 0.01)
        XCTAssertEqual(Double(darkShadow.alphaComponent), 0.50, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(LauncherPalette.contrast(lightRed, .white), 4.5)
        XCTAssertGreaterThanOrEqual(LauncherPalette.contrast(.white, lightFill), 4.5)
    }
}
