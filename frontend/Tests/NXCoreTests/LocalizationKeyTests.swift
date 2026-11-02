import XCTest
@testable import NXCore

/// The keys the code uses and the keys `frontend/l10n/en.json` has have to be the same set (LNPANDY/NX2Apple#388).
///
/// 1. A key that code names in a lookup (`t("key")`, `loc.t("key")`, `L10n.string("key", ...)`, `t('key')` in Python) is in en.json.
/// 2. A key that code builds at run time (a prefix and a variable) starts with an entry of `dynamicKeys` in
///    `frontend/Tests/l10n-key-rules.json`, and every entry has a key in en.json and a place in the sources that builds it.
/// 3. A key of en.json that no source mentions, literally or under a `dynamicKeys` or `catalogKeys` entry, fails, unless it is in
///    `unusedAllowed`. `catalogKeys` are the iOS shell's texts (`ios.*`): `tools/l10n_shell_catalogs.py` writes them into the shell's
///    string catalogs, and `tools/tests/test_l10n_shell_catalogs.py` checks that the catalogs are current.
///
/// The sources are both front ends, so a key only the Windows launcher or only the Mac launcher uses is used. The Qt front end
/// runs the same rules in `frontend-qt/tests/test_localization_keys.py`, from the same rules file.
final class LocalizationKeyTests: XCTestCase {
    private struct Rules: Decodable {
        struct Dynamic: Decodable { let prefix: String; let suffix: String; let why: String }
        struct Allowed: Decodable { let key: String; let why: String }
        struct Catalog: Decodable { let prefix: String; let why: String }
        let dynamicKeys: [Dynamic]
        let catalogKeys: [Catalog]
        let unusedAllowed: [Allowed]
    }

    private struct Lookup { let file: String; let text: String; let built: Bool }

    private struct Scan {
        var keys: Set<String> = []
        var rules: Rules
        var sources: [String: String] = [:]
        var literals: Set<String> = []
        var lookups: [Lookup] = []

        func covered(_ key: String) -> Bool {
            rules.dynamicKeys.contains { key.hasPrefix($0.prefix) && key.hasSuffix($0.suffix) && key.count >= $0.prefix.count + $0.suffix.count }
                || rules.catalogKeys.contains { key.hasPrefix($0.prefix) }
        }
    }

