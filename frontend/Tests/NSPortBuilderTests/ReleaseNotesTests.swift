import AppKit
import SwiftUI
import XCTest
@testable import NSPortBuilder

/// The update sheet's Markdown: blocks and auto-links, on v0.7.0's real body
/// (Tests/Fixtures/release_v0.7.0.md, copied from `gh release view v0.7.0`).
final class ReleaseNotesTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func body() throws -> String {
        try String(contentsOf: root.appendingPathComponent("frontend/Tests/Fixtures/release_v0.7.0.md"), encoding: .utf8)
    }

    private func links(_ s: AttributedString) -> [(String, String)] {
        s.runs.compactMap { r in r.link.map { (String(s[r.range].characters), $0.absoluteString) } }
    }
    private func text(_ b: ReleaseNotes.Block) -> AttributedString {
        switch b { case .heading(let t), .bullet(let t), .paragraph(let t): return t }
    }
    private func kind(_ b: ReleaseNotes.Block) -> String {
        switch b { case .heading: return "heading"; case .bullet: return "bullet"; case .paragraph: return "paragraph" }
    }

    // ---- Auto-links ----

    func testBareIssueNumberLinksToTheIssue() {
        XCTAssertEqual(links(ReleaseNotes.inline("see #155 now")).map { [$0.0, $0.1] },
                       [["#155", "https://github.com/LNPANDY/NX2Apple/issues/155"]])
    }

    func testRepositoryQualifiedReference() {
        XCTAssertEqual(links(ReleaseNotes.inline("forwarded seedds/nxnative#493.")).map { [$0.0, $0.1] },
                       [["seedds/nxnative#493", "https://github.com/seedds/nxnative/issues/493"]])
    }

    func testASlashPairIsTwoLinks() {
        XCTAssertEqual(links(ReleaseNotes.inline("(#166/#205)")).map { [$0.0, $0.1] },
                       [["#166", "https://github.com/LNPANDY/NX2Apple/issues/166"],
                        ["#205", "https://github.com/LNPANDY/NX2Apple/issues/205"]])
    }

    func testMentionLinksToTheProfile() {
        XCTAssertEqual(links(ReleaseNotes.inline("thanks @dreamw0rk, and @a-b!")).map { [$0.0, $0.1] },
                       [["@dreamw0rk", "https://github.com/dreamw0rk"], ["@a-b", "https://github.com/a-b"]])
    }

    func testNoMentionInAnEmailOrCode() {
        let l = links(ReleaseNotes.inline("mail me@example.com or `@user` or user@host"))
        // The Markdown parser itself links the address as mailto:, which is fine. No profile link.
        XCTAssertFalse(l.contains { $0.1.contains("github.com") }, "\(l)")
    }

    func testNoLinksInCodeOrExistingLinksOrCSharp() {
        XCTAssertTrue(links(ReleaseNotes.inline("`#155` and `seedds/nxnative#1`")).isEmpty)
        XCTAssertTrue(links(ReleaseNotes.inline("written in C# and F#")).isEmpty)
        XCTAssertTrue(links(ReleaseNotes.inline("version #x and #")).isEmpty)
        // An existing link keeps its own target and the reference inside it is not linked a second time.
        XCTAssertEqual(links(ReleaseNotes.inline("[PR #7](https://example.com/p)")).map { [$0.0, $0.1] },
                       [["PR #7", "https://example.com/p"]])
    }

    func testCommitHashesStayText() {
        XCTAssertTrue(links(ReleaseNotes.inline("fixed in 3526c2f1 and 1a8478b8")).isEmpty)
    }

    func testMarkdownAndBareURLs() {
        let l = links(ReleaseNotes.inline("[brew](https://brew.sh) and https://example.com/a?b=1, then more"))
        XCTAssertEqual(l.map { [$0.0, $0.1] }, [["brew", "https://brew.sh"], ["https://example.com/a?b=1", "https://example.com/a?b=1"]])
    }

    func testInlineStyles() {
        let s = ReleaseNotes.inline("**bold** *it* `code`")
        let intents = s.runs.compactMap { r -> (String, InlinePresentationIntent)? in r.inlinePresentationIntent.map { (String(s[r.range].characters), $0) } }
        XCTAssertTrue(intents.contains { $0.0 == "bold" && $0.1.contains(.stronglyEmphasized) })
        XCTAssertTrue(intents.contains { $0.0 == "it" && $0.1.contains(.emphasized) })
        XCTAssertTrue(intents.contains { $0.0 == "code" && $0.1.contains(.code) })
        XCTAssertEqual(String(s.characters), "bold it code")
    }

    // ---- Blocks ----

    func testBlockKinds() {
        let b = ReleaseNotes.blocks(from: "## Title\n\nA paragraph.\n\n- one\n* two\n  continued\n\n---\n### Sub\n#155 is not a heading")
        XCTAssertEqual(b.map(kind), ["heading", "paragraph", "bullet", "bullet", "heading", "paragraph"])
        XCTAssertEqual(String(text(b[3]).characters), "two continued")
        XCTAssertEqual(links(text(b[5])).map { $0.0 }, ["#155"])
    }

    func testBoldLeadingParagraphIsNotABullet() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "**Bold** start").map(kind), ["paragraph"])
    }

    // ---- v0.7.0's real body ----

    func testRealBodyEnglish() throws {
        let b = ReleaseNotes.blocks(from: ReleaseNotes.markdown(try Self.body(), for: .en))
        let headings = b.filter { kind($0) == "heading" }.map { String(text($0).characters) }
        XCTAssertEqual(headings, ["What this release does", "New", "Fixes", "Known issues", "Install", "Credits"])
        XCTAssertFalse(b.contains { String(text($0).characters).contains("这一版做了什么") })
        XCTAssertFalse(b.contains { String(text($0).characters).contains("`") || String(text($0).characters).contains("**") })
        XCTAssertFalse(b.contains { String(text($0).characters).hasPrefix("- ") })
        let all = b.map(text).flatMap(links)
        XCTAssertTrue(all.contains { $0.0 == "#155" && $0.1 == "https://github.com/LNPANDY/NX2Apple/issues/155" })
        XCTAssertTrue(all.contains { $0.0 == "#166" } && all.contains { $0.0 == "#205" })
        XCTAssertTrue(all.contains { $0.0 == "#192" } && all.contains { $0.0 == "#196" })
        // Code spans carry the code intent: `devicectl`.
        let reinstall = try XCTUnwrap(b.map(text).first { String($0.characters).contains("devicectl") })
        XCTAssertTrue(reinstall.runs.contains { String(reinstall[$0.range].characters) == "devicectl" && $0.inlinePresentationIntent?.contains(.code) == true })
        // Bold: the lead of a bullet.
        let console = try XCTUnwrap(b.map(text).first { String($0.characters).hasPrefix("Console mode") })
        XCTAssertTrue(console.runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        // Names in credits are bold, not mentions, and a `$(whoami)` stays in code.
        XCTAssertFalse(all.contains { $0.1 == "https://github.com/v0lumehi" })
    }

    func testRealBodyChinese() throws {
        let b = ReleaseNotes.blocks(from: ReleaseNotes.markdown(try Self.body(), for: .zh))
        let headings = b.filter { kind($0) == "heading" }.map { String(text($0).characters) }
        XCTAssertEqual(headings, ["这一版做了什么", "新增", "修复", "已知问题", "安装", "致谢"])
        XCTAssertFalse(b.contains { String(text($0).characters).contains("Guided first-run") })
        XCTAssertTrue(b.map(text).flatMap(links).contains { $0.0 == "#185" })
    }

    // ---- v0.7.2's real body (language sections and a shared footer) ----

    static func body072() throws -> String {
        try String(contentsOf: root.appendingPathComponent("frontend/Tests/Fixtures/release_v0.7.2.md"), encoding: .utf8)
    }

    func testSectionedBodyEnglish() throws {
        let lines = ReleaseNotes.lines(try Self.body072(), for: .en)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("- Fixed games opening to a black screen"))
        XCTAssertTrue(lines[1].hasPrefix("- 26 upstream commits"))
        XCTAssertTrue(lines[2].hasPrefix("**Install:**"))
        let all = lines.joined(separator: "\n")
        XCTAssertEqual(all.components(separatedBy: "Install:").count, 2, "footer once")
        XCTAssertFalse(all.contains("修复部分游戏"))
        XCTAssertFalse(all.contains("## "))
    }

    func testSectionedBodyChinese() throws {
        let lines = ReleaseNotes.lines(try Self.body072(), for: .zh)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("- 修复部分游戏打开后黑屏"))
        XCTAssertTrue(lines[1].hasPrefix("- 同步上游 26 个提交"))
        XCTAssertTrue(lines[2].hasPrefix("**Install:**"))
        let all = lines.joined(separator: "\n")
        XCTAssertEqual(all.components(separatedBy: "Install:").count, 2, "footer once")
        XCTAssertFalse(all.contains("Fixed games opening"))
        XCTAssertFalse(all.contains("upstream commits"))
    }

    func testSwedishAndGermanUseTheEnglishSection() throws {
        let body = try Self.body072()
        for lang in [Lang.sv, Lang.de] {
            XCTAssertEqual(ReleaseNotes.lines(body, for: lang), ReleaseNotes.lines(body, for: .en))
        }
    }

    func testGermanReadsTheEnglishHalfOfTheOtherShapes() {
        let halves = "- English line\n\n---\n\n- 中文行"
        XCTAssertEqual(ReleaseNotes.lines(halves, for: .de), ReleaseNotes.lines(halves, for: .en))
        let marked = "**中文** 中文行\n**English** English line"
        XCTAssertEqual(ReleaseNotes.lines(marked, for: .de), ["English line"])
    }

    func testHeadingAndBoldMarkerVariants() {
        let body = "### English\n- a\n\n**中文**\n- 乙\n\n---\nfoot"
        XCTAssertEqual(ReleaseNotes.lines(body, for: .en), ["- a", "foot"])
        XCTAssertEqual(ReleaseNotes.lines(body, for: .zh), ["- 乙", "foot"])
        // Without a footer, and with the Chinese section first.
        let two = "## 中文\n- 乙\n---\n## English\n- a"
        XCTAssertEqual(ReleaseNotes.lines(two, for: .en), ["- a"])
        XCTAssertEqual(ReleaseNotes.lines(two, for: .zh), ["- 乙"])
    }

    func testOldShapesStillSplitWithoutLanguageHeadings() throws {
        // v0.7.0 has `---` halves and no language headings.
        XCTAssertFalse(ReleaseNotes.lines(try Self.body(), for: .en).joined().contains("这一版"))
        XCTAssertEqual(ReleaseNotes.lines("just text", for: .zh), ["just text"])
    }

    // ---- Visual QA ----

    /// Opt-in native rendering for pull request screenshots (NX_LAUNCHER_CAPTURE_DIR).
    @MainActor func testRenderUpdateSheetForScreenshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let body = try Self.body()
        // The body as it is, and the middle of it (the code spans, the links and the Fixes section) as the sheet shows it scrolled.
        let middle = "## New\n\n" + String(body[body.range(of: "- **Reinstall")!.lowerBound...body.range(of: "## Known issues")!.lowerBound])
            + "\n---\n\n## 新增\n\n" + String(body[body.range(of: "- **不重构建")!.lowerBound...body.range(of: "## 已知问题")!.lowerBound])
        let body072 = try Self.body072()
        for (name, lang, notes, tag) in [("update-sheet-notes-v072-en", Lang.en, body072, "v0.7.2"), ("update-sheet-notes-v072-zh", Lang.zh, body072, "v0.7.2")]
            + [("update-sheet-notes-en", Lang.en, body, "v0.7.0"), ("update-sheet-notes-zh", Lang.zh, body, "v0.7.0"),
                                    ("update-sheet-notes-middle-en", Lang.en, middle, "v0.7.0"), ("update-sheet-notes-middle-zh", Lang.zh, middle, "v0.7.0")] {
            let m = BuildModel()
            m.lang = lang
            m.appUpdate = AppUpdate.Release(tag: tag, url: "", digest: nil, notes: notes)
            let width: CGFloat = 560, height: CGFloat = 640
            let host = NSHostingView(rootView: UpdateSheet(m: m).frame(width: width, height: height))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: .darkAqua)
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
    }
}
