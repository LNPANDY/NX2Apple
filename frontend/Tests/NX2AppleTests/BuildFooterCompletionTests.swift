import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

@MainActor final class BuildFooterCompletionTests: IsolatedDefaultsTestCase {
    func testCompletionDeadlineSurvivesHidingAndResetsForNewWork() async throws {
        let timer = BuildCompletionDismissal()
        let first = Task { await timer.monitor("first", duration: 0.08) }
        try await Task.sleep(for: .milliseconds(20))
        let startedAt = try XCTUnwrap(timer.startedAt)
        first.cancel()
        await first.value
        XCTAssertFalse(timer.expired)
        try await Task.sleep(for: .milliseconds(80))
        await timer.monitor("first", duration: 0.08)
        XCTAssertEqual(timer.startedAt, startedAt)
        XCTAssertTrue(timer.expired)
        await timer.monitor(nil)
        XCTAssertNil(timer.startedAt)
        XCTAssertFalse(timer.expired)
        await timer.monitor("next", duration: 0)
        XCTAssertNotEqual(timer.startedAt, startedAt)
        XCTAssertTrue(timer.expired)
        XCTAssertEqual(BuildCompletionDismissal.duration, 10)
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

    private func withFooter(waiting: Bool = false, playEnabled: Bool = true,
        check: (LauncherStores, PadFocus, () -> (Int, Int, Int)) -> Void) {
        let stores = LauncherStores(defaults: testDefaults)
        stores.build.runningTarget = BuildTarget.mac
        stores.build.macAppPath = "/fixture/Game.app"; stores.build.done = true
        if waiting { stores.queue.enqueue([QueueEntry(game: LibraryGame(titleID: "0100000000000000", name: "Next"), engineID: "")]) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = GameLibrary(file: root.appendingPathComponent("library.json"))
        let focus = PadFocus()
        var opens = 0, plays = 0, dismisses = 0
        let view = BuildActivityFooter(build: stores.build, library: library, queue: stores.queue, repo: "", fetchMetadata: false,
            onOpen: { opens += 1 }, onPlay: { plays += 1 }, playEnabled: playEnabled, onDismiss: { dismisses += 1 })
            .environmentObject(stores.localizer).environmentObject(focus).padScope("main", focus)
        let window = OffscreenWindow(size: .init(width: 900, height: 96))
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil); settle()
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        check(stores, focus, { (opens, plays, dismisses) })
    }

    private func activate(_ id: String, focus: PadFocus) {
        focus.focused = nil; focus.show(default: id)
        XCTAssertEqual(focus.focused, id); focus.activate(); settle()
    }

    func testPlayDismissesWhenQueueIsEmptyAndControlsHaveSeparateTargets() {
        withFooter { _, focus, counts in
            let frames = Dictionary(uniqueKeysWithValues: focus.frames["main", default: []].map { ($0.id, $0.frame) })
            XCTAssertEqual(frames["build.activity"]?.height ?? 0, 96, accuracy: 1)
            XCTAssertEqual(frames["build.activity.dismiss"]?.width ?? 0, frames["build.activity.dismiss"]?.height ?? 1, accuracy: 1)
            XCTAssertEqual(frames["build.activity.play"]?.height ?? 0, frames["build.activity.dismiss"]?.height ?? 1, accuracy: 1)
            activate("build.activity.play", focus: focus)
            XCTAssertEqual(counts().0, 0)
            XCTAssertEqual(counts().1, 1)
            XCTAssertEqual(counts().2, 1)
        }
    }

    func testPlayKeepsFooterForWaitingWorkAndCloseDoesNotCancelQueue() {
        withFooter(waiting: true) { stores, focus, counts in
            activate("build.activity.play", focus: focus)
            XCTAssertEqual(counts().1, 1); XCTAssertEqual(counts().2, 0)
            activate("build.activity.dismiss", focus: focus)
            XCTAssertEqual(counts().2, 1)
            XCTAssertEqual(stores.queue.queued.count, 1)
            XCTAssertTrue(stores.build.done)
        }
    }

    func testCompletedMetadataOpensResultAndDisabledPlayCannotActivate() {
        withFooter(playEnabled: false) { stores, focus, counts in
            activate("build.activity", focus: focus)
            XCTAssertEqual(counts().0, 1)
            XCTAssertFalse(focus.frames["main", default: []].contains { $0.id == "build.activity.play" })
            stores.build.done = false; stores.build.running = true; settle()
            XCTAssertFalse(focus.frames["main", default: []].contains { $0.id == "build.activity.dismiss" })
            XCTAssertFalse(focus.frames["main", default: []].contains { $0.id == "build.activity.play" })
        }
    }
}
