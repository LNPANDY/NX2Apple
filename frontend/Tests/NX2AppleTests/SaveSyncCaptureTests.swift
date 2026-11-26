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
        let macOSDir = appDir.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: macOSDir.appendingPathComponent("nxnative"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        try FileManager.default.createSymbolicLink(at: macOSDir.appendingPathComponent("dmhost"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let titleID = "0100535012974000"
        let info: [String: Any] = ["DMTitleID": titleID, "CFBundleExecutable": "nxnative", "CFBundleDisplayName": "Hades"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: appDir.appendingPathComponent("Contents/Info.plist"))
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

        let libFile = temp.appendingPathComponent("library.json")
        struct Snapshot: Codable { let games: [LibraryGame]; let folder: String }
        try JSONEncoder().encode(Snapshot(games: [game], folder: temp.path)).write(to: libFile)
        let library = GameLibrary(file: libFile, defaults: testDefaults)
        let optionsView = LaunchOptionsView(
            m: stores.build,
            library: library,
            gameID: game.id,
            initialCategory: .saves,
            savesDevicectl: DeviceControl { _ in (false, "") },
            savesListDevices: { [] }
        )
            .environmentObject(stores.saveSettings)
            .environmentObject(stores.players)
            .environment(\.dsSheetMaxHeight, 760)
            .launcherDropdownHost()
        let host = NSHostingView(
            rootView: optionsView
                .environmentObject(stores.localizer)
                .environmentObject(PadFocus())
                .preferredColorScheme(.dark)
        )
        host.frame = NSRect(origin: .zero, size: NSSize(width: LauncherSheet.width, height: 760))
        let win = OffscreenWindow(size: host.frame.size)
        win.contentView = host
        win.orderFront(nil)
        defer { win.orderOut(nil); win.contentView = nil; win.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(
            to: output.appendingPathComponent("launch-options-saves-\(lang.code).png")
        )
    }
}
