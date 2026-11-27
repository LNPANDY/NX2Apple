import CryptoKit
import Foundation
import Testing
@testable import ShellHost
@testable import ShellUI

private final class MockCheatRecorder: @unchecked Sendable {
    var launched: [LaunchableGame] = []
}

private struct MockRecordingLauncher: GameLauncher {
    let recorder: MockCheatRecorder
    @MainActor func launch(_ game: LaunchableGame) async throws {
        recorder.launched.append(game)
    }
}

private actor MockHTTPTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private(set) var requests: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try await handler(request)
    }

    func capturedRequests() -> [URLRequest] {
        requests
    }
}

@MainActor @Suite struct CheatFetcherAndSeedTests {
    private let titleID = "01006F8002326000"
    private let buildID = "20CA968C082118C2"

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nx-ios-cheat-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFramework(
        at fwURL: URL,
        buildID: String,
        trampolines: String? = nil,
        bundledCheats: [String: Data] = [:]
    ) throws {
        let fm = FileManager.default
        let dm = fwURL.appendingPathComponent("dm", isDirectory: true)
        try fm.createDirectory(at: dm, withIntermediateDirectories: true)
        try Data("# BUILD_ID\t\(buildID)0011223344556677\n# MAIN_RX_END\t0x100000\n".utf8)
            .write(to: dm.appendingPathComponent("main.fixups.tsv"))
        if let trampolines {
            try Data(trampolines.utf8).write(to: dm.appendingPathComponent("cheat_trampolines.tsv"))
        }
        if !bundledCheats.isEmpty {
            let cheats = dm.appendingPathComponent("cheats", isDirectory: true)
            try fm.createDirectory(at: cheats, withIntermediateDirectories: true)
            for (name, data) in bundledCheats {
                try data.write(to: cheats.appendingPathComponent(name))
            }
        }
    }

    private func makePlayableGameDir(
        at gamesRoot: URL,
        titleID: String,
        buildID: String,
        bundledCheats: [String: Data] = [:],
        trampolines: String? = nil
    ) throws -> URL {
        let gameDir = gamesRoot.appendingPathComponent(titleID, isDirectory: true)
        let fw = gameDir.appendingPathComponent("DmGame.framework", isDirectory: true)
        try makeFramework(at: fw, buildID: buildID, trampolines: trampolines, bundledCheats: bundledCheats)
        try Data("bin".utf8).write(to: fw.appendingPathComponent("DmGame"))
        let mslDir = fw.appendingPathComponent("msl/b-3f9a2c", isDirectory: true)
        try FileManager.default.createDirectory(at: mslDir, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: mslDir.appendingPathComponent("fixture.metallib"))
        let manifest = """
        {
          "schema": 1,
          "title_id": "\(titleID)",
          "name": "Seed Fixture",
          "display_version": "1.0.0",
          "package_version": "65536",
          "modules": ["main"],
          "nro_count": 0,
          "chain": "b-3f9a2c",
          "loader": "FR",
          "framework": "DmGame.framework",
          "framework_executable": "DmGame",
          "image_marker": "dmgame_image_marker",
          "profile": "profile.tsv",
          "shader_map": "dm/shader_map.tsv",
          "launcher": "dm/launcher.json",
          "romfs_marker": "fixture.marker",
          "romfs_identity": "DMROMFSID1 fixture",
          "min_os": "26.0"
        }
        """
        try Data(manifest.utf8).write(to: gameDir.appendingPathComponent("game.manifest.json"))
        try Data("{\"schema\":1,\"game\":\"\(titleID)\",\"settings\":[]}".utf8).write(to: gameDir.appendingPathComponent("launcher.json"))
        return gameDir
    }

    // MARK: - 1. Bundled Seed 4-State Protection & Delete Anti-Bounce

    @Test func bundledSeedCoversAllFourStatesAndDoesNotTouchEnabled() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let fw = root.appendingPathComponent("DmGame.framework", isDirectory: true)
        let v1Cheat = Data("[HP]\n04000000 00180020 000003E7\n".utf8)
        let v1Receipt = GameCheatFetchReceipt(
            titleID: titleID,
            buildID: buildID,
            status: "found",
            sources: ["HamletDuFromage/switch-cheats-db"],
            entryCount: 1,
            fetchedAt: 1_795_770_000,
            fileName: "\(buildID).txt",
            fileSHA256: IOSCheatFetcher.sha256Hex(v1Cheat),
            origin: "bundled"
        )
        let v1ReceiptData = try JSONEncoder().encode(v1Receipt)
        try makeFramework(at: fw, buildID: buildID, bundledCheats: [
            "\(buildID).txt": v1Cheat,
            ".cheats-fetch.json": v1ReceiptData,
        ])

