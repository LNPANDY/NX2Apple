#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import ShellUI

/// Visual QA showcase renderer for `ShellWidgetView` across iPad Pro, iPhone Pro Home Screen & Lock Screen,
/// Switch 2 / Pinned configurations, localized `.lproj` catalogs, and all 7 WidgetKit families.
/// Skips automatically unless `NX_SHELL_CAPTURE_DIR` is set. Optional colon-separated `NX_WIDGET_ART_DIRS`
/// loads embedded `.framework` manifests and artwork for realistic previews without hardcoding local paths.
@MainActor
final class WidgetCaptureTests: XCTestCase {
    private struct LoadedLibrary {
        var allGames: [ShellWidgetGame]
        var byID: [String: ShellWidgetGame]
    }

    private func captureDir() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_DIR"], !raw.isEmpty else {
            throw XCTSkip("Set NX_SHELL_CAPTURE_DIR to render widget showcase PNGs")
        }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func renderPNG<V: View>(_ name: String, width: CGFloat, height: CGFloat, into dir: URL, @ViewBuilder content: () -> V) throws {
        let root = content()
            .frame(width: width, height: height)
            .tint(.white)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: root)
        renderer.scale = 2.0
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        let nsImage = try XCTUnwrap(renderer.nsImage, "ImageRenderer failed for \(name)")
        let tiff = try XCTUnwrap(nsImage.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("\(name).png"), options: .atomic)
    }

    private func localizedView<V: View>(language: String, @ViewBuilder build: () -> V) -> NSImage? {
        let lproj = language == "zh" ? "zh-Hans" : language
        let previous = ShellStrings.captureBundle
        if let path = Bundle.module.path(forResource: lproj, ofType: "lproj") {
            ShellStrings.captureBundle = Bundle(path: path)
        }
        defer { ShellStrings.captureBundle = previous }
        let view = build().tint(.white).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        return renderer.nsImage
    }

    private func loadLibrary() -> LoadedLibrary {
        let envDirs = (ProcessInfo.processInfo.environment["NX_WIDGET_ART_DIRS"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }

        struct RawManifest: Decodable {
            var title_id: String
            var name: String
            var display_version: String?
            var console: String?
        }

        var discovered: [String: ShellWidgetGame] = [:]
        let fm = FileManager.default
        for root in envDirs {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for fw in items where fw.pathExtension == "framework" {
                let idUpper = fw.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "DmGame", with: "")
                    .uppercased()
                if discovered[idUpper] != nil { continue }
                let manifestURL = fw.appendingPathComponent("game.manifest.json")
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? JSONDecoder().decode(RawManifest.self, from: data) else { continue }
                let bannerURL = ["banner.jpg", "banner.png", "banner.jpeg"]
                    .map { fw.appendingPathComponent($0) }
                    .first { fm.fileExists(atPath: $0.path) }
                let iconURL = ["icon.png", "icon.jpg", "icon.jpeg"]
                    .map { fw.appendingPathComponent($0) }
                    .first { fm.fileExists(atPath: $0.path) }
                guard bannerURL != nil || iconURL != nil else { continue }

                let banner = WidgetSnapshotStore.downsampledArtwork(at: bannerURL, maxPixelSize: 960)
                let icon = WidgetSnapshotStore.downsampledArtwork(at: iconURL, maxPixelSize: 256)
                let cleanTitle = Self.cleanDisplayTitle(manifest.name)
                let isS2 = manifest.console == "switch2" || manifest.title_id.uppercased().hasPrefix("0400")
                discovered[manifest.title_id.uppercased()] = ShellWidgetGame(
                    id: manifest.title_id.uppercased(),
                    title: cleanTitle,
                    version: manifest.display_version ?? "1.0.0",
                    state: .playable,
                    recentlyPlayed: nil,
                    isSwitch2: isS2,
                    banner: banner,
                    icon: icon
                )
            }
        }

        if discovered.isEmpty {
            let fallback = ShellWidgetSnapshot.sample.games
            return LoadedLibrary(
                allGames: fallback,
                byID: Dictionary(uniqueKeysWithValues: fallback.map { ($0.id.uppercased(), $0) })
            )
        }

        // Curated priority order for realistic Continue Playing showcase, followed by the rest of the library.
        let featuredOrder: [(id: String, recent: String?)] = [
            ("0400C3F00006E000", "Played today"),
            ("040074A01BF12000", "Played today"),
            ("0100F2C0115B6000", "Played yesterday"),
            ("0400380020056000", "Played 2d ago"),
            ("010015100B514000", "Played 3d ago"),
            ("0400A3A01EE4C000", "Played 4d ago"),
            ("010012101468C000", "Played 5d ago"),
            ("0100000000010000", "Played last week"),
            ("0400245021D2C000", nil),
            ("0400D4201C6EA000", nil),
            ("0400486024DEC000", "Played today"),
            ("01001F5010DFA000", nil),
            ("01007EF00011E000", nil),
            ("01008CF01BAAC000", nil),
            ("0100FD8022DAA000", nil),
        ]

        var ordered: [ShellWidgetGame] = []
        var used = Set<String>()
        for (id, recent) in featuredOrder {
            if var game = discovered[id] {
                game.recentlyPlayed = recent
                ordered.append(game)
                used.insert(id)
                discovered[id] = game
            }
        }
        for key in discovered.keys.sorted() where !used.contains(key) {
            if let game = discovered[key] {
                ordered.append(game)
            }
        }
        return LoadedLibrary(allGames: ordered, byID: discovered)
    }

    private static func cleanDisplayTitle(_ raw: String) -> String {
        if raw == "SUPER MARIO ODYSSEY" { return "Super Mario Odyssey" }
        return raw
    }

    func testCaptureAllWidgetShowcases() throws {
        let outDir = try captureDir()
        let lib = loadLibrary()
        let totalCount = max(lib.allGames.count, 7)
        let mainSnapshot = ShellWidgetSnapshot(games: lib.allGames, readyCount: totalCount, totalCount: totalCount)
        let switch2Snapshot = mainSnapshot.resolved(filter: .switch2)

        // 1. 13-inch iPad Pro (M4) Landscape Home Screen Showcase
        try renderPNG("widget-ipad-pro-showcase", width: 1240, height: 850, into: outDir) {
            IPadProShowcaseBoard(mainSnapshot: mainSnapshot, switch2Snapshot: switch2Snapshot)
        }

        // 2. iPhone Pro Home Screen + Lock Screen Side-by-Side
        try renderPNG("widget-iphone-home-lock", width: 1020, height: 930, into: outDir) {
            IPhoneHomeAndLockBoard(mainSnapshot: mainSnapshot, switch2Snapshot: switch2Snapshot)
        }

        // 3. Switch 2 Deck, Pinned Hero, States & 10-Language Localization Showcase
        let now = Date(timeIntervalSince1970: 1_763_050_000)
        let jaImage = try XCTUnwrap(localizedView(language: "ja") {
            let localizedSnap = Self.relocalizeSnapshotDates(mainSnapshot, now: now)
            SystemWidgetFrame(snapshot: localizedSnap, family: .medium, filter: .all, width: 364, height: 170, radius: 22)
        })
        let deImage = try XCTUnwrap(localizedView(language: "de") {
            let localizedSnap = Self.relocalizeSnapshotDates(switch2Snapshot, now: now)
            SystemWidgetFrame(snapshot: localizedSnap, family: .medium, filter: .switch2, width: 364, height: 170, radius: 22)
        })
        try renderPNG("widget-switch2-and-pinned", width: 1200, height: 820, into: outDir) {
            ConfigurationsAndL10nBoard(
                mainSnapshot: mainSnapshot,
                switch2Snapshot: switch2Snapshot,
                jaMedium: jaImage,
                deMedium: deImage
            )
        }

        // 4. All 7 WidgetKit Families Design Specimen Sheet
        try renderPNG("widget-families-sheet", width: 1260, height: 900, into: outDir) {
            WidgetFamiliesSpecimenBoard(mainSnapshot: mainSnapshot, switch2Snapshot: switch2Snapshot)
        }
    }

    private static func relocalizeSnapshotDates(_ snapshot: ShellWidgetSnapshot, now: Date) -> ShellWidgetSnapshot {
        let offsets: [TimeInterval] = [-1800, -3600, -90_000, -180_000, -260_000]
        let updated = snapshot.games.enumerated().map { idx, game in
            var copy = game
            if copy.recentlyPlayed != nil {
                let delta = offsets[min(idx, offsets.count - 1)]
                copy.recentlyPlayed = ShellFormat.played(now.addingTimeInterval(delta), now: now)
            }
            return copy
        }
        return ShellWidgetSnapshot(games: updated, readyCount: snapshot.readyCount, totalCount: snapshot.totalCount)
    }
}

