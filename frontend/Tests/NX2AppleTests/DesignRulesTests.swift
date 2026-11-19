import XCTest

/// LNPANDY/NX2Apple#1458: rules of the launcher's design system that are checked on the sources and data, not on a rendering.
final class DesignRulesTests: XCTestCase {
    private static let frontend = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // MARK: Text

    /// No dash used as punctuation and no semicolon in any language: an em dash, a horizontal bar, an en dash outside a range of
    /// numbers ("2015–2022"), ";" or the full-width "；". HTML entities ("&amp;") are not punctuation.
    func testLocalizedTextHasNoDashesOrSemicolons() throws {
        let dir = Self.frontend.appendingPathComponent("l10n")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 10, "the ten languages")
        let entity = try NSRegularExpression(pattern: "&[a-z]+;")
        let range = try NSRegularExpression(pattern: "[0-9]–[0-9]")
        var problems: [String] = []
        for file in files {
            let table = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            // The English of ios.setting.* is upstream's text from a game's launcher.json, the iOS catalog's key: kept word for word.
            for (key, value) in table where !key.hasPrefix("_") && !(file.lastPathComponent == "en.json" && key.hasPrefix("ios.setting.")) {
                guard var text = value as? String else { continue }
                text = entity.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                text = range.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                if text.contains(where: { "—―–;；".contains($0) }) { problems.append("\(file.lastPathComponent) \(key): \(value)") }
            }
        }
        XCTAssertEqual(problems, [], "rephrase without a dash or a semicolon")
    }

    // MARK: Contrast

    private struct RGBA { var r, g, b, a: Double }

    private static func colour(_ hex: String) -> RGBA {
        let digits = hex.dropFirst()
        func byte(_ i: Int) -> Double {
            let start = digits.index(digits.startIndex, offsetBy: i * 2)
            return Double(Int(digits[start..<digits.index(start, offsetBy: 2)], radix: 16)!) / 255
        }
        return RGBA(r: byte(0), g: byte(1), b: byte(2), a: digits.count == 8 ? byte(3) : 1)
    }

    private static func over(_ top: RGBA, _ bottom: RGBA) -> RGBA {
        RGBA(r: top.r * top.a + bottom.r * (1 - top.a), g: top.g * top.a + bottom.g * (1 - top.a), b: top.b * top.a + bottom.b * (1 - top.a), a: 1)
    }

    private static func luminance(_ c: RGBA) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    static func contrast(_ text: String, on background: String) -> Double {
        let bg = colour(background)
        let a = luminance(over(colour(text), bg)), b = luminance(bg)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// WCAG contrast of the text and symbol colours on every surface, computed from tokens.json: primary and secondary text at
    /// least 4.5:1, tertiary text, symbols and status colours at least 3:1.
    func testTokenColoursHaveEnoughContrast() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.frontend.appendingPathComponent("design-tokens/tokens.json"))) as? [String: Any])
        let colours = try XCTUnwrap(json["color"] as? [String: Any])
        func value(_ path: String) throws -> String {
            var node: Any = colours
            for part in path.split(separator: ".") { node = try XCTUnwrap((node as? [String: Any])?[String(part)], path) }
            return try XCTUnwrap((node as? [String: Any])?["$value"] as? String, path)
        }
        let surfaces = ["background", "surface", "surfaceRaised"]
        let rules: [(String, Double)] = [("text.primary", 4.5), ("text.secondary", 4.5), ("text.tertiary", 3), ("symbol.default", 3), ("symbol.accent", 3),
                                         ("status.ready", 3), ("status.success", 3), ("status.warning", 3), ("status.error", 3), ("status.info", 3)]
        for surface in surfaces {
            let background = try value(surface)
            for (token, minimum) in rules {
                let ratio = Self.contrast(try value(token), on: background)
                XCTAssertGreaterThanOrEqual(ratio, minimum, "\(token) on \(surface) is \(String(format: "%.2f", ratio)):1")
            }
        }
        XCTAssertGreaterThanOrEqual(Self.contrast(try value("accentOn"), on: try value("accent")), 4.5, "text on the accent")
        XCTAssertGreaterThanOrEqual(Self.contrast(try value("status.errorOn"), on: try value("status.errorFill")), 4.5, "text on the destructive fill")
    }

    // MARK: Liquid Glass

    /// Glass belongs to the navigation layer that floats above the content (Apple HIG for Liquid Glass): the top bar, the controls
    /// over the library hero, the carousel arrows and the wizard footer. Only those mark themselves `launcherGlassLayer()` or draw
    /// `launcherGlass(` themselves. Everything else gets flat controls from the same button styles.
    func testGlassOnlyInTheNavigationLayer() throws {
        let navigation: Set<String> = ["NX2Apple/LauncherView+Header.swift", "NX2Apple/LauncherView+HeroAction.swift", "NX2Apple/LauncherView+Carousel.swift",
                                       "NXLauncher/DesignComponents.swift", "NXLauncher/LauncherGlass.swift", "NXLauncher/PlayerPicker.swift"]
        let pattern = try NSRegularExpression(pattern: #"\.launcherGlassLayer\(\)|\.launcherGlass\(|glassEffect\(|\.buttonStyle\(\.glass"#)
        var offenders: [String] = []
        for (path, text) in try Self.sources() where !navigation.contains(path) {
            if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { offenders.append(path) }
        }
        XCTAssertEqual(offenders, [], "glass outside the navigation layer: use the DS button styles, which are flat in the content")
    }

    // MARK: Colours

    /// Symbols and text take their colour from the tokens (symbol.default, the status colours), never a raw SwiftUI or AppKit
    /// colour (`.yellow`, `Color.orange`, `NSColor.systemRed`, also in a ternary). Only the generated token file may hold them.
    /// The files below, all of them console, onboarding or sheets, still do, with the count they may keep: lower it when a file
    /// moves to tokens, and drop its entry at zero.
    private static let rawColourAllowed: [String: Int] = [
        "NX2Apple/ConsoleControllersView.swift": 2,   // a low battery
        "NX2Apple/GameControllerMappingView.swift": 1,
        "NXLauncher/ExportSteps.swift": 1,
        "NXLauncher/TransferCard.swift": 1,
    ]

    /// `(?!:)` leaves out a case label (`case .red:`), not the `:` of a ternary, which the earlier `(?!\s*:)` let through.
    static let rawColour = try! NSRegularExpression(pattern: #"(?<![\w])(?:Color|NSColor)?\.(?:yellow|orange|red|green|blue|purple|pink|mint|teal|cyan|indigo|brown|gray|systemYellow|systemOrange|systemRed|systemGreen|systemBlue|systemPurple|systemPink|systemTeal|systemMint|systemCyan|systemIndigo|systemBrown|systemGray)\b(?!:)"#)

    func testNoRawSwiftUIColours() throws {
        XCTAssertEqual(Self.matches(Self.rawColour, "x ? Color.orange : Color.secondary"), 1, "a ternary is caught")
        XCTAssertEqual(Self.matches(Self.rawColour, "case .red: break"), 0, "a case label is not a colour")
        var seen: Set<String> = []
        for (path, text) in try Self.sources() {
            let count = Self.matches(Self.rawColour, text)
            if count > 0 { seen.insert(path) }
            XCTAssertLessThanOrEqual(count, Self.rawColourAllowed[path] ?? 0, "\(path) uses \(count) raw colours: use DS.Color.symbolDefault or a status token")
        }
        for path in Self.rawColourAllowed.keys where !seen.contains(path) { XCTFail("\(path) has no raw colours left: drop its entry") }
    }

    /// The accent (the cream) marks the one primary action, a selection and focus. Text in it is the selected or primary
    /// component's own (the button styles, the dropdown, the segmented control, the wordmark): a screen never colours a Text or a
    /// Label with the accent itself. Console mode below still does, with the count it may keep.
    private static let accentTextComponents: Set<String> = [
        "NXLauncher/LauncherStyles.swift", "NXLauncher/LauncherDropdown.swift", "NXLauncher/DesignComponents.swift",
        "NXLauncher/LauncherGlass.swift", "NXLauncher/LauncherWordmark.swift", "NXLauncher/LauncherBrandMark.swift", "NXLauncher/PadFocus.swift",
    ]
    private static let accentTextAllowed: [String: Int] = [
        "NX2Apple/ConsoleBuildsPage.swift": 1, "NX2Apple/ConsoleCloudSaveView.swift": 1, "NX2Apple/ConsoleCloudSaves.swift": 1,
        "NX2Apple/ConsoleControllersView.swift": 2, "NX2Apple/ConsoleGameOptions.swift": 3, "NX2Apple/ConsoleOptionRow.swift": 1,
        "NX2Apple/ConsolePages.swift": 2, "NX2Apple/ConsoleSupportedGamesPage.swift": 1, "NX2Apple/ConsoleTiles.swift": 1,
    ]
    private static let accentStyle = try! NSRegularExpression(pattern:
        #"\.foreground(?:Style|Color)\([^()\n]*?(?:LauncherPalette\.(?:accent|cream|notice|focusRing|primaryHover|primaryPressed|segmentSelected|selectionUnderline|radioOn)|DS\.Color\.(?:accent|symbolAccent|statusInfo))\b"#)
    private static let viewStart = try! NSRegularExpression(pattern: #"\b(Text|Label|Image|[A-Z]\w*(?:View|Mark|Glyph)|Circle|Capsule|Rectangle|RoundedRectangle|Group|HStack|VStack|ZStack|DSPill)\("#)

    /// How many accent foregrounds apply to a Text or a Label: the view a modifier belongs to is the last one started before it.
    static func accentOnText(_ text: String) -> Int {
        let ns = text as NSString
        return accentStyle.matches(in: text, range: NSRange(location: 0, length: ns.length)).filter { match in
            let start = max(0, match.range.location - 400)
            let before = NSRange(location: start, length: match.range.location - start)
            guard let last = viewStart.matches(in: text, range: before).last else { return false }
            return ["Text", "Label"].contains(ns.substring(with: last.range(at: 1)))
        }.count
    }

    func testNoAccentOnTextOutsideTheSelectedAndPrimaryComponents() throws {
        XCTAssertEqual(Self.accentOnText(#"Text("x").font(DS.Font.body).foregroundStyle(LauncherPalette.cream)"#), 1)
        XCTAssertEqual(Self.accentOnText("Text(\"x\")\n    .foregroundStyle(on ? DS.Color.accent : DS.Color.textPrimary)"), 1)
        XCTAssertEqual(Self.accentOnText(#"Image(systemName: "checkmark").foregroundStyle(LauncherPalette.accent)"#), 0, "a selected symbol is fine")
        var seen: Set<String> = []
        for (path, text) in try Self.sources() where !Self.accentTextComponents.contains(path) {
            let count = Self.accentOnText(text)
            if count > 0 { seen.insert(path) }
            XCTAssertLessThanOrEqual(count, Self.accentTextAllowed[path] ?? 0,
                                     "\(path) colours \(count) texts with the accent: use text.primary, a status colour or the selected component")
        }
        for path in Self.accentTextAllowed.keys where !seen.contains(path) { XCTFail("\(path) has no accent text left: drop its entry") }
    }

    // MARK: Controls

    /// A dropdown that shows its value is a pop-up with the up and down chevron (LauncherDropdownKind, Apple HIG). Nothing draws
    /// a `chevron.down` face of its own: the onboarding's details disclosure is the one other down chevron.
    func testNoHandDrawnPullDownChevrons() throws {
        let allowed: [String: Int] = ["NXLauncher/LauncherDropdown.swift": 1, "NX2Apple/OnboardingView.swift": 1]
        let pattern = try NSRegularExpression(pattern: #""chevron\.down""#)
        for (path, text) in try Self.sources() {
            XCTAssertLessThanOrEqual(Self.matches(pattern, text), allowed[path] ?? 0, "\(path): a pop-up uses LauncherDropdown (chevron.up.chevron.down)")
        }
    }

    /// A capsule or round outline is drawn by DSPill: `Capsule().strokeBorder` comes out with bars past its round ends in AppKit's
    /// bitmap caching, so captures showed buttons and chips cut at their sides. The shared components and screens outside console,
    /// onboarding and the sheets have none left.
    func testCapsuleOutlinesUseDSPill() throws {
        let pattern = try NSRegularExpression(pattern: #"Capsule\(\)\.stroke"#)
        for (path, text) in try Self.sources() where path.hasPrefix("NXLauncher/") && !path.contains("Sheet") && !path.contains("ExportSteps") && !path.contains("TransferCard") {
            XCTAssertEqual(Self.matches(pattern, text), 0, "\(path): use DSPill().strokeBorder")
        }
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Int {
        pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func sources() throws -> [(String, String)] {
        var out: [(String, String)] = []
        for target in ["NX2Apple", "NXLauncher"] {
            let root = frontend.appendingPathComponent("Sources").appendingPathComponent(target)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files where !file.path.contains("/Generated/") {
                out.append((target + "/" + String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)), try String(contentsOf: file, encoding: .utf8)))
            }
        }
        return out
    }
}
