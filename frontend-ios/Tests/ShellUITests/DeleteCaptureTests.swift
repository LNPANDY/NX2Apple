#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import ShellUI

/// Visual QA of Delete game in the shell (#559), rendered on the Mac: the end of a game's settings with the Delete button, and
/// the question with the saves kept and with the saves chosen. Set NX_SHELL_CAPTURE_DIR to write the PNGs.
@MainActor
final class DeleteCaptureTests: XCTestCase {
    private func capture<V: View>(_ name: String, width: CGFloat, _ view: V) throws {
        guard let dir = ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_DIR"] else { throw XCTSkip("Set NX_SHELL_CAPTURE_DIR to capture the shell") }
        // NX_SHELL_CAPTURE_LANG=en (or de, zh, ...): the shell's language, whatever the Mac's is. Not saved anywhere.
        if let lang = ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_LANG"],
           let path = Bundle.module.path(forResource: lang == "zh" ? "zh-Hans" : lang, ofType: "lproj") {
            ShellStrings.captureBundle = Bundle(path: path)
        }
        defer { ShellStrings.captureBundle = nil }
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: view.frame(width: width).background(ShellPalette.background).environment(\.colorScheme, .dark))
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
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    private let game = GameTile(id: "0100535012974000", title: "Hades II")

    func testCaptureTheSettingsEnd() throws {
        let detail = GameDetail(game: game, dataSource: "This app's folder")
        try capture("shell-settings-delete", width: 402,
                    GameDetailView(detail: detail, showsPrimaryAction: false, showsHeader: false)
                        .environment(\.shellAskDelete, { _ in })
                        .padding(24))
    }

    func testCaptureTheQuestion() throws {
        for saves in [false, true] {
            let card = DeleteGameView(game: game, saves: .constant(saves), delete: {}, cancel: {})
                .background(Color(red: 0.075, green: 0.075, blue: 0.082), in: RoundedRectangle(cornerRadius: 26))
                .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.10)))
                .padding(16)
            try capture(saves ? "shell-delete-saves" : "shell-delete", width: 402, card.background(Color.black.opacity(0.55)))
        }
    }
}
#endif