// MARK: - Shared Device & Widget Chrome Helpers

private struct SystemWidgetFrame: View {
    let snapshot: ShellWidgetSnapshot
    let family: ShellWidgetFamily
    var filter: ShellWidgetFilter = .all
    var tapBehavior: ShellWidgetTapBehavior = .launch
    let width: CGFloat
    let height: CGFloat
    var radius: CGFloat = 22

    var body: some View {
        ZStack {
            ShellWidgetBackdrop(snapshot: snapshot)
            ShellWidgetView(snapshot: snapshot, family: family, filter: filter, tapBehavior: tapBehavior)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.46), radius: 22, y: 12)
    }
}

private struct AtmosphericWallpaper: View {
    var accent: Color = Color(red: 0.24, green: 0.28, blue: 0.62)
    var warm: Color = Color(red: 0.52, green: 0.20, blue: 0.28)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.05, blue: 0.09),
                    Color(red: 0.07, green: 0.07, blue: 0.12),
                    Color(red: 0.03, green: 0.03, blue: 0.06),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [accent.opacity(0.44), accent.opacity(0.12), .clear],
                center: .init(x: 0.20, y: 0.18),
                startRadius: 20,
                endRadius: 560
            )
            RadialGradient(
                colors: [warm.opacity(0.32), warm.opacity(0.08), .clear],
                center: .init(x: 0.84, y: 0.26),
                startRadius: 20,
                endRadius: 480
            )
            RadialGradient(
                colors: [Color(red: 0.12, green: 0.36, blue: 0.42).opacity(0.22), .clear],
                center: .init(x: 0.52, y: 0.88),
                startRadius: 20,
                endRadius: 460
            )
        }
    }
}

