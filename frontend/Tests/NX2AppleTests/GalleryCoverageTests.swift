import XCTest
@testable import NX2Apple

/// The state gallery shows everything (LNPANDY/NX2Apple#1459): every View type of NX2Apple and NXLauncher, every sheet, popover and
/// alert, every notice and every case of the state enums in GalleryCoverage.stateEnums has a scene, or one of GalleryCoverage's few
/// reasons. A new view or state fails here until it has a scene. COVERAGE.md is written from the tables:
/// `NX_WRITE_COVERAGE=1 swift test --package-path frontend --filter GalleryCoverageTests` after a change.
final class GalleryCoverageTests: XCTestCase {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")
    static let coverageFile = sources.appendingPathComponent("NX2Apple/DesignGallery/COVERAGE.md")

    func testEveryViewAndStateHasASceneOrAReason() throws {
        let inventory = try Inventory.read(Self.sources)
        let ids = Set(GalleryScene.allCases.map(\.id))
        var missing: [String] = [], both: [String] = [], unknownScenes: [String] = []
        func check(_ items: [String], _ table: [String: [GalleryScene]], _ kind: String) {
            for item in items {
                let scenes = table[item] ?? []
                let reason = GalleryCoverage.reason(for: item)
                if scenes.isEmpty && reason == nil { missing.append("\(kind) \(item)") }
                if !scenes.isEmpty && reason != nil { both.append("\(kind) \(item)") }
                for scene in scenes where !ids.contains(scene.id) { unknownScenes.append("\(kind) \(item): \(scene.id)") }
            }
            let stale = Set(table.keys).subtracting(items)
            XCTAssertTrue(stale.isEmpty, "\(kind) entries for what the sources no longer have: \(stale.sorted())")
        }
        check(inventory.views, GalleryCoverage.views, "view")
        check(inventory.presentations, GalleryCoverage.presentations, "presentation")
        check(inventory.notices, GalleryCoverage.notices, "notice")
        check(inventory.states, GalleryCoverage.states, "state")
        XCTAssertTrue(missing.isEmpty, "no scene and no reason (add a scene in the gallery, or a reason in GalleryCoverage): \(missing)")
        XCTAssertTrue(both.isEmpty, "a scene and a reason: \(both)")
        XCTAssertTrue(unknownScenes.isEmpty, "scenes the gallery does not list: \(unknownScenes)")
        let all = Set(inventory.views + inventory.presentations + inventory.notices + inventory.states)
        let unusedReasons = GalleryCoverage.reasons.flatMap(\.items).filter { !all.contains($0) }
        XCTAssertTrue(unusedReasons.isEmpty, "reasons for what the sources no longer have: \(unusedReasons)")
        XCTAssertLessThanOrEqual(GalleryCoverage.reasons.count, 6, "keep the reason list short: a scene is the answer")
        XCTAssertGreaterThanOrEqual(inventory.views.count, 200, "the inventory reads the views")
        XCTAssertGreaterThanOrEqual(inventory.states.count, 250, "the inventory reads the state enums")
    }

    func testCoverageFileIsCurrent() throws {
        let text = try Inventory.read(Self.sources).markdown()
        if ProcessInfo.processInfo.environment["NX_WRITE_COVERAGE"] == "1" {
            try text.write(to: Self.coverageFile, atomically: true, encoding: .utf8)
        }
        let saved = try String(contentsOf: Self.coverageFile, encoding: .utf8)
        XCTAssertEqual(saved, text, "COVERAGE.md is not current: NX_WRITE_COVERAGE=1 swift test --package-path frontend --filter GalleryCoverageTests")
    }

    /// The parts of the sources the gallery must show, read from the code.
    struct Inventory {
        var views: [String] = []
        var presentations: [String] = []
        var notices: [String] = []
        var states: [String] = []

