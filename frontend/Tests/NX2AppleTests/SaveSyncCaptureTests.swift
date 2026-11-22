import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

/// Visual QA of immediate cloud save sync rows, conflict resolution sheet, and Switch JKSV `.zip` import/export controls.
final class SaveSyncCaptureTests: IsolatedDefaultsTestCase {
    @MainActor func testRenderSaveSyncAndJKSVForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else {
            throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views")
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("save-sync-qa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let stores = LauncherStores(defaults: testDefaults)
        let lang = CaptureLanguage.current(.en)
        stores.localizer.lang = lang

        let appDir = temp.appendingPathComponent("Game.app")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let titleID = "0100535012974000"
        let game = LibraryGame(titleID: titleID, name: "Hades", appPath: appDir.path)

        var saves = GameCloudSaves(titleID: titleID, appPath: appDir.path)
        saves.home = "/Users/jo"
        let drive = "/Users/jo/Library/Mobile Documents/com~apple~CloudDocs/nxnative Saves"
        saves.readPreference = { drive }
        saves.writePreference = { _ in }

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let localSave = CloudSaveCheck.Save(hash: "11112222333344445555666677778888", saved: now.addingTimeInterval(-1800))
        let cloudSave = CloudSaveCheck.Save(hash: "aaaabbbbccccddddeeeeffff00001111", saved: now.addingTimeInterval(-300), device: "iPhone17,1")

        func render<V: View>(_ name: String, width: CGFloat = LauncherSheet.width, _ view: V) throws {
            let framed = view
                .environmentObject(stores.localizer)
                .environmentObject(PadFocus())
                .padding(24)
                .frame(width: width)
                .background(LauncherPalette.background)
                .font(.manrope(13))
                .preferredColorScheme(.dark)
            let host = NSHostingView(rootView: framed)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = OffscreenWindow(size: host.frame.size)
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(
                to: output.appendingPathComponent("\(name)-\(lang.code).png")
            )
        }

        let cardStates: [(String, CloudSaveNow.SyncStatus)] = [
            ("cloud-sync-in-step", .inStep(local: localSave, cloud: localSave)),
            ("cloud-sync-pull", .onlyCloudChanged(local: localSave, cloud: cloudSave)),
            ("cloud-sync-conflict", .conflict(local: localSave, cloud: cloudSave)),
        ]
        for (name, syncStatus) in cardStates {
            let card = CloudSavesCard(
                game: game,
                saves: saves,
                overrides: stores.saveSettings,
                players: stores.players,
                preview: (.hasSave(cloudSave.saved), (.inStep, now.addingTimeInterval(-7200))),
                previewSync: syncStatus,
                home: "/Users/jo"
            )
            try render(name, card)
        }

        let plan = CloudSaveNow.SyncPlan(
            titleID: titleID,
            gameName: game.displayName(lang),
            save: temp.appendingPathComponent("save"),
            cloudFile: temp.appendingPathComponent("save.dmsync")
        )
        let prompt = CloudSaveSyncStore.ConflictPrompt(plan: plan, local: localSave, cloud: cloudSave)
        try render("cloud-sync-conflict-sheet", width: 520, CloudSyncConflictSheet(prompt: prompt, picked: .cloud, cancel: {}, choose: { _ in }))

        try render("game-saves-jksv", GameSavesSection(game: game, settings: stores.saveSettings, players: stores.players))
    }
}