private struct MockAppIcon: View {
    let title: String
    let symbol: String
    let topColor: Color
    let bottomColor: Color
    var iconSize: CGFloat = 64
    var showLabel: Bool = true
    var customArt: Artwork? = nil

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let customArt {
                    Image(decorative: customArt.image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else {
                    LinearGradient(colors: [topColor, bottomColor], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: symbol)
                        .font(.system(size: iconSize * 0.44, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
                }
            }
            .frame(width: iconSize, height: iconSize)
            .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.225, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: iconSize * 0.225, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)

            if showLabel {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
            }
        }
    }
}

// MARK: - Board 1: 13-inch iPad Pro (M4) Landscape Home Screen

private struct IPadProShowcaseBoard: View {
    let mainSnapshot: ShellWidgetSnapshot
    let switch2Snapshot: ShellWidgetSnapshot

    private var mediumSlice: ShellWidgetSnapshot {
        let games = Array(mainSnapshot.games.dropFirst(2)) + Array(mainSnapshot.games.prefix(2))
        return ShellWidgetSnapshot(games: games, readyCount: mainSnapshot.readyCount, totalCount: mainSnapshot.totalCount)
    }

    private var smallHeroSnapshot: ShellWidgetSnapshot {
        if let oot = mainSnapshot.games.first(where: { $0.id == "0400486024DEC000" }) {
            return ShellWidgetSnapshot(games: [oot], readyCount: mainSnapshot.readyCount, totalCount: mainSnapshot.totalCount)
        }
        let games = Array(switch2Snapshot.games.dropFirst(2)) + switch2Snapshot.games
        return ShellWidgetSnapshot(games: games, readyCount: switch2Snapshot.readyCount, totalCount: switch2Snapshot.totalCount)
    }

