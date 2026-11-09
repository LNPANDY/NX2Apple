import Foundation

/// The experimental builder (LNPANDY/NX2Apple#749): nxbuild, a build tool in Rust that reproduces the NSP script's stages byte for byte and faster.
/// With the switch on, the launcher starts `nxb build` itself and the NSP script is not run. There is no fallback to the script: a case `nxb build` cannot do
/// (exit code 4), a failure or an input it does not take is shown as an error with nxb's own message and its exit code. BUILDING.md has the details.
///
/// Where `nxb` comes from:
/// 1. the path the player chose in Settings (the `nxb` binary, or the folder that holds it), for a local build of nxbuild;
/// 2. the app's own copy, `Contents/Resources/nxbuild/nxb`: the release `frontend/nxbuild.pin` names, downloaded when the app is built, its SHA-256
///    checked against the pin before it is unpacked (`frontend/tools/nxbuild.py fetch`). Players download nothing at run time.
package enum ExperimentalBuilder {
    /// The feature toggle. It is off for now: the launcher shows no builder row, ignores a saved "on" and builds with the NSP script.
    /// The player's saved choice stays stored, so turning the toggle on again brings it back. `NX2APPLE_NXBUILD=1` turns it on for one run.
    package static var featureEnabled = ProcessInfo.processInfo.environment["NX2APPLE_NXBUILD"] == "1"

    /// The app's copy of nxb under a Resources folder.
    package static func bundled(resources: String?) -> String? {
        resources.map { ($0 as NSString).appendingPathComponent("nxbuild/nxb") }
    }

    /// The `nxb` a chosen path names: the file itself, or `nxb` inside a folder. Empty for an empty path.
    package static func binary(at path: String, isDirectory: (String) -> Bool = directoryExists) -> String {
        let p = (path as NSString).expandingTildeInPath
        if p.isEmpty { return "" }
        return isDirectory(p) ? (p as NSString).appendingPathComponent("nxb") : p
    }

    /// The `nxb` the build takes: the chosen path when it is an executable `nxb`, else the app's copy. nil when there is none.
    package static func resolve(customPath: String, bundled: String?, isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                                isDirectory: (String) -> Bool = directoryExists) -> String? {
        let chosen = binary(at: customPath, isDirectory: isDirectory)
        if !chosen.isEmpty {
            return isExecutable(chosen) ? chosen : nil   // a chosen path that does not work is reported, not silently replaced by the app's copy
        }
        return bundled.flatMap { isExecutable($0) ? $0 : nil }
    }

    /// What the build gets in the environment: the engine `nxb build` reads the game profiles and tools from (`NXB_ENGINE`).
    package static func environment(engine: String) -> [String: String] {
        ["NXB_ENGINE": engine]
    }

    /// The oldest nxbuild that builds with this app: it has the whole `nxb build` command line of the NSP script, reads the engine from
    /// `NXB_ENGINE` and takes the pinned engine's `patch_nso.py` (0.5.1 to 0.6.1 stop with "--engine is required" or at the rewrite).
    /// 0.6.2 stops in the Mac shader step, because it needs the own front end's verdicts and a fresh build has none.
    package static let minimumVersion = "0.6.3"

    /// The command line of `nxb build` from the script's: the same options in the same names, with `build` in place of the script's path (the first element).
    package static func arguments(fromScript args: [String]) -> [String] {
        ["build"] + args.dropFirst()
    }

    /// Whether the output of `nxb version` ("nxb 0.5.1") names a version of at least `minimum`. A text with no version in it is too old.
    package static func isNewEnough(_ output: String, minimum: String = minimumVersion) -> Bool {
        func parts(_ s: String) -> [Int]? {
            let numbers = s.split(whereSeparator: { !"0123456789.".contains($0) }).first { $0.first?.isNumber == true }
            return numbers.map { $0.split(separator: ".").compactMap { Int($0) } }.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let have = parts(output), let want = parts(minimum) else { return false }
        for i in 0..<max(have.count, want.count) {
            let (h, w) = (i < have.count ? have[i] : 0, i < want.count ? want[i] : 0)
            if h != w { return h > w }
        }
        return true
    }

    /// The string key of what nxb's exit code says (`nxb build`'s: 0 done, 1 error, 2 bad arguments, 3 damaged data, 4 not supported yet, 6 missing key, 130 interrupted).
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

    package static func directoryExists(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }
}
