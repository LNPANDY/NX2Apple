import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ShellUI

@Suite struct ShellWidgetTests {
    @Test func deepLinksParseAndNormalizeHexTitleIDs() {
        #expect(ShellDeepLink(url: URL(string: "nx2apple://library")!) == .library)
        #expect(ShellDeepLink(url: URL(string: "NX2APPLE://controllers")!) == .controllers)
        #expect(ShellDeepLink(url: URL(string: "nx2apple://play/0400001000000000")!) == .play(id: "0400001000000000"))
        #expect(ShellDeepLink(url: URL(string: "nx2apple://game/0100f2c0115b6000")!) == .game(id: "0100F2C0115B6000"))
        #expect(ShellDeepLink(url: URL(string: "nx2apple://settings/0100535012974000")!) == .settings(id: "0100535012974000"))
        #expect(ShellDeepLink(url: URL(string: "nx2apple://play/")!) == .library)
        #expect(ShellDeepLink(url: URL(string: "https://example.com/play/0100")!) == nil)
        #expect(ShellDeepLink(url: URL(string: "nx2apple://unknown/0100")!) == nil)

        for route: ShellDeepLink in [.library, .controllers, .game(id: "0100F2C0115B6000"), .play(id: "0400001000000000"), .settings(id: "orbit")] {
            #expect(ShellDeepLink(url: route.url) == route)
        }
    }