    private var switch2Rearranged: ShellWidgetSnapshot {
        let games = Array(switch2Snapshot.games.dropFirst(1)) + Array(switch2Snapshot.games.prefix(1))
        return ShellWidgetSnapshot(games: games, readyCount: switch2Snapshot.readyCount, totalCount: switch2Snapshot.totalCount)
    }

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.03, blue: 0.04)

            // Outer 13-inch iPad Pro M4 hardware bezel
            ZStack {
                AtmosphericWallpaper()

                VStack(spacing: 0) {
                    // iPadOS Status Bar
                    HStack(spacing: 8) {
                        Text("9:41")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Tue Nov 13")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                        Spacer()
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "wifi")
                            .font(.system(size: 12, weight: .semibold))
                        Text("100%")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "battery.100percent")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.top, 14)
                    .padding(.bottom, 18)

                    // 6-Column iPad Pro SpringBoard Grid (752 + 24 + 364 = 1140 pt)
                    VStack(alignment: .leading, spacing: 24) {
                        // Row 1-2: ExtraLarge Command Deck (752x376) + Switch 2 Large Shelf (364x376)
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 6) {
                                SystemWidgetFrame(
                                    snapshot: mainSnapshot,
                                    family: .extraLarge,
                                    filter: .all,
                                    width: 752,
                                    height: 376,
                                    radius: 24
                                )
                                Text("Continue Playing")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.86))
                                    .frame(width: 752)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                SystemWidgetFrame(
                                    snapshot: switch2Rearranged,
                                    family: .large,
                                    filter: .switch2,
                                    width: 364,
                                    height: 376,
                                    radius: 24
                                )
                                Text("Switch 2 Deck")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.86))
                                    .frame(width: 364)
                            }
                        }

                        // Row 3: Medium Deck (364x170) + Small Poster (170x170) + SpringBoard App Icons
                        HStack(alignment: .top, spacing: 24) {
                            VStack(spacing: 6) {
                                SystemWidgetFrame(
                                    snapshot: mediumSlice,
                                    family: .medium,
                                    filter: .all,
                                    width: 364,
                                    height: 170,
                                    radius: 22
                                )
                                Text("Continue Playing")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.86))
                            }

                            VStack(spacing: 6) {
                                SystemWidgetFrame(
                                    snapshot: smallHeroSnapshot,
                                    family: .small,
                                    filter: .pinned,
                                    width: 170,
                                    height: 170,
                                    radius: 22
                                )
                                Text("Switch 2 Deck")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.86))
                            }

                            // 3 columns of iPadOS app icons beside the widgets
                            VStack(spacing: 20) {
                                HStack(spacing: 38) {
                                    MockAppIcon(
                                        title: "NX2Apple",
                                        symbol: "gamecontroller.fill",
                                        topColor: Color(red: 0.94, green: 0.22, blue: 0.26),
                                        bottomColor: Color(red: 0.58, green: 0.08, blue: 0.14)
                                    )
                                    MockAppIcon(
                                        title: "Files",
                                        symbol: "folder.fill",
                                        topColor: Color(red: 0.24, green: 0.62, blue: 0.98),
                                        bottomColor: Color(red: 0.12, green: 0.38, blue: 0.86)
                                    )
                                    MockAppIcon(
                                        title: "Controllers",
                                        symbol: "dpad.fill",
                                        topColor: Color(red: 0.22, green: 0.23, blue: 0.28),
                                        bottomColor: Color(red: 0.10, green: 0.11, blue: 0.14)
                                    )
                                    MockAppIcon(
                                        title: "Settings",
                                        symbol: "gearshape.fill",
                                        topColor: Color(red: 0.52, green: 0.54, blue: 0.58),
                                        bottomColor: Color(red: 0.28, green: 0.30, blue: 0.34)
                                    )
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, 18)
                            .padding(.top, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 34)

                    Spacer(minLength: 10)

                    // iPadOS Floating Glass Dock
                    HStack(spacing: 16) {
                        MockAppIcon(
                            title: "",
                            symbol: "gamecontroller.fill",
                            topColor: Color(red: 0.94, green: 0.22, blue: 0.26),
                            bottomColor: Color(red: 0.58, green: 0.08, blue: 0.14),
                            iconSize: 52,
                            showLabel: false
                        )
                        MockAppIcon(
                            title: "",
                            symbol: "safari.fill",
                            topColor: Color(red: 0.20, green: 0.66, blue: 0.98),
                            bottomColor: Color(red: 0.10, green: 0.38, blue: 0.88),
                            iconSize: 52,
                            showLabel: false
                        )
                        MockAppIcon(
                            title: "",
                            symbol: "folder.fill",
                            topColor: Color(red: 0.24, green: 0.62, blue: 0.98),
                            bottomColor: Color(red: 0.12, green: 0.38, blue: 0.86),
                            iconSize: 52,
                            showLabel: false
                        )
                        Rectangle()
                            .fill(.white.opacity(0.18))
                            .frame(width: 1, height: 38)
                            .padding(.horizontal, 2)
                        ForEach(Array(mainSnapshot.games.prefix(3))) { g in
                            MockAppIcon(
                                title: "",
                                symbol: "play.fill",
                                topColor: .black,
                                bottomColor: .gray,
                                iconSize: 52,
                                showLabel: false,
                                customArt: g.icon ?? g.banner
                            )
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    .padding(.bottom, 16)
                }
            }
            .frame(width: 1208, height: 818)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.28), .white.opacity(0.08), .white.opacity(0.18)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 2
                    )
            )
            .shadow(color: .black.opacity(0.65), radius: 28, y: 14)
        }
    }
}

