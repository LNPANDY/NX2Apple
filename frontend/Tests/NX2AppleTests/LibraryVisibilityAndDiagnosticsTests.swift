import AppKit
import Combine
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
import NXLauncher

@MainActor final class LibraryVisibilityAndDiagnosticsTests: IsolatedDefaultsTestCase {
    private typealias F = ControlPackageFixture
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-lib-diag-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        VerifiedProfiles.resetCacheForTesting()
    }

    override func tearDownWithError() throws {
        VerifiedProfiles.resetCacheForTesting()
        try? FileManager.default.removeItem(at: temporary)
    }

    private func metaNCA(programID: UInt64, type: UInt8 = 1, headerKey: [UInt8] = F.headerKey) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: KeyCheck.headerBytes)
        header.replaceSubrange(0x200..<0x204, with: Array("NCA3".utf8))
        header[0x205] = type
        header[0x220] = 3
        header.replaceSubrange(0x210..<0x218, with: F.le(programID, 8))
        return KeyCheck.xts(header, key: headerKey, encrypt: true)!
    }

    private func writeBytes(_ bytes: [UInt8], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    private func scanSync(_ library: GameLibrary, folder: URL? = nil, repo: String = "") {
        library.applicationFolders = []
        let done = expectation(description: "library scan finished")
        let token = library.$scanning.dropFirst().filter { !$0 }.sink { _ in done.fulfill() }
        if let folder, library.folders.isEmpty {
            library.setFolder(folder)
        } else {
            library.discover(repo: repo)
        }
        wait(for: [done], timeout: 10)
        token.cancel()
    }

    private func realRepoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            url.deleteLastPathComponent()
        }
        return url
    }

    // MARK: - Feature 1: Renamed .xci / .xcz header identification

    func testRenamedXCIAndXCZPackagesIdentifyBaseTitleIDAndSurviveCorruptedHeaders() throws {
        let singleXCI = temporary.appendingPathComponent("Games/Celeste.xci")
        try writeBytes(
            F.xci([
                ("0000.nca", metaNCA(programID: 0x0100_2B30_028F_6000, type: 0)),
                ("0001.cnmt.nca", metaNCA(programID: 0x0100_2B30_028F_6000)),
            ]),
            to: singleXCI
        )
        XCTAssertEqual(PackageTitleID.read(singleXCI.path, headerKey: F.headerKey), 0x0100_2B30_028F_6000)

        // Full cartridge dump with 0x1000-byte initial key area and compressed .ncz entries (.xcz).
        let keystoreXCZ = temporary.appendingPathComponent("Games/Wonder.xcz")
        try writeBytes(
            F.xci([
                ("program.ncz", metaNCA(programID: 0x0100_1510_0B51_4000, type: 0)),
                ("meta.cnmt.ncz", metaNCA(programID: 0x0100_1510_0B51_4000)),
            ], keyArea: true),
            to: keystoreXCZ
        )
        XCTAssertEqual(PackageTitleID.read(keystoreXCZ.path, headerKey: F.headerKey), 0x0100_1510_0B51_4000)

        // Multi-content cartridge where Update (...800) and DLC (...3000, ...3001) appear before Base (...2000).
        let multiXCI = temporary.appendingPathComponent("Games/Monster Hunter Rise Complete.xci")
        try writeBytes(
            F.xci([
                ("upd.cnmt.nca", metaNCA(programID: 0x0100_B040_1174_2800)),
                ("dlc0.cnmt.nca", metaNCA(programID: 0x0100_B040_1174_3000)),
                ("dlc1.cnmt.nca", metaNCA(programID: 0x0100_B040_1174_3001)),
                ("base.cnmt.nca", metaNCA(programID: 0x0100_B040_1174_2000)),
            ]),
            to: multiXCI
        )
        XCTAssertEqual(
            PackageTitleID.read(multiXCI.path, headerKey: F.headerKey),
            0x0100_B040_1174_2000,
            "Multi-content cartridge must prefer the base game meta NCA over update and DLC meta NCAs"
        )

        // Supplement-only cartridge falls back to the supplement meta Title ID.
        let updateOnlyXCI = temporary.appendingPathComponent("Supplements/OnlyUpdate.xci")
        try writeBytes(
            F.xci([("upd.cnmt.nca", metaNCA(programID: 0x0100_B040_1174_2800))]),
            to: updateOnlyXCI
        )
        XCTAssertEqual(PackageTitleID.read(updateOnlyXCI.path, headerKey: F.headerKey), 0x0100_B040_1174_2800)

        // Adversarial / corrupted inputs must return nil cleanly without crashing or overflowing.
        let emptyXCI = temporary.appendingPathComponent("Bad/Empty.xci")
        try writeBytes([], to: emptyXCI)
        XCTAssertNil(PackageTitleID.read(emptyXCI.path, headerKey: F.headerKey))

        let truncatedXCI = temporary.appendingPathComponent("Bad/Truncated.xci")
        var truncatedBytes = [UInt8](repeating: 0, count: 0x110)
        truncatedBytes.replaceSubrange(0x100..<0x104, with: Array("HEAD".utf8))
        try writeBytes(truncatedBytes, to: truncatedXCI)
        XCTAssertNil(PackageTitleID.read(truncatedXCI.path, headerKey: F.headerKey))

        let overflowRootXCI = temporary.appendingPathComponent("Bad/OverflowRoot.xci")
        var overflowCard = [UInt8](repeating: 0, count: 0x200)
        overflowCard.replaceSubrange(0x100..<0x104, with: Array("HEAD".utf8))
        overflowCard.replaceSubrange(0x130..<0x138, with: F.le(UInt64.max - 4, 8))
        try writeBytes(overflowCard, to: overflowRootXCI)
        XCTAssertNil(PackageTitleID.read(overflowRootXCI.path, headerKey: F.headerKey))

        let badTableXCI = temporary.appendingPathComponent("Bad/HugeCount.xci")
        var hugeHFS0 = [UInt8](repeating: 0, count: 0x300)
        hugeHFS0.replaceSubrange(0x100..<0x104, with: Array("HEAD".utf8))
        hugeHFS0.replaceSubrange(0x130..<0x138, with: F.le(0x200, 8))
        hugeHFS0.replaceSubrange(0x200..<0x204, with: Array("HFS0".utf8))
        hugeHFS0.replaceSubrange(0x204..<0x208, with: F.le(99_999, 4))
        hugeHFS0.replaceSubrange(0x208..<0x20C, with: F.le(64, 4))
        try writeBytes(hugeHFS0, to: badTableXCI)
        XCTAssertNil(PackageTitleID.read(badTableXCI.path, headerKey: F.headerKey))

        let unterminatedXCI = temporary.appendingPathComponent("Bad/UnterminatedStrings.xci")
        var noNullHFS0 = [UInt8](repeating: 0, count: 0x280)
        noNullHFS0.replaceSubrange(0x100..<0x104, with: Array("HEAD".utf8))
        noNullHFS0.replaceSubrange(0x130..<0x138, with: F.le(0x200, 8))
        noNullHFS0.replaceSubrange(0x200..<0x204, with: Array("HFS0".utf8))
        noNullHFS0.replaceSubrange(0x204..<0x208, with: F.le(1, 4))
        noNullHFS0.replaceSubrange(0x208..<0x20C, with: F.le(16, 4))
        // Entry size = UInt64.max triggers overflow guard on secureEnd, string table has no null terminator.
        noNullHFS0.replaceSubrange(0x218..<0x220, with: F.le(UInt64.max, 8))
        noNullHFS0.replaceSubrange(0x250..<0x260, with: Array("secureXXXXXXXXXX".utf8))
        try writeBytes(noNullHFS0, to: unterminatedXCI)
        XCTAssertNil(PackageTitleID.read(unterminatedXCI.path, headerKey: F.headerKey))

        // End-to-end library discovery with saved keys and real engine game profiles.
        let keysURL = temporary.appendingPathComponent("prod.keys")
        try F.keysFile().write(to: keysURL, atomically: true, encoding: .utf8)
        let repoPath = realRepoRoot().path
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        library.keysFile = { keysURL.path }
        scanSync(library, folder: temporary.appendingPathComponent("Games"), repo: repoPath)
        XCTAssertEqual(
            Set(library.games.map(\.titleID)),
            ["01002B30028F6000", "010015100B514000", "0100B04011742000"]
        )
    }

    // MARK: - Feature 2: Skipped library file diagnostics

    func testSkippedItemsClassifyOrphansArchivesAndKeylessPackagesAndClearOnRemediation() throws {
        let root = temporary.appendingPathComponent("SwitchFolder")
        try writeBytes(
            F.partition([("meta.cnmt.nca", metaNCA(programID: 0x0100_7EF0_0011_E800))]),
            to: root.appendingPathComponent("Zelda Update [01007EF00011E800][v196608].nsp")
        )
        try writeBytes(
            F.partition([("meta.cnmt.nca", metaNCA(programID: 0x0100_74F0_1326_3001))]),
            to: root.appendingPathComponent("Xenoblade DLC [010074F013263001].nsp")
        )
        try writeBytes(Array("7z\u{BC}\u{AF}".utf8), to: root.appendingPathComponent("Fire Emblem Engage.7z"))
        try writeBytes([0xAA, 0xBB], to: root.appendingPathComponent("Metroid Prime.nsp.00"))
        try writeBytes([0xCC, 0xDD], to: root.appendingPathComponent("Metroid Prime.nsp.01"))
        try writeBytes([0xEE, 0xFF], to: root.appendingPathComponent("Metroid Prime.nsp.02"))
        try writeBytes([0x11, 0x22], to: root.appendingPathComponent("Kirby.part1.rar"))
        try writeBytes([0x33, 0x44], to: root.appendingPathComponent("Kirby.part2.rar"))
        try writeBytes(
            F.partition([("meta.cnmt.nca", metaNCA(programID: 0x0100_5350_1297_4000))]),
            to: root.appendingPathComponent("Hollow Knight Silksong.nsp")
        )
        try writeBytes(
            F.xci([("meta.cnmt.nca", metaNCA(programID: 0x0100_7300_020F_A000))]),
            to: root.appendingPathComponent("Astral Chain.xci")
        )
        // Ignored noise files that must not pollute skippedItems.
        try writeBytes([0x00], to: root.appendingPathComponent("._ResourceFork.zip"))
        try writeBytes([0x00], to: root.appendingPathComponent("0100_build/intermediate.zip"))
        try writeBytes([0x00], to: root.appendingPathComponent("NX2Apple-macOS.zip"))
        try writeBytes([0x00], to: root.appendingPathComponent("Firmware 19.0.0.zip"))

        var activeKeys = ""
        let library = GameLibrary(file: temporary.appendingPathComponent("diag-lib.json"))
        library.keysFile = { activeKeys }
        scanSync(library, folder: root)

        XCTAssertTrue(library.games.isEmpty)
        XCTAssertEqual(
            library.skippedItems.map(\.name),
            [
                "Astral Chain.xci",
                "Fire Emblem Engage.7z",
                "Hollow Knight Silksong.nsp",
                "Kirby.part1.rar",
                "Metroid Prime.nsp.00",
                "Xenoblade DLC [010074F013263001].nsp",
                "Zelda Update [01007EF00011E800][v196608].nsp",
            ]
        )
        let byName = Dictionary(uniqueKeysWithValues: library.skippedItems.map { ($0.name, $0) })
        XCTAssertEqual(byName["Astral Chain.xci"]?.reason, .unidentifiedWithoutKeys)
        XCTAssertEqual(byName["Hollow Knight Silksong.nsp"]?.reason, .unidentifiedWithoutKeys)
        XCTAssertEqual(byName["Fire Emblem Engage.7z"]?.reason, .unextractedArchiveOrSplit)
        XCTAssertEqual(byName["Kirby.part1.rar"]?.reason, .unextractedArchiveOrSplit)
        XCTAssertEqual(byName["Metroid Prime.nsp.00"]?.reason, .unextractedArchiveOrSplit)
        XCTAssertEqual(byName["Zelda Update [01007EF00011E800][v196608].nsp"]?.reason, .orphanSupplement(titleID: "01007EF00011E800"))
        XCTAssertEqual(byName["Zelda Update [01007EF00011E800][v196608].nsp"]?.expectedBaseTitleID, "01007EF00011E000")
        XCTAssertEqual(byName["Xenoblade DLC [010074F013263001].nsp"]?.expectedBaseTitleID, "010074F013262000")

        // Saving prod.keys and rescanning promotes both renamed packages into library games.
        let keysURL = temporary.appendingPathComponent("prod.keys")
        try F.keysFile().write(to: keysURL, atomically: true, encoding: .utf8)
        activeKeys = keysURL.path
        scanSync(library, repo: realRepoRoot().path)
        XCTAssertEqual(Set(library.games.map(\.titleID)), ["0100535012974000", "01007300020FA000"])
        XCTAssertFalse(library.skippedItems.contains { $0.reason == .unidentifiedWithoutKeys })

        // Adding the missing Zelda base package clears its orphan update on rescan.
        try writeBytes(
            F.partition([("meta.cnmt.nca", metaNCA(programID: 0x0100_7EF0_0011_E000))]),
            to: root.appendingPathComponent("Zelda Base [01007EF00011E000][v0].nsp")
        )
        scanSync(library, repo: realRepoRoot().path)
        XCTAssertFalse(library.skippedItems.contains { $0.name.hasPrefix("Zelda Update") })

        // Removing the last folder immediately clears skippedItems.
        library.removeFolder(root.path)
        XCTAssertEqual(library.skippedItems, [])
    }

    func testSkippedItemsRespectScanGenerationGuardAgainstStalePass() throws {
        let root = temporary.appendingPathComponent("StaleRoot")
        try writeBytes(Array("7z".utf8), to: root.appendingPathComponent("Archive.7z"))

        let library = GameLibrary(file: temporary.appendingPathComponent("stale-lib.json"))
        library.applicationFolders = []
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        library.onBackgroundScanStart = {
            started.signal()
            release.wait()
        }

        library.addFolder(root)
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        library.removeFolder(root.path)
        XCTAssertEqual(library.skippedItems, [])
        release.signal()

        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(library.skippedItems, [], "Stale discovery pass from a removed folder must not repopulate skippedItems")
    }

    // MARK: - Feature 3: Verified profiles memoization and Unverified status

    func testVerifiedProfilesCachesRealEngineGamesAndAvoidsRepeatedDiskScans() throws {
        // 1. Empty or missing engine directory never marks any game as unverified and is not cached permanently.
        let emptyEngine = temporary.appendingPathComponent("pending-engine")
        XCTAssertEqual(VerifiedProfiles.titleIDs(engineRoot: emptyEngine.path), [])
        XCTAssertFalse(VerifiedProfiles.isUnverified(titleID: "01007300020FA000", verifiedTitleIDs: []))

        let profileDir = emptyEngine.appendingPathComponent("dm/games/01002B30028F6000")
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try "title_id\t01002B30028F6000\nname\tCeleste\n".write(
            to: profileDir.appendingPathComponent("game.tsv"),
            atomically: true,
            encoding: .utf8
        )
        let populated = VerifiedProfiles.titleIDs(engineRoot: emptyEngine.path)
        XCTAssertTrue(populated.contains("01002B30028F6000"))
        XCTAssertFalse(VerifiedProfiles.isUnverified(titleID: "01002B30028F6000", verifiedTitleIDs: populated))
        XCTAssertTrue(VerifiedProfiles.isUnverified(titleID: "01007300020FA000", verifiedTitleIDs: populated))

        // 2. Real shipped engine/dm/games check and single-scan memoization proof.
        VerifiedProfiles.resetCacheForTesting()
        let realEngine = EngineLayout.root(realRepoRoot().path)
        let firstLoad = VerifiedProfiles.titleIDs(engineRoot: realEngine)
        XCTAssertGreaterThan(firstLoad.count, 100, "Expected real engine/dm/games profiles to load")
        XCTAssertEqual(VerifiedProfiles.diskScanCount, 1)

        // Repeated lookups hit memory without re-scanning game.tsv files.
        let secondLoad = VerifiedProfiles.titleIDs(engineRoot: realEngine)
        let cachedHit = VerifiedProfiles.cachedTitleIDs(engineRoot: realEngine)
        XCTAssertEqual(secondLoad, firstLoad)
        XCTAssertEqual(cachedHit, firstLoad)
        XCTAssertEqual(VerifiedProfiles.diskScanCount, 1, "Memoized engineRoot must not re-read dm/games/*.tsv")

        // Multi-program collection sub-profile (010049900F546001) aligns its base container (010049900F546000) as verified.
        XCTAssertFalse(VerifiedProfiles.isUnverified(titleID: "010049900F546000", verifiedTitleIDs: firstLoad))
    }

    func testLauncherViewWiresSkippedDiagnosticsAndVerifiedProfilesTrackerEndToEnd() throws {
        let root = temporary.appendingPathComponent("WiredRoot")
        try writeBytes(Array("7z".utf8), to: root.appendingPathComponent("PackedArchive.7z"))

        let stores = LauncherStores(defaults: testDefaults)
        stores.repo.path = realRepoRoot().path
        stores.localizer.lang = .en

        let library = GameLibrary(file: temporary.appendingPathComponent("wired-lib.json"))
        scanSync(library, folder: root, repo: stores.repo.path)
        let unverified = LibraryGame(titleID: "0100DEADBEEF0000", name: "Unlisted Prototype")
        let verified = LibraryGame(titleID: "01002B30028F6000", name: "Celeste")
        library.upsert(unverified)
        library.upsert(verified)
        library.selectedID = unverified.id

        let rep = try renderWindow(
            LauncherView(stores: stores, library: library, performStartupChecks: false, qaSkippedOpen: true),
            size: NSSize(width: 1100, height: 760)
        )
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        XCTAssertEqual(library.skippedItems.map(\.name), ["PackedArchive.7z"])

        VerifiedProfiles.resetCacheForTesting()
        let coldTracker = VerifiedProfilesTracker()
        let loaded = expectation(description: "verified profiles loaded asynchronously")
        let token = coldTracker.$titleIDs.filter { !$0.isEmpty }.first().sink { _ in loaded.fulfill() }
        coldTracker.refresh(engineRoot: EngineLayout.root(stores.repo.path))
        wait(for: [loaded], timeout: 5)
        token.cancel()
        XCTAssertTrue(coldTracker.isUnverified(unverified))
        XCTAssertFalse(coldTracker.isUnverified(verified))

        // Warm tracker hits the in-memory cache synchronously without another async hop.
        let warmTracker = VerifiedProfilesTracker()
        warmTracker.refresh(engineRoot: EngineLayout.root(stores.repo.path))
        XCTAssertFalse(warmTracker.titleIDs.isEmpty)
        XCTAssertTrue(warmTracker.isUnverified(unverified))
        XCTAssertFalse(warmTracker.isUnverified(verified))
    }

    func testSkippedBannerDismissesForSessionAndRearmsOnNewFileManualRescanOrFreshLaunch() throws {
        for lang in Lang.all {
            let label = L10n.string("library.dismissSkipped", lang)
            XCTAssertFalse(label.isEmpty, "Missing library.dismissSkipped in \(lang.code)")
            XCTAssertNotEqual(label, "library.dismissSkipped", "Untranslated key in \(lang.code)")
            XCTAssertFalse(label.contains(";"))
            XCTAssertFalse(label.contains("；"))
        }

        let root = temporary.appendingPathComponent("DismissSessionRoot")
        let firstArchive = root.appendingPathComponent("FirstArchive.7z")
        let secondArchive = root.appendingPathComponent("SecondArchive.rar")
        try writeBytes(Array("7z".utf8), to: firstArchive)
        try writeBytes(Array("Rar!".utf8), to: secondArchive)

        let libFile = temporary.appendingPathComponent("dismiss-session-lib.json")
        let repoPath = realRepoRoot().path
        let library = GameLibrary(file: libFile)
        scanSync(library, folder: root, repo: repoPath)
        XCTAssertEqual(library.skippedItems.count, 2)
        XCTAssertTrue(library.showsSkippedBanner)

        // Dismiss hides the banner for this session without deleting skippedItems.
        library.dismissSkippedBanner()
        XCTAssertFalse(library.showsSkippedBanner)
        XCTAssertEqual(library.skippedItems.count, 2)

        // Background re-discovery of the exact same set (or a subset) keeps the banner dismissed.
        let sameDone = expectation(description: "same set rediscovery")
        let sameToken = library.$scanning.dropFirst().filter { !$0 }.first().sink { _ in sameDone.fulfill() }
        library.discover(repo: repoPath)
        wait(for: [sameDone], timeout: 5)
        sameToken.cancel()
        XCTAssertFalse(library.showsSkippedBanner, "Automatic rediscovery of the same skipped files must stay dismissed")

        try FileManager.default.removeItem(at: secondArchive)
        let subsetDone = expectation(description: "subset rediscovery")
        let subsetToken = library.$scanning.dropFirst().filter { !$0 }.first().sink { _ in subsetDone.fulfill() }
        library.discover(repo: repoPath)
        wait(for: [subsetDone], timeout: 5)
        subsetToken.cancel()
        XCTAssertEqual(library.skippedItems.count, 1)
        XCTAssertFalse(library.showsSkippedBanner, "A subset of already-dismissed skipped files must stay dismissed")

        // A brand-new skipped file in the folder re-arms the banner automatically.
        let thirdArchive = root.appendingPathComponent("NewArrival.zip")
        try writeBytes([0x50, 0x4B, 0x03, 0x04], to: thirdArchive)
        let newDone = expectation(description: "new file rediscovery")
        let newToken = library.$scanning.dropFirst().filter { !$0 }.first().sink { _ in newDone.fulfill() }
        library.discover(repo: repoPath)
        wait(for: [newDone], timeout: 5)
        newToken.cancel()
        XCTAssertEqual(library.skippedItems.count, 2)
        XCTAssertTrue(library.showsSkippedBanner, "A newly added skipped file must show the banner again")

        // Dismiss again, then verify manual rescan (`library.rescan`) re-shows the banner.
        library.dismissSkippedBanner()
        XCTAssertFalse(library.showsSkippedBanner)
        let manualDone = expectation(description: "manual rescan")
        let manualToken = library.$scanning.dropFirst().filter { !$0 }.first().sink { _ in manualDone.fulfill() }
        library.rescan(repo: repoPath)
        wait(for: [manualDone], timeout: 5)
        manualToken.cancel()
        XCTAssertTrue(library.showsSkippedBanner, "Manual rescan from Settings must re-show the banner")

        // Dismiss again, then simulate a fresh NX2Apple launch (new GameLibrary instance reading the saved library.json).
        library.dismissSkippedBanner()
        XCTAssertFalse(library.showsSkippedBanner)
        let relaunched = GameLibrary(file: libFile)
        let launchDone = expectation(description: "fresh launch discovery")
        let launchToken = relaunched.$scanning.dropFirst().filter { !$0 }.first().sink { _ in launchDone.fulfill() }
        relaunched.discover(repo: repoPath)
        wait(for: [launchDone], timeout: 5)
        launchToken.cancel()
        XCTAssertEqual(relaunched.skippedItems.count, 2)
        XCTAssertTrue(relaunched.showsSkippedBanner, "Relaunching NX2Apple must scan and show the banner again")

        // Clearing all skipped files resets dismissal so re-adding the same path later notifies again.
        relaunched.dismissSkippedBanner()
        XCTAssertFalse(relaunched.showsSkippedBanner)
        try FileManager.default.removeItem(at: firstArchive)
        try FileManager.default.removeItem(at: thirdArchive)
        let emptyDone = expectation(description: "empty folder rediscovery")
        let emptyToken = relaunched.$scanning.dropFirst().filter { !$0 }.first().sink { _ in emptyDone.fulfill() }
        relaunched.discover(repo: repoPath)
        wait(for: [emptyDone], timeout: 5)
        emptyToken.cancel()
        XCTAssertTrue(relaunched.skippedItems.isEmpty)
        try writeBytes(Array("7z".utf8), to: firstArchive)
        let readdedDone = expectation(description: "re-added archive discovery")
        let readdedToken = relaunched.$scanning.dropFirst().filter { !$0 }.first().sink { _ in readdedDone.fulfill() }
        relaunched.discover(repo: repoPath)
        wait(for: [readdedDone], timeout: 5)
        readdedToken.cancel()
        XCTAssertTrue(relaunched.showsSkippedBanner)
    }

    private func renderWindow(_ view: some View, size: NSSize = NSSize(width: 1280, height: 820)) throws -> NSBitmapImageRep {
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: view)
        let window = OffscreenWindow(size: size, styleMask: [.titled, .closable, .resizable])
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.75))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}
