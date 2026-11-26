import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

/// Regression tests verifying:
/// 1. Unified import NSOpenPanel allows directories, files (including extensionless Stardew saves), and multiple selection.
/// 2. `SavesView` and `LaunchOptionsView` (`.saves` tab) share unified controls and respect `SaveSettingsStore` overrides.
/// 3. External/shared MNG save routing remains intact across both save views.
final class SaveUnificationTests: IsolatedDefaultsTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private let stardewTID = "0100E65002BB8000"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory.appendingPathComponent("save-unify-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    @MainActor func testImportPanelAllowsFilesDirectoriesAndMultiSelectionWithoutExtensionFilter() {
        let panel = GameSavesSection.openImportPanelConfigured(nil)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertTrue(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.allowedContentTypes.isEmpty, "setting [.zip] grays out extensionless Stardew Valley save files")
    }

    func testSaveTransferMacSaveRespectsCustomOverrideAndGlobalSaveRoot() throws {
        let support = root.appendingPathComponent("support")
        let customSave = root.appendingPathComponent("custom/stardew/save")
        let globalRoot = root.appendingPathComponent("global-saves")

        let customResolved = SaveTransfer.macSave(
            titleID: stardewTID,
            appPath: "",
            global: SaveGlobalSettings(saveRoot: globalRoot.path),
            game: SaveGameOverride(saveFolder: customSave.path),
            support: support
        )
        XCTAssertEqual(customResolved.save.standardizedFileURL.path, customSave.standardizedFileURL.path)
        XCTAssertNil(customResolved.legacy)

        let globalResolved = SaveTransfer.macSave(
            titleID: stardewTID,
            appPath: "",
            global: SaveGlobalSettings(saveRoot: globalRoot.path),
            game: SaveGameOverride(),
            support: support
        )
        XCTAssertEqual(globalResolved.save.standardizedFileURL.path, globalRoot.appendingPathComponent("\(stardewTID)/save").standardizedFileURL.path)
    }

    @MainActor func testSavesViewAndLaunchOptionsSavesTabAlignFeaturesAndReflectOverrides() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let stores = LauncherStores(defaults: testDefaults)
        stores.localizer.lang = .en
        let support = root.appendingPathComponent("support")
        let customSave = root.appendingPathComponent("custom-save/save")
        try fm.createDirectory(at: customSave, withIntermediateDirectories: true)
        try Data("save".utf8).write(to: customSave.appendingPathComponent("slot"))

        stores.saveSettings.setGame(stardewTID, SaveGameOverride(saveFolder: customSave.path))

        let app = root.appendingPathComponent("Stardew Valley.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: app.appendingPathComponent("Contents/MacOS/nxnative"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        try fm.createSymbolicLink(at: app.appendingPathComponent("Contents/MacOS/dmhost"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let info: [String: Any] = ["DMTitleID": stardewTID, "CFBundleExecutable": "nxnative", "CFBundleDisplayName": "Stardew Valley"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))

        let iosApp = root.appendingPathComponent("Shell.app")
        try fm.createDirectory(at: iosApp, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.stardew"], format: .xml, options: 0)
            .write(to: iosApp.appendingPathComponent("Info.plist"))

        var game = LibraryGame(titleID: stardewTID, name: "Stardew Valley", appPath: app.path)
        game.iosAppPath = iosApp.path
        game.installedDevice = "00008150-AAAA"
        let library = GameLibrary(file: root.appendingPathComponent("library.json"), defaults: testDefaults)
        library.games = [game]

        let fakeDevice = AppleDevice(id: "00008150-AAAA", name: "iPhone", model: "iPhone17,1", os: "26.1", reachable: true)
        let fakeDevicectl = DeviceControl { args in
            guard let i = args.firstIndex(of: "--json-output") else { return (false, "missing json") }
            if args.starts(with: ["device", "info", "apps"]) {
                try? JSONSerialization.data(withJSONObject: ["result": ["apps": [["bundleIdentifier": "com.example.stardew", "name": game.name]]]])
                    .write(to: URL(fileURLWithPath: args[i + 1]))
                return (true, "")
            }
            let files = args.contains("--recurse") ? [["name": "SaveGameInfo", "fileType": "file", "modificationDate": ISO8601DateFormatter().string(from: Date())]] : []
            try? JSONSerialization.data(withJSONObject: ["result": ["files": files]])
                .write(to: URL(fileURLWithPath: args[i + 1]))
            return (true, "")
        }

        func registeredFocusIDs<V: View>(_ view: V, scope: String, width: CGFloat = 640, height: CGFloat = 900) -> Set<String> {
            let focus = PadFocus()
            let host = NSHostingView(
                rootView: view
                    .environmentObject(stores.localizer)
                    .environmentObject(focus)
                    .environmentObject(stores.saveSettings)
                    .environmentObject(stores.players)
                    .environment(\.dsSheetMaxHeight, height)
                    .launcherDropdownHost()
            )
            host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
            let window = OffscreenWindow(size: NSSize(width: width, height: height))
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.45))
            host.layoutSubtreeIfNeeded()
            return Set(focus.frames[scope, default: []].map(\.id))
        }

        let savesViewIDs = registeredFocusIDs(
            SavesView(
                m: stores.build,
                library: library,
                gameID: game.id,
                saveSettings: stores.saveSettings,
                players: stores.players,
                devicectl: fakeDevicectl,
                support: support,
                listDevices: { [fakeDevice] }
            ),
            scope: "saves"
        )
        let optionsSavesIDs = registeredFocusIDs(
            LaunchOptionsView(
                m: stores.build,
                library: library,
                gameID: game.id,
                initialCategory: .saves,
                savesDevicectl: fakeDevicectl,
                savesListDevices: { [fakeDevice] }
            ),
            scope: "launch"
        )

        let expectedSharedControls = [
            "saves.show",
            "saves.change",
            "saves.reset",
            "saves.import",
            "saves.export",
            "saves.exportZip",
            "saves.toDevice",
            "saves.toMac",
            "saves.refresh",
            "cloud.choose",
        ]
        for controlID in expectedSharedControls {
            XCTAssertTrue(savesViewIDs.contains(controlID), "SavesView missing aligned control \(controlID): \(savesViewIDs)")
            XCTAssertTrue(optionsSavesIDs.contains(controlID), "LaunchOptionsView(.saves) missing aligned control \(controlID): \(optionsSavesIDs)")
        }

        // Verify SavesModel.updateTemplate propagates override changes onto existing found SaveTransfer.
        let control = DeviceControl { _ in (false, "") }
        let defaultMac = SaveTransfer.macSave(titleID: stardewTID, appPath: app.path, support: support)
        let model = SavesModel(
            template: SaveTransfer(titleID: stardewTID, macSave: defaultMac.save, legacySave: defaultMac.legacy, device: "", bundle: "", devicectl: control),
            name: game.name,
            recordedBundle: nil,
            recordedDevice: "",
            installTarget: "",
            listDevices: { [] }
        )
        XCTAssertTrue(model.macSave.folders.isEmpty)
        let overrideMac = SaveTransfer.macSave(
            titleID: stardewTID,
            appPath: app.path,
            global: stores.saveSettings.global,
            game: stores.saveSettings.game(stardewTID),
            support: support
        )
        model.updateTemplate(
            SaveTransfer(titleID: stardewTID, macSave: overrideMac.save, legacySave: overrideMac.legacy, device: "", bundle: "", devicectl: control)
        )
        XCTAssertEqual(model.template.macSave.standardizedFileURL.path, customSave.standardizedFileURL.path)
        XCTAssertEqual(model.macSave.folders, ["save"])
    }
}
