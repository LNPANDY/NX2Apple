import Foundation

/// Key-free identification, matching scan_nsps/title_of in the build script. Never reads ticket contents.
enum PackageCheck {
    static let missingID = "No recognized ticket name and no filename [16 hex title ID]. This is not a keys check."
    static let extensions = ["nsp", "xci", "nsz", "xcz"]

    struct Package: Sendable {
        var path: String
        var title: UInt64?
        var method = "none"
        var reason = ""
        var role = ""
        var selected = true
        var consumed = true
        var family: UInt64? {
            guard let title else { return nil }
            let low = title & 0xFFF
            if low == 0 { return title }
            let high = title & ~UInt64(0xFFF)
            return low == 0x800 ? high : (high >= 0x1000 ? high - 0x1000 : nil)
        }
        var actualRole: String { title.map { $0 & 0xFFF == 0 ? "base" : $0 & 0xFFF == 0x800 ? "update" : "dlc" } ?? "" }
        var status: String {
            let identity = title.map { String(format: "%016llX via ", $0) + method } ?? method
            return "\(role): \(identity); \(reason.isEmpty ? "identified" : reason)"
        }
    }

    struct Result: Sendable {
        var packages: [Package] = []
        var title: UInt64?
        var ready = false
        var needsStaging = true
        var paths: [String] { packages.filter { $0.consumed && $0.reason.isEmpty }.map(\.path) }
        // Paths, filenames and package/key contents deliberately do not enter diagnostics.
        var diagnostics: String { (["Package identification (independent of keys)"] + packages.map(\.status)).joined(separator: "\n") }
    }

