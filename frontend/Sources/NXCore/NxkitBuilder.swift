import CryptoKit
import Darwin
import Foundation

/// nxkit (https://github.com/v0lumehi/nxkit, LNPANDY/NX2Apple#1460), the build engine "nxkit (Beta)": a build tool in Rust (`nxb`) and the runtime that
/// is the program of the app it makes (`nxkit-host`). Mac only, macOS 26 and later, Apple silicon only. The app bundles the pair of the release
/// `frontend/nxbuild.pin` names in `Contents/Resources/nxbuild/` and updates it from newer signed releases (NxkitUpdate.swift). `nxb build` writes the
/// same `--progress json` events as the NSP script, so the stage list needs no new parser. There is no fallback to the NSP script: a failure shows
/// nxb's exit code and its last lines.
package enum NxkitBuilder {
    /// `NX2APPLE_MULTI_UPSTREAM=0` hides every engine but nxnative, as for the others.
    package static var featureEnabled = ProcessInfo.processInfo.environment["NX2APPLE_MULTI_UPSTREAM"] != "0"

    package static let repository = "v0lumehi/nxkit"
    package static let builderName = "nxb"
    package static let hostName = "nxkit-host"
    package static let manifestName = "MANIFEST.json"
    package static let sumsName = "SHA256SUMS"
    /// The folder under Resources the app bundles the pair in.
    package static let bundleFolderName = "nxbuild"
    /// The oldest macOS nxkit runs on (the release's MANIFEST.json says `macos_min` 26.0).
    package static let minimumMacOS = 26

    // MARK: Where it runs

    package enum Availability: Equatable, Sendable {
        case available
        case needsNewerMacOS
        case needsAppleSilicon
    }

    package static func availability(macOSMajor: Int, appleSilicon: Bool) -> Availability {
        if !appleSilicon { return .needsAppleSilicon }
        return macOSMajor >= minimumMacOS ? .available : .needsNewerMacOS
    }

    /// This Mac: its macOS and whether it has Apple silicon (also under Rosetta, `hw.optional.arm64`).
    package static var currentAvailability: Availability {
        availability(macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, appleSilicon: isAppleSilicon)
    }

    package static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    // MARK: The pair

    /// The app's own copy, `Contents/Resources/nxbuild/`. nil without a Resources folder (tests, `swift run`).
    package static func bundledFolder(resources: String?) -> String? {
        resources.map { ($0 as NSString).appendingPathComponent(bundleFolderName) }
    }

    package static func builderPath(in folder: String) -> String { path(folder, builderName) }
    package static func hostPath(in folder: String) -> String { path(folder, hostName) }

    /// nxb and nxkit-host are both there and executable: the folder can build apps.
    package static func canBuildApps(_ folder: String, fileManager fm: FileManager = .default) -> Bool {
        !folder.isEmpty && fm.isExecutableFile(atPath: builderPath(in: folder)) && fm.isExecutableFile(atPath: hostPath(in: folder))
    }

    private static func path(_ folder: String, _ name: String) -> String {
        (folder.hasSuffix("/") ? folder : folder + "/") + name
    }

    // MARK: MANIFEST.json

    /// The formats of MANIFEST.json this launcher reads. It changes only with the ZIP's layout.
    package static let manifestFormats: Set<Int> = [1]

    /// A release's MANIFEST.json: `{"format": 1, "version": "0.10.2", "platform": "macos", "arch": "arm64", "macos_min": "26.0", "files": {"nxb": sha, "nxkit-host": sha}}`.
    package struct Manifest: Equatable, Sendable {
        package var format: Int
        package var version: String
        package var platform: String
        package var arch: String
        package var macOSMin: String
        package var files: [String: String]

        package init(format: Int, version: String, platform: String = "macos", arch: String = "arm64", macOSMin: String = "26.0", files: [String: String]) {
            self.format = format; self.version = version; self.platform = platform; self.arch = arch; self.macOSMin = macOSMin; self.files = files
        }

        /// The SHA-256 of nxkit-host the release names: the engine build a game report carries.
        package var hostBuild: String { files[NxkitBuilder.hostName] ?? "" }
    }

    package static func parseManifest(_ data: Data) -> Manifest? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let format = root["format"] as? Int,
              let version = root["version"] as? String, !version.isEmpty,
              let files = root["files"] as? [String: String] else { return nil }
        return Manifest(format: format, version: version, platform: root["platform"] as? String ?? "",
                        arch: root["arch"] as? String ?? "", macOSMin: root["macos_min"] as? String ?? "", files: files)
    }

    package static func readManifest(in folder: String) -> Manifest? {
        FileManager.default.contents(atPath: path(folder, manifestName)).flatMap(parseManifest)
    }

    /// Why this launcher does not take a release with this manifest on this Mac, nil when it does.
    package enum Incompatibility: Equatable, Sendable {
        case format(Int)
        case macOS(String)
        case arch(String)
    }

    package static func incompatibility(_ m: Manifest, running: OperatingSystemVersion) -> Incompatibility? {
        guard manifestFormats.contains(m.format) else { return .format(m.format) }
        guard m.arch == "arm64" else { return .arch(m.arch) }
        let need = m.macOSMin.split(separator: ".").compactMap { Int($0) }
        let have = [running.majorVersion, running.minorVersion, running.patchVersion]
        for i in 0..<3 {
            let n = i < need.count ? need[i] : 0
            if have[i] != n { return have[i] > n ? nil : .macOS(m.macOSMin) }
        }
        return nil
    }

    // MARK: Versions

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

    /// The SHA-256 of a file, read in pieces.
    package static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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

    /// The environment of the build: the tools of the system, and the runtime `nxb` puts into the app (the one beside the nxb that runs).
    package static func environment(folder: String, base: [String: String]) -> [String: String] {
        var env = base
        env["NXB_NXKIT_HOST"] = hostPath(in: folder)
        return env
    }

    /// The work folder of one game, inside the nxkit work root (`~/Library/Caches/NX2Apple/nxkit` unless the player moved it,
    /// BuildCacheRoots). A second build with the same files reuses its stages.
    package static func workDirectory(root: String, key: String) -> String {
        root + "/" + key
    }

    // MARK: Exit codes and output

    /// The string key of what nxb's exit code says (`nxb build`'s: 0 done, 1 error, 2 bad arguments, 3 damaged data, 4 not supported, 6 missing key, 130 interrupted).
    package static func exitKey(_ status: Int32) -> String {
        [1: "nxb.exit.1", 2: "nxb.exit.2", 3: "nxb.exit.3", 4: "nxb.exit.4", 6: "nxb.exit.6", 130: "nxb.exit.130"][status] ?? "nxb.exit.other"
    }

    /// The last line nxb printed as an error (`[RED] ...`, in a `say` event or as plain text), without the marker. nil when there is none.
    package static func lastError(in log: String) -> String? {
        for line in log.split(separator: "\n").reversed() {
            var text = String(line)
            if text.hasPrefix("{"), let data = text.data(using: .utf8), let e = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], e["ev"] as? String == "say" {
                text = e["msg"] as? String ?? ""
            }
            if let r = text.range(of: "[RED] ") { return String(text[r.upperBound...]) }
        }
        return nil
    }

    /// The last `count` lines of nxb's output as a person reads them: a `say` event as its message, other JSON events left out.
    package static func outputTail(_ log: String, count: Int) -> [String] {
        var lines: [String] = []
        for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            if text.hasPrefix("{"), let data = text.data(using: .utf8), let e = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if e["ev"] as? String == "say", let msg = e["msg"] as? String { lines.append(msg) }
                continue
            }
            lines.append(text)
        }
        return Array(lines.suffix(count))
    }
}
