import NXCore

// Compact banner index for shipped game profiles (SupportedGamesSheet / ConsoleSupportedGamesPage).
// Backed by `NXCore.KnownGameBanners` so the launcher and iOS packaging share one source of truth.
enum SupportedBanners {
    static let urls: [String: String] = KnownGameBanners.urls
}