        let appFolder = root.appendingPathComponent("app", isDirectory: true)
        let store = GameCheatsStore(titleID: titleID, appFolder: appFolder, frameworkURL: fw)

        // State 4 (first install): seeds <BID>.txt and .cheats-fetch.json, never writes .enabled.
        let snap1 = store.loadSnapshot(gameTitle: "Seed Fixture")
        #expect(snap1.hasCurrentFile)
        #expect(snap1.entries.count == 1)
        #expect(!snap1.entries[0].enabled)
        #expect(snap1.fetchReceipt?.origin == "bundled")
        #expect(!FileManager.default.fileExists(atPath: store.enabledURL(for: buildID).path))
        #expect(store.readSeededHashes()["\(buildID).txt"] == IOSCheatFetcher.sha256Hex(v1Cheat))

        // State 4 (app upgrade while user left file untouched): replaces with v2 bundled file.
        let v2Cheat = Data("[HP]\n04000000 00180020 000007D0\n[MP]\n04000000 00180024 000003E7\n".utf8)
        let v2Receipt = GameCheatFetchReceipt(
            titleID: titleID,
            buildID: buildID,
            status: "found",
            sources: ["HamletDuFromage/switch-cheats-db"],
            entryCount: 2,
            fetchedAt: 1_795_780_000,
            fileName: "\(buildID).txt",
            fileSHA256: IOSCheatFetcher.sha256Hex(v2Cheat),
            origin: "bundled"
        )
        let bundledDir = fw.appendingPathComponent("dm/cheats", isDirectory: true)
        try v2Cheat.write(to: bundledDir.appendingPathComponent("\(buildID).txt"))
        try JSONEncoder().encode(v2Receipt).write(to: bundledDir.appendingPathComponent(".cheats-fetch.json"))

        let snap2 = store.loadSnapshot(gameTitle: "Seed Fixture")
        #expect(snap2.entries.map(\.name) == ["HP", "MP"])
        #expect(snap2.fetchReceipt?.entryCount == 2)
        #expect(store.readSeededHashes()["\(buildID).txt"] == IOSCheatFetcher.sha256Hex(v2Cheat))

        // State 3a (user edited the seeded file): bundled upgrade must not overwrite user edits.
        let userEdited = Data("[Custom Edit]\n04000000 00180030 00000001\n".utf8)
        try userEdited.write(to: store.flatCheatURL(for: buildID))
        let v3Cheat = Data("[HP v3]\n04000000 00180020 00000999\n".utf8)
        try v3Cheat.write(to: bundledDir.appendingPathComponent("\(buildID).txt"))
        let snap3 = store.loadSnapshot(gameTitle: "Seed Fixture")
        #expect(snap3.entries.map(\.name) == ["Custom Edit"])

        // State 2 (deleted via Files app while present in .seeded.json): recorded in .deleted.json and never re-seeded.
        try v2Cheat.write(to: store.flatCheatURL(for: buildID))
        // Re-align .seeded.json to current disk file so state 2 detects deletion cleanly.
        let storeFreshDir = root.appendingPathComponent("app2", isDirectory: true)
        let store2 = GameCheatsStore(titleID: titleID, appFolder: storeFreshDir, frameworkURL: fw)
        _ = store2.loadSnapshot(gameTitle: "Seed Fixture")
        try FileManager.default.removeItem(at: store2.flatCheatURL(for: buildID))
        let afterFilesDelete = store2.loadSnapshot(gameTitle: "Seed Fixture")
        #expect(!afterFilesDelete.hasCurrentFile)
        #expect(store2.readDeletedCheatFiles().contains("\(buildID).txt"))
        // Even on subsequent loadSnapshot, State 1 keeps it deleted.
        #expect(!store2.loadSnapshot(gameTitle: "Seed Fixture").hasCurrentFile)