    // t("k"), loc.t("k"), t('k'), t(f'k.{x}'), t("k.\(x)"), t("k." + x). Group 2 is the literal's text, group 3 what follows it.
    private static let calls: [NSRegularExpression] = [
        #"(?<![A-Za-z0-9_])t\(\s*f?(['"])((?:(?!\1).)*)\1(\s*[+%])?"#,
        #"L10n\.string\(\s*()"((?:[^"\\]|\\.)*)"()"#,
        #"L10n\.table\[\s*()"((?:[^"\\]|\\.)*)"()"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    private static let literal = try! NSRegularExpression(pattern: #"["']([A-Za-z0-9_][A-Za-z0-9_.\-]*)["']"#)
    private static let dynamic = try! NSRegularExpression(pattern: #"\\\(|\{"#)
    /// win/build_app.py has its own t() that writes a log line, it does not look up a text.
    private static let notLookups: Set<String> = ["build_app.py"]

    private static let frontend = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let scan: Scan = {
        let root = frontend.deletingLastPathComponent()
        let en = try! JSONSerialization.jsonObject(with: Data(contentsOf: frontend.appendingPathComponent("l10n/en.json"))) as! [String: Any]
        let rules = try! JSONDecoder().decode(Rules.self, from: Data(contentsOf: frontend.appendingPathComponent("Tests/l10n-key-rules.json")))
        var scan = Scan(keys: Set(en.keys).subtracting(["_language"]), rules: rules)
        for base in [frontend.appendingPathComponent("Sources"), root.appendingPathComponent("frontend-qt/nspb_qt")] {
            guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" || url.pathExtension == "py" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scan.sources[url.path.replacingOccurrences(of: root.path + "/", with: "")] = text
            }
        }
        for (file, text) in scan.sources {
            let whole = NSRange(location: 0, length: (text as NSString).length)
            func group(_ m: NSTextCheckingResult, _ i: Int) -> String { m.range(at: i).location == NSNotFound ? "" : (text as NSString).substring(with: m.range(at: i)) }
            for m in literal.matches(in: text, range: whole) { scan.literals.insert(group(m, 1)) }
            if notLookups.contains((file as NSString).lastPathComponent) { continue }
            for call in calls {
                for m in call.matches(in: text, range: whole) {
                    let body = group(m, 2), tail = group(m, 3).trimmingCharacters(in: .whitespaces)
                    let built = dynamic.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) != nil || tail == "+" || tail == "%"
                    var text = body
                    if built, let cut = dynamic.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) {
                        text = (body as NSString).substring(to: cut.range.location)
                    }
                    scan.lookups.append(Lookup(file: file, text: text, built: built))
                }
            }
        }
        return scan
    }()

    func testTheSourcesWereFound() {
        let scan = Self.scan
        XCTAssertTrue(scan.sources.keys.contains { $0.hasSuffix(".py") }, "no Python sources")
        XCTAssertTrue(scan.sources.keys.contains { $0.hasSuffix(".swift") }, "no Swift sources")
        XCTAssertGreaterThan(scan.lookups.count, 100, "the lookup patterns found almost nothing")
    }

    func testEveryLiteralKeyInALookupIsInEnglish() {
        let scan = Self.scan
        let missing = Set(scan.lookups.filter { !$0.built && !scan.keys.contains($0.text) }.map { "\($0.file): \($0.text)" }).sorted()
        XCTAssertEqual(missing, [], "keys that a lookup names and en.json lacks")
    }

    func testEveryBuiltKeyStartsWithADeclaredPrefix() {
        let scan = Self.scan
        let undeclared = Set(scan.lookups.filter { lookup in
            lookup.built && !scan.rules.dynamicKeys.contains { lookup.text.hasPrefix($0.prefix) || $0.prefix.hasPrefix(lookup.text) }
        }.map { "\($0.file): \($0.text)" }).sorted()
        XCTAssertEqual(undeclared, [], "keys built at run time whose prefix is not in dynamicKeys of l10n-key-rules.json")
    }

    func testEveryDeclaredPrefixHasKeysAndIsBuiltSomewhere() {
        let scan = Self.scan
        for entry in scan.rules.dynamicKeys {
            let matching = scan.keys.filter { $0.hasPrefix(entry.prefix) && $0.hasSuffix(entry.suffix) && $0.count >= entry.prefix.count + entry.suffix.count }
            XCTAssertFalse(matching.isEmpty, "dynamicKeys \(entry.prefix) \(entry.suffix) has no key in en.json")
            // Built in a lookup or anywhere else (a Dep's name, a labelKey), so the check is that a string literal starts with it.
            XCTAssertTrue(scan.sources.values.contains { $0.contains("\"" + entry.prefix) || $0.contains("'" + entry.prefix) },
                          "no source has a string that starts with \(entry.prefix)")
            XCTAssertFalse(entry.why.trimmingCharacters(in: .whitespaces).isEmpty, "dynamicKeys \(entry.prefix) has no reason")
        }
    }

    func testEveryCatalogPrefixHasKeysAndAReason() {
        let scan = Self.scan
        for entry in scan.rules.catalogKeys {
            XCTAssertTrue(scan.keys.contains { $0.hasPrefix(entry.prefix) }, "catalogKeys \(entry.prefix) has no key in en.json")
            XCTAssertFalse(entry.why.trimmingCharacters(in: .whitespaces).isEmpty, "catalogKeys \(entry.prefix) has no reason")
        }
    }

    func testNoKeyIsUnused() {
        let scan = Self.scan
        let allowed = Set(scan.rules.unusedAllowed.map(\.key))
        let unused = scan.keys.filter { !scan.literals.contains($0) && !scan.covered($0) && !allowed.contains($0) }.sorted()
        XCTAssertEqual(unused, [], "keys in en.json that no source uses (remove them from every language file, or explain them in unusedAllowed)")
    }

    func testTheUnusedAllowlistHasNoStaleEntries() {
        let scan = Self.scan
        for entry in scan.rules.unusedAllowed {
            XCTAssertFalse(entry.why.trimmingCharacters(in: .whitespaces).isEmpty, "\(entry.key) has no reason")
            XCTAssertTrue(scan.keys.contains(entry.key), "\(entry.key) is not in en.json any more")
            XCTAssertFalse(scan.literals.contains(entry.key), "\(entry.key) is used, so it needs no entry")
            XCTAssertFalse(scan.covered(entry.key), "\(entry.key) is covered by a dynamicKeys entry")
        }
    }
}
