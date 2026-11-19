import XCTest

/// LNPANDY/NX2Apple#1458: the screens of frontend/Sources/NX2Apple use the design tokens (`DS`, generated from
/// frontend/design-tokens/tokens.json) and the components on them, not their own font sizes and colours. A raw Manrope size, a
/// `Color(red:)`, `Color(white:)`, `NSColor(srgbRed:)` or `.foregroundStyle(.white.opacity(` is refused outside the files listed
/// below with the count they had when the guard came in. The listed files may only shrink: lower the number when a file moves
/// to tokens, and drop its entry at zero. NXLauncher, where the tokens and components live, is not scanned.
final class DesignTokenGuardTests: XCTestCase {
    private static let pattern = try! NSRegularExpression(pattern: #"\.font\(\.manrope\(|(?<!CG)Color\(red:|\.foregroundStyle\(\.white\.opacity\(|(?<!CG)Color\(white:|NSColor\(srgbRed:"#)

    /// File under frontend/Sources/NX2Apple -> raw styles it may still hold. The console mode's own look is most of it.
    private static let allowed: [String: Int] = [
        "ArtworkPanel.swift": 7,
        "BuildActivityFooter.swift": 1,
        "ConsoleBuildIndicator.swift": 1,
        "ConsoleBuildsPage.swift": 9,
        "ConsoleCloudSaveView.swift": 8,
        "ConsoleCloudSaves.swift": 11,
        "ConsoleControllersView.swift": 12,
        "ConsoleEntryView.swift": 4,
        "ConsoleGameOptions.swift": 21,
        "ConsoleGamePage.swift": 9,
        "ConsoleGlyphs.swift": 2,
        "ConsoleHomeView.swift": 7,
        "ConsoleLibraryPages.swift": 7,
        "ConsoleOptionRow.swift": 6,
        "ConsolePadDiagram.swift": 8,
        "ConsolePadMappingView.swift": 28,
        "ConsolePages.swift": 10,
        "ConsoleSupportedGamesPage.swift": 11,
        "ConsoleTiles.swift": 3,
        "ConsoleView.swift": 20,
        "ControlPresets.swift": 1,
        "LauncherView+Library.swift": 1,
        "LauncherView+RefreshUI.swift": 1,
        "LibraryEmptyState.swift": 1,
        "LiveConsoleDriver+Identify.swift": 2,
        "LiveConsoleDriver.swift": 1,
        "OnboardingGamesContent.swift": 1,
        "OnboardingKeysContent.swift": 1,
        "OnboardingView.swift": 12,
        "StickDeadzoneCard.swift": 1,
    ]

    func testScreensUseTheDesignTokens() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NX2Apple")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "the sources are next to the tests")
        var seen: Set<String> = []
        for file in files {
            let path = String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            let text = try String(contentsOf: file, encoding: .utf8)
            let count = Self.pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            let allowed = Self.allowed[path] ?? 0
            if count > 0 { seen.insert(path) }
            XCTAssertLessThanOrEqual(count, allowed, "\(path) has \(count) raw font sizes or colours, \(allowed) allowed. Use DS.Font, DS.Color and the DS components (frontend/README.md, Design tokens and components)")
        }
        for path in Self.allowed.keys where !seen.contains(path) {
            XCTFail("\(path) has no raw styles left: drop its entry from DesignTokenGuardTests")
        }
    }
}
