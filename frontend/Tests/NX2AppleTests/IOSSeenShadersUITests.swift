import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

@MainActor final class IOSSeenShadersUITests: IsolatedDefaultsTestCase {
    private func makeFakeEngineRepo(root: URL) throws -> URL {
        let repo = root.appendingPathComponent("repo")
        let script = repo.appendingPathComponent("engine/scripts/build_ipa_from_nsp.py")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "ap.add_argument('--seen-shaders')  # ios_seen_shaders DM_PARTIAL_SHADERS\n".write(to: script, atomically: true, encoding: .utf8)
        let extract = repo.appendingPathComponent("engine/dm/tools/nx_extract/Program.cs")
        try FileManager.default.createDirectory(at: extract.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: extract)

        // Pokopia (opt-in iOS --seen-shaders)
        let pokopia = repo.appendingPathComponent("engine/dm/games/0400A3A01EE4C000")
        try FileManager.default.createDirectory(at: pokopia, withIntermediateDirectories: true)
        try "title_id\t0400A3A01EE4C000\nios_seen_shaders\t1\n".write(to: pokopia.appendingPathComponent("game.tsv"), atomically: true, encoding: .utf8)
        try "key\tstage\n0000000000000001\tpixel\n".write(to: pokopia.appendingPathComponent("shader_seen.tsv"), atomically: true, encoding: .utf8)
        try "package\tindex\tstage\tkey\tsource\np.bin\t0\tvs\t0000000000000001\tsrc\np.bin\t1\tvs\t0000000000000002\tsrc\n".write(to: pokopia.appendingPathComponent("shader_map.tsv"), atomically: true, encoding: .utf8)

        // Another game with shader_seen.tsv but without ios_seen_shaders opt-in
        let other = repo.appendingPathComponent("engine/dm/games/0100111122220000")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "title_id\t0100111122220000\n".write(to: other.appendingPathComponent("game.tsv"), atomically: true, encoding: .utf8)
        try "key\tstage\n0000000000000001\tpixel\n".write(to: other.appendingPathComponent("shader_seen.tsv"), atomically: true, encoding: .utf8)
        try "package\tindex\tstage\tkey\tsource\np.bin\t0\tvs\t0000000000000001\tsrc\np.bin\t1\tvs\t0000000000000002\tsrc\n".write(to: other.appendingPathComponent("shader_map.tsv"), atomically: true, encoding: .utf8)
        return repo
    }

    func testTargetCardShowsIOSFastShaderSwitchOnlyForOptInIOSGames() throws {
        let stores = LauncherStores(defaults: testDefaults)
        let build = stores.build
        let pad = PadFocus()
        build.buildUpstream = .nxnative
        build.target = BuildTarget.ios
        XCTAssertFalse(build.iosSeenShadersOnly)

        let window = OffscreenWindow(size: .init(width: 820, height: 480))
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        func host() {
            window.contentView = NSHostingView(rootView: TargetCard(build: build)
                .environmentObject(stores.localizer)
                .environmentObject(pad)
                .padScope("main", pad))
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }

        // 1. iOS + nxnative + supportsIOS == true -> toggle visible and defaults off; controller activation flips it on.
        build.setSeenShadersForGallery(SeenShadersInfo(seenCount: 8163, totalCount: 131427, supportsIOS: true))
        host()
        XCTAssertNotNil(pad.frame(of: "set.build.bc"))
        XCTAssertNotNil(pad.frame(of: "set.build.iosSeenShaders"))
        pad.focused = "set.build.iosSeenShaders"
        pad.activate()
        XCTAssertTrue(build.iosSeenShadersOnly)

        // 2. Non-opt-in game (supportsIOS == false) -> toggle hidden, BC switch stays visible.
        build.setSeenShadersForGallery(SeenShadersInfo(seenCount: 100, totalCount: 5000, supportsIOS: false))
        host()
        XCTAssertNotNil(pad.frame(of: "set.build.bc"))
        XCTAssertNil(pad.frame(of: "set.build.iosSeenShaders"))

        // 3. Switch to Mac -> hides both iOS switches.
        build.setSeenShadersForGallery(SeenShadersInfo(seenCount: 8163, totalCount: 131427, supportsIOS: true))
        build.target = BuildTarget.mac
        host()
        XCTAssertNil(pad.frame(of: "set.build.bc"))
        XCTAssertNil(pad.frame(of: "set.build.iosSeenShaders"))
    }

    func testExecutionGuardIsolatesOptInTitleIDInMixedQueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-seen-guard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        SeenShadersProfile.clearCacheForTesting()
        let repo = try makeFakeEngineRepo(root: root)

        let stores = LauncherStores(defaults: testDefaults)
        stores.repo.path = repo.path
        let build = stores.build
        build.buildUpstream = .nxnative
        build.target = BuildTarget.ios

        // Default off -> never passes --seen-shaders
        XCTAssertFalse(build.iosSeenShadersOnly)
        XCTAssertFalse(build.shouldPassIOSSeenShaders(forTitleID: "0400A3A01EE4C000"))

