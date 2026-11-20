import SwiftUI
import XCTest
@testable import ShellUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor final class CoverFlowTests: XCTestCase {
    func testCarouselMetricsCenterAndDividedGeometry() {
        let regular = CoverFlowView.carouselMetrics(width: 1376, cover: 600, primaryWidth: 1376)
        XCTAssertEqual(regular.stride, 384, accuracy: 0.01)
        XCTAssertEqual(regular.leadingMargin, (1376 - 384) / 2, accuracy: 0.01)
        XCTAssertEqual(regular.trailingMargin, regular.leadingMargin, accuracy: 0.01)
        XCTAssertEqual(regular.targetMidX, 192, accuracy: 0.01)
        XCTAssertEqual(CoverFlowView.cardPlace(midX: regular.targetMidX, targetMidX: regular.targetMidX, stride: regular.stride), 0, accuracy: 0.001)
        XCTAssertEqual(CoverFlowView.cardPlace(midX: regular.targetMidX + regular.stride, targetMidX: regular.targetMidX, stride: regular.stride), 1, accuracy: 0.001)
        XCTAssertEqual(CoverFlowView.cardPlace(midX: regular.targetMidX - regular.stride, targetMidX: regular.targetMidX, stride: regular.stride), -1, accuracy: 0.001)

        // Vertical division keeps the focused card centred in the leading pane while reserving trailing space for the last card.
        let divided = CoverFlowView.carouselMetrics(width: 1200, cover: 400, primaryWidth: 560)
        XCTAssertEqual(divided.stride, 256, accuracy: 0.01)
        XCTAssertEqual(divided.leadingMargin, (560 - 256) / 2, accuracy: 0.01)
        XCTAssertEqual(divided.trailingMargin, 1200 - 256 - divided.leadingMargin, accuracy: 0.01)
        XCTAssertEqual(divided.targetMidX, 128, accuracy: 0.01)

        // Degenerate inputs stay finite and non-negative.
        let narrow = CoverFlowView.carouselMetrics(width: 200, cover: 500, primaryWidth: 200)
        XCTAssertEqual(narrow.leadingMargin, 0)
        XCTAssertEqual(narrow.trailingMargin, 0)
        XCTAssertEqual(CoverFlowView.cardPlace(midX: .nan, targetMidX: 100, stride: 200), 0)
        XCTAssertEqual(CoverFlowView.cardPlace(midX: 100, targetMidX: 100, stride: 0), 0)
    }

    func testNearestIndexRoundsAndClampsAtBounds() {
        XCTAssertEqual(CoverFlowView.nearestIndex(offset: 0, stride: 300, count: 5), 0)
        XCTAssertEqual(CoverFlowView.nearestIndex(offset: -120, stride: 300, count: 5), 0)
        XCTAssertEqual(CoverFlowView.nearestIndex(offset: 149, stride: 300, count: 5), 0)
        XCTAssertEqual(CoverFlowView.nearestIndex(offset: 151, stride: 300, count: 5), 1)
        XCTAssertEqual(CoverFlowView.nearestIndex(offset: 1200, stride: 300, count: 5), 4)
        XCTAssertEqual(CoverFlowView.nearestIndex(offset: 5000, stride: 300, count: 5), 4)
        XCTAssertEqual(CoverFlowView.nearestIndex(offset: .nan, stride: 300, count: 5), 0)
        XCTAssertEqual(CoverFlowView.nearestIndex(offset: .infinity, stride: 300, count: 5), 0)
        XCTAssertEqual(CoverFlowView.nearestIndex(offset: 300, stride: 0, count: 5), 0)
        XCTAssertEqual(CoverFlowView.nearestIndex(offset: 300, stride: 300, count: 0), 0)
    }

    #if canImport(UIKit)
    func testColdLaunchMaterializesAllCardsAndScrollsToLastWithoutAttributeGraphCycle() throws {
        setenv("AG_PRINT_CYCLES", "2", 1)
        let games = (0..<12).map { index in
            GameDetail(game: GameTile(id: "g\(index)", title: "Game \(index)", state: .playable))
        }
        var selectedID = games[0].id
        var reportedTargets: [FocusTarget] = []
        var controller: UIHostingController<AnyView>!
        func makeView(id: String) -> AnyView {
            let current = games.first { $0.id == id } ?? games[0]
            return AnyView(
                CoverFlowView(
                    games: games,
                    selected: current,
                    controllers: 1,
                    showsHints: false,
                    select: { nextID in
                        selectedID = nextID
                        controller.rootView = makeView(id: nextID)
                    },
                    primary: { _ in },
                    openSettings: {},
                    openControllers: {},
                    openShellSettings: {}
                )
                .onPreferenceChange(FocusTargets.self) { targets in
                    reportedTargets = targets
                }
            )
        }

        let stderrOutput = try captureStderr {
            controller = UIHostingController(rootView: makeView(id: selectedID))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1376, height: 1032))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            pumpMainRunLoop(seconds: 0.35)

            let scrollView = try XCTUnwrap(findFirstScrollView(in: controller.view), "CoverFlowView must host a UIScrollView")
            let tileTargets = Dictionary(uniqueKeysWithValues: reportedTargets
                .filter { $0.id.hasPrefix("lib.tile.g") }
                .map { ($0.id, $0) })
            // Non-lazy HStack materializes all cards up front instead of lazily mutating during tail arrival.
            XCTAssertEqual(tileTargets.count, games.count,
                           "Expected all \(games.count) cards materialized at cold launch, found \(tileTargets.keys.sorted())")
            let firstFrame = try XCTUnwrap(tileTargets["lib.tile.g0"]?.frame)
            let secondFrame = try XCTUnwrap(tileTargets["lib.tile.g1"]?.frame)
            let thirdFrame = try XCTUnwrap(tileTargets["lib.tile.g2"]?.frame)
            let lastFrame = try XCTUnwrap(tileTargets["lib.tile.g11"]?.frame)
            XCTAssertEqual(firstFrame.midX, 1376 / 2, accuracy: 2)
            // Side cards share the same perspective tilt, so their centre-to-centre spacing equals the fixed layout stride.
            let step = thirdFrame.midX - secondFrame.midX
            XCTAssertGreaterThan(step, firstFrame.width * 0.5)
            XCTAssertEqual(lastFrame.midX - secondFrame.midX, step * 10, accuracy: 2)

            // Sweep across every card to the last card and back, then drive programmatic selection to the last card.
            let minX = -scrollView.adjustedContentInset.left
            let maxX = max(minX, scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right)
            for stepIndex in 1...12 {
                let targetX = minX + (maxX - minX) * CGFloat(stepIndex) / 12
                scrollView.setContentOffset(CGPoint(x: targetX, y: scrollView.contentOffset.y), animated: false)
                pumpMainRunLoop(seconds: 0.04)
            }
            controller.rootView = makeView(id: games.last!.id)
            pumpMainRunLoop(seconds: 0.25)
            controller.rootView = makeView(id: games[games.count - 2].id)
            pumpMainRunLoop(seconds: 0.25)

            window.isHidden = true
            window.rootViewController = nil
        }

        XCTAssertFalse(stderrOutput.contains("AttributeGraph: cycle detected"),
                       "CoverFlowView triggered an AttributeGraph cycle:\n\(stderrOutput)")
    }

    private func pumpMainRunLoop(seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func findFirstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for subview in view.subviews {
            if let found = findFirstScrollView(in: subview) { return found }
        }
        return nil
    }

    private func captureStderr(_ body: () throws -> Void) throws -> String {
        fflush(stderr)
        var pipeFDs: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeFDs), 0)
        let savedStderr = dup(STDERR_FILENO)
        XCTAssertGreaterThanOrEqual(savedStderr, 0)
        dup2(pipeFDs[1], STDERR_FILENO)
        close(pipeFDs[1])

        var captured = Data()
        let reader = DispatchQueue(label: "coverflow.stderr.reader")
        let readDone = DispatchSemaphore(value: 0)
        reader.async {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(pipeFDs[0], &buffer, buffer.count)
                if count <= 0 { break }
                captured.append(buffer, count: count)
            }
            close(pipeFDs[0])
            readDone.signal()
        }

        let error: Error?
        do {
            try body()
            error = nil
        } catch let caught {
            error = caught
        }

        fflush(stderr)
        dup2(savedStderr, STDERR_FILENO)
        close(savedStderr)
        _ = readDone.wait(timeout: .now() + 2)
        if let error { throw error }
        return String(decoding: captured, as: UTF8.self)
    }
    #endif
}
