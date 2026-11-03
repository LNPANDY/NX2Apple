import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

/// #336: the buttons this feature adds keep one width per role in every language, at the default text size and a larger one, and
/// their label fits or wraps inside. Settings > Controls: "Open Settings" is a row control like its neighbours (LauncherControl.width).
/// Console mode: the hint's "Open Settings" and "Not now" take the sheet's width. Set NX_LAUNCHER_CAPTURE_DIR to keep PNGs of both
/// in English, German, Chinese and the language whose label is longest.
@MainActor final class HomeButtonCaptureTests: XCTestCase {
    private final class Box<T> { var value: T; init(_ value: T) { self.value = value } }
    private let typeSizes: [DynamicTypeSize] = [.large, .xxxLarge]

    private func controlsCard(_ lang: Lang, open: (() -> Void)?) -> some View {
        let localizer = LauncherStores().localizer; localizer.lang = lang
        return ControlsCard(controlChanges: 0, padMerge: .constant(false), consolePrompt: .constant(true), startInConsole: .constant(false),
                            onOpenControls: {}, onOpenControllers: {}, onOpenHomeSettings: open)
            .buttonStyle(LauncherSecondaryButtonStyle())   // as on the Settings page (LauncherPageScroll)
            .environmentObject(localizer).environmentObject(PadFocus())
            .padding(24).frame(width: 760).background(LauncherPalette.background).preferredColorScheme(.dark)
    }

    private func hint(_ lang: Lang) -> some View {
        let driver = MockConsoleDriver(scenario: .full, lang: lang, animated: false)
        driver.state.showHomeButtonHint()
        return ConsoleView(driver: driver, lang: lang).transaction { $0.disablesAnimations = true }
    }

    /// Draws `view` offscreen at `size` and returns the host after layout.
    private func draw<V: View>(_ view: V, size: NSSize, run: TimeInterval = 0.15) -> (NSHostingView<V>, OffscreenWindow) {
        let host = NSHostingView(rootView: view)
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        window.contentView = host
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(run))
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    func testOpenSettingsInControlsHasTheRowControlWidthInEveryLanguage() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        for typeSize in typeSizes {
            for lang in Lang.all {
                let samples = Box<[LauncherControlSample]>([])
                let view = controlsCard(lang, open: {}).dynamicTypeSize(typeSize).environment(\.measuresLauncherControls, true)
                    .onPreferenceChange(LauncherControlSamples.self) { samples.value = $0 }
                let (_, window) = draw(view, size: NSSize(width: 760, height: 1000))
                defer { window.orderOut(nil); window.close() }
                let at = "\(lang.code), \(typeSize)"
                XCTAssertGreaterThanOrEqual(samples.value.count, 3, "\(at): Customize, Open and Open Settings")
                for (index, sample) in samples.value.enumerated() {
                    XCTAssertEqual(sample.size.width, LauncherControl.width, "\(at), button \(index): the same width as its neighbours, whatever the label")
                    XCTAssertEqual(sample.size.height, LauncherControl.height, "\(at), button \(index)")
                    XCTAssertLessThanOrEqual(sample.labelWidth, sample.room, "\(at), button \(index): the label fits on one line")
                }
            }
        }
    }

    func testHintButtonsKeepOneWidthInEveryLanguage() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        for (name, width, height) in [("tv", 1920.0, 1080.0), ("mac", 1280.0, 800.0), ("compact", 390.0, 844.0)] {
            var first: CGFloat?
            for typeSize in typeSizes {
                for lang in Lang.all {
                    let widths = Box<[String: CGFloat]>([:])
                    let view = hint(lang).dynamicTypeSize(typeSize).frame(width: width, height: height)
                        .onPreferenceChange(ConsoleButtonWidths.self) { widths.value = $0 }
                    let (_, window) = draw(view, size: NSSize(width: width, height: height))
                    defer { window.orderOut(nil); window.close() }
                    let at = "\(name), \(lang.code), \(typeSize)"
                    let open = try XCTUnwrap(widths.value["console.homeHint.open"], at), later = try XCTUnwrap(widths.value["console.homeHint.later"], at)
                    XCTAssertEqual(open, later, accuracy: 0.5, "\(at): both buttons are as wide as each other")
                    if let first { XCTAssertEqual(open, first, accuracy: 0.5, "\(at): the same width as in every other language") } else { first = open }
                }
            }
        }
    }

    func testRenderHomeButtonViews() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        // the language whose "Open Settings" is longest, beside English, German and Chinese
        let font = try XCTUnwrap(Typography.manropeFont(size: 21, weight: .bold))
        func length(_ lang: Lang) -> CGFloat {
            CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: L10n.string("console.homeHint.open", lang), attributes: [.font: font])), nil, nil, nil)
        }
        let longest = try XCTUnwrap(Lang.all.max { length($0) < length($1) })
        var langs: [Lang] = []
        for lang in [Lang.en, Lang.find("de"), Lang.zh, longest].compactMap({ $0 }) where !langs.contains(lang) { langs.append(lang) }
        func save(_ host: NSView, _ name: String) throws {
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
        for lang in langs {
            for (suffix, open) in [("macos27", { } as (() -> Void)?), ("macos26", nil)] {
                let (host, window) = draw(controlsCard(lang, open: open), size: NSSize(width: 760, height: 1000), run: 0.2)
                host.setFrameSize(host.fittingSize); host.layoutSubtreeIfNeeded()
                try save(host, "controls-\(suffix)-\(lang.code)")
                window.orderOut(nil); window.close()
            }
            let (host, window) = draw(hint(lang).frame(width: 1920, height: 1080), size: NSSize(width: 1920, height: 1080))
            try save(host, "console-hint-\(lang.code)")
            window.orderOut(nil); window.close()
        }
        print("home button captures: \(langs.map(\.code)), longest Open Settings: \(longest.code)")
    }
}
