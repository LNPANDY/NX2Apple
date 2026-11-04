import Foundation

extension ShellInstall {
    /// Puts each game's current cover into the shell mirror and into the copy embedded in the installed app
    /// (`App.app/Frameworks`, which is what the phone shows). Returns the title IDs whose picture inside the app changed.
    /// A reinstall signs again only for those, so an unchanged app is installed as it is.
    /// A game with no chosen file and no cached eShop banner is left alone: a missing cache must not strip the picture the phone already has.
    @discardableResult
    package static func refreshCovers(root: String, app: String, artwork: (String) -> String?, banners: URL = BannerCache.directory,
                                      fm: FileManager = .default) -> [String] {
        var changed: [String] = []
        for game in ShellLibrary.load(root: root).games {
            let picked = artwork(game.titleID)
            let pick = (picked?.isEmpty == false && fm.fileExists(atPath: picked ?? "")) ? picked : nil
            guard pick != nil || BannerCache.cached(game.titleID, in: banners) != nil else { continue }
            if fm.fileExists(atPath: game.framework) {
                _ = placeBanner(titleID: game.titleID, framework: game.framework, banners: banners, picked: pick, fm: fm)
            }
            let embedded = (app as NSString).appendingPathComponent("Frameworks")
                .appendingPathComponent((game.framework as NSString).lastPathComponent)
            guard fm.fileExists(atPath: embedded) else { continue }
            let before = bannerFiles(embedded, fm)
            _ = placeBanner(titleID: game.titleID, framework: embedded, banners: banners, picked: pick, fm: fm)
            if bannerFiles(embedded, fm) != before { changed.append(game.titleID) }
        }
        return changed
    }

    private static func bannerFiles(_ framework: String, _ fm: FileManager) -> [String: Data] {
        var out: [String: Data] = [:]
        for ext in CoverFile.shellExtensions {
            let path = framework + "/banner." + ext
            if let data = fm.contents(atPath: path) { out[ext] = data }
        }
        return out
    }
}
