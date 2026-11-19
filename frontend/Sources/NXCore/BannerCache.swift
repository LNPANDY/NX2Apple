import Foundation

/// Where the eShop banners and cached icons live (the launcher's `ArtworkStore` downloads them, and `PackageControl` caches
/// offline NACP icons beside them). The shared app's install and `NXLauncher` sheets read them here, with no AppKit.
package enum BannerCache {
    package static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NS Port Builder/artwork")

    private static func safeTitleID(_ titleID: String) -> String? {
        let upper = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !upper.isEmpty, upper != ".", upper != "..",
              !upper.contains("/"), !upper.contains("\\"), !upper.contains(":") else { return nil }
        return upper
    }

    /// Where a title's banner is kept; nil while it has none.
    package static func cached(_ titleID: String, in directory: URL = BannerCache.directory) -> URL? {
        let url = directory.appendingPathComponent(titleID.uppercased() + ".jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `<dir>/<TITLEID>/icon.jpg` (online square metadata icon).
    package static func iconFile(_ titleID: String, in directory: URL = BannerCache.directory) -> URL? {
        guard let id = safeTitleID(titleID) else { return nil }
        return directory.appendingPathComponent(id, isDirectory: true).appendingPathComponent("icon.jpg")
    }

    /// `<dir>/<TITLEID>/nacp-icon.jpg` (offline 256×256 JPEG icon extracted from the ROM's Control NCA).
    package static func nacpIconFile(_ titleID: String, in directory: URL = BannerCache.directory) -> URL? {
        guard let id = safeTitleID(titleID) else { return nil }
        return directory.appendingPathComponent(id, isDirectory: true).appendingPathComponent("nacp-icon.jpg")
    }

    /// Existing cached `nacp-icon.jpg`, or nil when not extracted yet.
    package static func cachedNacpIcon(_ titleID: String, in directory: URL = BannerCache.directory) -> URL? {
        guard let url = nacpIconFile(titleID, in: directory) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Best cached square icon on disk: `icon.jpg` first, then offline `nacp-icon.jpg`.
    package static func cachedIcon(_ titleID: String, in directory: URL = BannerCache.directory) -> URL? {
        if let online = iconFile(titleID, in: directory), FileManager.default.fileExists(atPath: online.path) { return online }
        return cachedNacpIcon(titleID, in: directory)
    }
}
