import Foundation

/// The experimental builder (LNPANDY/NX2Apple#749): nxbuild, a build tool in Rust that reproduces stages of the NSP script byte for byte and faster.
/// The script stays the driver. With `DM_EXPERIMENTAL_BUILDER=1` and `NXB_BIN` it hands the stages nxbuild supports (the extraction and the shader split today)
/// to nxbuild, and runs every other case the standard way. An engine without that patch ignores both variables.
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

    /// The variables the build gets: the switch and the path of `nxb`.
    package static func environment(nxb: String) -> [String: String] {
        ["DM_EXPERIMENTAL_BUILDER": "1", "NXB_BIN": nxb]
    }

    package static func directoryExists(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }
}
