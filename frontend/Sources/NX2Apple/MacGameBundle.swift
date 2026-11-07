import Foundation
import NXCore

/// A game's Mac app as the library reads it: its title ID, its bundle name and its names by language (`DMTitleNames`).
struct MacGameBundle {
    let titleID: String
    let name: String
    var titleNames: [String: String] = [:]

    enum Invalid: LocalizedError {
        case notGame
        var errorDescription: String? { L10n.string("library.notGame", Lang.initial()) }
    }

    static func read(_ url: URL) throws -> MacGameBundle {
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
        return MacGameBundle(titleID: rawID.uppercased(),
                             name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent,
                             titleNames: GameTitleNames.read(info))
    }
}
