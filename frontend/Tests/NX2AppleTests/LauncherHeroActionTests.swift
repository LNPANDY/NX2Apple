import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

final class LauncherHeroActionTests: IsolatedDefaultsTestCase {
    @MainActor func testLocalizedHeroActionsKeepTheirHeightAndSizeToContent() {
        for lang in Lang.all {
            for key in ["library.play", "library.setUpBuild", "library.addToBuildQueue", "library.queued", "library.building", "dev.open", "console.build"] {
                let title = String(format: L10n.string(key, lang), "iPhone 17 Pro Max")
                XCTAssertNotEqual(title, key, "\(lang) \(key)")
                let host = NSHostingView(rootView: LauncherHeroActionLabel(title: title, symbol: "play.fill"))
                XCTAssertEqual(host.fittingSize.height, 44, "\(lang) \(key)")
                XCTAssertGreaterThanOrEqual(host.fittingSize.width, 120, "\(lang) \(key)")
            }
        }
        let short = NSHostingView(rootView: LauncherHeroActionLabel(title: "Play", symbol: "play.fill"))
        let long = NSHostingView(rootView: LauncherHeroActionLabel(title: "Open on my iPhone 17 Pro Max", symbol: "iphone"))
        XCTAssertLessThan(short.fittingSize.width, long.fittingSize.width)
        XCTAssertLessThan(short.fittingSize.width, 200)
    }

    @MainActor func testLoadingDoesNotChangeHeroActionGeometry() {
        let idle = NSHostingView(rootView: LauncherHeroActionLabel(title: "Play", symbol: "play.fill"))
        let busy = NSHostingView(rootView: LauncherHeroActionLabel(title: "Play", symbol: "play.fill", loading: true))
        XCTAssertEqual(idle.fittingSize, busy.fittingSize)
    }

