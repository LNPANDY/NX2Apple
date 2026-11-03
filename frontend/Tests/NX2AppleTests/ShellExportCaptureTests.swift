import XCTest
import SwiftUI
import AppKit
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// Visual QA of LNPANDY/NX2Apple#416 (matched by --filter testRenderExportStatesForVisualQA).
final class ShellExportCaptureTests: IsolatedDefaultsTestCase {
    /// The Install card in every state of the export, for the pull request's screenshots: ready, exported, sending, done, app not found,
    /// refused, several apps, drive, copying, copied, FAT32 and the drive before an export. Also the card with the install flow, which the segmented switch changed.
    @MainActor func testRenderExportStatesForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let lang = ProcessInfo.processInfo.environment["NX_CAPTURE_LANG"].flatMap { Lang.find($0) } ?? .en
        let shellFolder = fm.temporaryDirectory.appendingPathComponent("NX2Apple-capture-\(UUID().uuidString)")
        try fm.createDirectory(at: shellFolder, withIntermediateDirectories: true)
        let ipa = shellFolder.appendingPathComponent("NX2Apple.ipa")   // the name an export writes
        fm.createFile(atPath: ipa.path, contents: nil)
        let handle = try FileHandle(forWritingTo: ipa)
        try handle.truncate(atOffset: 184_000_000)   // a sparse file of the size the card shows
        try handle.close()
        defer { try? fm.removeItem(at: shellFolder) }

        let stores = LauncherStores(defaults: testDefaults); let model = stores.build
        stores.localizer.lang = lang
        model.target = "ios"
        model.slots[0].paths = ["/Games/Super Mario Odyssey [0100000000010000].nsp"]
        stores.deviceStore.devices = [AppleDevice(id: "DEV-1", name: "Zijad’s iPhone", model: "iPhone 17 Pro", os: "27.0", reachable: true, transport: "wired")]
        stores.deviceStore.checked = true
        stores.deviceStore.installDevice = "DEV-1"
        stores.deviceStore.sendWhere = SendWhere.device
        stores.deviceStore.exportOneGame = false
        func shot<V: View>(_ name: String, _ view: V) throws {
            let framed = view.environmentObject(stores.localizer).padding(24).frame(width: 760).background(Color(white: 0.09)).environment(\.colorScheme, .dark)
            NSApplication.shared.setActivationPolicy(.accessory)
            let host = NSHostingView(rootView: framed)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            // the fitting size can round above the laid-out card: the page colour, not white, fills the rest
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor
            let window = OffscreenWindow(size: host.frame.size)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("export-\(name)-\(lang.code).png"))
            window.orderOut(nil)
        }
        func card() -> InstallCard { InstallCard(devices: stores.deviceStore, build: model) }

        stores.deviceStore.exportIPA = false
        try shot("0-install", card())
        stores.deviceStore.exportIPA = true
        try shot("1-ready", card())
        model.exportedIPAPath = ipa.path
        model.archivePath = "/Users/me/Games/0100000000010000_build/games/0100000000010000"
        try shot("2-exported", card())
        model.send = .sending(done: 3_100_000_000, total: 12_400_000_000,
                              note: L10n.string("shell.copyWired", lang).replacingOccurrences(of: "%@", with: "Zijad’s iPhone"))
        try shot("3-sending", card())
        model.send = .sent(app: "NX2Apple")
        try shot("4-done", card())
        model.send = .appNotFound
        try shot("5-app-not-found", card())
        model.send = .refused(detail: "ERROR: Failed to copy: the app does not allow access to its data container (get-task-allow). (com.apple.dt.CoreDeviceError error 7)")
        try shot("6-refused", card())
        model.finderShown = true   // after Copy with Finder (#491)
        try shot("6a-refused-finder", card())
        model.send = .chooseApp([InstalledApp(bundle: "org.nxnative.shell.ABCDE12345", name: "NX2Apple"),
                                 InstalledApp(bundle: "org.nxnative.shell", name: "NX2Apple")])
        try shot("6b-choose-app", card())
        model.send = .idle
        stores.deviceStore.sendWhere = SendWhere.drive
        stores.deviceStore.driveFolder = "/Volumes/GameDrive/Switch"
        model.drive = DriveState(volume: DriveCopy.Volume(freeBytes: 412_000_000_000, fileSystem: "exfat", readOnly: false), needed: 12_400_000_000, problem: nil)
        try shot("7-drive", card())
        model.send = .copying(done: 5_300_000_000, total: 12_400_000_000)
        try shot("8-drive-copying", card())
        model.send = .copied(folder: "/Volumes/GameDrive/Switch/0100000000010000")
        try shot("9-drive-done", card())
        model.send = .idle
        model.drive = DriveState(volume: DriveCopy.Volume(freeBytes: 412_000_000_000, fileSystem: "msdos", readOnly: false), needed: 12_400_000_000,
                                 problem: .fat32(largest: 12_000_000_000))
        try shot("10-fat32", card())
        model.exportedIPAPath = ""
        stores.deviceStore.driveFolder = ""
        model.drive = nil
        try shot("11-drive-before-export", card())
        // One game's own IPA with its game data inside (#540): two steps, no step 3
        stores.deviceStore.exportOneGame = true
        try shot("12-one-game-ready", card())
        let oneGame = shellFolder.appendingPathComponent("0100000000010000.ipa")   // the name a one-game export writes
        fm.createFile(atPath: oneGame.path, contents: nil)
        let big = try FileHandle(forWritingTo: oneGame)
        try big.truncate(atOffset: 5_900_000_000)
        try big.close()
        model.exportedIPAPath = oneGame.path
        try shot("13-one-game-exported", card())
    }
}
