import CoreText
import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

/// The hero's cream button has one size (LauncherHeroAction) whatever the game's state and the language.
final class LauncherHeroActionTests: IsolatedDefaultsTestCase {
    private let languages = Lang.all

    private func width(_ text: String) throws -> CGFloat {
        let font = try XCTUnwrap(Typography.manropeFont(size: 18, weight: .bold))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    func testPlayAndBuildFitOnOneLineInEveryLanguage() throws {
        for key in ["library.play", "library.setUpBuild"] {
            for lang in languages {
                let text = L10n.string(key, lang)
                XCTAssertNotEqual(text, key)
                if key == "library.setUpBuild" {
                    XCTAssertNotEqual(text, L10n.string("library.newBuild", lang))
                }
                XCTAssertLessThanOrEqual(try width(text), LauncherHeroAction.labelWidth, "\(lang) \(key): \(text)")
            }
        }
    }

    func testAddToBuildQueueFitsAfterShrinkingInEveryLanguage() throws {
        for lang in languages {
            let text = L10n.string("library.addToBuildQueue", lang)
            XCTAssertNotEqual(text, "library.addToBuildQueue")
            XCTAssertLessThanOrEqual(try width(text) * LauncherHeroAction.minimumScale, LauncherHeroAction.labelWidth,
                                     "\(lang) \(text)")
        }
    }

    func testOpenOnDeviceFitsAfterShrinkingForADeviceName() throws {
        for lang in languages {
            let text = String(format: L10n.string("dev.open", lang), "iPhone")
            XCTAssertLessThanOrEqual(try width(text) * LauncherHeroAction.minimumScale, LauncherHeroAction.labelWidth, "\(lang): \(text)")
        }
    }

    @MainActor func testEveryStateHasTheSameSize() throws {
        let states: [(String, String)] = [("play.fill", "library.play"), ("hammer.fill", "library.setUpBuild"),
                                           ("hammer.fill", "library.addToBuildQueue"), ("iphone", "dev.open")]
        for lang in languages {
            var sizes = Set<String>()
            for (symbol, key) in states {
                let title = String(format: L10n.string(key, lang), "iPhone 17 Pro Max of a very long name")
                let size = NSHostingView(rootView: LauncherHeroActionLabel(title: title, symbol: symbol)).fittingSize
                XCTAssertEqual(size.width, LauncherHeroAction.width, "\(lang) \(key)")
                XCTAssertEqual(size.height, LauncherHeroAction.height, "\(lang) \(key)")
                sizes.insert("\(size.width)x\(size.height)")
            }
            XCTAssertEqual(sizes.count, 1, "\(lang): \(sizes)")
        }
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
        var rebuildGame = LibraryGame(titleID: "0100000000020000", name: "Rebuild test game")
        rebuildGame.inputs["base"] = [directory.appendingPathComponent("rebuild.nsp").path]
        library.upsert(rebuildGame)
        library.selectedID = game.id

        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous ?? false, forAttribute: enhanced) }
        let window = OffscreenWindow(size: NSSize(width: 960, height: 680))
        let host = NSHostingView(rootView: LauncherView(stores: stores, library: library, performStartupChecks: false,
                                                       olderTools: [rebuildGame.id]))
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
        library.selectedID = rebuildGame.id
        let rebuild = stores.localizer.t("library.rebuildShort")
        while !labels().contains(rebuild) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(labels().contains(rebuild))
        _ = labels(press: rebuild)
        XCTAssertEqual(stores.queue.queued.map(\.titleID), [game.titleID, rebuildGame.titleID])
        XCTAssertTrue(labels().contains(stores.localizer.t("library.queued")))
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
}
