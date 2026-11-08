import Foundation

package struct MacGameBundle {
    package let titleID: String
    package let name: String
    package let shaderChain: String?
    let displayName: String?

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
                             shaderChain: info["DMChain"] as? String, displayName: title)
    }
}