    @MainActor func testLibraryQueuesSelectedGameDuringAnotherBuildAndShowsQueuedStatus() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = LauncherStores(localizer: Localizer(.en), defaults: testDefaults)
        stores.dependencies.checked = true
        stores.repo.path = directory.path
        stores.build.running = true
        let library = GameLibrary(file: directory.appendingPathComponent("library.json"))
        var game = LibraryGame(titleID: "0100000000010000", name: "Queue test game")
        game.inputs["base"] = [directory.appendingPathComponent("game.nsp").path]
        library.upsert(game)
        library.selectedID = game.id

        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous ?? false, forAttribute: enhanced) }
        let window = OffscreenWindow(size: NSSize(width: 960, height: 680))
        let host = NSHostingView(rootView: LauncherView(stores: stores, library: library, performStartupChecks: false))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }

        func labels(press: String? = nil) -> Set<String> {
            var found: Set<String> = []
            var action: NSObject?
            func visit(_ node: NSObject) {
                for selector in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                    let method = NSSelectorFromString(selector)
                    if node.responds(to: method), let value = node.perform(method)?.takeUnretainedValue() as? String {
                        found.insert(value)
                        if value == press && node.responds(to: NSSelectorFromString("accessibilityPerformPress")) { action = node }
                    }
                }
                let children = NSSelectorFromString("accessibilityChildren")
                if node.responds(to: children), let next = node.perform(children)?.takeUnretainedValue() as? [NSObject] { next.forEach(visit) }
            }
            host.layoutSubtreeIfNeeded()
            visit(window)
            if press != nil { XCTAssertNotNil(action); _ = action?.perform(NSSelectorFromString("accessibilityPerformPress")) }
            return found
        }
        let add = stores.localizer.t("library.addToBuildQueue")
        let deadline = Date().addingTimeInterval(5)
        while !labels().contains(add) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(labels().contains(add))
        _ = labels(press: add)
        while !labels().contains(stores.localizer.t("library.queued")) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(stores.queue.queued.map(\.titleID), [game.titleID])
        XCTAssertTrue(labels().contains(stores.localizer.t("library.queued")))
        XCTAssertFalse(labels().contains(add))
        _ = labels(press: stores.localizer.t("library.queued"))   // a second press adds nothing
        XCTAssertEqual(stores.queue.queued.map(\.titleID), [game.titleID])
    }

    @MainActor func testExternallyStartedBuildWakesWaitingQueueOnFinish() {
        let stores = LauncherStores(localizer: Localizer(.en), defaults: testDefaults)
        var settled = false
        stores.settleFinishedBuild = { settled = true }
        stores.build.running = true
        stores.queue.enqueue([QueueEntry(titleID: "A", name: "A", target: BuildTarget.mac,
                                         inputs: ["base": ["/game.nsp"]], outputDirectory: "/out", engineID: "outdated")])
        XCTAssertEqual(stores.queue.queued.count, 1)
        stores.build.running = false
        let deadline = Date().addingTimeInterval(2)
        while stores.queue.entries.first?.status == .queued && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(stores.queue.entries.first?.status, .skipped)
        XCTAssertTrue(settled)
    }

    @MainActor func testStoppedExternalBuildPausesWaitingQueueInsteadOfStartingNext() {
        let stores = LauncherStores(localizer: Localizer(.en), defaults: testDefaults)
        var settled = false
        stores.settleFinishedBuild = { settled = true }
        stores.build.running = true
        stores.queue.enqueue([QueueEntry(titleID: "A", name: "A", target: BuildTarget.mac,
                                         inputs: ["base": ["/game.nsp"]], outputDirectory: "/out", engineID: "outdated")])
        stores.build.stop()
        stores.build.running = false
        let deadline = Date().addingTimeInterval(0.5)
        while !stores.queue.paused && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(stores.queue.paused)
        XCTAssertFalse(stores.queue.active)
        XCTAssertEqual(stores.queue.entries.first?.status, .queued)
        XCTAssertFalse(settled)
    }

    @MainActor func testHeroPrimaryDescriptorRespectsBuildingMissingSourcesDeviceAndQueueBoundaries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = LauncherStores(localizer: Localizer(.en), defaults: testDefaults)
        stores.dependencies.checked = true
        stores.repo.path = directory.path
        stores.build.running = true

        let library = GameLibrary(file: directory.appendingPathComponent("library.json"))
        var buildingGame = LibraryGame(titleID: "0100000000010000", name: "Building Game")
        buildingGame.inputs["base"] = [directory.appendingPathComponent("building.nsp").path]
        let missingSourceGame = LibraryGame(titleID: "0100000000020000", name: "Missing Source")
        var deviceGame = LibraryGame(titleID: "0100000000030000", name: "Device Game")
        let iosApp = directory.appendingPathComponent("DeviceGame.app")
        try FileManager.default.createDirectory(at: iosApp, withIntermediateDirectories: true)
        try Data().write(to: iosApp.appendingPathComponent("Info.plist"))
        deviceGame.iosAppPath = iosApp.path
        deviceGame.installedDevice = "DEV-1"
        deviceGame.inputs["base"] = [directory.appendingPathComponent("device.nsp").path]
        var switch2Game = LibraryGame(titleID: "04008E001F098000", name: "Switch 2 Game")
        switch2Game.inputs[GameLibrary.folderInput] = [directory.appendingPathComponent("s2folder").path]

        library.upsert(buildingGame)
        library.upsert(missingSourceGame)
        library.upsert(deviceGame)
        library.upsert(switch2Game)
        library.selectedID = buildingGame.id

        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous ?? false, forAttribute: enhanced) }

        let window = OffscreenWindow(size: NSSize(width: 960, height: 680))
        let host = NSHostingView(rootView: LauncherView(stores: stores, library: library, activeBuildID: buildingGame.id, performStartupChecks: false))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }

        func heroButton(named title: String) -> (found: Bool, enabled: Bool, node: NSObject?) {
            var matched: NSObject?
            func visit(_ node: NSObject) {
                for selector in ["accessibilityLabel", "accessibilityTitle"] {
                    let method = NSSelectorFromString(selector)
                    if node.responds(to: method),
                       let value = node.perform(method)?.takeUnretainedValue() as? String,
                       value == title,
                       node.responds(to: NSSelectorFromString("accessibilityPerformPress")) {
                        matched = node
                        return
                    }
                }
                let children = NSSelectorFromString("accessibilityChildren")
                if node.responds(to: children), let next = node.perform(children)?.takeUnretainedValue() as? [NSObject] {
                    for child in next where matched == nil { visit(child) }
                }
            }
            host.layoutSubtreeIfNeeded()
            visit(window)
            guard let matched else { return (false, false, nil) }
            let enabledSel = NSSelectorFromString("isAccessibilityEnabled")
            let enabledValue: Bool
            if matched.responds(to: enabledSel) {
                typealias BoolGetter = @convention(c) (AnyObject, Selector) -> ObjCBool
                let imp = matched.method(for: enabledSel)
                enabledValue = unsafeBitCast(imp, to: BoolGetter.self)(matched, enabledSel).boolValue
            } else {
                enabledValue = true
            }
            return (true, enabledValue, matched)
        }

        func waitForHeroButton(_ title: String) -> (found: Bool, enabled: Bool, node: NSObject?) {
            let deadline = Date().addingTimeInterval(3)
            var state = heroButton(named: title)
            while !state.found && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                state = heroButton(named: title)
            }
            return state
        }

        // 1. The game currently being built stays disabled and shows Building, never Add to build queue.
        let buildingTitle = stores.localizer.t("library.building")
        let buildingButton = waitForHeroButton(buildingTitle)
        XCTAssertTrue(buildingButton.found)
        XCTAssertFalse(buildingButton.enabled)
        _ = buildingButton.node?.perform(NSSelectorFromString("accessibilityPerformPress"))
        XCTAssertFalse(heroButton(named: stores.localizer.t("library.addToBuildQueue")).found)
        XCTAssertTrue(stores.queue.entries.isEmpty)

        // 2. An unbuilt game missing source inputs stays disabled and cannot be queued.
        library.selectedID = missingSourceGame.id
        let missingButton = waitForHeroButton(stores.localizer.t("library.setUpBuild"))
        XCTAssertTrue(missingButton.found)
        XCTAssertFalse(missingButton.enabled)
        _ = missingButton.node?.perform(NSSelectorFromString("accessibilityPerformPress"))
        XCTAssertFalse(heroButton(named: stores.localizer.t("library.addToBuildQueue")).found)
        XCTAssertTrue(stores.queue.entries.isEmpty)

        // 3. A game installed on a paired device keeps Open on device enabled even if another build runs or it is queued.
        stores.queue.enqueue([QueueEntry(game: deviceGame, engineID: stores.engineSync.selection.engineID, target: BuildTarget.ios)])
        library.selectedID = deviceGame.id
        let openTitle = String(format: stores.localizer.t("dev.open"), stores.deviceStore.deviceName(deviceGame.installedDevice))
        let deviceButton = waitForHeroButton(openTitle)
        XCTAssertTrue(deviceButton.found)
        XCTAssertTrue(deviceButton.enabled)

        // 4. Another game with folder/NUP sources under framework export mode carries framework flags when queued.
        stores.build.target = BuildTarget.ios
        stores.deviceStore.exportIPA = true
        stores.deviceStore.exportOneGame = false
        stores.deviceStore.exportFramework = true
        library.selectedID = switch2Game.id
        let addTitle = stores.localizer.t("library.addToBuildQueue")
        let s2Button = waitForHeroButton(addTitle)
        XCTAssertTrue(s2Button.found)
        XCTAssertTrue(s2Button.enabled)
        _ = s2Button.node?.perform(NSSelectorFromString("accessibilityPerformPress"))
        let queuedTitle = stores.localizer.t("library.queued")
        let s2QueuedButton = waitForHeroButton(queuedTitle)
        XCTAssertTrue(s2QueuedButton.found)
        XCTAssertFalse(s2QueuedButton.enabled)
        let queuedS2 = try XCTUnwrap(stores.queue.entries.first { $0.titleID == switch2Game.titleID })
        XCTAssertEqual(queuedS2.target, BuildTarget.ios)
        XCTAssertEqual(queuedS2.exportIPA, true)
        XCTAssertEqual(queuedS2.exportFramework, true)
        XCTAssertFalse(queuedS2.packageAfter)

        // 5. Case-insensitive titleID deduplication prevents a second queue entry.
        let lowerDesc = LauncherView.heroPrimaryDescriptor(
            for: { var g = switch2Game; g.titleID = switch2Game.titleID.lowercased(); return g }(),
            macStarting: false,
            launching: false,
            running: true,
            isBuilding: false,
            isQueued: stores.queue.queued.contains { $0.titleID.caseInsensitiveCompare(switch2Game.titleID) == .orderedSame },
            canEnqueue: stores.queue.canEnqueue(switch2Game.titleID.lowercased(), target: BuildTarget.ios),
            deviceName: "",
            t: stores.localizer.t
        )
        XCTAssertFalse(lowerDesc.enabled)
        XCTAssertEqual(lowerDesc.title, queuedTitle)

        stores.queue.cancelQueued()
        stores.build.running = false
    }
}