    static func match(_ pattern: String, _ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    static func inspect(_ path: String) -> Package {
        var p = Package(path: path)
        guard let f = FileHandle(forReadingAtPath: path) else { p.reason = "File missing or unreadable."; return p }
        defer { try? f.close() }
        func malformed() -> Package {
            var bad = Package(path: path)
            bad.reason = "Malformed or truncated package header/table."
            return bad
        }
        guard let size = try? f.seekToEnd(), (try? f.seek(toOffset: 0)) != nil,
              let headData = try? f.read(upToCount: 0x104) else { return malformed() }
        let head = [UInt8](headData)
        func number(_ b: [UInt8], _ at: Int, _ n: Int) -> UInt64 {
            (0..<n).reduce(0) { $0 | UInt64(b[at + $1]) << (8 * $1) }
        }
        if head.prefix(4).elementsEqual("PFS0".utf8) {
            guard head.count >= 16 else { return malformed() }
            let count = number(head, 4, 4), names = number(head, 8, 4)
            let length = count * 24 + names
            guard count <= 4096, names <= 1 << 20, size >= 16, length <= size - 16,
                  (try? f.seek(toOffset: 16)) != nil else { return malformed() }
            let data = length == 0 ? Data() : (try? f.read(upToCount: Int(length)))
            guard let data, data.count == Int(length) else { return malformed() }
            let table = [UInt8](data), remaining = size - 16 - length
            for i in 0..<Int(count) {
                let offset = number(table, i * 24, 8), bytes = number(table, i * 24 + 8, 8)
                let nameAt = number(table, i * 24 + 16, 4)
                guard nameAt < names, offset <= remaining, bytes <= remaining - offset else { return malformed() }
                let start = Int(count * 24 + nameAt)
                guard let end = table[start...].firstIndex(of: 0) else { return malformed() }
                let name = String(decoding: table[start..<end], as: UTF8.self)
                if p.title == nil, let rights = match(#"^([0-9A-Fa-f]{32})\.tik$"#, name) {
                    p.title = UInt64(rights.prefix(16), radix: 16); p.method = "ticket name"
                }
            }
        } else if head.count != 0x104 || !head[0x100..<0x104].elementsEqual("HEAD".utf8) {
            return malformed()
        }
        if p.title == nil {
            if let tag = match(#"\[([0-9A-Fa-f]{16})\]"#, (path as NSString).lastPathComponent) {
                p.title = UInt64(tag, radix: 16); p.method = "filename tag"
            } else { p.reason = missingID }
        }
        return p
    }

    static func run(_ files: [String]) -> Result {
        guard let first = files.first, !first.isEmpty else { return Result() }
        let fm = FileManager.default, dir = (first as NSString).deletingLastPathComponent
        var result = Result()
        var skipped: [Package] = []
        var picked = Set(files)
        for (i, path) in files.enumerated() where !path.isEmpty {
            var p = inspect(path)
            p.role = i == 0 ? "base" : i == 1 ? "update" : "dlc"
            if let ext = ["nsz": "nsp", "xcz": "xci"][(path as NSString).pathExtension] {
                let counterpart = (path as NSString).deletingPathExtension + "." + ext
                if fm.fileExists(atPath: counterpart), p.reason.isEmpty || p.reason == missingID {
                    p.method = "skipped: decompressed counterpart is used"; p.reason = ""; p.consumed = false
                    p.title = nil
                    skipped.append(p)
                    p = inspect(counterpart); p.role = i == 0 ? "base" : i == 1 ? "update" : "dlc"
                    picked.insert(counterpart)
                }
            }
            if !extensions.contains((path as NSString).pathExtension) { p.reason = "Choose a lowercase .nsp, .xci, .nsz or .xcz package." }
            if (path as NSString).lastPathComponent.hasPrefix("._") { p.reason = "AppleDouble metadata is not a build input; choose the original package." }
            if !result.packages.contains(where: {
                URL(fileURLWithPath: $0.path).standardizedFileURL == URL(fileURLWithPath: p.path).standardizedFileURL
                    && $0.role == p.role
            }) {
                result.packages.append(p)
            }
        }
        func compressedCopy(_ path: String) -> Bool {
            let ext = (path as NSString).pathExtension
            guard let target = ["nsz": "nsp", "xcz": "xci"][ext] else { return false }
            return fm.fileExists(atPath: (path as NSString).deletingPathExtension + "." + target)
        }
        let siblingPaths = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted().filter {
            !$0.hasPrefix("._") && extensions.contains(($0 as NSString).pathExtension)
        }.map { dir + "/" + $0 }
        let others = siblingPaths.filter {
            !picked.contains($0) && !compressedCopy($0)
        }.map { inspect($0) }
        let candidates = result.packages + others
        let families = Set(candidates.filter { $0.reason.isEmpty }.compactMap(\.family))
        let unknown = candidates.filter { $0.reason == missingID }
        if result.packages[0].reason == missingID, families.count == 1, unknown.count == 1,
           let family = families.first, !candidates.contains(where: { $0.title == family }) {
            result.packages[0].method = "ticketless base paired with one family; build IDs checked during build"
            result.packages[0].reason = ""; result.title = family
        }
        if result.packages[0].title != nil { result.title = result.packages[0].family }
        for i in result.packages.indices where result.packages[i].title != nil {
            if result.packages[i].actualRole != result.packages[i].role {
                result.packages[i].reason = "Package role does not match the selected slot."
            } else if result.packages[i].family != result.title {
                result.packages[i].reason = "Package belongs to a different game."
            }
        }
        for var p in others where p.title != nil && p.family == result.title && p.reason.isEmpty && p.actualRole != "base" {
            if p.actualRole == "update" && files.count > 1 && !files[1].isEmpty { continue }
            if compressedCopy(p.path) { continue }
            p.role = p.actualRole; p.selected = false
            result.packages.append(p)
        }
        let names = result.packages.map { ($0.path as NSString).lastPathComponent }
        if Set(names).count != names.count { result.packages[0].reason = "Selected files have duplicate names; choose files with distinct names." }
        result.ready = result.title != nil && result.packages.allSatisfy { $0.reason.isEmpty }
        result.needsStaging = Set(result.paths) != Set(siblingPaths)
        result.packages += skipped
        return result
    }

    static func stage(_ paths: [String], in folder: String, fallbackFolder: String? = nil,
                      fileManager fm: FileManager = .default) throws -> String {
        let fallback = fallbackFolder ?? fm.temporaryDirectory.path
        func attempt(_ parent: String) throws -> String {
            let directory = (parent as NSString).appendingPathComponent(".nx2apple-inputs-" + UUID().uuidString)
            do {
                try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
                for path in paths {
                    try fm.createSymbolicLink(atPath: directory + "/" + (path as NSString).lastPathComponent,
                                              withDestinationPath: URL(fileURLWithPath: path).path)
                }
                return directory
            } catch {
                try? fm.removeItem(atPath: directory)
                throw error
            }
        }
        do {
            return try attempt(folder)
        } catch {
            // exFAT/FAT output drives cannot hold symlinks. Only links move to the
            // system filesystem; package contents and the build work/output stay put.
            return try attempt(fallback)
        }
    }
}
