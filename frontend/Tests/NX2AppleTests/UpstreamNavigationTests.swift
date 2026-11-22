import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

private struct OfflineUpstreamTransport: EngineTransport {
    func data(from url: URL) -> EngineFetch<Data> { .failed }
    func download(from url: URL, to destination: URL) -> Bool { false }
}

@MainActor final class UpstreamNavigationTests: IsolatedDefaultsTestCase {
    func testEngineCardsSettingsChoicesAndMacOnlyTargetKeepControllerNavigation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldMNG = MacNativeGamesBuilder.featureEnabled, oldS2 = S2ArmBuilder.featureEnabled
        MacNativeGamesBuilder.featureEnabled = true; S2ArmBuilder.featureEnabled = true
        defer { MacNativeGamesBuilder.featureEnabled = oldMNG; S2ArmBuilder.featureEnabled = oldS2 }
        let stores = LauncherStores(defaults: testDefaults), pad = PadFocus()
        let build = stores.build
        build.upstreamTransport = OfflineUpstreamTransport()
        build.upstreamChanged = {}
        let dropdowns = LauncherDropdownState()
        build.macNativeGamesPath = ""; build.s2armPath = ""; build.buildUpstream = .nxnative
        let window = OffscreenWindow(size: .init(width: 900, height: 500))
        defer { build.running = false; window.contentView = nil; window.orderOut(nil); window.close() }
        func host<V: View>(_ view: V) {
            window.contentView = NSHostingView(rootView: view.environmentObject(stores.localizer)
                .environmentObject(pad).padScope("main", pad).launcherDropdownHost(dropdowns, pad: pad))
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        host(EngineSwitcherCard(build: build))
        pad.show(default: "set.build.engine"); pad.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(pad.scope, "engineDropdown")
        for id in ["nxnative", "download.macnativegames", "download.s2arm"] {
            XCTAssertNotNil(pad.frame(of: "set.build.engine." + id))
        }
        let current = try XCTUnwrap(pad.frame(of: "set.build.engine.nxnative"))
        for id in ["macnativegames", "s2arm"] {
            let download = try XCTUnwrap(pad.frame(of: "set.build.engine.download." + id))
            XCTAssertLessThan(download.maxY - current.minY, 260, "Engine dropdown rows must remain compact")
        }
        XCTAssertTrue(PadKeyboardInput.handle(125, focus: pad, back: dropdowns.close))
        XCTAssertEqual(pad.focused, "set.build.engine.download.macnativegames")
        pad.move(dx: 0, dy: -1)
        XCTAssertEqual(pad.focused, "set.build.engine.nxnative")
        dropdowns.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(pad.scope, "main")
        build.running = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(pad.frames["main", default: []].contains { $0.id.hasPrefix("set.build.engine.") })
        build.running = false
        for kind in [EngineUpstreamKind.macNativeGames, .s2arm] {
            let directory = root.appendingPathComponent(kind.rawValue)
            let markers = EngineUpstream.descriptor(for: kind).markerPaths + (kind == .s2arm ? [S2ArmBuilder.macOneClickScript] : [])
            for marker in markers {
                let file = directory.appendingPathComponent(marker)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: file)
            }
            if kind == .macNativeGames { build.macNativeGamesPath = directory.path }
            else { build.s2armPath = directory.path }
        }
        host(EngineSwitcherCard(build: build))
        pad.show(default: "set.build.engine"); pad.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        pad.focused = "set.build.engine.macnativegames"; pad.activate()
        XCTAssertEqual(build.buildUpstream, .macNativeGames)
        XCTAssertEqual(build.target, BuildTarget.mac)
        host(TargetCard(build: build))
        XCTAssertNotNil(pad.frame(of: "set.build.target." + BuildTarget.mac))
        XCTAssertNil(pad.frame(of: "set.build.target.ios"))
        host(VStack { UpstreamPicker(build: build); UpstreamBuilderRow(build: build) })
        for id in ["set.upstream", "set.upstream.mngFolder", "set.upstream.s2armFolder"] {
            XCTAssertNotNil(pad.frame(of: id))
        }
        pad.focused = "set.upstream"; pad.horizontal(1)
        XCTAssertEqual(build.buildUpstream, .s2arm)
    }

    func testEngineDropdownScrollsCleanlyInShortWindow() throws {
        let oldMNG = MacNativeGamesBuilder.featureEnabled, oldS2 = S2ArmBuilder.featureEnabled
        MacNativeGamesBuilder.featureEnabled = true; S2ArmBuilder.featureEnabled = true
        defer { MacNativeGamesBuilder.featureEnabled = oldMNG; S2ArmBuilder.featureEnabled = oldS2 }
        let stores = LauncherStores(defaults: testDefaults), pad = PadFocus()
        stores.build.upstreamTransport = OfflineUpstreamTransport()
        let dropdowns = LauncherDropdownState()
        let window = OffscreenWindow(size: .init(width: 900, height: 240))
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        window.contentView = NSHostingView(rootView: EngineSwitcherCard(build: stores.build)
            .environmentObject(stores.localizer)
            .environmentObject(pad)
            .padScope("main", pad)
            .launcherDropdownHost(dropdowns, pad: pad))
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        pad.show(default: "set.build.engine"); pad.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(pad.scope, "engineDropdown")
        XCTAssertNotNil(pad.frame(of: "set.build.engine.nxnative"))
        dropdowns.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(pad.scope, "main")
    }

    func testUnsupportedGameDisablesMNGDropdownAndSupportedGameShowsRecommendation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("upstream-nav-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldMNG = MacNativeGamesBuilder.featureEnabled
        let oldS2 = S2ArmBuilder.featureEnabled
        MacNativeGamesBuilder.featureEnabled = true
        S2ArmBuilder.featureEnabled = true
        defer {
            MacNativeGamesBuilder.featureEnabled = oldMNG
            S2ArmBuilder.featureEnabled = oldS2
        }

        let stores = LauncherStores(defaults: testDefaults), pad = PadFocus()
        let build = stores.build
        build.upstreamTransport = OfflineUpstreamTransport()
        build.upstreamChanged = {}
        let mngDir = root.appendingPathComponent("mng")
        try FileManager.default.createDirectory(at: mngDir.appendingPathComponent("games/totk"), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8).write(to: mngDir.appendingPathComponent("build_app.py"))
        build.macNativeGamesPath = mngDir.path

        let nonMngFile = root.appendingPathComponent("MarioKart [0100152000022000].nsp")
        let nonMngUntaggedFile = root.appendingPathComponent("MarioKart.nsp")
        let totkFile = root.appendingPathComponent("TOTK [0100F2C0115B6000].nsp")
        try Data([0]).write(to: nonMngFile)
        try Data([0]).write(to: nonMngUntaggedFile)
        try Data([0]).write(to: totkFile)

        // 1. Supported game on nxnative shows recommendation button; tapping switches to MacNativeGames + Mac target.
        build.target = BuildTarget.ios
        build.buildUpstream = .nxnative
        build.updateSlot("base") { $0.paths = [totkFile.path] }
        let dropdowns = LauncherDropdownState()
        let window = OffscreenWindow(size: .init(width: 900, height: 500))
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        window.contentView = NSHostingView(rootView: EngineSwitcherCard(build: build)
            .environmentObject(stores.localizer)
            .environmentObject(pad)
            .padScope("main", pad)
            .launcherDropdownHost(dropdowns, pad: pad))
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotNil(pad.frame(of: "set.build.mngRecommend"))

        pad.focused = "set.build.mngRecommend"
        pad.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(build.buildUpstream, .macNativeGames)
        XCTAssertEqual(build.target, BuildTarget.mac)
        XCTAssertNil(pad.frame(of: "set.build.mngRecommend"))

        // 2. Switching to a non-12 game reverts to nxnative, disables MacNativeGames inside dropdown, and keyboard arrow skips it.
        build.updateSlot("base") { $0.paths = [nonMngFile.path] }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(build.buildUpstream, .nxnative)
        pad.show(default: "set.build.engine")
        pad.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(pad.scope, "engineDropdown")
        XCTAssertNil(pad.frame(of: "set.build.engine.macnativegames"), "Disabled MacNativeGames row must not register active padTarget")
        XCTAssertTrue(PadKeyboardInput.handle(125, focus: pad, back: dropdowns.close))
        XCTAssertEqual(pad.focused, "set.build.engine.download.s2arm", "Down arrow must skip disabled MacNativeGames row")
        if build.nxkitSelectable {
            XCTAssertTrue(PadKeyboardInput.handle(125, focus: pad, back: dropdowns.close))
            XCTAssertEqual(pad.focused, "set.build.engine.nxkit")
        }
        XCTAssertTrue(PadKeyboardInput.handle(125, focus: pad, back: dropdowns.close))
        XCTAssertEqual(pad.focused, "set.build.engine.nxnative")
        dropdowns.close()

        // 2b. Library game without [TitleID] in filename still reverts MNG and blocks it in Builds.
        build.buildUpstream = .macNativeGames
        let untaggedGame = LibraryGame(
            titleID: "0100152000022000",
            name: "Mario Kart 8 Deluxe",
            lastTarget: BuildTarget.ios,
            inputs: ["base": [nonMngUntaggedFile.path]]
        )
        let library = GameLibrary(file: root.appendingPathComponent("library.json"))
        library.upsert(untaggedGame)
        library.selectedID = library.games.first?.id
        let launcherHost = NSHostingView(rootView: LauncherView(
            stores: stores,
            library: library,
            initialPage: .library,
            performStartupChecks: false,
            controls: ControlLayout(defaults: testDefaults),
            gamepad: LauncherGamepad(steam: nil, observeSystem: false),
            padFocus: pad
        ).defaultAppStorage(testDefaults))
        window.contentView = launcherHost
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        build.leaveGameFolder()
        build.updateSlot("base") { $0.paths = [nonMngUntaggedFile.path] }
        build.applyKnownTitleID(untaggedGame.titleID)
        build.target = build.isMacNativeGamesSelected ? BuildTarget.mac : untaggedGame.lastTarget
        XCTAssertEqual(build.buildUpstream, .nxnative)
        XCTAssertEqual(build.target, BuildTarget.ios)
        XCTAssertTrue(build.isMNGBlockedByCurrentGame)
        XCTAssertEqual(build.detectedGameTitleID16, "0100152000022000")

        // 3. SupportedGamesSheet search matches "MacNativeGames" and "MNG" for all 12 titles.
        let full = SupportedGames.list(engineRoot: root.path, includeMacNativeGames: true)
            + [SupportedGame(titleID: "0100152000022000", name: "Mario Kart 8 Deluxe", edition: .switch1, version: "3.0.3", notes: "")]
        let mngHits = full.filter { SupportedGamesSheet.matchesSearch($0, needle: "MacNativeGames", ownedName: "") }
        let shortHits = full.filter { SupportedGamesSheet.matchesSearch($0, needle: "mng", ownedName: "") }
        XCTAssertEqual(Set(mngHits.map(\.titleID)), MacNativeGamesBuilder.supportedTitleIDs)
        XCTAssertEqual(Set(shortHits.map(\.titleID)), MacNativeGamesBuilder.supportedTitleIDs)
        XCTAssertEqual(mngHits.count, 12)

        // 4. LibraryArtworkState carries MNG upstream flag for built MNG bundles only.
        let mngApp = root.appendingPathComponent("TOTK.app")
        try FileManager.default.createDirectory(at: mngApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: mngApp.appendingPathComponent("Contents/MacOS/totk"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let plist: [String: Any] = [
            "DMTitleID": "0100F2C0115B6000",
            "DMUpstream": "macnativegames",
            "CFBundleExecutable": "totk",
            "CFBundleIdentifier": "org.macnativegames.totk",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: mngApp.appendingPathComponent("Contents/Info.plist"))
        var libGame = LibraryGame(titleID: "0100F2C0115B6000", name: "TOTK")
        libGame.appPath = mngApp.path
        XCTAssertTrue(LibraryArtworkState(libGame).isMacNativeGames)
        XCTAssertFalse(LibraryArtworkState(LibraryGame(titleID: "0100152000022000", name: "Mario Kart 8 Deluxe")).isMacNativeGames)
    }

    func testEngineDropdownIncludesNxkitWhenSelectableAndBuildPageUsesTopSwitcher() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("upstream-nxkit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldNxkit = NxkitBuilder.featureEnabled
        NxkitBuilder.featureEnabled = true
        defer { NxkitBuilder.featureEnabled = oldNxkit }

        let pair = root.appendingPathComponent("nxbuild", isDirectory: true)
        try FileManager.default.createDirectory(at: pair, withIntermediateDirectories: true)
        for name in ["nxb", "nxkit-host"] {
            FileManager.default.createFile(
                atPath: pair.appendingPathComponent(name).path,
                contents: Data("#!/bin/sh\nexit 1\n".utf8),
                attributes: [.posixPermissions: 0o755]
            )
        }
        try Data(#"{"format":1,"version":"0.10.3","platform":"macos","arch":"arm64","macos_min":"26.0","files":{"nxb":"a","nxkit-host":"b"}}"#.utf8)
            .write(to: pair.appendingPathComponent("MANIFEST.json"))

        let stores = LauncherStores(defaults: testDefaults), pad = PadFocus(), dropdowns = LauncherDropdownState()
        let build = stores.build
        build.upstreamTransport = OfflineUpstreamTransport()
        build.upstreamChanged = {}
        build.nxkitBundledFolder = pair.path
        build.nxkitVersions = NxkitVersionStore(root: root.appendingPathComponent("nxkit-versions", isDirectory: true))
        build.nxkitAvailability = .available
        build.nxkitAutoUpdate = { false }
        build.refreshNxkit()

        XCTAssertTrue(build.nxkitSelectable)
        XCTAssertEqual(build.upstreamVersionBadge(.nxkit), "0.10.3")

        let totkFile = root.appendingPathComponent("TOTK [0100F2C0115B6000].nsp")
        try Data([0]).write(to: totkFile)
        build.target = BuildTarget.ios
        build.buildUpstream = .nxnative
        build.updateSlot("base") { $0.paths = [totkFile.path] }

        let marker = root.appendingPathComponent(EngineLayout.marker)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        stores.repo.path = root.path
        let library = GameLibrary(file: root.appendingPathComponent("library.json"))
        let window = OffscreenWindow(size: .init(width: 1100, height: 1400))
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        let host = NSHostingView(rootView: LauncherView(
            stores: stores,
            library: library,
            initialPage: .builds,
            performStartupChecks: false,
            controls: ControlLayout(defaults: testDefaults),
            gamepad: LauncherGamepad(steam: nil, observeSystem: false),
            padFocus: pad,
            dropdowns: dropdowns
        ).defaultAppStorage(testDefaults))
        window.contentView = host
        window.orderFront(nil)
        func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return condition()
        }
        XCTAssertTrue(waitUntil { Set(pad.frames["main", default: []].map(\.id)).contains("set.build.engine") },
                      "Builds page must show top EngineSwitcherCard")
        XCTAssertFalse(Set(pad.frames["main", default: []].map(\.id)).contains("set.build.nxkitFeedback"),
                       "Send feedback shows only with nxkit (Beta) chosen")

        let mainIDs = Set(pad.frames["main", default: []].map(\.id))
        XCTAssertFalse(mainIDs.contains("set.build.engine.change"), "Builds page must not show duplicate EngineFootnote")
        XCTAssertEqual(pad.frames["main", default: []].filter { $0.id == "set.build.mngRecommend" }.count, 1,
                       "Only the EngineSwitcherCard MNG recommendation bar should be registered")

        pad.show(default: "set.build.engine")
        pad.activate()
        XCTAssertTrue(waitUntil { pad.scope == "engineDropdown" && pad.frame(of: "set.build.engine.nxkit") != nil },
                      "Engine dropdown must list nxkit (Beta) when selectable")

        pad.focused = "set.build.engine.nxkit"
        pad.activate()
        XCTAssertTrue(waitUntil { build.buildUpstream == .nxkit && build.target == BuildTarget.mac },
                      "Selecting nxkit from the dropdown must switch upstream and target Mac")
        XCTAssertTrue(waitUntil { pad.scope == "main" && pad.frame(of: "set.build.nxkitFeedback") != nil },
                      "With nxkit (Beta) chosen the switcher card offers Send feedback")
        let feedback = build.nxkitSendFeedbackURL.absoluteString
        XCTAssertTrue(feedback.hasPrefix(NxkitFeedback.newIssueURL + "?template=game_report.yml"), feedback)
        XCTAssertTrue(feedback.contains("nxkit_version=0.10.3"), feedback)
    }

    /// #1498 review: the Experimental badge is nxkit's alone, and the nxkit row has no "Switch" label.
    func testOnlyNxkitIsExperimentalAndHasNoSwitchLabel() {
        for kind in EngineUpstreamKind.allCases {
            XCTAssertEqual(EngineDropdownPanel.showsExperimentalBadge(kind), kind == .nxkit, kind.rawValue)
            XCTAssertEqual(EngineDropdownPanel.showsSwitchLabel(kind), kind != .nxkit, kind.rawValue)
        }
        XCTAssertFalse(EngineDropdownPanel.showsExperimentalBadge(.macNativeGames), "MacNativeGames is not marked Experimental")
    }
}
