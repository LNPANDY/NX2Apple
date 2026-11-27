import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

@MainActor final class KidWithSwordSeparateRomfsUITests: IsolatedDefaultsTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kws-sep-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testGameDeletionIncludesSeparateRomfsFolderForKidWithSword() throws {
        let tid = EngineUpstreamKind.ootSwitch2TitleID
        let outDir = root.appendingPathComponent("out", isDirectory: true)
        let ipaURL = outDir.appendingPathComponent("\(tid)-kidwithsword.ipa")
        let romfsDir = outDir.appendingPathComponent("\(tid)-kidwithsword-romfs", isDirectory: true)
        let romfsImg = romfsDir.appendingPathComponent("romfs.img")
        try FileManager.default.createDirectory(at: romfsDir, withIntermediateDirectories: true)
        try Data("ipa".utf8).write(to: ipaURL)
        try Data("DMROMFS1".utf8).write(to: romfsImg)

        var game = LibraryGame(titleID: tid, name: "Ocarina of Time")
        game.ipaPath = ipaURL.path
        game.ipaBuilds[EngineUpstreamKind.kidWithSword.rawValue] = ipaURL.path

        let scopedPlan = GameDeletion.plan(for: game, shellRoot: "", upstream: .kidWithSword, home: root.path)
        XCTAssertTrue(scopedPlan.items.contains { $0.kind == .ipa && $0.paths == [ipaURL.path] })
        XCTAssertTrue(scopedPlan.items.contains { $0.kind == .archive && $0.paths.contains(romfsDir.path) })

        let fullPlan = GameDeletion.plan(for: game, shellRoot: "", upstream: nil, home: root.path)
        XCTAssertTrue(fullPlan.items.contains { $0.kind == .ipa && $0.paths == [ipaURL.path] })
        XCTAssertTrue(fullPlan.items.contains { $0.kind == .archive && $0.paths.contains(romfsDir.path) })
    }

    func testRenderKidWithSwordSeparateRomfsInstallAndOutcomeViews() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let kwsTree = root.appendingPathComponent("kws-tree", isDirectory: true)
        try FileManager.default.createDirectory(at: kwsTree.appendingPathComponent("dm/tools/nx_extract"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: kwsTree.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("// cs\n".utf8).write(to: kwsTree.appendingPathComponent("dm/tools/nx_extract/Program.cs"))
        try Data("# '--romfs' ('bundle', 'separate')\n".utf8).write(to: kwsTree.appendingPathComponent("scripts/build_ipa_from_nsp.py"))

        let outDir = root.appendingPathComponent("Builds", isDirectory: true)
        let ipaURL = outDir.appendingPathComponent("0400486024DEC000-kidwithsword.ipa")
        let romfsURL = outDir.appendingPathComponent("0400486024DEC000-kidwithsword-romfs/romfs.img")
        try FileManager.default.createDirectory(at: romfsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 4096).write(to: ipaURL)
        try Data("DMROMFS1fixture".utf8).write(to: romfsURL)

        NSApplication.shared.setActivationPolicy(.accessory)

        for lang in [Lang.en, Lang.zh] {
            let stores = LauncherStores(defaults: testDefaults)
            stores.localizer.lang = lang
            let build = stores.build
            build.kidWithSwordPath = kwsTree.path
            build.target = BuildTarget.ios
            build.buildUpstream = .kidWithSword
            build.kwsSeparateRomfs = true

            // 1. Pre-build InstallCard showing default-on Separate romfs.img toggle and 3-step export flow.
            try capture(
                InstallCard(devices: stores.deviceStore, build: build)
                    .environmentObject(stores.localizer)
                    .environmentObject(PadFocus())
                    .padding(24)
                    .frame(width: 780)
                    .background(LauncherPalette.background)
                    .environment(\.colorScheme, .dark),
                to: output.appendingPathComponent("kws-separate-install-\(lang.code).png")
            )

            // 2. Post-build OutcomeCard + ExportSteps(resultOnly: true) showing IPA + external romfs.img files and Step 3 copy guidance.
            build.runningTarget = BuildTarget.ios
            build.oneGameIPAPath = ipaURL.path
            build.exportedIPAPath = ipaURL.path
            build.externalRomfsImagePath = romfsURL.path
            build.completedOneGameSeparateRomfs = true
            build.done = true

            try capture(
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    OutcomeCard(build: build, devices: stores.deviceStore, onViewGame: {})
                    CardGroup(stores.localizer.t("result.next")) {
                        ExportSteps(build: build, devices: stores.deviceStore, resultOnly: true)
                    }
                }
                .environmentObject(stores.localizer)
                .environmentObject(PadFocus())
                .padding(24)
                .frame(width: 780)
                .background(LauncherPalette.background)
                .environment(\.colorScheme, .dark),
                to: output.appendingPathComponent("kws-separate-outcome-\(lang.code).png")
            )
        }
    }

    private func capture<V: View>(_ view: V, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(LauncherPalette.background).cgColor
        let window = OffscreenWindow(size: host.frame.size)
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        window.orderOut(nil)
    }
}