    @Test func primaryTapURLRespectsPlayabilityAndTapBehavior() {
        let playable = ShellWidgetGame(id: "0400001000000000", title: "Mario Kart World", state: .playable, isSwitch2: true)
        let missingData = ShellWidgetGame(id: "0100F2C0115B6000", title: "Tears of the Kingdom", state: .needsGameData)

        #expect(playable.primaryURL(behavior: .launch) == URL(string: "nx2apple://play/0400001000000000")!)
        #expect(playable.primaryURL(behavior: .inspect) == URL(string: "nx2apple://game/0400001000000000")!)
        #expect(missingData.primaryURL(behavior: .launch) == URL(string: "nx2apple://game/0100F2C0115B6000")!,
                "a game without data opens its library setup card instead of attempting boot")
    }

    @Test func snapshotResolutionFiltersSwitch2AndPromotesPinnedHero() {
        let games = [
            ShellWidgetGame(id: "0100000000010000", title: "Super Mario Odyssey", state: .needsGameData, isSwitch2: false),
            ShellWidgetGame(id: "0400001000000000", title: "Mario Kart World", state: .playable, isSwitch2: true),
            ShellWidgetGame(id: "0100F2C0115B6000", title: "Tears of the Kingdom", state: .playable, isSwitch2: false),
            ShellWidgetGame(id: "0400002000000000", title: "Donkey Kong Bananza", state: .playable, isSwitch2: true),
        ]
        let base = ShellWidgetSnapshot(games: games, readyCount: 3, totalCount: 4)

        let all = base.resolved(filter: .all)
        #expect(all.games.map(\.id) == ["0400001000000000", "0100F2C0115B6000", "0400002000000000", "0100000000010000"])
        #expect(all.readyCount == 3 && all.totalCount == 4)

        let switch2 = base.resolved(filter: .switch2)
        #expect(switch2.games.map(\.id) == ["0400001000000000", "0400002000000000"])
        #expect(switch2.readyCount == 2 && switch2.totalCount == 2)

        let pinned = base.resolved(filter: .pinned, pinnedGameID: "0400002000000000")
        #expect(pinned.games.first?.id == "0400002000000000")
        #expect(pinned.games.count == 4)
    }

    @Test func downsamplingAndTier3FrameworkFallbackStayWithinJetsamBounds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("widget-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let appBundle = root.appendingPathComponent("DmShell.app", isDirectory: true)
        let appexBundle = appBundle.appendingPathComponent("PlugIns/DmShellWidget.appex", isDirectory: true)
        let fw = appBundle.appendingPathComponent("Frameworks/DmGame0400001000000000.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: appexBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)

        #expect(WidgetSnapshotStore.defaultParentAppBundle(bundleURL: appexBundle) == appBundle)
        #expect(WidgetSnapshotStore.baseAppBundleIdentifier(from: "org.nxnative.shell.TV7X9T2SB9.widget") == "org.nxnative.shell.TV7X9T2SB9")

        let manifest = """
        {
          "schema": 1,
          "title_id": "0400001000000000",
          "name": "Mario Kart World",
          "display_version": "1.8.0",
          "console": "switch2",
          "framework": "DmGame0400001000000000.framework",
          "framework_executable": "DmGame0400001000000000"
        }
        """
        try Data(manifest.utf8).write(to: fw.appendingPathComponent("game.manifest.json"))
        try Data("macho".utf8).write(to: fw.appendingPathComponent("DmGame0400001000000000"))
        try Self.makeSolidPNG(width: 1920, height: 1080).write(to: fw.appendingPathComponent("banner.png"))
        try Self.makeSolidPNG(width: 512, height: 512).write(to: fw.appendingPathComponent("icon.png"))

        let tier3 = WidgetSnapshotStore.loadSnapshot(
            directory: nil,
            appGroupDirectory: nil,
            parentAppBundle: appBundle,
            keychainFallback: false
        )
        #expect(tier3.games.count == 1)
        let hero = try #require(tier3.games.first)
        #expect(hero.title == "Mario Kart World")
        #expect(hero.isSwitch2)
        #expect(hero.version == "1.8.0")
        let bannerImage = try #require(hero.banner?.image)
        let iconImage = try #require(hero.icon?.image)
        #expect(max(bannerImage.width, bannerImage.height) <= WidgetSnapshotStore.heroMaxPixelSize)
        #expect(max(iconImage.width, iconImage.height) <= WidgetSnapshotStore.iconMaxPixelSize)

        // Even when 8 Switch 1 titles precede a Switch 2 title in the saved snapshot, filtering or pinning
        // promotes the Switch 2 title before ImageIO thumbnail decoding so it receives full hero artwork.
        let snapDir = root.appendingPathComponent("snap", isDirectory: true)
        var records: [WidgetSnapshotPayload.GameRecord] = (0..<8).map { i in
            WidgetSnapshotPayload.GameRecord(id: String(format: "01000000000%05d", i), title: "Game \(i)", version: "1.0", isSwitch2: false)
        }
        records.append(WidgetSnapshotPayload.GameRecord(id: "0400001000000000", title: "Mario Kart World", version: "1.8.0", isSwitch2: true))
        let payload = WidgetSnapshotPayload(generatedAtEpoch: 1_700_000_000, readyCount: 9, totalCount: 9, games: records)
        _ = WidgetSnapshotStore.save(payload, directory: snapDir, appGroupDirectory: nil, reloadTimelines: false)

        let filteredSwitch2 = WidgetSnapshotStore.loadSnapshot(
            directory: snapDir,
            appGroupDirectory: nil,
            parentAppBundle: appBundle,
            keychainFallback: false,
            filter: .switch2
        )
        let s2Hero = try #require(filteredSwitch2.games.first)
        #expect(s2Hero.id == "0400001000000000")
        #expect(try #require(s2Hero.banner?.image).width == WidgetSnapshotStore.heroMaxPixelSize)

        let pinnedDeep = WidgetSnapshotStore.loadSnapshot(
            directory: snapDir,
            appGroupDirectory: nil,
            parentAppBundle: appBundle,
            keychainFallback: false,
            filter: .pinned,
            pinnedGameID: "0400001000000000"
        )
        #expect(pinnedDeep.games.first?.id == "0400001000000000")
        #expect(pinnedDeep.games.first?.banner != nil)
    }

    private static func makeSolidPNG(width: Int, height: Int) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.85, green: 0.18, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