        // Turned on -> passes ONLY for opt-in Pokopia, NEVER for non-opt-in game
        build.iosSeenShadersOnly = true
        XCTAssertTrue(build.shouldPassIOSSeenShaders(forTitleID: "0400A3A01EE4C000"))
        XCTAssertFalse(build.shouldPassIOSSeenShaders(forTitleID: "0100111122220000"))
        XCTAssertFalse(build.shouldPassIOSSeenShaders(forTitleID: "0400A3A01EE4C000", requested: false))

        // Switch to Mac -> iOS opt-in guard returns false
        build.target = BuildTarget.mac
        XCTAssertFalse(build.shouldPassIOSSeenShaders(forTitleID: "0400A3A01EE4C000"))
    }

    func testQueueEligibilityRefreshesAsynchronouslyAndDrivesInstallCard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-seen-queue-async-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        SeenShadersProfile.clearCacheForTesting()
        let repo = try makeFakeEngineRepo(root: root)

        let stores = LauncherStores(defaults: testDefaults)
        stores.repo.path = repo.path
        let build = stores.build
        let queue = stores.queue
        build.buildUpstream = .nxnative
        build.target = BuildTarget.ios
        XCTAssertFalse(build.queueHasIOSSeenShadersEligible)

        func waitUntil(_ timeout: TimeInterval = 2.0, _ predicate: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !predicate() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return predicate()
        }

        // 1. Enqueue a non-opt-in iOS game -> remains false even after async probe settles.
        queue.enqueue([QueueEntry(
            titleID: "0100111122220000",
            name: "Other Game",
            target: BuildTarget.ios,
            inputs: [:],
            outputDirectory: root.path,
            engineID: "main"
        )])
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertFalse(build.queueHasIOSSeenShadersEligible)

        // 2. Enqueue Pokopia for iOS without pre-selecting it on the Build form -> async probe turns flag true.
        queue.enqueue([QueueEntry(
            titleID: "0400A3A01EE4C000",
            name: "Pokemon Pokopia",
            target: BuildTarget.ios,
            inputs: [:],
            outputDirectory: root.path,
            engineID: "main"
        )])
        XCTAssertTrue(waitUntil { build.queueHasIOSSeenShadersEligible })

        // 3. InstallCard(forQueue: true) renders the switch from pure in-memory state.
        let pad = PadFocus()
        let window = OffscreenWindow(size: .init(width: 820, height: 640))
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        window.contentView = NSHostingView(rootView: InstallCard(devices: stores.deviceStore, build: build, forQueue: true)
            .environmentObject(stores.localizer)
            .environmentObject(pad)
            .padScope("main", pad))
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotNil(pad.frame(of: "set.build.iosSeenShaders"))

        // 4. Cancelling queued entries immediately resets flag synchronously and invalidates generation.
        queue.cancelQueued()
        XCTAssertFalse(build.queueHasIOSSeenShadersEligible)

        // 5. Enqueue Pokopia for Mac only -> never marks iOS queue eligibility true.
        queue.enqueue([QueueEntry(
            titleID: "0400A3A01EE4C000",
            name: "Pokemon Pokopia",
            target: BuildTarget.mac,
            inputs: [:],
            outputDirectory: root.path,
            engineID: "main"
        )])
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertFalse(build.queueHasIOSSeenShadersEligible)
    }

    func testCaptureTargetCardBeforeAndAfterForVisualQA() throws {
        guard let dir = ProcessInfo.processInfo.environment["NX_IOS_SEEN_SHADERS_CAPTURE_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set NX_IOS_SEEN_SHADERS_CAPTURE_DIR to render Before/After visual QA screenshots")
        }
        let output = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)

        func capture(name: String, lang: Lang, info: SeenShadersInfo?, toggleOn: Bool) throws {
            let stores = LauncherStores(defaults: testDefaults)
            stores.localizer.lang = lang
            let build = stores.build
            build.buildUpstream = .nxnative
            build.target = BuildTarget.ios
            build.iosSeenShadersOnly = toggleOn
            build.setSeenShadersForGallery(info)
            let pad = PadFocus()

            let content = TargetCard(build: build)
                .padding(24)
                .frame(width: 760, alignment: .topLeading)
                .background(LauncherPalette.background)
                .environmentObject(stores.localizer)
                .environmentObject(pad)
                .padScope("main", pad)
                .preferredColorScheme(.dark)

            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: .darkAqua)
            let size = NSSize(width: 760, height: info?.supportsIOS == true ? 430 : 340)
            host.frame = NSRect(origin: .zero, size: size)
            let window = OffscreenWindow(size: size, styleMask: [.borderless])
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent(name))
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        let pokopia = SeenShadersInfo(seenCount: 8163, totalCount: 131427, supportsIOS: true)
        try capture(name: "ios_target_before_en.png", lang: .en, info: nil, toggleOn: false)
        try capture(name: "ios_target_after_en.png", lang: .en, info: pokopia, toggleOn: true)
        try capture(name: "ios_target_before_zh.png", lang: .zh, info: nil, toggleOn: false)
        try capture(name: "ios_target_after_zh.png", lang: .zh, info: pokopia, toggleOn: true)
    }
}