// MARK: - Board 2: iPhone Pro Home Screen & Lock Screen Side-by-Side

private struct IPhoneHomeAndLockBoard: View {
    let mainSnapshot: ShellWidgetSnapshot
    let switch2Snapshot: ShellWidgetSnapshot

    private var switch2DeckSlice: ShellWidgetSnapshot {
        let rotated = Array(switch2Snapshot.games.dropFirst(3)) + Array(switch2Snapshot.games.prefix(3))
        return ShellWidgetSnapshot(games: rotated, readyCount: switch2Snapshot.readyCount, totalCount: switch2Snapshot.totalCount)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.04, blue: 0.055), Color(red: 0.07, green: 0.07, blue: 0.09)],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(spacing: 48) {
                VStack(spacing: 12) {
                    IPhoneBezel {
                        IPhoneHomeScreenContent(mainSnapshot: mainSnapshot, switch2Snapshot: switch2DeckSlice)
                    }
                    Text("iPhone Pro · Home Screen (Large + Switch 2 Medium)")
                        .font(ShellFonts.fixed(13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.74))
                }

                VStack(spacing: 12) {
                    IPhoneBezel {
                        IPhoneLockScreenContent(mainSnapshot: mainSnapshot)
                    }
                    Text("iPhone Pro · Lock Screen & StandBy (Inline + Rectangular + Circular)")
                        .font(ShellFonts.fixed(13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.74))
                }
            }
        }
    }
}

private struct IPhoneBezel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            content
                .frame(width: 402, height: 836)
                .clipShape(RoundedRectangle(cornerRadius: 50, style: .continuous))

            // Dynamic Island
            Capsule()
                .fill(.black)
                .frame(width: 112, height: 31)
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
                .padding(.top, 11)
        }
        .padding(8)
        .background(Color(red: 0.08, green: 0.08, blue: 0.10), in: RoundedRectangle(cornerRadius: 58, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 58, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.32), .white.opacity(0.10), .white.opacity(0.22)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
        )
        .shadow(color: .black.opacity(0.58), radius: 26, y: 14)
    }
}

private struct IPhoneHomeScreenContent: View {
    let mainSnapshot: ShellWidgetSnapshot
    let switch2Snapshot: ShellWidgetSnapshot

    var body: some View {
        ZStack {
            AtmosphericWallpaper(
                accent: Color(red: 0.30, green: 0.24, blue: 0.62),
                warm: Color(red: 0.62, green: 0.22, blue: 0.24)
            )

            VStack(spacing: 0) {
                // Status bar around Dynamic Island
                HStack {
                    Text("9:41")
                        .font(.system(size: 14.5, weight: .semibold))
                    Spacer()
                    HStack(spacing: 5) {
                        Image(systemName: "cellularbars")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "wifi")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "battery.100percent")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 20)

                VStack(spacing: 14) {
                    VStack(spacing: 5) {
                        SystemWidgetFrame(
                            snapshot: mainSnapshot,
                            family: .large,
                            filter: .all,
                            width: 364,
                            height: 382,
                            radius: 24
                        )
                        Text("Continue Playing")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                    }

                    VStack(spacing: 5) {
                        SystemWidgetFrame(
                            snapshot: switch2Snapshot,
                            family: .medium,
                            filter: .switch2,
                            width: 364,
                            height: 170,
                            radius: 22
                        )
                        Text("Switch 2 Deck")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                    }
                }

                Spacer(minLength: 14)

                // Dock
                HStack(spacing: 22) {
                    MockAppIcon(
                        title: "",
                        symbol: "gamecontroller.fill",
                        topColor: Color(red: 0.94, green: 0.22, blue: 0.26),
                        bottomColor: Color(red: 0.58, green: 0.08, blue: 0.14),
                        iconSize: 58,
                        showLabel: false
                    )
                    MockAppIcon(
                        title: "",
                        symbol: "folder.fill",
                        topColor: Color(red: 0.24, green: 0.62, blue: 0.98),
                        bottomColor: Color(red: 0.12, green: 0.38, blue: 0.86),
                        iconSize: 58,
                        showLabel: false
                    )
                    MockAppIcon(
                        title: "",
                        symbol: "safari.fill",
                        topColor: Color(red: 0.20, green: 0.66, blue: 0.98),
                        bottomColor: Color(red: 0.10, green: 0.38, blue: 0.88),
                        iconSize: 58,
                        showLabel: false
                    )
                    MockAppIcon(
                        title: "",
                        symbol: "gearshape.fill",
                        topColor: Color(red: 0.52, green: 0.54, blue: 0.58),
                        bottomColor: Color(red: 0.28, green: 0.30, blue: 0.34),
                        iconSize: 58,
                        showLabel: false
                    )
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 1))
                .padding(.bottom, 16)
            }
        }
    }
}

