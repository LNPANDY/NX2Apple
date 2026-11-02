import Foundation

/// Finds and reads the language files, `frontend/l10n/<code>.json` (LNPANDY/NX2Apple#388). One flat JSON object per language: the keys
/// are the texts' names, the values the texts, and `_language` (the language's own name and its locale prefixes) is not a text.
///
/// Where they are, in this order:
///
///     NX_L10N_DIR                   a folder named in the environment, for a try-out
///     Contents/Resources/l10n       the app: build-mac-app.yml and tools/try-local copy the folder there
///     <ancestor>/frontend/l10n      `swift run`: found by walking up from the executable
///     the checkout of this source   `swift test`: from the path of this file
///
/// A missing or broken file never stops the app. That language has no texts, a lookup falls back to English and then to the key, and
/// the problem is written to standard error once (the files are read once, at the first lookup).
package enum LocalizationFiles {
    /// What a file says about its language in `_language`. A file without it still works as a catalog: its name is its code and its
    /// only locale prefix is its code.
    package struct Language: Equatable, Sendable {
        package let code: String
        /// The language's own name, which the picker shows (Svenska, Deutsch).
        package let name: String
        /// The lowercased prefixes that select it: a language tag (`de`, so `de-AT`) or, on Windows, a locale name (`german`).
        package let locales: [String]
        /// Where the picker puts it. Languages without one come after those with one, by code.
        package let order: Int?
    }

    /// The codes of the language files in `directory`: the names of its `*.json` files, sorted.
    package static func codes(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// One file's `_language` entry, with the defaults above for a missing or odd one.
    package static func language(code: String, in file: URL) -> Language {
        var name = code
        var locales = [code]
        var order: Int?
        if let data = try? Data(contentsOf: file),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let entry = object["_language"] as? [String: Any] {
            if let n = entry["name"] as? String, !n.isEmpty { name = n }
            let given = (entry["locales"] as? [Any])?.compactMap { ($0 as? String)?.lowercased() }.filter { !$0.isEmpty } ?? []
            if !given.isEmpty { locales = given }
            order = entry["order"] as? Int
        }
        return Language(code: code, name: name, locales: locales, order: order)
    }

    /// Every language in `directory` in picker order: those with an `order` by it, then the rest by code.
    package static func languages(from directory: URL? = directory()) -> [Language] {
        guard let directory else { return [] }
        let all = codes(in: directory).map { language(code: $0, in: directory.appendingPathComponent("\($0).json")) }
        return all.sorted {
            switch ($0.order, $1.order) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.code < $1.code
            }
        }
    }

    /// The folder with the language files, nil when none of the places has `en.json`.
    package static func directory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  resources: URL? = BundledTools.resources,
                                  executable: URL? = Bundle.main.executableURL,
                                  sourceFile: String = #filePath) -> URL? {
        var candidates: [URL] = []
        if let named = environment["NX_L10N_DIR"], !named.isEmpty { candidates.append(URL(fileURLWithPath: named)) }
        if let resources { candidates.append(resources.appendingPathComponent("l10n")) }
        var folder = executable?.deletingLastPathComponent()
        while let current = folder, current.path != "/" {
            candidates.append(current.appendingPathComponent("frontend/l10n"))
            if current.lastPathComponent == "frontend" { candidates.append(current.appendingPathComponent("l10n")) }
            folder = current.deletingLastPathComponent()
        }
        // Sources/NXCore/<this file> sits two folders below frontend.
        candidates.append(URL(fileURLWithPath: sourceFile).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("l10n"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("en.json").path) }
    }

    /// One file's texts: every entry whose value is a string, except `_language`. Nil when the file is missing or is not a JSON object.
    package static func texts(in file: URL, report: (String) -> Void = { FileHandle.standardError.write(Data(("l10n: " + $0 + "\n").utf8)) }) -> [String: String]? {
        guard let data = try? Data(contentsOf: file) else { report("\(file.path) cannot be read"); return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            report("\(file.path) is not a JSON object")
            return nil
        }
        var out: [String: String] = [:]
        for (key, value) in object where key != "_language" {
            if let text = value as? String { out[key] = text } else { report("\(file.lastPathComponent): \(key) is not a text") }
        }
        return out
    }

    /// Every language's texts by code. A language whose file is missing or broken is left out.
    package static func load(from directory: URL? = directory(),
                             report: (String) -> Void = { FileHandle.standardError.write(Data(("l10n: " + $0 + "\n").utf8)) }) -> [String: [String: String]] {
        guard let directory else {
            report("no language files found (Contents/Resources/l10n or frontend/l10n), the app shows its keys")
            return [:]
        }
        var out: [String: [String: String]] = [:]
        for code in codes(in: directory) {
            if let texts = texts(in: directory.appendingPathComponent("\(code).json"), report: report) { out[code] = texts }
        }
        return out
    }
}
