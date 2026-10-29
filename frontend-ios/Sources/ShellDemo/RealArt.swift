import Foundation
import ShellUI

/// A real game a sample entry stands for when its art is on this machine: its name, title ID and the file name of
/// its picture in the repository's docs/images.
struct RealTitle {
    let title: String
    let titleID: String
    let docsImage: String
    init(_ title: String, _ titleID: String, _ docsImage: String) {
        self.title = title
        self.titleID = titleID
        self.docsImage = docsImage
    }
}

/// Real Switch art for the demo, read at runtime from where the Mac launcher keeps it and never from this package:
/// the eShop banner cache (`<TITLEID>.jpg`) and the repository's docs/images. Nothing is copied into the app.
///
/// `--art-dir <folder>` (repeatable) names the folders. `--real-art` uses the Mac launcher's cache in the host's home
/// and this checkout's docs/images, which the Simulator can read. Without either, every sample stays fictional.
enum RealArt {
    static let folders: [URL] = {
        let args = ProcessInfo.processInfo.arguments
        var folders = args.indices.filter { args[$0] == "--art-dir" && args.indices.contains($0 + 1) }.map { URL(fileURLWithPath: args[$0 + 1]) }
        if args.contains("--real-art") {
            let env = ProcessInfo.processInfo.environment
            let home = env["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
            folders.append(URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/NS Port Builder/artwork"))
            // This file is frontend-ios/Sources/ShellDemo/RealArt.swift: four levels up is the checkout.
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            folders.append(repo.appendingPathComponent("docs/images"))
        }
        return folders
    }()

    /// The title's banner, else its docs/images picture, from the first folder that has one.
    static func banner(for title: RealTitle) -> Artwork? {
        for name in [title.titleID.uppercased() + ".jpg", title.docsImage] {
            for folder in folders {
                let url = folder.appendingPathComponent(name)
                if let data = try? Data(contentsOf: url), let art = Artwork(id: "real.\(name)", data: data) { return art }
            }
        }
        return nil
    }
}

extension SampleArt {
    /// A sample game: the real title with its banner when the art is found, else the fictional one with its drawn icon.
    static func tile(_ id: String, title: String, version: String, real: RealTitle?, state: GameState = .playable,
                     recentlyPlayed: String? = nil) -> GameTile {
        let subtitle = demoText("Version \(version)")
        if let real, let banner = RealArt.banner(for: real) {
            return GameTile(id: id, title: real.title, subtitle: subtitle, banner: banner, state: state, recentlyPlayed: recentlyPlayed)
        }
        return GameTile(id: id, title: title, subtitle: subtitle, icon: icon(id), state: state, recentlyPlayed: recentlyPlayed)
    }
}
