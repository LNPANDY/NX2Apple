import CryptoKit
import Foundation

/// nxkit (https://github.com/v0lumehi/nxkit, LNPANDY/NX2Apple#1460): a build tool in Rust (`nxb`) and the runtime that is the program of the app it makes
/// (`nxkit-host`). Mac only. There is no checkout to choose: the launcher installs the binaries of the latest GitHub release into its own
/// support folder (`upstreams/nxkit/`). `nxb build` writes the same `--progress json` events as the NSP script, so the stage list needs no new parser.
package enum NxkitBuilder {
    package static var featureEnabled = ProcessInfo.processInfo.environment["NX2APPLE_MULTI_UPSTREAM"] != "0"

    package static let repository = "v0lumehi/nxkit"
    package static let latestReleaseURL = URL(string: "https://api.github.com/repos/v0lumehi/nxkit/releases/latest")!
    package static let builderName = "nxb"
    package static let hostName = "nxkit-host"
    package static let sumsName = "SHA256SUMS"
    package static let installInfoName = "install.json"

    // MARK: Release

    /// What the latest release offers: its tag, the macOS ZIP and the checksum file.
    package struct Release: Equatable, Sendable {
        package let tag: String
        package let zipName: String
        package let zipURL: URL
        package let sumsURL: URL?

        package var version: String { NxkitBuilder.normalizedVersion(tag) }
    }

    /// The answer of `repos/v0lumehi/nxkit/releases/latest`. nil when it names no macOS ZIP.
    package static func parseRelease(_ data: Data) -> Release? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = root["tag_name"] as? String, !tag.isEmpty,
              let assets = root["assets"] as? [[String: Any]] else { return nil }
        func url(_ asset: [String: Any]) -> URL? { (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        let zips = assets.filter {
            let name = ($0["name"] as? String)?.lowercased() ?? ""
            return name.hasSuffix(".zip") && name.contains("macos")
        }
        let zip = zips.first { ($0["name"] as? String)?.lowercased().contains("arm64") == true } ?? zips.first
        guard let zip, let name = zip["name"] as? String, let zipURL = url(zip) else { return nil }
        let sums = assets.first { ($0["name"] as? String) == sumsName }.flatMap(url)
        return Release(tag: tag, zipName: name, zipURL: zipURL, sumsURL: sums)
    }

    /// "v0.10.1" and "nxb 0.10.1" give "0.10.1". A text with no version gives "".
    package static func normalizedVersion(_ raw: String) -> String {
        let token = raw.split(whereSeparator: { !"0123456789.".contains($0) }).first { $0.first?.isNumber == true }
        return token.map(String.init) ?? ""
    }

    /// Whether `latest` is a higher version than `installed` (numbers compared part by part).
    package static func isNewer(_ latest: String, than installed: String) -> Bool {
        func parts(_ s: String) -> [Int] { normalizedVersion(s).split(separator: ".").compactMap { Int($0) } }
        let (l, i) = (parts(latest), parts(installed))
        guard !l.isEmpty else { return false }
        guard !i.isEmpty else { return true }
        for k in 0..<max(l.count, i.count) {
            let (a, b) = (k < l.count ? l[k] : 0, k < i.count ? i[k] : 0)
            if a != b { return a > b }
        }
        return false
    }

    // MARK: Checksums

    /// `SHA256SUMS`: one `<hex>  <name>` line per file (a `*` before the name marks binary mode). Names are kept as written.
    package static func parseChecksums(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let hash = String(parts[0]).lowercased()
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { continue }
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            if !name.isEmpty { out[name] = hash }
        }
        return out
    }

    package enum Verification: Equatable, Sendable {
        case ok
        case mismatch
        case missing   // the checksum file does not list the file, or the file cannot be read
    }

    /// The SHA-256 of a file, read in pieces.
    package static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    package static func verify(file: URL, listedAs name: String, in sums: [String: String]) -> Verification {
        guard let want = sums[name], let have = sha256(of: file) else { return .missing }
        return have == want ? .ok : .mismatch
    }

    // MARK: The installed files

    /// What the install left next to the binaries: the release it came from and whether the runtime was in it.
    package struct InstallInfo: Codable, Equatable, Sendable {
        package var tag: String
        package var hasHost: Bool
        package init(tag: String, hasHost: Bool) { self.tag = tag; self.hasHost = hasHost }

        package var version: String { NxkitBuilder.normalizedVersion(tag) }
    }

    package static func readInfo(in tree: String) -> InstallInfo? {
        guard let data = FileManager.default.contents(atPath: path(tree, installInfoName)) else { return nil }
        return try? JSONDecoder().decode(InstallInfo.self, from: data)
    }

    package static func writeInfo(_ info: InstallInfo, in dir: URL) {
        if let data = try? JSONEncoder().encode(info) { try? data.write(to: dir.appendingPathComponent(installInfoName)) }
    }

    package static func builderPath(in tree: String) -> String { path(tree, builderName) }
    package static func hostPath(in tree: String) -> String { path(tree, hostName) }

    /// nxb is there and runs: the tree can check for updates and be selected.
    package static func isUsableTree(_ directory: String, fileManager fm: FileManager = .default) -> Bool {
        !directory.isEmpty && fm.isExecutableFile(atPath: builderPath(in: directory))
    }

    /// nxb finds `nxkit-host` in its own folder: without it `nxb build` cannot make an app. The first nxkit release ZIP held nxb only.
    package static func canBuildApps(_ directory: String, fileManager fm: FileManager = .default) -> Bool {
        isUsableTree(directory, fileManager: fm) && fm.isExecutableFile(atPath: hostPath(in: directory))
    }

    private static func path(_ tree: String, _ name: String) -> String {
        (tree.hasSuffix("/") ? tree : tree + "/") + name
    }

    // MARK: The build

    /// `nxb build <folder or .nup> [-k KEYS] --platform mac -o APP --work-dir WORK --progress json`.
    /// `--progress json` and not `bar`: the bar redraws one terminal line with escape codes, the JSON events are what the launcher's stage list reads.
    /// A Switch 2 package (`nup`) takes `--nup FILE` and no keys.
    package static func arguments(
        input: String,
        nup: String?,
        keysPath: String,
        outputAppPath: String,
        workDir: String,
        titleID: String?
    ) -> [String] {
        var args = ["build", nup.map { ($0 as NSString).deletingLastPathComponent } ?? input]
        if let nup {
            args += ["--nup", nup]
        } else if !keysPath.isEmpty {
            args += ["-k", keysPath]
        }
        args += ["--platform", "mac", "-o", outputAppPath, "--work-dir", workDir, "--progress", "json"]
        if let titleID {
            let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !tid.isEmpty { args += ["--title-id", tid] }
        }
        return args
    }

    /// The environment of the build: the tools of the system, and the runtime `nxb` puts into the app.
    package static func environment(tree: String, base: [String: String]) -> [String: String] {
        var env = base
        env["NXB_NXKIT_HOST"] = hostPath(in: tree)
        return env
    }

    /// The work folder of one game, under the launcher's caches. A second build with the same files reuses its stages.
    package static func workDirectory(home: String, key: String) -> String {
        home + "/Library/Caches/NX2Apple/nxkit/" + key
    }

    /// nxb's last error line (`[RED] ...`), else the last meaningful line of the log.
    package static func lastError(in log: String) -> String? {
        ExperimentalBuilder.lastError(in: log) ?? BuildProgress.lastMeaningfulLine(log)
    }
}