        // State 3b (user imported a file directly without .seeded.json): never overwritten by bundle.
        let store3Dir = root.appendingPathComponent("app3", isDirectory: true)
        let store3 = GameCheatsStore(titleID: titleID, appFolder: store3Dir, frameworkURL: fw)
        let userFile = Data("[Player Imported]\n04000000 00180040 00000005\n".utf8)
        _ = try store3.saveCheatFile(data: userFile, targetBuildID: buildID, gameTitle: "Seed Fixture")
        let snapUser = store3.loadSnapshot(gameTitle: "Seed Fixture")
        #expect(snapUser.entries.map(\.name) == ["Player Imported"])
    }

    @Test func deleteCheatFileMarksDeletedAndPreventsLaunchReseed() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let gamesRoot = root.appendingPathComponent("Games", isDirectory: true)
        let bundledCheat = Data("[HP]\n04000000 00180020 000003E7\n".utf8)
        let gameDir = try makePlayableGameDir(
            at: gamesRoot,
            titleID: titleID,
            buildID: buildID,
            bundledCheats: ["\(buildID).txt": bundledCheat]
        )
        let appData = root.appendingPathComponent("appData", isDirectory: true)
        let marker = appData.appendingPathComponent("\(titleID)/romfs/fixture.marker")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)

        let recorder = MockCheatRecorder()
        let model = ShellHostModel(
            config: ShellHostConfig(
                gamesRoot: gamesRoot,
                appDataRoot: appData,
                environment: HostEnvironment(chain: "b-3f9a2c"),
                defaults: TestDefaults.keyed("cheat-delete-test"),
                sideloadCertBacking: InMemoryCertBacking()
            ),
            launcher: MockRecordingLauncher(recorder: recorder),
            shellSettings: ShellSettingsStore(defaults: TestDefaults.make("cheat-delete-shell"))
        )

        // Initial load seeds bundled cheat.
        let seededSnap = await model.loadCheatsSnapshotAsync(for: titleID)
        #expect(seededSnap.hasCurrentFile)
        _ = await model.setCheatEntryAsync(for: titleID, key: "HP", on: true)

        // User deletes cheat file via CheatsSheetView action -> removed + recorded in .deleted.json + .enabled cleared.
        let afterDelete = await model.deleteCheatFileAsync(for: titleID)
        #expect(!afterDelete.hasCurrentFile)
        let cheatsDir = appData.appendingPathComponent("\(titleID)/cheats", isDirectory: true)
        let store = GameCheatsStore(titleID: titleID, cheatsFolder: cheatsDir, frameworkURL: gameDir.appendingPathComponent("DmGame.framework"))
        #expect(store.readDeletedCheatFiles().contains("\(buildID).txt"))
        #expect(!FileManager.default.fileExists(atPath: store.enabledURL(for: buildID).path))

        // Launching the game triggers EngineLaunchPlan/finishLaunch seeding, which must NOT restore deleted file.
        #expect(model.details.first?.game.state == .playable)
        await model.playNow(titleID)
        #expect(model.notice == nil)
        #expect(recorder.launched.count == 1)
        #expect(!FileManager.default.fileExists(atPath: store.flatCheatURL(for: buildID).path))
    }

    @Test func engineLaunchPlanCreateFoldersSeedsBundledCheatsWithoutModifyingEnabled() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let gamesRoot = root.appendingPathComponent("Games", isDirectory: true)
        let bundledCheat = Data("[HP]\n04000000 00180020 000003E7\n".utf8)
        let gameDir = try makePlayableGameDir(
            at: gamesRoot,
            titleID: titleID,
            buildID: buildID,
            bundledCheats: ["\(buildID).txt": bundledCheat]
        )
        let fw = gameDir.appendingPathComponent("DmGame.framework", isDirectory: true)
        let appFolder = root.appendingPathComponent("docs/games/\(titleID)", isDirectory: true)
        let entry = try #require(GameCatalogue.scan(root: gamesRoot).first)
        let game = LaunchableGame(
            titleID: titleID,
            name: entry.title,
            manifest: try #require(entry.manifest),
            directory: gameDir,
            frameworkURL: fw,
            dataURL: root.appendingPathComponent("data"),
            appFolder: appFolder,
            environment: [:]
        )
        let plan = EngineLaunchPlan.make(
            game: game,
            appResources: root.appendingPathComponent("appRes"),
            documents: root.appendingPathComponent("docs"),
            envFileText: nil
        )
        try plan.createFolders()

        let seededFile = appFolder.appendingPathComponent("cheats/\(buildID).txt")
        #expect(FileManager.default.fileExists(atPath: seededFile.path))
        #expect(!FileManager.default.fileExists(atPath: appFolder.appendingPathComponent("cheats/\(buildID).enabled").path))
    }

    // MARK: - 2. Online Fetcher, Merge, Timeout, Size Limit, Offline & User-File Protection

    @Test func fetcherMergesSourcesOrdersMasterFirstDeduplicatesAndProtectsUserFiles() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cheatsDir = root.appendingPathComponent("cheats", isDirectory: true)

        let mainDB: [String: Any] = [
            "attribution": ["author": "community"],
            buildID.lowercased(): [
                "[Infinite Health]": "[Infinite Health]\n04000000 00180020 000003E7",
                "{Master Code}": "{Master Code}\n580F0000 00200000",
            ],
        ]
        let gbatempDB: [String: Any] = [
            buildID: [
                "[Infinite Health]": "[Infinite Health]\n04000000 00180020 00000001",
                "[2x Speed]": "04000000 00000800 1E202800",
            ],
        ]
        let gfxDB: [String: Any] = [
            buildID: [
                "[60 FPS]": "[60 FPS]\n04000000 00180050 0000003C",
            ],
        ]

        let mainData = try JSONSerialization.data(withJSONObject: mainDB)
        let gbaData = try JSONSerialization.data(withJSONObject: gbatempDB)
        let gfxData = try JSONSerialization.data(withJSONObject: gfxDB)

        let transport = MockHTTPTransport { request in
            let urlStr = request.url?.absoluteString ?? ""
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if urlStr.contains("/cheats/\(self.titleID).json") { return (mainData, resp) }
            if urlStr.contains("/cheats_gbatemp/\(self.titleID).json") { return (gbaData, resp) }
            if urlStr.contains("/cheats_gfx/\(self.titleID).json") { return (gfxData, resp) }
            let nf = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data(), nf)
        }

        let fixedDate = Date(timeIntervalSince1970: 1_795_770_123)
        let fetcher = IOSCheatFetcher(now: { fixedDate }, transport: { try await transport.send($0) })
        let receipt = await fetcher.fetchAndSave(titleID: titleID, buildID: buildID, to: cheatsDir)

        let captured = await transport.capturedRequests()
        #expect(captured.count == 3)
        #expect(captured.allSatisfy { $0.timeoutInterval == 5.0 })

        #expect(receipt.status == "found")
        #expect(receipt.entryCount == 4)
        #expect(receipt.fetchedAt == 1_795_770_123)
        #expect(receipt.sources == [
            "HamletDuFromage/switch-cheats-db",
            "HamletDuFromage/switch-cheats-db (gbatemp)",
            "HamletDuFromage/switch-cheats-db (gfx)",
        ])
        #expect(receipt.origin == "fetched")
        #expect(receipt.fileName == "\(buildID).txt")

        let savedText = try String(contentsOf: cheatsDir.appendingPathComponent("\(buildID).txt"), encoding: .utf8)
        // Master code must appear first, and Infinite Health must use the first source (000003E7), not gbatemp (00000001).
        let masterIdx = try #require(savedText.range(of: "{Master Code}")?.lowerBound)
        let healthIdx = try #require(savedText.range(of: "[Infinite Health]")?.lowerBound)
        #expect(masterIdx < healthIdx)
        #expect(savedText.contains("000003E7"))
        #expect(!savedText.contains("00000001"))
        #expect(savedText.contains("[2x Speed]\n04000000 00000800 1E202800"))
        #expect(!FileManager.default.fileExists(atPath: cheatsDir.appendingPathComponent("\(buildID).enabled").path))

        // If user modifies the file on disk, a subsequent fetch must preserve user file and emit preserved_user.
        let userCustom = Data("[User Custom]\n04000000 00180090 00000009\n".utf8)
        try userCustom.write(to: cheatsDir.appendingPathComponent("\(buildID).txt"))
        let preserved = await fetcher.fetchAndSave(titleID: titleID, buildID: buildID, to: cheatsDir)
        #expect(preserved.status == "preserved_user")
        let stillUser = try Data(contentsOf: cheatsDir.appendingPathComponent("\(buildID).txt"))
        #expect(stillUser == userCustom)
    }

    @Test func fetcherHandlesOfflineOversizedAndExplicitRefetchAfterDelete() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let gamesRoot = root.appendingPathComponent("Games", isDirectory: true)
        let bundled = Data("[HP]\n04000000 00180020 000003E7\n".utf8)
        let gameDir = try makePlayableGameDir(
            at: gamesRoot,
            titleID: titleID,
            buildID: buildID,
            bundledCheats: ["\(buildID).txt": bundled]
        )
        let appData = root.appendingPathComponent("appData", isDirectory: true)

        // Offline transport
        let offlineModel = ShellHostModel(
            config: ShellHostConfig(
                gamesRoot: gamesRoot,
                appDataRoot: appData,
                environment: HostEnvironment(chain: "b-3f9a2c"),
                defaults: TestDefaults.keyed("cheat-offline-test"),
                fetchCheatsTransport: { _ in throw URLError(.notConnectedToInternet) },
                sideloadCertBacking: InMemoryCertBacking()
            ),
            shellSettings: ShellSettingsStore(defaults: TestDefaults.make("cheat-offline-shell"))
        )
        let offlineOutcome = await offlineModel.fetchCheatsAsync(for: titleID)
        guard case .completed(_, let offReceipt) = offlineOutcome else {
            Issue.record("Expected offline receipt")
            return
        }
        #expect(offReceipt.status == "offline")

        // Delete the file so it enters .deleted.json, then explicitly fetch online -> must succeed and clear .deleted.json!
        _ = await offlineModel.deleteCheatFileAsync(for: titleID)
        let store = GameCheatsStore(
            titleID: titleID,
            appFolder: appData.appendingPathComponent(titleID),
            frameworkURL: gameDir.appendingPathComponent("DmGame.framework")
        )
        #expect(store.readDeletedCheatFiles().contains("\(buildID).txt"))

        let hugePayload = Data(repeating: UInt8(ascii: " "), count: IOSCheatFetcher.maxResponseBytes + 16)
        let validDB = try JSONSerialization.data(withJSONObject: [
            buildID: ["[Refetched]": "[Refetched]\n04000000 00180020 00000100"],
        ])
        let refetchModel = ShellHostModel(
            config: ShellHostConfig(
                gamesRoot: gamesRoot,
                appDataRoot: appData,
                environment: HostEnvironment(chain: "b-3f9a2c"),
                defaults: TestDefaults.keyed("cheat-refetch-test"),
                fetchCheatsTransport: { request in
                    let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    if request.url!.absoluteString.contains("/cheats/") {
                        return (hugePayload, resp) // oversized first mirror must be rejected cleanly
                    }
                    if request.url!.absoluteString.contains("/cheats_gbatemp/") {
                        return (validDB, resp)
                    }
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
                },
                sideloadCertBacking: InMemoryCertBacking()
            ),
            shellSettings: ShellSettingsStore(defaults: TestDefaults.make("cheat-refetch-shell"))
        )
        let refetchOutcome = await refetchModel.fetchCheatsAsync(for: titleID)
        guard case .completed(let snap, let receipt) = refetchOutcome else {
            Issue.record("Expected completed refetch")
            return
        }
        #expect(receipt.status == "found")
        #expect(snap.hasCurrentFile)
        #expect(snap.entries.map(\.name) == ["Refetched"])
        #expect(!store.readDeletedCheatFiles().contains("\(buildID).txt"))
    }

    // MARK: - 3. Fixed Address Detection & Unsafe Code Blocking

    @Test func detectsFixedAddressAcrossOpcodesZeroOneFiveWithoutPointerChainFalsePositives() {
        let cheatText = """
        [Op0 Fixed Heap]
        04100000 00004200 000F423F
        [Op0 Fixed Alias]
        04200000 00001000 00000001
        [Op1 Fixed Heap Conditional]
        14110000 00004200 00000001
        20000000
        [Op5 Fixed Heap Load]
        581F0000 00004200
        041F0000 00000010 00000063
        [Pointer Chain Safe]
        580F0000 00200000
        580F1000 00000010
        14111F00 00000020 00000001
        041F0000 00000030 000003E7
        20000000
        [Main Data Write Safe]
        04000000 00180020 00000005
        """
        let parsed = GameCheatsStore.parse(Data(cheatText.utf8), rxEnd: 0x100000)
        let byName = Dictionary(uniqueKeysWithValues: parsed.map { ($0.name, $0) })

        #expect(byName["Op0 Fixed Heap"]?.hasFixedAddress == true)
        #expect(byName["Op0 Fixed Heap"]?.capability == .fixedHeapWarning)
        #expect(byName["Op0 Fixed Alias"]?.hasFixedAddress == true)
        #expect(byName["Op0 Fixed Alias"]?.capability == .fixedHeapWarning)
        #expect(byName["Op1 Fixed Heap Conditional"]?.hasFixedAddress == true)
        #expect(byName["Op1 Fixed Heap Conditional"]?.capability == .fixedHeapWarning)
        #expect(byName["Op5 Fixed Heap Load"]?.hasFixedAddress == true)
        #expect(byName["Op5 Fixed Heap Load"]?.capability == .fixedHeapWarning)

        #expect(byName["Pointer Chain Safe"]?.hasFixedAddress == false)
        #expect(byName["Pointer Chain Safe"]?.capability == .dataReady)
        #expect(byName["Main Data Write Safe"]?.hasFixedAddress == false)
        #expect(byName["Main Data Write Safe"]?.capability == .dataReady)
    }

    @Test func parsesUnsafeCodeReasonAndBlocksEnablingOnIOS() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let trampolines = """
        # BUILD_ID\t\(buildID)
        # MAIN_RX_END\t0x100000
        row_type\tname\tcheat_key\tkind\tslot_id\tvariant_mask\ttarget_off\tpatched_word\tkey_mask\tdetail
        entry\tUnsafe Bypass\tUnsafe Bypass\tunsafe_code\t-1\t0x0\t0x400\t0xd503201f\t0x0\tdataflow_bypass: x24 read at +0x1468a74 bypassed def at +0x1468a5c
        """
        let fw = root.appendingPathComponent("DmGame.framework", isDirectory: true)
        try makeFramework(at: fw, buildID: buildID, trampolines: trampolines)

        let appFolder = root.appendingPathComponent("app", isDirectory: true)
        let store = GameCheatsStore(titleID: titleID, appFolder: appFolder, frameworkURL: fw)
        let cheatText = """
        [Unsafe Bypass]
        04000000 00000400 D503201F
        [Safe Data]
        04000000 00180020 00000001
        """
        _ = try store.saveCheatFile(data: Data(cheatText.utf8), targetBuildID: buildID, gameTitle: "Unsafe Fixture")
        let snap = store.loadSnapshot(gameTitle: "Unsafe Fixture")

        #expect(snap.unsafeCodeCount == 1)
        #expect(snap.codeNeedsBakeCount == 0)
        let unsafeEntry = try #require(snap.entries.first(where: { $0.name == "Unsafe Bypass" }))
        #expect(unsafeEntry.isUnsafeCode)
        #expect(unsafeEntry.unsafeCodeReason == "dataflow_bypass: x24 read at +0x1468a74 bypassed def at +0x1468a5c")
        #expect(!unsafeEntry.switchableOnIOS)

        // Attempting to force-enable unsafe_code must never persist to <BID>.enabled.
        let afterEnable = try store.setEntryEnabled(key: "Unsafe Bypass", on: true, gameTitle: "Unsafe Fixture")
        let stillBlocked = try #require(afterEnable.entries.first(where: { $0.name == "Unsafe Bypass" }))
        #expect(!stillBlocked.enabled)
        #expect(store.readEnabled(for: buildID).isEmpty)
    }

    // MARK: - 4. Manual Fetch Preview, Diff, Merge/Replace Backup & Cross-Platform Receipt

    @Test func manualFetchOverUserFileReturnsPreviewWithoutOverwritingAndSupportsMergeAndReplace() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let gamesRoot = root.appendingPathComponent("Games", isDirectory: true)
        let trampolines = """
        # BUILD_ID\t\(buildID)
        # MAIN_RX_END\t0x100000
        row_type\tname\tcheat_key\tkind\tslot_id\tvariant_mask\ttarget_off\tpatched_word\tkey_mask\tdetail
        entry\tBaked Jump\tBaked Jump\tbaked_static\t0\t0x1\t0x400\t0xd503201f\t0x0\t
        """
        let gameDir = try makePlayableGameDir(
            at: gamesRoot,
            titleID: titleID,
            buildID: buildID,
            trampolines: trampolines
        )
        let appData = root.appendingPathComponent("appData", isDirectory: true)
        let cheatsDir = appData.appendingPathComponent("\(titleID)/cheats", isDirectory: true)
        try FileManager.default.createDirectory(at: cheatsDir, withIntermediateDirectories: true)

        let localText = """
        [Infinite Health]
        04000000 00180020 000003E7

        [Local Only Bonus]
        04000000 00180030 00000064
        """
        let localURL = cheatsDir.appendingPathComponent("\(buildID).txt")
        let localData = Data(localText.utf8)
        try localData.write(to: localURL)
        try Data("Infinite Health\nLocal Only Bonus\n".utf8).write(to: cheatsDir.appendingPathComponent("\(buildID).enabled"))

        // Mark deleted previously to verify merge/replace also clears .deleted.json.
        let store = GameCheatsStore(
            titleID: titleID,
            cheatsFolder: cheatsDir,
            frameworkURL: gameDir.appendingPathComponent("DmGame.framework")
        )
        try Data("[\"\(buildID).txt\"]".utf8).write(to: store.deletedURL)

        let dbPayload = try JSONSerialization.data(withJSONObject: [
            buildID: [
                "{Master Code}": "{Master Code}\n580F0000 00200000",
                "[Infinite Health]": "[Infinite Health]\n04000000 00180020 00000999",
                "[Max Rupees]": "[Max Rupees]\n04100000 00004200 000F423F",
                "[Baked Jump]": "[Baked Jump]\n04000000 00000400 D503201F",
                "[Code Needs Bake]": "[Code Needs Bake]\n04000000 00000800 1E202800",
            ],
        ])

        let fixedDate = Date(timeIntervalSince1970: 1_795_770_555)
        let model = ShellHostModel(
            config: ShellHostConfig(
                gamesRoot: gamesRoot,
                appDataRoot: appData,
                environment: HostEnvironment(chain: "b-3f9a2c"),
                defaults: TestDefaults.keyed("cheat-preview-test"),
                fetchCheatsTransport: { request in
                    if request.url?.absoluteString.contains("/cheats/\(self.titleID).json") == true {
                        let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                        return (dbPayload, ok)
                    }
                    let nf = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                    return (Data(), nf)
                },
                now: { fixedDate },
                sideloadCertBacking: InMemoryCertBacking()
            ),
            shellSettings: ShellSettingsStore(defaults: TestDefaults.make("cheat-preview-shell"))
        )

        let outcome = await model.fetchCheatsAsync(for: titleID)
        guard case .previewRequired(let snapBeforeDecision, let receipt, let preview) = outcome else {
            Issue.record("Expected previewRequired outcome, got \(outcome)")
            return
        }

        // Local file must NOT be overwritten yet.
        #expect(try Data(contentsOf: localURL) == localData)
        #expect(receipt.status == "preserved_user")
        #expect(receipt.origin == "user")
        #expect(snapBeforeDecision.entries.map(\.name) == ["Infinite Health", "Local Only Bonus"])

        // Verify diff summary and entry classifications.
        #expect(preview.titleID == titleID)
        #expect(preview.buildID == buildID)
        #expect(preview.fileName == "\(buildID).txt")
        #expect(preview.sources == ["HamletDuFromage/switch-cheats-db"])
        #expect(preview.localCount == 2)
        #expect(preview.onlineCount == 5)
        #expect(preview.addedCount == 4)
        #expect(preview.sameNameCount == 1)
        #expect(preview.localOnlyCount == 1)

        let byName = Dictionary(uniqueKeysWithValues: preview.entries.map { ($0.name, $0) })
        #expect(byName["Master Code"]?.isMaster == true)
        #expect(byName["Master Code"]?.isAdded == true)
        #expect(byName["Infinite Health"]?.isAdded == false)
        #expect(byName["Infinite Health"]?.capability == .dataReady)
        #expect(byName["Infinite Health"]?.rawLines == ["04000000 00180020 00000999"])
        #expect(byName["Max Rupees"]?.isAdded == true)
        #expect(byName["Max Rupees"]?.hasFixedAddress == true)
        #expect(byName["Max Rupees"]?.capability == .fixedHeapWarning)
        #expect(byName["Baked Jump"]?.capability == .codeBaked)
        #expect(byName["Code Needs Bake"]?.capability == .codeNeedsBake)

        // 1. Merge online cheats -> creates .bak, keeps local entries & .enabled switches, adds only new entries (default OFF).
        let mergeOutcome = await model.mergeOnlineCheatsAsync(for: titleID, preview: preview)
        guard case .applied(let mergedSnap) = mergeOutcome else {
            Issue.record("Expected applied merge outcome, got \(mergeOutcome)")
            return
        }
        let backupURL = cheatsDir.appendingPathComponent("\(buildID).txt.bak")
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(try Data(contentsOf: backupURL) == localData)
        #expect(!store.readDeletedCheatFiles().contains("\(buildID).txt"))
        #expect(mergedSnap.fetchReceipt?.origin == "user")
        #expect(mergedSnap.fetchReceipt?.status == "preserved_user")

        let mergedText = try String(contentsOf: localURL, encoding: .utf8)
        #expect(mergedText.contains("000003E7")) // local Infinite Health preserved
        #expect(!mergedText.contains("00000999")) // online Infinite Health not duplicated
        #expect(mergedText.contains("[Local Only Bonus]"))
        #expect(mergedText.contains("[Max Rupees]"))

        let mergedByName = Dictionary(uniqueKeysWithValues: mergedSnap.entries.map { ($0.name, $0) })
        #expect(mergedByName["Infinite Health"]?.enabled == true)
        #expect(mergedByName["Local Only Bonus"]?.enabled == true)
        #expect(mergedByName["Max Rupees"]?.enabled == false)
        #expect(mergedByName["Baked Jump"]?.enabled == false)

        // 2. Replace with online cheats -> backs up merged file to .bak, writes onlineText, updates receipt to found/fetched, prunes stale .enabled.
        let beforeReplaceData = try Data(contentsOf: localURL)
        let replaceOutcome = await model.replaceWithOnlineCheatsAsync(for: titleID, preview: preview)
        guard case .applied(let replacedSnap) = replaceOutcome else {
            Issue.record("Expected applied replace outcome, got \(replaceOutcome)")
            return
        }
        #expect(try Data(contentsOf: backupURL) == beforeReplaceData)
        #expect(try String(contentsOf: localURL, encoding: .utf8) == preview.onlineText)
        #expect(replacedSnap.fetchReceipt?.status == "found")
        #expect(replacedSnap.fetchReceipt?.origin == "fetched")
        #expect(!store.readDeletedCheatFiles().contains("\(buildID).txt"))

        let enabledAfterReplace = store.readEnabled(for: buildID)
        #expect(enabledAfterReplace == Set(["Infinite Health"]))
        #expect(!enabledAfterReplace.contains("Local Only Bonus"))
    }

    @Test func fetchReceiptDecodesCrossPlatformStatusesAndTimestampFormats() throws {
        // Mac writes status = "fetched" and ISO-8601 fetchedAt string.
        let macJSON = Data("""
        {
          "schemaVersion": 1,
          "titleID": "\(titleID)",
          "buildID": "\(buildID)",
          "status": "fetched",
          "sources": ["switch-cheats-db"],
          "entryCount": 12,
          "fetchedAt": "2026-11-27T12:12:29Z",
          "fileName": "\(buildID).txt",
          "fileSHA256": "deadbeef",
          "origin": "fetched",
          "detail": ""
        }
        """.utf8)
        let macReceipt = try JSONDecoder().decode(GameCheatFetchReceipt.self, from: macJSON)
        #expect(macReceipt.status == "fetched")
        #expect(macReceipt.isFoundStatus)
        #expect(macReceipt.fetchedAt > 1_795_000_000)

        // Fractional seconds ISO-8601 string.
        let fractionalJSON = Data("""
        {
          "titleID": "\(titleID)",
          "buildID": "\(buildID)",
          "status": "found",
          "fetchedAt": "2026-11-27T12:12:29.500Z"
        }
        """.utf8)
        let fractionalReceipt = try JSONDecoder().decode(GameCheatFetchReceipt.self, from: fractionalJSON)
        #expect(fractionalReceipt.isFoundStatus)
        #expect(abs(fractionalReceipt.fetchedAt - macReceipt.fetchedAt - 0.5) < 0.01)

        // Python / iOS writes numeric timestamp and status = "found".
        let pyJSON = Data("""
        {
          "schemaVersion": 1,
          "titleID": "\(titleID)",
          "buildID": "\(buildID)",
          "status": "found",
          "sources": ["HamletDuFromage/switch-cheats-db"],
          "entryCount": 4,
          "fetchedAt": 1795770000,
          "fileName": "\(buildID).txt",
          "fileSHA256": "cafebabe",
          "origin": "fetched",
          "detail": ""
        }
        """.utf8)
        let pyReceipt = try JSONDecoder().decode(GameCheatFetchReceipt.self, from: pyJSON)
        #expect(pyReceipt.isFoundStatus)
        #expect(pyReceipt.fetchedAt == 1_795_770_000)
    }
}