        static func read(_ root: URL) throws -> Inventory {
            var inventory = Inventory()
            var files: [(name: String, text: String)] = []
            for folder in ["NX2Apple", "NXLauncher"] {
                let base = root.appendingPathComponent(folder)
                guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
                for case let url as URL in walker where url.pathExtension == "swift" && !url.path.contains("/DesignGallery/") {
                    files.append((url.lastPathComponent, stripComments(try String(contentsOf: url, encoding: .utf8))))
                }
            }
            files.sort { $0.name < $1.name }
            let viewPattern = try NSRegularExpression(pattern: #"\bstruct\s+([A-Za-z_][A-Za-z0-9_]*)\s*(<[^{]*?>)?\s*:\s*([^{]*?)\{"#, options: [.dotMatchesLineSeparators])
            let noticePattern = try NSRegularExpression(pattern: #"LauncherNoticeItem\(id:\s*"([^"]+)""#)
            let presentPattern = try NSRegularExpression(pattern: #"\.(sheet|popover|alert|confirmationDialog|fullScreenCover)\("#)
            var views = Set<String>(), notices = Set<String>()
            for (name, text) in files {
                let ns = text as NSString
                for m in viewPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    var conformances = ns.substring(with: m.range(at: 3))
                    if let whereRange = conformances.range(of: "where") { conformances = String(conformances[..<whereRange.lowerBound]) }
                    if conformances.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).contains("View") {
                        views.insert(ns.substring(with: m.range(at: 1)))
                    }
                }
                for m in noticePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) { notices.insert(ns.substring(with: m.range(at: 1))) }
                var seen: [String: Int] = [:]
                for m in presentPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let modifier = ns.substring(with: m.range(at: 1))
                    let content = presented(in: text, after: m.range.location + m.range.length - 1)
                    var key = "\(name) .\(modifier) \(content)"
                    seen[key, default: 0] += 1
                    if seen[key]! > 1 { key += " \(seen[key]!)" }
                    inventory.presentations.append(key)
                }
            }
            inventory.views = views.sorted()
            inventory.notices = notices.sorted()
            for (file, path) in GalleryCoverage.stateEnums {
                let text = stripComments(try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8))
                let cases = try enumCases(path, in: text)
                guard !cases.isEmpty else { throw NSError(domain: "GalleryCoverage", code: 1, userInfo: [NSLocalizedDescriptionKey: "no cases of \(path) in \(file)"]) }
                inventory.states += cases.map { path + "." + $0 }
            }
            return inventory
        }

        /// The view a presentation shows: the first type its content closure builds.
        private static func presented(in text: String, after open: Int) -> String {
            let chars = Array(text.utf16)
            var depth = 0, i = open
            while i < chars.count {   // the modifier's arguments
                if chars[i] == 0x28 { depth += 1 } else if chars[i] == 0x29 { depth -= 1; if depth == 0 { break } }
                i += 1
            }
            guard let brace = (i..<chars.count).first(where: { chars[$0] == 0x7B }) else { return "?" }
            let body = String(utf16CodeUnits: Array(chars[brace..<min(chars.count, brace + 600)]), count: min(chars.count, brace + 600) - brace)
            let skip: Set<String> = ["Binding", "Button", "PendingImport"]
            let pattern = try! NSRegularExpression(pattern: #"\b([A-Z][A-Za-z0-9]*)\s*[\(\{]"#)
            for m in pattern.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length)) {
                let name = (body as NSString).substring(with: m.range(at: 1))
                if !skip.contains(name) { return name }
            }
            return "?"
        }

        /// The cases of `path` ("Outer.Inner"), found through its containers in `text`.
        static func enumCases(_ path: String, in text: String) throws -> [String] {
            var scope = text
            let parts = path.split(separator: ".").map(String.init)
            for (index, part) in parts.enumerated() {
                let keyword = index == parts.count - 1 ? "enum" : "(?:struct|enum|class|extension)"
                let pattern = try NSRegularExpression(pattern: #"\b"# + keyword + #"\s+"# + part + #"\b[^{]*\{"#)
                let ns = scope as NSString
                var found: String?
                for m in pattern.matches(in: scope, range: NSRange(location: 0, length: ns.length)) {
                    let body = block(scope, from: m.range.location + m.range.length - 1)
                    if index < parts.count - 1, !body.contains(parts[index + 1]) { continue }
                    found = body
                    break
                }
                guard let body = found else { return [] }
                scope = body
            }
            // the cases at the enum's own level
            var top = "", depth = 0
            for ch in scope {
                if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1 } else if depth == 0 { top.append(ch) }
                else if ch == "\n" { top.append(" ") }
            }
            var cases: [String] = []
            let casePattern = try NSRegularExpression(pattern: #"(?m)^\s*(?:indirect\s+)?case\s+(.+)$"#)
            let ns = top as NSString
            for m in casePattern.matches(in: top, range: NSRange(location: 0, length: ns.length)) {
                var level = 0, item = ""
                for ch in ns.substring(with: m.range(at: 1)) + "," {
                    if ch == "(" { level += 1 } else if ch == ")" { level -= 1 }
                    if ch == "," && level == 0 {
                        let name = item.trimmingCharacters(in: .whitespaces).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                        if !name.isEmpty { cases.append(String(name)) }
                        item = ""
                    } else { item.append(ch) }
                }
            }
            return cases
        }

        /// The text inside the braces that open at `open`.
        private static func block(_ text: String, from open: Int) -> String {
            let chars = Array(text.utf16)
            var depth = 0, inString = false
            for i in open..<chars.count {
                if chars[i] == 0x22 && (i == 0 || chars[i - 1] != 0x5C) { inString.toggle(); continue }   // a brace in a string is text
                if inString { continue }
                if chars[i] == 0x7B { depth += 1 } else if chars[i] == 0x7D {
                    depth -= 1
                    if depth == 0 { return String(utf16CodeUnits: Array(chars[(open + 1)..<i]), count: i - open - 1) }
                }
            }
            return ""
        }

        static func stripComments(_ text: String) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
                guard let range = line.range(of: "//") else { return line }
                let before = line[..<range.lowerBound]
                return before.filter { $0 == "\"" }.count % 2 == 0 ? before : line   // a // inside a string stays
            }.joined(separator: "\n")
        }

        func markdown() -> String {
            func scenes(_ list: [GalleryScene]?) -> String { (list ?? []).map { "`\($0.id)`" }.joined(separator: ", ") }
            func section(_ title: String, _ items: [String], _ table: [String: [GalleryScene]]) -> String {
                let covered = items.filter { table[$0]?.isEmpty == false }.count
                var lines = ["## \(title): \(covered) of \(items.count) in a scene", "", "| \(title.dropLast()) | Scenes |", "|---|---|"]
                for item in items {
                    let cell = table[item].map { scenes($0) } ?? (GalleryCoverage.reason(for: item).map { "Reason: " + $0 } ?? "none")
                    lines.append("| `\(item)` | \(cell) |")
                }
                return lines.joined(separator: "\n")
            }
            return ([
                "# State gallery coverage",
                "",
                "Written by `GalleryCoverageTests` from `GalleryCoverage.swift`: every View type of NX2Apple and NXLauncher, every sheet,",
                "popover and alert, every notice and every case of the state enums the views switch on, with the gallery's scenes",
                "(`GalleryScene.id`) that show it, or the reason none can. After a change:",
                "`NX_WRITE_COVERAGE=1 swift test --package-path frontend --filter GalleryCoverageTests`. The gallery has",
                "\(GalleryScene.allCases.count) scenes.",
                "",
                section("Views", views, GalleryCoverage.views),
                "",
                section("Presentations", presentations, GalleryCoverage.presentations),
                "",
                section("Notices", notices, GalleryCoverage.notices),
                "",
                section("States", states, GalleryCoverage.states),
                "",
                "## Reasons",
                "",
            ] + GalleryCoverage.reasons.map { "- \($0.reason) " + $0.items.map { "`\($0)`" }.joined(separator: ", ") }).joined(separator: "\n") + "\n"
        }
    }
}