private struct IPhoneLockScreenContent: View {
    let mainSnapshot: ShellWidgetSnapshot

    var body: some View {
        ZStack {
            AtmosphericWallpaper(
                accent: Color(red: 0.18, green: 0.34, blue: 0.58),
                warm: Color(red: 0.44, green: 0.18, blue: 0.38)
            )

            VStack(spacing: 0) {
                HStack {
                    Text("Carrier")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    HStack(spacing: 5) {
                        Image(systemName: "wifi")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "battery.100percent")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 34)

                // accessoryInline widget right above the Lock Screen clock
                ShellWidgetView(snapshot: mainSnapshot, family: .accessoryInline)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.bottom, 2)

                Text("9:41")
                    .font(.system(size: 86, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    .padding(.bottom, 14)

                // Lock Screen Accessory Shelf: Rectangular (172x76) + Circular (76x76) + Controller Battery Circular
                HStack(spacing: 12) {
                    ShellWidgetView(snapshot: mainSnapshot, family: .accessoryRectangular)
                        .padding(.horizontal, 12)
                        .frame(width: 176, height: 76)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.20), lineWidth: 1))

                    ShellWidgetView(snapshot: mainSnapshot, family: .accessoryCircular)
                        .frame(width: 72, height: 72)

                    ZStack {
                        Circle().fill(.white.opacity(0.12))
                        Circle().strokeBorder(.white.opacity(0.26), lineWidth: 1.5)
                        VStack(spacing: 2) {
                            Image(systemName: "dpad.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text("94%")
                                .font(ShellFonts.fixed(11.5, weight: .bold))
                        }
                        .foregroundStyle(.white.opacity(0.92))
                    }
                    .frame(width: 72, height: 72)
                }
                .padding(.horizontal, 20)

                Spacer()

                // Lock Screen quick actions + home indicator
                HStack {
                    Circle()
                        .fill(.black.opacity(0.38))
                        .frame(width: 50, height: 50)
                        .overlay(Image(systemName: "flashlight.off.fill").font(.system(size: 18)).foregroundStyle(.white))
                        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    Spacer()
                    Circle()
                        .fill(.black.opacity(0.38))
                        .frame(width: 50, height: 50)
                        .overlay(Image(systemName: "camera.fill").font(.system(size: 17)).foregroundStyle(.white))
                        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                }
                .padding(.horizontal, 42)
                .padding(.bottom, 18)

                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 134, height: 5)
                    .padding(.bottom, 10)
            }
        }
    }
}

// MARK: - Board 3: Switch 2 Deck, Pinned Hero, States & 10-Language Localization

private struct ConfigurationsAndL10nBoard: View {
    let mainSnapshot: ShellWidgetSnapshot
    let switch2Snapshot: ShellWidgetSnapshot
    let jaMedium: NSImage
    let deMedium: NSImage

    private var pinnedSnapshot: ShellWidgetSnapshot {
        let targetID = mainSnapshot.games.first(where: { $0.id == "0400486024DEC000" })?.id
            ?? mainSnapshot.games.dropFirst(3).first?.id
        return mainSnapshot.resolved(filter: .pinned, pinnedGameID: targetID)
    }

    private var missingDataSnapshot: ShellWidgetSnapshot {
        guard var sample = mainSnapshot.games.first(where: { !$0.isSwitch2 }) ?? mainSnapshot.games.first else {
            return ShellWidgetSnapshot()
        }
        sample.state = .needsGameData
        sample.recentlyPlayed = nil
        return ShellWidgetSnapshot(games: [sample], readyCount: mainSnapshot.readyCount, totalCount: mainSnapshot.totalCount)
    }

