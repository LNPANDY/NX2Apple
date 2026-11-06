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

    /// The command line of `nxb build` for a Mac app, in the NSP script's own names. `inputDir` holds one game's NSPs.
    /// No `--gpu`: nxb builds no pipeline archive then, where the script made one for this Mac's GPU.
    package static func buildArguments(inputDir: String, keys: String, titleID: String, out: String, workDir: String, engine: String) -> [String] {
        ["build", inputDir, "--platform", "mac-app", "-k", keys, "--title-id", titleID, "-o", out, "--work-dir", workDir, "--engine", engine, "--progress", "json"]
    }

    /// The string key of what `nxb build` does not take, nil when it takes the case. The inputs are what the player picked:
    /// `iPhone` is a build for an iPhone or iPad, `gameFolder` a game's files as a folder or a NUP, `compressed` an NSZ or XCZ, `card` an XCI, `dlc` add-on content.
    package static func unsupportedKey(mac: Bool, gameFolder: Bool, compressed: Bool, card: Bool, dlc: Bool) -> String? {
        if !mac { return "nxb.unsupported.target" }
        if gameFolder || compressed || card { return "nxb.unsupported.input" }
        if dlc { return "nxb.unsupported.dlc" }
        return nil
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
