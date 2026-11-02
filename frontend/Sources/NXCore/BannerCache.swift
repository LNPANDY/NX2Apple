import Foundation

/// Where the eShop banners are cached (the launcher's `ArtworkStore` downloads them). The shared app's install reads them to put a
/// game's banner into its framework, so the folder and the lookup are here, with no AppKit.
package enum BannerCache {
    package static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NS Port Builder/artwork")

    /// Where a title's banner is kept; nil while it has none.
    package static func cached(_ titleID: String, in directory: URL = BannerCache.directory) -> URL? {
        let url = directory.appendingPathComponent(titleID.uppercased() + ".jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
