import Foundation

/// The experimental builder (LNPANDY/NX2Apple#749): nxbuild, a build tool in Rust that reproduces stages of the NSP script byte for byte and faster.
/// The script stays the driver. With `DM_EXPERIMENTAL_BUILDER=1` and `NXB_BIN` it hands the stages nxbuild supports (the extraction and the shader split today)
/// to the binaries beside `nxb`, and runs every other case the standard way. An engine without that patch ignores both variables.
///
/// Where `nxb` comes from:
/// 1. the path the player chose in Settings (the `nxb` binary, or the folder that holds it), for a local build of nxbuild;
/// 2. a release unpacked into `installFolder` by a download on demand. That download needs a published release: `releaseURL` and `releaseSHA256` are
///    pinned here together once it exists (a macOS arm64 zip of the binaries, signed ad hoc). Until then both are nil and only the chosen path is used.
///    The download writes the zip to a temporary file, checks its SHA-256 against `releaseSHA256` before anything is unpacked, and unpacks it into
///    `installFolder/<version>`. A zip whose digest differs is deleted and never run.
package enum ExperimentalBuilder {
    /// The nxbuild release the launcher downloads on demand. nil: none is published yet.
    package static let releaseURL: URL? = nil
    /// The SHA-256 (lowercase hex) of the zip at `releaseURL`, checked before it is unpacked. nil with it.
    package static let releaseSHA256: String? = nil

    /// The binaries the NSP script runs, all beside `nxb`. A missing stage binary makes that stage run the standard way.
    package static let stageTools = ["nxb-extract", "nxb-split"]

    /// Where a downloaded release goes: `<support>/nxbuild`, beside the venv in the launcher's data folder.
    package static func installFolder(support: String) -> String {
        (support as NSString).appendingPathComponent("nxbuild")
    }

    /// The `nxb` a chosen path names: the file itself, or `nxb` inside a folder. Empty for an empty path.
    package static func binary(at path: String, isDirectory: (String) -> Bool = directoryExists) -> String {
        let p = (path as NSString).expandingTildeInPath
        if p.isEmpty { return "" }
        return isDirectory(p) ? (p as NSString).appendingPathComponent("nxb") : p
    }

    /// The `nxb` the build takes: the chosen path when it is an executable `nxb`, else the newest release in `installFolder`. nil when there is none.
    package static func resolve(customPath: String, support: String, isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                                isDirectory: (String) -> Bool = directoryExists, list: (String) -> [String] = listing) -> String? {
        let chosen = binary(at: customPath, isDirectory: isDirectory)
        if !chosen.isEmpty {
            return isExecutable(chosen) ? chosen : nil   // a chosen path that does not work is not silently replaced by another binary
        }
        let folder = installFolder(support: support)
        let versions = list(folder).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        return versions.lazy.map { ((folder as NSString).appendingPathComponent($0) as NSString).appendingPathComponent("nxb") }.first(where: isExecutable)
    }

    /// The variables the build gets: the switch and the path of `nxb`.
    package static func environment(nxb: String) -> [String: String] {
        ["DM_EXPERIMENTAL_BUILDER": "1", "NXB_BIN": nxb]
    }

    /// Whether a downloaded zip is the pinned release: its SHA-256 (lowercase hex, as `shasum -a 256` prints it) against `releaseSHA256`.
    package static func matchesRelease(sha256 digest: String, expected: String? = releaseSHA256) -> Bool {
        guard let expected, expected.count == 64 else { return false }
        return digest.lowercased() == expected.lowercased()
    }

    package static func directoryExists(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    package static func listing(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}
