import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// Guards the launcher against changes that make it slow. A synthetic library (30 owned games with banners, every third one
/// built, 150 game profiles in the checkout, about 3 MB of frame time recordings for one game) is hosted in a window, and the
/// test drives it with the gamepad: the three tab switches, Options, Manage and a plain redraw of the library.
///
/// The first guard counts work on the main thread per interaction (LauncherWork): game cards built, Manrope fonts made,
/// Info.plist reads and frame time recordings parsed. The counts do not depend on the machine, so they catch work that grows
/// with the library long before a stopwatch would. The second guard is the time the main thread is busy, the median of
/// several rounds, with budgets far above what main needs on CI. See "Launcher performance test" in frontend/README.md.
final class LauncherPerformanceTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-perf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private static func titleID(_ i: Int) -> String { String(format: "0100%08X%04X", 0xA0000 + i * 17, 0) }

    private func banner(_ i: Int, to url: URL) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 360, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(hue: CGFloat(i % 37) / 37, saturation: 0.6, brightness: 0.7, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 640, height: 360).fill()
        NSColor(hue: CGFloat((i * 7) % 37) / 37, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 40 + i % 200, y: 40, width: 280, height: 280)).fill()
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!.write(to: url)
    }

    private func recording(frames: Int, to url: URL) throws {
        var text = ""
        text.reserveCapacity(frames * 110)
        var t = 0.0
        for n in 0..<frames {
            let ms = n % 997 == 0 ? 71.3 : 16.6 + Double(n % 13) * 0.11
            t += ms / 1000
            text += "\(n)\t@t_s\t\(String(format: "%.6f", t))\n\(n)\t@frame_ms\t\(String(format: "%.3f", ms))\n"
            text += "\(n)\t@presented_ms\t\(String(format: "%.3f", ms - 0.4))\n\(n)\t@gpu_ms\t\(String(format: "%.3f", ms * 0.6))\n"
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The launch options of a built game, as dm/launcher.json lists them: the basic rows and a few advanced ones.
    private static let settings = [
        #"{"env": "DM_FPS_TARGET", "kind": "choice", "label": "Frame rate", "note": "", "default": "60", "section": "Game", "options": [["30", "30"], ["60", "60"], ["120", "120"]]}"#,
        #"{"env": "DM_RENDER_SCALE", "kind": "range", "label": "Render scale", "note": "", "default": "1.0", "section": "Game", "min": 0.5, "max": 2.0, "step": 0.25}"#,
        #"{"env": "DM_OPMODE", "kind": "choice", "label": "Console mode", "note": "", "default": "1", "section": "Game", "options": [["1", "Docked"], ["0", "Handheld"]]}"#,
        #"{"env": "DM_LANG", "kind": "choice", "label": "Language", "note": "", "default": "en", "section": "Game", "options": [["en", "English"], ["ja", "Japanese"], ["de", "German"]]}"#,
        #"{"env": "DM_RUMBLE", "kind": "toggle", "label": "Rumble", "note": "", "default": "1", "section": "Controls"}"#,
        #"{"env": "DM_VSYNC", "kind": "toggle", "label": "Vertical sync", "note": "", "default": "1", "section": "Performance"}"#,
        #"{"env": "DM_SHADER_CACHE", "kind": "toggle", "label": "Shader cache", "note": "", "default": "1", "section": "Performance"}"#,
        #"{"env": "DM_AUDIO_LATENCY", "kind": "range", "label": "Audio latency", "note": "", "default": "40", "section": "Performance", "min": 10, "max": 200, "step": 10}"#,
    ].joined(separator: ", ")

    private struct Snapshot: Encodable { let games: [LibraryGame]; let folder: String }

    /// Synthetic world: a checkout with `catalogue` game profiles and a library of `owned` games, every third one built.
    private func makeWorld(owned: Int, catalogue: Int) throws -> (repo: URL, libraryFile: URL, selected: UUID) {
        let fm = FileManager.default
        let repo = temporary.appendingPathComponent("repo"), folder = temporary.appendingPathComponent("library")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<max(catalogue, owned) {
            let dir = repo.appendingPathComponent("dm/games/" + Self.titleID(i))
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try "name\tSynthetic Game \(i)\nrender_base\t1600x900 1280x720\n".write(to: dir.appendingPathComponent("game.tsv"), atomically: true, encoding: .utf8)
        }
        var games: [LibraryGame] = []
        for i in 0..<owned {
            let id = Self.titleID(i), name = "Synthetic Game \(i)"
            var game = LibraryGame(titleID: id, name: name)
            let art = folder.appendingPathComponent("art/\(id).jpg")
            try fm.createDirectory(at: art.deletingLastPathComponent(), withIntermediateDirectories: true)
            try banner(i, to: art)
            game.artworkPath = art.path
            game.inputs = ["base": ["/synthetic/\(name) [\(id)].nsp"]]
            if i % 3 == 0 {
                let app = folder.appendingPathComponent("\(name).app")
                try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
                for exe in ["nxnative", "dmhost"] {
                    try fm.createSymbolicLink(at: app.appendingPathComponent("Contents/MacOS/" + exe), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
                }
                let info: [String: Any] = ["DMTitleID": id, "CFBundleDisplayName": name, "CFBundleExecutable": "nxnative",
                                           "CFBundleIdentifier": "org.nxnative.perftest." + id]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
                let dm = app.appendingPathComponent("Contents/Resources/dm")
                try fm.createDirectory(at: dm, withIntermediateDirectories: true)
                try "{\"game\": \"\(id)\", \"settings\": [\(Self.settings)]}".write(to: dm.appendingPathComponent("launcher.json"), atomically: true, encoding: .utf8)
                game.appPath = app.path
                game.lastTarget = "mac-app"
            }
            games.append(game)
        }
        let frameTimes = FrameTimes.folder(titleID: games[0].titleID, library: folder.path)
        try recording(frames: 30_000, to: frameTimes.appendingPathComponent("2026-10-30 21-00-00.tsv"))
        try recording(frames: 8_000, to: frameTimes.appendingPathComponent("2026-10-29 20-00-00.tsv"))
        let file = temporary.appendingPathComponent("library.json")
        try JSONEncoder().encode(Snapshot(games: games, folder: folder.path)).write(to: file)
        return (repo, file, games[0].id)
    }

    /// One step the player takes, with the most work main may do for it. Main's counts on this library are about half of
    /// each budget (main makes no font after the warm-up), its CI time a quarter or less.
    private struct Interaction {
        let name: String
        let action: () -> Void
        var undo: (() -> Void)? = nil
        let cards: Int, fonts: Int, plistReads: Int, busyMs: Double
    }

    private struct Sample { var busyMs: Double; var counts: [LauncherWork.Kind: Int] }

    private static let rounds = 5

    @MainActor func testLauncherInteractionsStayFast() throws {
        #if !DEBUG
        throw XCTSkip("LauncherWork counts only in debug builds")
        #else
        let world = try makeWorld(owned: 30, catalogue: 150)
        NSApplication.shared.setActivationPolicy(.accessory)
        let saved = ["repoPath", "buildOutputDirectory"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        let model = BuildModel()
        model.repoPath = world.repo.path
        model.lang = .en
        let library = GameLibrary(file: world.libraryFile)
        library.selectedID = world.selected
        let pad = LauncherGamepad()
        let host = NSHostingView(rootView: ContentView(model: model, library: library, performStartupChecks: false, gamepad: pad))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        let interactions = [
            Interaction(name: "redraw of the library", action: { library.objectWillChange.send() },
                        cards: 60, fonts: 20, plistReads: 50, busyMs: 200),
            Interaction(name: "tab Library to Builds", action: { pad.perform(.r) },
                        cards: 10, fonts: 20, plistReads: 10, busyMs: 300),
            Interaction(name: "tab Builds to Settings", action: { pad.perform(.r) },
                        cards: 10, fonts: 20, plistReads: 10, busyMs: 300),
            Interaction(name: "tab Settings to Library", action: { pad.perform(.r) },
                        cards: 180, fonts: 20, plistReads: 140, busyMs: 400),
            Interaction(name: "open Options", action: { pad.perform(.x) }, undo: { pad.perform(.b) },
                        cards: 120, fonts: 20, plistReads: 110, busyMs: 800),
            Interaction(name: "open Manage", action: { pad.perform(.y) }, undo: { pad.perform(.b) },
                        cards: 180, fonts: 20, plistReads: 180, busyMs: 400),
        ]
        let meter = MainThreadMeter()
        defer { meter.stop() }
        var samples = [[Sample]](repeating: [], count: interactions.count)
        for round in 0...Self.rounds {
            for (i, step) in interactions.enumerated() {
                let sample = meter.measure(step.action)
                if round > 0 { samples[i].append(sample) }   // round 0 warms up caches and the first sheet
                step.undo?()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            }
        }

        var report = ["Launcher interactions, median of \(Self.rounds) rounds (budget in brackets):"]
        var failures: [String] = []
        for (step, runs) in zip(interactions, samples) {
            let busy = Self.median(runs.map(\.busyMs))
            func count(_ kind: LauncherWork.Kind) -> Int { Int(Self.median(runs.map { Double($0.counts[kind, default: 0]) })) }
            let cards = count(.card), fonts = count(.font), plists = count(.infoPlistRead), parses = count(.frameTimesParse)
            report.append("  " + step.name.padding(toLength: 24, withPad: " ", startingAt: 0) + String(format: "busy %6.0f ms (%4.0f)  cards %4d (%3d)  fonts %5d (%3d)  Info.plist reads %4d (%3d)  parses %d (0)",
                                 busy, step.busyMs, cards, step.cards, fonts, step.fonts, plists, step.plistReads, parses))
            if cards > step.cards {
                failures.append("\(step.name): \(cards) game cards built, budget \(step.cards). The library row builds every card on each "
                    + "redraw, so the work grows with the number of games. Use a LazyHStack or cut the cards that are shown.")
            }
            if fonts > step.fonts {
                failures.append("\(step.name): \(fonts) Manrope fonts made, budget \(step.fonts). Typography keeps one font per size and "
                    + "weight. A font made past that cache is made again on every redraw, for every label. Use Font.manrope.")
            }
            if plists > step.plistReads {
                failures.append("\(step.name): \(plists) Info.plist reads, budget \(step.plistReads). LibraryGame.isReady and "
                    + "ContentView.status read the app bundle on every call. Call them less often per redraw or cache the result.")
            }
            if parses > 0 {
                failures.append("\(step.name): \(parses) frame time recordings parsed on the main thread, budget 0. "
                    + "Parse them off the main thread, as FrameTimesRecordingView does with Task.detached.")
            }
            if busy > step.busyMs {
                failures.append(String(format: "%@: main thread busy %.0f ms, budget %.0f ms. Something does more work per redraw. "
                    + "Work that grows with the library size is the usual cause: use a lazy stack or cache what each card needs, "
                    + "then profile the release build with the Time Profiler.", step.name, busy, step.busyMs))
            }
        }
        print(report.joined(separator: "\n"))
        for failure in failures { XCTFail(failure) }
        #endif
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// Time the main run loop spends running rather than sleeping, from the start of an interaction until the launcher is idle.
    /// Two run loop observers sum the sleeps, so `busy = wall time - sleeping`. Wall time rather than CPU time: a sheet that
    /// blocks the main thread on the window server counts too.
    @MainActor private final class MainThreadMeter {
        private var sleeping = 0.0, fellAsleep = 0.0
        private var observers: [CFRunLoopObserver] = []

        init() {
            let asleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [unowned self] _, _ in
                fellAsleep = CACurrentMediaTime()
            }
            let awake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [unowned self] _, _ in
                sleeping += CACurrentMediaTime() - fellAsleep
            }
            observers = [asleep!, awake!]
            for observer in observers { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        }

        func stop() {
            for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observers = []
        }

        /// Runs `action`, then the run loop for `settle` seconds, which covers the redraw, the sheet and its animation.
        func measure(settle: Double = 0.8, _ action: () -> Void) -> Sample {
            #if DEBUG
            LauncherWork.reset()
            #endif
            sleeping = 0
            let start = CACurrentMediaTime()
            action()
            while CACurrentMediaTime() - start < settle { CFRunLoopRunInMode(.defaultMode, 0.02, true) }
            let busy = CACurrentMediaTime() - start - sleeping
            #if DEBUG
            return Sample(busyMs: busy * 1000, counts: LauncherWork.counts)
            #else
            return Sample(busyMs: busy * 1000, counts: [:])
            #endif
        }
    }
}
