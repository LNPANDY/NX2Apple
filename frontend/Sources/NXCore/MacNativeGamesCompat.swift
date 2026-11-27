import Foundation

/// macOS launcher compatibility guard for external `MacNativeGames` (`ly05010419/MacNativeGames`) trees.
///
/// Upstream `games/oot/assets/app-icon.json` pinned a Nintendo Store asset URL that started returning
/// HTTP 404 after Nintendo replaced the store image, breaking `games/oot/scripts/extract_app_icon.py`.
/// When the known broken URL is detected, this guard updates `url` and `sha256` in place to the
/// verified replacement from `MacNativeGames#2401` while preserving all other JSON fields.
package enum MacNativeGamesCompat {
    package static let ootAppIconSpecRelativePath = "games/oot/assets/app-icon.json"

    package static let brokenOotIconURL =
        "https://assets.nintendo.com/image/upload/c_fill,g_auto,h_1024,w_1024/f_jpg/q_90/store/software/switch2/70010000130792/21d17919819cffebda2817f9b0110116c28568e0b6fa30a9778f1679271be809"

    package static let fixedOotIconURL =
        "https://assets.nintendo.com/image/upload/c_fill,g_auto,h_1024,w_1024/f_jpg/q_90/store/software/switch2/70010000130792/da79eecb8ff4a1918790e0084cfcf8581a40f4864854e7a95615f5d43f41f937"

    package static let fixedOotIconSHA256 =
        "a9e8bc2008e81b8702551e45c29afa7ce6b4991e4913c6ba116a1f55e54ce087"

    /// Updates `games/oot/assets/app-icon.json` in place when it still points to `brokenOotIconURL`.
    /// Returns `true` when the file was updated, or `false` when already fixed, updated upstream,
    /// missing, invalid JSON, or escaping the engine tree via symlink.
    @discardableResult
    package static func ensureOotAppIconCompatibility(
        in treePath: String,
        fileManager fm: FileManager = .default
    ) -> Bool {
        guard !treePath.isEmpty else { return false }
        let rootURL = URL(fileURLWithPath: treePath, isDirectory: true).standardizedFileURL
        let resolvedRoot = rootURL.resolvingSymlinksInPath()
        let rootPrefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"

        let specURL = rootURL.appendingPathComponent(ootAppIconSpecRelativePath)
        guard isContainedRegularFile(specURL, within: rootPrefix, fileManager: fm) else {
            return false
        }
        guard let data = try? Data(contentsOf: specURL),
              let updatedData = patchedAppIconSpecData(from: data) else {
            return false
        }
        do {
            try updatedData.write(to: specURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Rewrites `url` and `sha256` when `url == brokenOotIconURL`, preserving all other JSON keys.
    /// Returns `nil` when no update is needed or the input is not a JSON object.
    package static func patchedAppIconSpecData(from data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              var dict = object as? [String: Any],
              let currentURL = dict["url"] as? String,
              currentURL == brokenOotIconURL else {
            return nil
        }
        dict["url"] = fixedOotIconURL
        dict["sha256"] = fixedOotIconSHA256
        guard var serialized = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            return nil
        }
        serialized.append(0x0A)
        return serialized
    }

    private static func isContainedRegularFile(_ url: URL, within rootPrefix: String, fileManager fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        let resolved = url.resolvingSymlinksInPath().path
        return resolved.hasPrefix(rootPrefix)
    }
}
