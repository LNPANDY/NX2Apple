import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import ShellHost

enum Fixtures {
    static var gamesURL: URL { Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("Games") }
    static let orbit = "0100000000010000", chain = "0100000000020000", newerOS = "0100000000030000", noFramework = "0100000000040000"
    static let badManifest = "0100000000050000", missingKey = "0100000000060000", badSettings = "0100000000070000"
}

/// A temporary folder with a copy of the fixture bundles and an empty app data root, removed with the object.
final class Sandbox: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shellhost-\(UUID().uuidString)", isDirectory: true)
    var games: URL { root.appendingPathComponent("Games", isDirectory: true) }
    var appData: URL { root.appendingPathComponent("Documents/games", isDirectory: true) }
    let suite = "shellhost.tests.\(UUID().uuidString)."

    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: appData, withIntermediateDirectories: true)
        try fm.copyItem(at: Fixtures.gamesURL, to: games)
        // Stripped-framework readiness checks require bundled msl/ in Sandbox fixtures unless a test removes it.
        if let children = try? fm.contentsOfDirectory(at: games, includingPropertiesForKeys: nil) {
            for gameDir in children {
                let fw = gameDir.appendingPathComponent("DmGame.framework", isDirectory: true)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fw.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let mslDir = fw.appendingPathComponent("msl", isDirectory: true)
                guard !fm.fileExists(atPath: mslDir.path) else { continue }
                var chainDirName = "b-3f9a2c"
                if let data = fm.contents(atPath: gameDir.appendingPathComponent("game.manifest.json").path),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let chain = obj["chain"] as? String, !chain.isEmpty {
                    chainDirName = chain
                }
                let chainDir = mslDir.appendingPathComponent(chainDirName, isDirectory: true)
                try fm.createDirectory(at: chainDir, withIntermediateDirectories: true)
                try Data("fixture".utf8).write(to: chainDir.appendingPathComponent("fixture.metallib"))
            }
        }
    }
    deinit {
        try? FileManager.default.removeItem(at: root)
        for id in ["0100000000010000", "0100000000020000", "0100000000030000", "0100000000040000", "0100000000080000"] { UserDefaults().removePersistentDomain(forName: suite + id) }
    }

    func defaults(_ id: String) -> UserDefaults { UserDefaults(suiteName: suite + id)! }

    func config(chain: String? = "b-3f9a2c", os: OperatingSystemVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
                updateURL: URL? = nil, open: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
                now: @escaping @Sendable () -> Date = { Date() }) -> ShellHostConfig {
        let suite = suite
        return ShellHostConfig(gamesRoot: games, appDataRoot: appData, environment: HostEnvironment(chain: chain, osVersion: os),
                               updateURL: updateURL, defaults: { UserDefaults(suiteName: suite + $0)! }, openURL: open, now: now)
    }

    /// The game's app data folder with the marker file the orbit fixture's manifest names (not game data: an empty file).
    @discardableResult func giveAppData(_ id: String = Fixtures.orbit) throws -> URL {
        let dir = appData.appendingPathComponent(id, isDirectory: true)
        let tree = dir.appendingPathComponent("romfs", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data().write(to: tree.appendingPathComponent("fixture.marker"))
        return dir
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

func pngData(width: Int, height: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}