    var body: some View {
        ZStack {
            Color(red: 0.045, green: 0.045, blue: 0.052)

            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CONFIGURABLE INTENTS · LOCALIZATION · EDGE STATES")
                            .font(ShellFonts.fixed(11, weight: .bold))
                            .tracking(1.6)
                            .foregroundStyle(ShellPalette.cream.opacity(0.78))
                        Text("AppIntents Edit Widget Modes & 10-Language Catalog")
                            .font(ShellFonts.fixed(24, weight: .heavy))
                            .tracking(-0.5)
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    IntentSummaryCard()
                }

                // Row 1: Switch 2 Deck + Pinned Featured Game + Missing Data + Empty Library
                HStack(alignment: .top, spacing: 24) {
                    LabeledPreviewColumn(title: "Switch 2 Deck · Collection: Switch 2 Only") {
                        SystemWidgetFrame(snapshot: switch2Snapshot, family: .medium, filter: .switch2, width: 364, height: 170, radius: 22)
                    }

                    LabeledPreviewColumn(title: "Continue Playing · Pinned Featured Game") {
                        SystemWidgetFrame(snapshot: pinnedSnapshot, family: .medium, filter: .pinned, width: 364, height: 170, radius: 22)
                    }

                    LabeledPreviewColumn(title: "Missing Data -> Setup") {
                        SystemWidgetFrame(snapshot: missingDataSnapshot, family: .small, filter: .all, width: 170, height: 170, radius: 22)
                    }

                    LabeledPreviewColumn(title: "Empty Library") {
                        SystemWidgetFrame(snapshot: ShellWidgetSnapshot(), family: .small, filter: .all, width: 170, height: 170, radius: 22)
                    }
                }

                // Row 2: Localized Previews (Japanese + German) + Empty Medium State
                HStack(alignment: .top, spacing: 24) {
                    LabeledPreviewColumn(title: "Japanese (ja.lproj) · 次にプレイ / プレイ可能") {
                        Image(nsImage: jaMedium)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 364, height: 170)
                    }

                    LabeledPreviewColumn(title: "German (de.lproj) · Switch 2 / spielbereit") {
                        Image(nsImage: deMedium)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 364, height: 170)
                    }

