import XCTest
@testable import NXCore

/// The rules every language file in `frontend/l10n` keeps (LNPANDY/NX2Apple#388). The languages are the files of the folder, so a new
/// `<code>.json` is checked here without a change to this test. The Qt front end has the same rules in
/// `frontend-qt/tests/test_localization_rules.py`.
final class LocalizationRulesTests: XCTestCase {
    private static let directory = LocalizationFiles.directory()
    private static let required = ["en", "zh"]

    private func files() throws -> [(code: String, url: URL)] {
        let directory = try XCTUnwrap(Self.directory, "frontend/l10n was not found")
        return LocalizationFiles.codes(in: directory).map { ($0, directory.appendingPathComponent("\($0).json")) }
    }

    private func object(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "\(url.lastPathComponent) is not a JSON object")
    }

    private func texts() throws -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for (code, url) in try files() {
            out[code] = try object(url).filter { $0.key != "_language" }.compactMapValues { $0 as? String }
        }
        return out
    }

    /// What String(format:) reads: the type of each argument by its position, the count of %%, and `{0}` or `{name}` braces.
    /// A positional `%2$@` is argument 2, so a translation may reorder arguments. Without a position they count 1, 2, 3.
    private struct Placeholders: Equatable {
        var arguments: [Int: String] = [:]
        var percents = 0
        var braces: [String] = []

        init(_ text: String) {
            let ns = text as NSString
            let printf = try! NSRegularExpression(pattern: "%(?:([0-9]+)\\$)?(\\.[0-9]+)?(ll|l)?([@dsf%])")
            var next = 1
            for match in printf.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                func group(_ i: Int) -> String { match.range(at: i).location == NSNotFound ? "" : ns.substring(with: match.range(at: i)) }
                if group(4) == "%" { percents += 1; continue }
                var index = next
                if let position = Int(group(1)) { index = position } else { next += 1 }
                arguments[index] = group(2) + group(3) + group(4)
            }
            let brace = try! NSRegularExpression(pattern: "\\{(\\w*)\\}")
            braces = brace.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }.sorted()
        }
    }

    /// The keys in the order the file has them. The files are one entry per line, indented by two spaces.
    private func rawKeys(_ url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let re = try NSRegularExpression(pattern: "^  \"((?:[^\"\\\\]|\\\\.)*)\": ", options: .anchorsMatchLines)
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    func testEnglishAndChineseExistAndHaveTheSameKeys() throws {
        let all = try texts()
        for code in Self.required { XCTAssertNotNil(all[code], "\(code).json is missing") }
        let en = Set(all["en"]?.keys ?? [:].keys), zh = Set(all["zh"]?.keys ?? [:].keys)
        XCTAssertEqual(en.subtracting(zh).sorted(), [], "keys only in en.json")
        XCTAssertEqual(zh.subtracting(en).sorted(), [], "keys only in zh.json")
    }

    func testNoLanguageHasAKeyEnglishDoesNotHave() throws {
        let all = try texts()
        let english = Set(all["en"]?.keys ?? [:].keys)
        for (code, texts) in all { XCTAssertEqual(Set(texts.keys).subtracting(english).sorted(), [], "\(code).json has keys that en.json does not have") }
    }

    func testPlaceholdersMatchTheEnglishTextOfTheSameKey() throws {
        let all = try texts()
        let english = all["en"] ?? [:]
        for (code, texts) in all {
            for (key, text) in texts {
                guard let source = english[key] else { continue }
                XCTAssertEqual(Placeholders(text), Placeholders(source), "\(code).json \(key)")
            }
        }
    }

    func testEveryValueIsANonEmptyText() throws {
        for (code, url) in try files() {
            for (key, value) in try object(url) where key != "_language" {
                guard let text = value as? String else { XCTFail("\(code).json \(key) is not a text"); continue }
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(code).json \(key) is empty")
            }
        }
    }

    func testEveryFileHasALanguageEntryWithNameAndLocales() throws {
        for (code, url) in try files() {
            let entry = try XCTUnwrap(try object(url)["_language"] as? [String: Any], "\(code).json has no _language")
            XCTAssertFalse((entry["name"] as? String ?? "").trimmingCharacters(in: .whitespaces).isEmpty, "\(code).json: _language has no name")
            let locales = entry["locales"] as? [String] ?? []
            XCTAssertFalse(locales.isEmpty, "\(code).json: _language has no locales")
            XCTAssertTrue(locales.allSatisfy { !$0.isEmpty && $0 == $0.lowercased() }, "\(code).json: locales are lowercase and not empty")
            XCTAssertTrue(locales.contains(code), "\(code).json: the code is one of its locales")
            if let order = entry["order"] { XCTAssertTrue(order is Int, "\(code).json: order is a number") }
        }
    }

    func testTheFilesAreFlatAndSortedWithLanguageFirst() throws {
        for (code, url) in try files() {
            let keys = try rawKeys(url)
            XCTAssertEqual(keys.first, "_language", "\(code).json starts with _language")
            // Sorted by code point, as Python's sorted() writes them, so the Mac and the Windows launcher see the same diff.
            let rest = Array(keys.dropFirst())
            XCTAssertEqual(rest, rest.sorted { Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes($1.unicodeScalars.map(\.value)) }, "\(code).json keys are not sorted")
            XCTAssertEqual(keys.count, Set(keys).count, "\(code).json has a duplicate key")
            XCTAssertEqual(keys.count, try object(url).count, "\(code).json has an entry that is not one line at the top level")
            XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasSuffix("}\n"), "\(code).json ends with a newline")
        }
    }

    func testLanguagesHaveDistinctLocales() throws {
        var seen: [String: String] = [:]
        for language in LocalizationFiles.languages() {
            for locale in language.locales {
                XCTAssertNil(seen[locale], "\(language.code).json and \(seen[locale] ?? "").json both claim \(locale)")
                seen[locale] = language.code
            }
        }
    }
}
