import XCTest
import SwiftUI
@testable import NX2Apple
@testable import NXCore
import NXModel

/// LNPANDY/NX2Apple#895: the library in the launcher's language, with games whose apps carry their names from the control data
/// (`DMTitleNames`) and the same games from apps packed before the key, which show the bundle name as every launcher did before.
/// Opt-in: `NX_LAUNCHER_CAPTURE_DIR=<dir> swift test --filter GameTitleNamesCaptureTests` writes
/// `title-names-<lang>-before.png` and `title-names-<lang>-after.png` for Chinese and Japanese.
@MainActor final class GameTitleNamesCaptureTests: IsolatedDefaultsTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-title-names-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private static let games: [(id: String, name: String, names: [String: String])] = [
        ("0100000000010000", "Super Mario Odyssey", ["en-US": "Super Mario Odyssey", "ja": "スーパーマリオ オデッセイ", "zh-Hans": "超级马力欧 奥德赛", "zh-Hant": "超級瑪利歐 奧德賽"]),
        ("01007EF00011E000", "The Legend of Zelda: Breath of the Wild",
         ["en-US": "The Legend of Zelda: Breath of the Wild", "ja": "ゼルダの伝説 ブレス オブ ザ ワイルド", "zh-Hans": "塞尔达传说 旷野之息", "zh-Hant": "薩爾達傳說 曠野之息"]),
        ("010093801237C000", "Metroid Dread", ["en-US": "Metroid Dread", "ja": "メトロイド ドレッド", "zh-Hans": "密特罗德 生存恐惧", "zh-Hant": "密特羅德 生存恐懼"]),
    ]

    private func makeApp(_ id: String, name: String, names: [String: String]?, in folder: URL) throws -> URL {
        let app = folder.appendingPathComponent(id + ".app")
        let executables = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        for exe in ["nxnative", "dmhost"] {
            try FileManager.default.createSymbolicLink(at: executables.appendingPathComponent(exe), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        var info: [String: Any] = ["DMTitleID": id, "CFBundleDisplayName": name, "CFBundleExecutable": "nxnative",
                                   "CFBundleIdentifier": TestPreferences.domain(in: temporary, "titles-" + id)]
        if let names { info["DMTitleNames"] = names }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    func testRenderNamesInLauncherLanguage() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let stores = LauncherStores(defaults: testDefaults)
        MainActor.assumeIsolated { stores.dependencies.checked = true }
        for (step, withNames) in [("before", false), ("after", true)] {
            let folder = temporary.appendingPathComponent(step)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let library = GameLibrary(file: folder.appendingPathComponent("library.json"))
            for g in Self.games { _ = try library.addApp(makeApp(g.id, name: g.name, names: withNames ? g.names : nil, in: folder)) }
            library.selectedID = library.games.first { $0.titleID == Self.games[1].id }?.id
            for lang in CaptureLanguage.all([.zh, Lang("ja")]) {
                stores.localizer.lang = lang
                let host = NSHostingView(rootView: LauncherView(stores: stores, library: library, initialPage: .library, performStartupChecks: false))
                let window = OffscreenWindow(size: NSSize(width: 1440, height: 1024), styleMask: [.titled, .closable, .resizable])
                window.contentView = host
                window.orderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("title-names-\(lang.code)-\(step).png"))
                window.orderOut(nil)
            }
        }
    }
}
