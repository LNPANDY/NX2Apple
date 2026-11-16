#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import ShellUI
@testable import ShellHost

/// Visual QA of the shell's texts in one language, rendered on the Mac from the fixture games: the library with each state, a game's
/// settings, the How to fix and How to update cards, Controllers and Cover Flow. The host's texts (reasons, data sources, players) and
/// the views' texts both come from that language's `.lproj`. Set NX_SHELL_CAPTURE_DIR to write the PNGs, NX_SHELL_CAPTURE_LANG (en, zh,
/// de, sv, fr, it) for the language.
@MainActor
final class ShellTextsCaptureTests: XCTestCase {
    private var currentLang = "en"

    private var captureLanguages: [String] {
        if let raw = ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_LANGS"], !raw.isEmpty {
            let list = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !list.isEmpty { return list }
        }
        return [ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_LANG"] ?? "en"]
    }

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_DIR"] != nil else { throw XCTSkip("Set NX_SHELL_CAPTURE_DIR to capture the shell") }
        applyLanguage(captureLanguages[0])
    }
    override func tearDown() async throws {
        ShellStrings.captureBundle = nil
        HostStrings.captureBundle = nil
    }

    private func applyLanguage(_ lang: String) {
        currentLang = lang
        ShellStrings.captureBundle = nil
        HostStrings.captureBundle = nil
        let code = lang == "zh" ? "zh-Hans" : lang
        if let ui = ShellStrings.bundle.path(forResource: code, ofType: "lproj") { ShellStrings.captureBundle = Bundle(path: ui) }
        if let host = HostStrings.bundle.path(forResource: code, ofType: "lproj") { HostStrings.captureBundle = Bundle(path: host) }
    }

    private func forEachCaptureLanguage(_ body: () throws -> Void) throws {
        for lang in captureLanguages {
            applyLanguage(lang)
            defer {
                ShellStrings.captureBundle = nil
                HostStrings.captureBundle = nil
            }
            try body()
        }
    }

    private func capture<V: View>(_ name: String, width: CGFloat, height: CGFloat? = nil, _ view: V) throws {
        let dir = try XCTUnwrap(ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_DIR"])
        NSApplication.shared.setActivationPolicy(.accessory)
        let framed = view.frame(width: width, height: height).background(ShellPalette.background).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: framed)
        host.frame = NSRect(origin: .zero, size: height.map { CGSize(width: width, height: $0) } ?? host.fittingSize)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: host.frame.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(currentLang).png"))
    }

    /// The fixture games through the real model: playable, needs game data, needs an app update and broken in several ways.
    private func model(_ box: Sandbox) throws -> ShellHostModel {
        try box.giveAppData(Fixtures.orbit)
        let shell = ShellSettingsStore(defaults: UserDefaults(suiteName: "capture-shell-\(UUID().uuidString)")!)
        let model = ShellHostModel(config: box.config(), shellSettings: shell)
        model.reload()
        return model
    }

    /// A fixture with no game data in the sandbox: it needs game data.
    private let quiet = "0100000000080000"

    private func detail(_ model: ShellHostModel, _ id: String) throws -> GameDetail { try XCTUnwrap(model.details.first { $0.id == id }) }

    func testCaptureTheLibraryInEachState() throws {
        let box = try Sandbox()
        let model = try model(box)
        for (name, id) in [("ready", Fixtures.orbit), ("needsdata", quiet), ("update", Fixtures.chain), ("broken", Fixtures.badManifest)] {
            try capture("texts-library-\(name)", width: 402, height: 874, LibraryView(games: model.details, initialSelection: id))
        }
        try capture("texts-coverflow", width: 874, height: 402, LibraryView(games: model.details, initialSelection: Fixtures.orbit))
        try capture("texts-library-empty", width: 402, height: 874, LibraryView(games: []))
    }

    func testCaptureAGamesSettings() throws {
        try forEachCaptureLanguage {
            let box = try Sandbox()
            let model = try model(box)
            try capture("texts-settings-ready", width: 402,
                        GameDetailView(detail: try detail(model, Fixtures.orbit), actions: model.actions, showsPrimaryAction: false)
                            .environment(\.shellAskDelete, { _ in })
                            .padding(24))
            try capture("texts-settings-needsdata", width: 402,
                        GameDetailView(detail: try detail(model, quiet), actions: model.actions, showsPrimaryAction: false)
                            .environment(\.shellAskDelete, { _ in })
                            .padding(24))
            try capture("texts-home-screen", width: 402,
                        AddToHomeScreenView(game: try detail(model, Fixtures.orbit).game,
                                            saveAndOpen: { true }, copyURL: {}, close: {}))
        }
    }

    func testCaptureAdaptiveGameActions() throws {
        let box = try Sandbox()
        let model = try model(box)
        for (name, width, height) in [("phone", 402.0, 874.0), ("ipad-portrait", 834.0, 1194.0),
                                       ("ipad-landscape", 1194.0, 834.0), ("resized", 507.0, 834.0)] {
            try capture("actions-" + name, width: width, height: height,
                        LibraryView(games: model.details, initialSelection: Fixtures.orbit))
        }
        try capture("actions-expanded-settings", width: 1194, height: 834,
                    LibraryView(games: model.details, initialSelection: Fixtures.orbit, initialDetailOpen: true))
        try capture("actions-update-inline", width: 402, height: 874,
                    LibraryView(games: model.details, initialSelection: Fixtures.chain))
        try capture("actions-ipad-large-text", width: 834, height: 1194,
                    LibraryView(games: model.details, initialSelection: Fixtures.orbit).environment(\.dynamicTypeSize, .accessibility3))
    }

    func testCaptureTheHelpCards() throws {
        let box = try Sandbox()
        let model = try model(box)
        for (name, id) in [("update", Fixtures.chain), ("broken", Fixtures.missingKey), ("settings", Fixtures.badSettings), ("code", Fixtures.noFramework)] {
            try capture("texts-help-\(name)", width: 402, StateHelpView(game: try detail(model, id).game))
        }
    }

    func testCaptureControllers() throws {
        let pad = ControllerInfo(id: "pad", name: "DualSense", player: hostText("Player \(String(1))"), batteryPercent: 64, charging: true)
        try capture("texts-controllers", width: 402, height: 874, ControllersView(controllers: [pad]))
        try capture("texts-controllers-empty", width: 402, height: 874, ControllersView(controllers: []))
    }

    func testCaptureTheShellSettings() throws {
        let box = try Sandbox()
        let model = try model(box)
        try capture("texts-shell-settings", width: 402, height: 1500, LibraryView(games: model.details, initialShellSettingsOpen: true))
    }
}
#endif
