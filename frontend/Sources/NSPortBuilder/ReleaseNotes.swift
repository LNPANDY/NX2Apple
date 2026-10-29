import Foundation

/// The update sheet's release notes: which lines belong to the interface language, how they split into
/// blocks (headings, bullets, paragraphs) and how a line's inline Markdown becomes an AttributedString
/// with links. All pure, so the tests run it on real release bodies. UpdateSheet only styles the result.
///
/// The release body follows docs/RELEASE-NOTES-GUIDE.md. Two shapes are in the wild:
///
/// * **Current**: English written out in full, `---`, then Chinese in full. The `---` is the split.
/// * **Older releases (0.4.7 and before)**: `**中文** …` and `**English** …` paragraphs with bullet
///   lists interleaved one line each. Those are split on the markers.
///
/// A body with neither is shown whole: splitting it by guesswork is how the first version gave an
/// English reader the Chinese paragraph (that line contains both scripts).
enum ReleaseNotes {
    enum Block: Equatable {
        case heading(AttributedString)
        case bullet(AttributedString)
        case paragraph(AttributedString)
    }

    /// The repository bare `#123` references point into.
    static let repository = "LNPANDY/NX2Apple"

    // ---- Language split ----

    /// The body's Markdown lines for one language, still carrying their Markdown (`##`, `- `, `**`).
    static func lines(_ notes: String, for lang: Lang) -> [String] {
        // Shape 1: two halves around a `---` line.
        let halves = notes.components(separatedBy: "\n---\n")
        if halves.count == 2 {
            let first = clean(halves[0]), second = clean(halves[1])
            // Pick by which half is which, not by order alone, so a body written the other way round still reads correctly.
            let firstIsEnglish = !containsHan(first.joined())
            let english = firstIsEnglish ? first : second
            let chinese = firstIsEnglish ? second : first
            if !english.isEmpty && !chinese.isEmpty { return lang == .zh ? chinese : english }
        }

        // Shape 2: `**中文**` / `**English**` markers.
        var zh: [String] = [], en: [String] = []
        var marked = 0
        for raw in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("---") { continue }
            if s.hasPrefix("#") { zh.append(s); en.append(s); continue }
            if let r = s.range(of: "**中文**") {
                marked += 1
                zh.append(s[r.upperBound...].trimmingCharacters(in: .whitespaces))
            } else if let r = s.range(of: "**English**") {
                marked += 1
                en.append(s[r.upperBound...].trimmingCharacters(in: .whitespaces))
            } else if containsHan(s) { zh.append(s) } else { en.append(s) }
        }
        if marked > 0, !zh.isEmpty, !en.isEmpty { return lang == .zh ? zh : en }

        // Neither shape: show it as it is.
        return clean(notes)
    }

    /// The Markdown for one language as a single string, ready for `blocks(from:)`.
    static func markdown(_ notes: String, for lang: Lang) -> String { lines(notes, for: lang).joined(separator: "\n") }

    /// One half of a body as lines: blanks and rules dropped, the old language markers removed.
    private static func clean(_ half: String) -> [String] {
        half.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let s = raw.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "**中文**", with: "")
                .replacingOccurrences(of: "**English**", with: "")
                .trimmingCharacters(in: .whitespaces)
            return s.isEmpty || s.hasPrefix("---") ? nil : s
        }
    }

    private static func containsHan(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4e00...0x9fff).contains($0.value) }
    }

    // ---- Blocks ----

    /// Markdown lines as blocks. A line is a heading (`#`..`######`), a bullet (`- `, `* `, `+ `) or a
    /// paragraph. A line indented under a bullet continues that bullet. Blank lines and `---` are dropped.
    static func blocks(from markdown: String) -> [Block] {
        var out: [Block] = []
        var pendingBullet: String?
        func flush() {
            if let b = pendingBullet { out.append(.bullet(inline(b))); pendingBullet = nil }
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || isRule(s) { flush(); continue }
            if let text = headingText(s) {
                flush()
                if !text.isEmpty { out.append(.heading(inline(text))) }
            } else if let text = bulletText(s) {
                flush()
                pendingBullet = text
            } else if pendingBullet != nil, line.first == " " || line.first == "\t" {
                pendingBullet! += " " + s
            } else {
                flush()
                out.append(.paragraph(inline(s)))
            }
        }
        flush()
        return out
    }

    private static func isRule(_ s: String) -> Bool {
        s.count >= 3 && (s.allSatisfy { $0 == "-" } || s.allSatisfy { $0 == "*" } || s.allSatisfy { $0 == "_" })
    }

    private static func headingText(_ s: String) -> String? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = s.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }   // `#123` is a reference, not a heading
        return rest.trimmingCharacters(in: .whitespaces)
    }

    private static func bulletText(_ s: String) -> String? {
        guard let first = s.first, "-*+".contains(first), s.dropFirst().first == " " else { return nil }
        return s.dropFirst(2).trimmingCharacters(in: .whitespaces)
    }

    // ---- Inline ----

    /// A line's inline Markdown (bold, italic, code, links) with GitHub references and bare URLs made links.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnly, failurePolicy: .returnPartiallyParsedIfPossible)
        var out = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        autolink(&out)
        return out
    }

    /// A bare URL, `owner/repo#123`, `#123` or `@login`, leftmost first. Groups: 1 URL, 2 repo, 3 repo's
    /// number, 4 number, 5 login.
    private static let pattern = try! NSRegularExpression(pattern: """
        (https?://[^\\s<>\\]]+)\
        |(?<![\\w/.@-])([A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]*[A-Za-z0-9_])#(\\d+)(?![\\w])\
        |(?<![\\w#&])#(\\d+)(?![\\w])\
        |(?<![\\w@./+-])@([A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38})(?![\\w@-])
        """)

    private static func autolink(_ s: inout AttributedString) {
        let plain = String(s.characters)
        let whole = NSRange(plain.startIndex..., in: plain)
        for m in pattern.matches(in: plain, range: whole) {
            func group(_ i: Int) -> String? { Range(m.range(at: i), in: plain).map { String(plain[$0]) } }
            var range = Range(m.range, in: plain)!
            let target: String
            if var url = group(1) {
                while let last = url.last, ".,;:!?)'\"".contains(last) { url.removeLast() }
                // A `)` that closes a parenthesis opened inside the URL belongs to it, but release notes rarely need that.
                range = range.lowerBound..<plain.index(range.lowerBound, offsetBy: url.count)
                target = url
            } else if let repo = group(2), let n = group(3) { target = "https://github.com/\(repo)/issues/\(n)"
            } else if let n = group(4) { target = "https://github.com/\(repository)/issues/\(n)"
            } else if let login = group(5) { target = "https://github.com/\(login)"
            } else { continue }
            guard let url = URL(string: target),
                  let lo = AttributedString.Index(range.lowerBound, within: s),
                  let hi = AttributedString.Index(range.upperBound, within: s) else { continue }
            let span = lo..<hi
            // Not inside code or an existing link.
            if s[span].runs.contains(where: { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true }) { continue }
            s[span].link = url
        }
    }
}
