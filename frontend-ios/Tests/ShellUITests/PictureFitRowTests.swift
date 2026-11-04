import Foundation
import Testing
@testable import ShellUI

/// The Picture row of a game's settings (#545): its texts come from launcher.json in English and are shown in the player's language.
@Suite struct PictureFitRowTests {
    static let note = "Fill crops the game's 16:9 picture to cover the screen. Health bars, subtitles or maps near the edges can be cut off. A full-screen picture without cropping needs a patch for each game."

    private func bundle(_ language: String) throws -> Bundle {
        try #require(ShellStrings.bundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)), "\(language).lproj")
    }

    @Test(arguments: ["zh-Hans", "de", "fr", "sv", "it"]) func everyShellLanguageHasTheRow(language: String) throws {
        let b = try bundle(language)
        let row = SettingRow(id: "DM_PICTURE_FIT", label: "Picture", note: Self.note,
                             kind: .choice([SettingOption("fit", "Fit", in: b), SettingOption("fill", "Fill", in: b)]), value: "fit", in: b)
        #expect(row.label != "Picture" && row.note != Self.note, "\(language)")
        #expect(!row.note.contains(";") && !row.note.contains("；") && !row.note.contains("—"), "the text rules: no semicolons, no em-dashes")
        guard case .choice(let options) = row.kind else { Issue.record("not a choice"); return }
        #expect(options.map(\.id) == ["fit", "fill"], "the values the engine reads are not translated")
        #expect(!options.contains { $0.label == "Fit" || $0.label == "Fill" }, "\(language)")
    }

    /// Two short labels: a segmented choice like Console mode and Frame rate around it, also in German at the iPhone's width.
    @Test(arguments: ["en", "de", "fr", "zh-Hans"]) func theChoiceIsSegmented(language: String) throws {
        let b = try bundle(language)
        let labels = [ShellStrings.setting("Fit", bundle: b), ShellStrings.setting("Fill", bundle: b)]
        #expect(ChoicePresentation.resolve(labels: labels, width: 320) == .segmented)
    }
}

#if os(macOS)
import AppKit
import SwiftUI
import XCTest

/// Visual QA of the Picture row (#545), rendered on the Mac: the Game section of a game's settings before (no row) and after (Fit,
/// and Fill chosen). Set NX_SHELL_CAPTURE_DIR to write the PNGs, NX_SHELL_CAPTURE_LANG for the language.
@MainActor
final class PictureFitCaptureTests: XCTestCase {
    private func capture<V: View>(_ name: String, width: CGFloat, _ view: () -> V) throws {
        guard let dir = ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_DIR"] else { throw XCTSkip("Set NX_SHELL_CAPTURE_DIR to capture the shell") }
        let lang = ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_LANG"] ?? "en"
        if let path = ShellStrings.bundle.path(forResource: lang == "zh" ? "zh-Hans" : lang, ofType: "lproj") {
            ShellStrings.captureBundle = Bundle(path: path)
        }
        defer { ShellStrings.captureBundle = nil }
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: view().frame(width: width).background(ShellPalette.background).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: host.frame.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(lang).png"))
    }

    private let game = GameTile(id: "0100F2C0115B6000", title: "The Legend of Zelda: Tears of the Kingdom")

    /// The Game section of an iOS game as launcher.json lists it, in the engine's order. Built inside the capture, so the texts
    /// come in the capture's language.
    private func section(picture: String?) -> SettingSection {
        var rows = [
            SettingRow(id: "DM_FPS_TARGET", label: "Frame rate", kind: .choice([SettingOption("30", "30 fps"), SettingOption("60", "60 fps")]), value: "60"),
            SettingRow(id: "DM_OPMODE", label: "Console mode", kind: .choice([SettingOption("1", "Docked"), SettingOption("0", "Handheld")]), value: "0"),
            SettingRow(id: "DM_PRESENT_UPSCALE", label: "Upscaling", note: "Uses more GPU time and can increase heat.",
                       kind: .choice([SettingOption("off", "Standard"), SettingOption("metalfx", "MetalFX")]), value: "off")
        ]
        if let picture {
            rows.append(SettingRow(id: "DM_PICTURE_FIT", label: "Picture", note: PictureFitRowTests.note,
                                   kind: .choice([SettingOption("fit", "Fit"), SettingOption("fill", "Fill")]), value: picture))
        }
        rows.append(SettingRow(id: "DM_SHOW_FPS", label: "Frame-rate counter", kind: .toggle(on: "1", off: "0"), value: "0"))
        return SettingSection(id: "Game", title: "Game", rows: rows)
    }

    func testCaptureTheGameSection() throws {
        for (name, picture) in [("shell-picture-before", nil), ("shell-picture-fit", "fit"), ("shell-picture-fill", "fill")] as [(String, String?)] {
            try capture(name, width: 402) {
                GameDetailView(detail: GameDetail(game: game, sections: [section(picture: picture)]), showsPrimaryAction: false, showsHeader: false)
                    .padding(24)
            }
        }
    }
}
#endif
