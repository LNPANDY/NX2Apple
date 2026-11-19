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

    /// Symbols and text take their colour from the tokens (symbol.default, the status colours), never a raw SwiftUI colour. The
    /// files below still hold some, with the count they may keep: lower it when a file moves to tokens.
    private static let rawColourAllowed: [String: Int] = [
        "NX2Apple/FrameTimesView.swift": 1,   // the frame-time graph's series colours
        "NX2Apple/OnboardingView.swift": 2,
        "NXLauncher/AppCard.swift": 1,
        "NXLauncher/BuildFilesCard.swift": 1,
        "NXLauncher/BuildQueueCard.swift": 1,
        "NXLauncher/ExportSteps.swift": 1,
        "NXLauncher/LauncherCard.swift": 3,
        "NXLauncher/LauncherPalette.swift": 1,   // the palette under the tokens
        "NXLauncher/ShellCacheRow.swift": 1,
        "NXLauncher/TransferCard.swift": 1,
    ]

    func testNoRawSwiftUIColours() throws {
        let pattern = try NSRegularExpression(pattern: #"(?<![\w])(?:Color|NSColor)?\.(?:yellow|orange|red|green|blue|purple|pink|mint|teal|cyan|indigo|systemYellow|systemOrange|systemRed|systemGreen|systemBlue)\b(?!\s*:)"#)
        var seen: Set<String> = []
        for (path, text) in try Self.sources() {
            let count = pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            if count > 0 { seen.insert(path) }
            XCTAssertLessThanOrEqual(count, Self.rawColourAllowed[path] ?? 0, "\(path) uses \(count) raw colours: use DS.Color.symbolDefault or a status token")
        }
        for path in Self.rawColourAllowed.keys where !seen.contains(path) { XCTFail("\(path) has no raw colours left: drop its entry") }
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
