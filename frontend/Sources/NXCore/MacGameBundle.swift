import Foundation

/// A game's Mac app as the library reads it: its title ID, its bundle name and its names by language (`DMTitleNames`).
package struct MacGameBundle {
    package let titleID: String
    package let name: String
    package let version: String?
    package let shaderChain: String?
    let displayName: String?
    package var titleNames: [String: String] = [:]

    enum Invalid: LocalizedError {
        case notGame
        var errorDescription: String? { L10n.string("library.notGame", Lang.initial()) }
    }

    package static func read(_ url: URL) throws -> MacGameBundle {
        guard url.pathExtension.lowercased() == "app" else { throw Invalid.notGame }
        LauncherWork.count(.infoPlistRead)
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let rawID = info["DMTitleID"] as? String,
              rawID.range(of: "^[0-9A-Fa-f]{16}$", options: .regularExpression) != nil,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/"),
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/" + executable).path),
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/dmhost").path)
        else { throw Invalid.notGame }
        let title = [info["CFBundleDisplayName"], info["CFBundleName"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return MacGameBundle(titleID: rawID.uppercased(), name: title ?? url.deletingPathExtension().lastPathComponent,
                             version: displayVersion(info), shaderChain: info["DMChain"] as? String, displayName: title,
                             titleNames: GameTitleNames.read(info))
    }

    /// The version of the package the app was packed with. A Mac app packed with DMPackageVersion states it in DMDisplayVersion, else
    /// (an update packed from a dump or a NUP without control data) only as the packed version, whose CFBundleShortVersionString is 1.0
    /// and not what runs (#953). The base game packed without a display version (v0) states none. An older app states it in
    /// CFBundleShortVersionString. Unknown stays nil: it is never guessed from the base game or from CFBundleVersion.
    static func displayVersion(_ info: [String: Any]) -> String? {
        let trimmed = { (key: String) in ((info[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let package = trimmed("DMPackageVersion")
        let version: String
        if !package.isEmpty {
            let display = trimmed("DMDisplayVersion")
            version = !display.isEmpty ? display : package == "v0" ? "" : package
        } else {
            version = trimmed("CFBundleShortVersionString")
        }
        return version.isEmpty ? nil : version
    }
}
