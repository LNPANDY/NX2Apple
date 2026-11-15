#if os(macOS)
import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import ShellUI

/// Opt-in visual QA captures for the iOS and iPadOS Activity Log, hero playtime and Play history row (#1161).
/// Run with `NX_SHELL_CAPTURE_DIR=<dir> NX_SHELL_CAPTURE_LANG=en|zh swift test --filter ActivityLogCaptureTests`.
@MainActor
final class ActivityLogCaptureTests: XCTestCase {
    private var lang: String { ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_LANG"] ?? "en" }

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_DIR"] != nil else {
            throw XCTSkip("Set NX_SHELL_CAPTURE_DIR to capture the shell")
        }
        if let path = ShellStrings.bundle.path(forResource: lang == "zh" ? "zh-Hans" : lang, ofType: "lproj") {
            ShellStrings.captureBundle = Bundle(path: path)
        }
    }

    override func tearDown() async throws {
        ShellStrings.captureBundle = nil
    }

    private func capture<V: View>(_ name: String, width: CGFloat, height: CGFloat? = nil, _ view: V) throws {
        let dir = try XCTUnwrap(ProcessInfo.processInfo.environment["NX_SHELL_CAPTURE_DIR"])
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let framed = view
            .frame(width: width)
            .frame(height: height)
            .background(ShellPalette.background)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: framed)
        host.frame = NSRect(origin: .zero, size: height.map { NSSize(width: width, height: $0) } ?? host.fittingSize)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: host.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("Missing bitmapImageRepForCachingDisplay")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let file = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(lang).png")
        guard let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("Missing PNG representation")
            return
        }
        try png.write(to: file)
    }

    private func makeGradientData(width: Int, height: Int, c0: (CGFloat, CGFloat, CGFloat), c1: (CGFloat, CGFloat, CGFloat)) throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let colors = [
            CGColor(srgbRed: c0.0, green: c0.1, blue: c0.2, alpha: 1),
            CGColor(srgbRed: c1.0, green: c1.1, blue: c1.2, alpha: 1)
        ] as CFArray
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]))
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(height)),
            end: CGPoint(x: CGFloat(width), y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
        let orb = CGFloat(min(width, height)) * 0.64
        ctx.fillEllipse(in: CGRect(x: CGFloat(width) * 0.64, y: CGFloat(height) * 0.42, width: orb, height: orb))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testCaptureActivityLogViews() throws {
        let locale = Locale(identifier: lang == "zh" ? "zh-Hans" : lang)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        cal.locale = locale
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 18, minute: 0)))
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let firstDate = cal.date(byAdding: .day, value: -24, to: now)!

        let dateFmt = DateFormatter()
        dateFmt.locale = locale
        dateFmt.dateStyle = .medium
        dateFmt.timeStyle = .none

        let starTitle = lang == "zh" ? "星光奥德赛" : "Starlight Odyssey"
        let chronoTitle = lang == "zh" ? "时空地平线" : "Chrono Horizon"
        let aetherTitle = lang == "zh" ? "苍穹漂移" : "Aether Drift"
        let removedTitle = lang == "zh" ? "曜星纪元" : "Solaris Prime"

        let starBanner = Artwork(id: "b1", data: try makeGradientData(width: 960, height: 540, c0: (0.20, 0.30, 0.80), c1: (0.48, 0.22, 0.78)))
        let starIcon = Artwork(id: "i1", data: try makeGradientData(width: 256, height: 256, c0: (0.20, 0.30, 0.80), c1: (0.48, 0.22, 0.78)))
        let chronoBanner = Artwork(id: "b2", data: try makeGradientData(width: 960, height: 540, c0: (0.16, 0.50, 0.54), c1: (0.22, 0.32, 0.62)))
        let chronoIcon = Artwork(id: "i2", data: try makeGradientData(width: 256, height: 256, c0: (0.16, 0.50, 0.54), c1: (0.22, 0.32, 0.62)))
        let aetherBanner = Artwork(id: "b3", data: try makeGradientData(width: 960, height: 540, c0: (0.76, 0.34, 0.30), c1: (0.44, 0.20, 0.48)))
        let aetherIcon = Artwork(id: "i3", data: try makeGradientData(width: 256, height: 256, c0: (0.76, 0.34, 0.30), c1: (0.44, 0.20, 0.48)))

        let starTime = ShellFormat.duration(51_900, locale: locale) // 14 hr, 25 min
        let chronoTime = ShellFormat.duration(19_200, locale: locale) // 5 hr, 20 min
        let aetherTime = ShellFormat.duration(7_500, locale: locale) // 2 hr, 5 min
        let removedTime = ShellFormat.duration(5_700, locale: locale) // 1 hr, 35 min

        let starRecent = ShellFormat.metaLine(starTime, ShellFormat.played(now, now: now, calendar: cal, locale: locale))
        let chronoRecent = ShellFormat.metaLine(chronoTime, ShellFormat.played(yesterday, now: now, calendar: cal, locale: locale))

        let starTile = GameTile(
            id: "0100AA0000010000",
            title: starTitle,
            subtitle: ShellFormat.version("1.2.0"),
            banner: starBanner,
            icon: starIcon,
            state: .playable,
            recentlyPlayed: starRecent,
            version: "1.2.0"
        )
        let chronoTile = GameTile(
            id: "0100AA0000020000",
            title: chronoTitle,
            subtitle: ShellFormat.version("1.0.4"),
            banner: chronoBanner,
            icon: chronoIcon,
            state: .playable,
            recentlyPlayed: chronoRecent,
            version: "1.0.4"
        )
        let aetherTile = GameTile(
            id: "0100AA0000030000",
            title: aetherTitle,
            subtitle: ShellFormat.version("2.1.0"),
            banner: aetherBanner,
            icon: aetherIcon,
            state: .playable,
            recentlyPlayed: nil,
            version: "2.1.0"
        )

        let starSummary = ShellFormat.playSummary(duration: starTime, sessions: 18)
        let starDetailBefore = GameDetail(
            game: GameTile(
                id: starTile.id,
                title: starTile.title,
                subtitle: starTile.subtitle,
                banner: starBanner,
                icon: starIcon,
                state: .playable,
                recentlyPlayed: ShellFormat.played(now, now: now, calendar: cal, locale: locale),
                version: "1.2.0"
            ),
            dataSource: ShellStrings.text("This app's folder"),
            playSummary: nil
        )
        let starDetailAfter = GameDetail(
            game: starTile,
            dataSource: ShellStrings.text("This app's folder"),
            playSummary: starSummary
        )
        let chronoDetail = GameDetail(game: chronoTile, playSummary: ShellFormat.playSummary(duration: chronoTime, sessions: 7))
        let aetherDetail = GameDetail(game: aetherTile, playSummary: ShellFormat.playSummary(duration: aetherTime, sessions: 3))

        let daySeconds: [Int: Double] = [
            13: 6600, 12: 4800, 11: 3300, 10: 5700, 9: 5400, 8: 4200,
            7: 6600, 6: 7500, 5: 5100, 4: 9300, 3: 3600, 2: 3900, 1: 9000, 0: 9300
        ]
        var activeKeys = Set<String>()
        let bars: [ActivityDayBar] = (0..<14).reversed().map { offset in
            let d = cal.date(byAdding: .day, value: -offset, to: now)!
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let key = String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 11, c.day ?? 1)
            let sec = daySeconds[offset] ?? 0
            if sec > 0 { activeKeys.insert(key) }
            return ActivityDayBar(id: key, label: "\(c.day ?? 1)", seconds: sec)
        }

        let snapshot = ActivityLogSnapshot(
            totalTime: ShellFormat.duration(84_300, locale: locale),
            totalSeconds: 84_300,
            totalSessions: 31,
            activeDaysCount: 14,
            gamesPlayedCount: 4,
            activeDayKeys: activeKeys,
            recentDays: bars,
            entries: [
                ActivityGameEntry(
                    id: starTile.id,
                    title: starTitle,
                    game: starTile,
                    seconds: 51_900,
                    totalTime: starTime,
                    sessions: 18,
                    averageTime: ShellFormat.duration(2_883, locale: locale),
                    daysPlayed: 10,
                    firstPlayed: dateFmt.string(from: firstDate),
                    lastPlayed: dateFmt.string(from: now),
                    lastPlayedDate: now,
                    isInstalled: true
                ),
                ActivityGameEntry(
                    id: chronoTile.id,
                    title: chronoTitle,
                    game: chronoTile,
                    seconds: 19_200,
                    totalTime: chronoTime,
                    sessions: 7,
                    averageTime: ShellFormat.duration(2_742, locale: locale),
                    daysPlayed: 5,
                    firstPlayed: dateFmt.string(from: cal.date(byAdding: .day, value: -18, to: now)!),
                    lastPlayed: dateFmt.string(from: yesterday),
                    lastPlayedDate: yesterday,
                    isInstalled: true
                ),
                ActivityGameEntry(
                    id: aetherTile.id,
                    title: aetherTitle,
                    game: aetherTile,
                    seconds: 7_500,
                    totalTime: aetherTime,
                    sessions: 3,
                    averageTime: ShellFormat.duration(2_500, locale: locale),
                    daysPlayed: 3,
                    firstPlayed: dateFmt.string(from: cal.date(byAdding: .day, value: -9, to: now)!),
                    lastPlayed: dateFmt.string(from: now),
                    lastPlayedDate: now,
                    isInstalled: true
                ),
                ActivityGameEntry(
                    id: "0100AA0000090000",
                    title: removedTitle,
                    game: nil,
                    seconds: 5_700,
                    totalTime: removedTime,
                    sessions: 3,
                    averageTime: ShellFormat.duration(1_900, locale: locale),
                    daysPlayed: 2,
                    firstPlayed: dateFmt.string(from: cal.date(byAdding: .day, value: -21, to: now)!),
                    lastPlayed: dateFmt.string(from: cal.date(byAdding: .day, value: -6, to: now)!),
                    lastPlayedDate: cal.date(byAdding: .day, value: -6, to: now)!,
                    isInstalled: false
                )
            ],
            referenceDate: now
        )

        // 1. Portrait iOS library after (430x932 matching ios-library-before-{en,zh}.png)
        try capture(
            "ios-library-after",
            width: 430,
            height: 932,
            LibraryView(games: [starDetailAfter, chronoDetail, aetherDetail], activityLog: snapshot)
        )

        // 2. GameDetailView before (no Play history row) & after (with Play history row)
        try capture(
            "ios-detail-card-before",
            width: 430,
            GameDetailView(detail: starDetailBefore, showsPrimaryAction: true, showsHeader: true)
                .padding(20)
        )
        try capture(
            "ios-detail-card-after",
            width: 430,
            GameDetailView(detail: starDetailAfter, showsPrimaryAction: true, showsHeader: true)
                .padding(20)
        )

        // 3. ActivityLogView on iPhone (430x932) and iPad (720x820)
        try capture(
            "ios-activity-log-after",
            width: 430,
            height: 932,
            ActivityLogView(snapshot: snapshot, onSelectGame: { _ in }, onClose: {})
                .environment(\.shellNativeBars, true)
        )
        try capture(
            "ipad-activity-log-after",
            width: 720,
            height: 820,
            ActivityLogView(snapshot: snapshot, onSelectGame: { _ in }, onClose: {})
                .environment(\.shellNativeBars, true)
        )
    }
}
#endif