                    LabeledPreviewColumn(title: "First-Run Empty Medium Widget -> Library") {
                        SystemWidgetFrame(snapshot: ShellWidgetSnapshot(), family: .medium, filter: .all, width: 364, height: 170, radius: 22)
                    }
                }

                // Footer note on all 10 languages
                HStack(spacing: 10) {
                    ForEach(["EN", "DE", "ES", "FR", "IT", "JA", "KO", "PT-BR", "SV", "ZH-HANS"], id: \.self) { code in
                        Text(code)
                            .font(ShellFonts.fixed(10.5, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(ShellPalette.cream.opacity(0.88))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(ShellPalette.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    }
                    Spacer()
                    Text("Every widget string & AppIntent option localized across all 10 shipped catalogs")
                        .font(ShellFonts.fixed(12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                }
            }
            .padding(34)
        }
    }
}

private struct IntentSummaryCard: View {
    var body: some View {
        HStack(spacing: 18) {
            IntentPillColumn(label: "Collection", value: "Recent · Switch 2 · Pinned")
            IntentPillColumn(label: "Featured Game", value: "Dynamic Library Picker")
            IntentPillColumn(label: "When Tapped", value: "Launch · Show in Library")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ShellPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }
}

private struct IntentPillColumn: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(ShellFonts.fixed(9, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(ShellPalette.cream.opacity(0.75))
            Text(value)
                .font(ShellFonts.fixed(11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
    }
}

private struct LabeledPreviewColumn<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(ShellFonts.fixed(12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            content
        }
    }
}

// MARK: - Board 4: All 7 WidgetKit Families Reference Sheet

private struct WidgetFamiliesSpecimenBoard: View {
    let mainSnapshot: ShellWidgetSnapshot
    let switch2Snapshot: ShellWidgetSnapshot

    var body: some View {
        ZStack {
            Color(red: 0.042, green: 0.043, blue: 0.05)

            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NX2APPLE WIDGETKIT DESIGN SYSTEM")
                            .font(ShellFonts.fixed(11, weight: .bold))
                            .tracking(1.6)
                            .foregroundStyle(ShellPalette.cream.opacity(0.78))
                        Text("All 7 Native Widget Families · iPadOS & iOS")
                            .font(ShellFonts.fixed(24, weight: .heavy))
                            .tracking(-0.5)
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Text("Deep Links: nx2apple://play/<id> · settings/<id> · controllers · library")
                        .font(ShellFonts.fixed(12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }

                HStack(alignment: .top, spacing: 28) {
                    // Left column: ExtraLarge (752x376) + Medium (364x170) + Small (170x170) + Accessories
                    VStack(alignment: .leading, spacing: 22) {
                        LabeledPreviewColumn(title: "systemExtraLarge · 752 × 376 pt (iPad Pro 7-Game Command Deck)") {
                            SystemWidgetFrame(snapshot: mainSnapshot, family: .extraLarge, filter: .all, width: 752, height: 376, radius: 24)
                        }

                        HStack(alignment: .top, spacing: 18) {
                            LabeledPreviewColumn(title: "systemMedium · 364 × 170 pt") {
                                SystemWidgetFrame(snapshot: mainSnapshot, family: .medium, filter: .all, width: 364, height: 170, radius: 22)
                            }

                            LabeledPreviewColumn(title: "systemSmall · 170 pt") {
                                SystemWidgetFrame(snapshot: switch2Snapshot, family: .small, filter: .switch2, width: 170, height: 170, radius: 22)
                            }

                            LabeledPreviewColumn(title: "Lock Screen Families") {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 5) {
                                        Image(systemName: "gamecontroller.fill")
                                            .font(.system(size: 11.5, weight: .bold))
                                        Text("\(mainSnapshot.games.first?.title ?? "Mario Kart World") · \(ShellStrings.text("Play"))")
                                            .font(ShellFonts.fixed(11.5, weight: .semibold))
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(.white.opacity(0.92))

                                    ShellWidgetView(snapshot: mainSnapshot, family: .accessoryRectangular)
                                        .padding(.horizontal, 10)
                                        .frame(width: 182, height: 68)
                                        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 1))

                                    HStack(spacing: 10) {
                                        ShellWidgetView(snapshot: mainSnapshot, family: .accessoryCircular)
                                            .frame(width: 58, height: 58)
                                        Text("accessoryInline\naccessoryRectangular\naccessoryCircular")
                                            .font(ShellFonts.fixed(10, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.54))
                                            .fixedSize()
                                    }
                                }
                                .frame(width: 184, alignment: .leading)
                            }
                        }
                    }

                    // Right column: Large (364x382) + Deep-Link Map Card
                    VStack(alignment: .leading, spacing: 22) {
                        LabeledPreviewColumn(title: "systemLarge · 364 × 382 pt (Hero + 2×2 Grid)") {
                            SystemWidgetFrame(snapshot: mainSnapshot, family: .large, filter: .all, width: 364, height: 382, radius: 24)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("INTERACTIVE TAP ZONES")
                                .font(ShellFonts.fixed(10, weight: .bold))
                                .tracking(1.4)
                                .foregroundStyle(ShellPalette.cream.opacity(0.78))
                            DeepLinkLegendRow(badge: "Play / Cover", route: "nx2apple://play/<title_id>", desc: "Boots game immediately (or opens setup if data missing)")
                            DeepLinkLegendRow(badge: "Sliders Icon", route: "nx2apple://settings/<title_id>", desc: "Opens per-game graphics, audio & save management")
                            DeepLinkLegendRow(badge: "Controller", route: "nx2apple://controllers", desc: "Opens Bluetooth & MFi controller mapping sheet")
                            DeepLinkLegendRow(badge: "Ready Pill", route: "nx2apple://library", desc: "Opens full Cover Flow / grid library")
                        }
                        .padding(16)
                        .frame(width: 364, alignment: .leading)
                        .background(ShellPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
                    }
                }
            }
            .padding(32)
        }
    }
}

private struct DeepLinkLegendRow: View {
    let badge: String
    let route: String
    let desc: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(badge)
                    .font(ShellFonts.fixed(10.5, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(ShellPalette.cream, in: Capsule())
                Text(route)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
            Text(desc)
                .font(ShellFonts.fixed(10.5, weight: .regular))
                .foregroundStyle(.white.opacity(0.56))
                .lineLimit(1)
        }
    }
}
#endif
