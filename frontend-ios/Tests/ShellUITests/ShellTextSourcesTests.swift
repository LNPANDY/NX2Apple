import Foundation
import Testing

/// Every text the shell's sources ask a catalog for is in that catalog. `ShellStrings.text("…")` in ShellUI and `hostText("…")` in
/// ShellHost look a text up by its English words, and a text with no entry shows in English in every language (three host messages did).
/// The sources are read as text: each literal of such a call, an interpolation standing for any placeholder (`%@`, `%lld`), is matched
/// against the catalog's keys. Texts passed on as `String.LocalizationValue` are checked where they are used (ShellStringsTests).
@Suite struct ShellTextSourcesTests {
    private static let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The catalog's keys with every format placeholder as one marker.
    private func keys(_ target: String) throws -> Set<String> {
        let url = Self.package.appendingPathComponent("Sources/\(target)/Resources/Localizable.xcstrings")
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])
        let placeholder = try Regex(#"%(?:[0-9]+\$)?(?:ll|l)?[@dfs]"#)
        return Set(strings.keys.map { $0.replacing(placeholder, with: "\u{0}") })
    }

    /// The text of a Swift string literal that starts at `start` (the opening quote), with each `\(…)` as the marker and escapes resolved.
    private func literal(_ s: [Character], from start: Int) -> (text: String, end: Int) {
        var i = start + 1, out = ""
        while i < s.count {
            let c = s[i]
            if c == "\\", i + 1 < s.count {
                if s[i + 1] == "(" {
                    var depth = 1, j = i + 2
                    while j < s.count, depth > 0 {
                        if s[j] == "\"" { j = literal(s, from: j).end; continue }
                        if s[j] == "(" { depth += 1 } else if s[j] == ")" { depth -= 1 }
                        j += 1
                    }
                    out.append("\u{0}"); i = j; continue
                }
                let escaped: [Character: Character] = ["n": "\n", "t": "\t", "\"": "\"", "\\": "\\"]
                out.append(escaped[s[i + 1]] ?? s[i + 1]); i += 2; continue
            }
            if c == "\"" || c == "\n" { return (out, i + 1) }
            out.append(c); i += 1
        }
        return (out, i)
    }

    /// Each `call("…")` literal of the target's sources, with the file and line.
    private func calls(_ call: String, in target: String) throws -> [(text: String, place: String)] {
        let folder = Self.package.appendingPathComponent("Sources/\(target)")
        var found: [(String, String)] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() where name.hasSuffix(".swift") {
            let source = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            let chars = Array(source)
            let opener = Array(call + "(\"")
            var i = 0
            while i + opener.count <= chars.count {
                if Array(chars[i..<(i + opener.count)]) == opener, i == 0 || !(chars[i - 1].isLetter || chars[i - 1] == ".") {
                    let line = chars[..<i].filter { $0 == "\n" }.count + 1
                    let (text, end) = literal(chars, from: i + opener.count - 1)
                    found.append((text, "\(name):\(line)"))
                    i = end
                } else { i += 1 }
            }
        }
        return found
    }

    @Test(arguments: [("ShellUI", "ShellStrings.text"), ("ShellHost", "hostText")])
    func everyTextTheSourcesAskForIsInTheCatalog(target: String, call: String) throws {
        let catalog = try keys(target)
        let found = try calls(call, in: target)
        #expect(found.count > 50, "the scan found the calls of \(target)")
        for (text, place) in found {
            #expect(catalog.contains(text), "\(place): \"\(text.replacingOccurrences(of: "\u{0}", with: "%@"))\" has no entry in the \(target) catalog")
        }
    }
}
