import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
import NXModel
@testable import NXLauncher

/// Opt-in screenshots for the achievements sheet, the hero count, and the Manage row.
/// `NX_LAUNCHER_CAPTURE_DIR=<dir> swift test --filter testRenderAchievementsForVisualQA`
@MainActor final class AchievementsCaptureTests: IsolatedDefaultsTestCase {
    private var temporary: URL!
    private let titleID = "01007EF00011E000"
    private let fm = FileManager.default

    override func setUpWithError() throws {
        temporary = fm.temporaryDirectory.appendingPathComponent("nxnative-achievements-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: temporary) }

    func testRenderAchievementsForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else {
            throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views")
        }
        let output = URL(fileURLWithPath: directory)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        XCTAssertNotNil(AchievementCatalog.bundled()[titleID], "the bundled catalog has no list for Breath of the Wild")

        let app = temporary.appendingPathComponent("Breath of the Wild.app")
        let executables = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: executables, withIntermediateDirectories: true)
        for name in ["nxnative", "dmhost"] {
            try fm.createSymbolicLink(at: executables.appendingPathComponent(name), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        let info: [String: Any] = ["DMTitleID": titleID, "CFBundleDisplayName": "The Legend of Zelda: Breath of the Wild",
                                   "CFBundleExecutable": "nxnative", "CFBundleIdentifier": "org.nxnative.achievements." + temporary.lastPathComponent]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))

        let support = temporary.appendingPathComponent("NS Port Builder")
        var book = AchievementProgress()
        for id in ["leave-the-plateau", "the-master-sword", "divine-beast"] { book.toggle(titleID: titleID, id: id) }
        try book.write(file: AchievementProgress.file(in: support))

        let modelStores = LauncherStores(defaults: testDefaults)
        MainActor.assumeIsolated { modelStores.dependencies.checked = true }
        MainActor.assumeIsolated { modelStores.dependencies.deps = [Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])] }
        let library = GameLibrary(file: temporary.appendingPathComponent("preview.json"))
        let gameID = try library.addApp(app)
        library.selectedID = gameID
        let game = try XCTUnwrap(library.games.first { $0.id == gameID })

        func shot(_ name: String, _ view: some View, width: CGFloat, height: CGFloat, titled: Bool) throws {
            let host = NSHostingView(rootView: view)
            let style: NSWindow.StyleMask = titled ? [.titled, .closable, .resizable] : [.titled]
            let window = OffscreenWindow(size: NSSize(width: width, height: height), styleMask: style)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }

        for code in ["en", "de", "fr", "it", "sv", "zh"] {
            modelStores.localizer.lang = Lang(code)
            try shot("achievements-hero-\(code)",
                     LauncherView(stores: modelStores, library: library, performStartupChecks: false, achievementFolder: support),
                     width: 1440, height: 1024, titled: true)
            try shot("achievements-menu-\(code)",
                     LauncherView(stores: modelStores, library: library, performStartupChecks: false, manageOpen: true, achievementFolder: support),
                     width: 1440, height: 1024, titled: true)
            try shot("achievements-sheet-\(code)",
                     AchievementsView(game: game, support: support).environmentObject(modelStores.localizer).environmentObject(PadFocus()),
                     width: 640, height: 760, titled: false)
        }
    }
}
