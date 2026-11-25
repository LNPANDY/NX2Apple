import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher
@testable import NXModel

@MainActor
final class SheetPolishAndDismissTests: XCTestCase {

    func testRefreshCompletionSheetFillsFullWidthWithoutGreySideMargins() throws {
        let shotDir = ProcessInfo.processInfo.environment["NX_SHEET_POLISH_SHOT_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        if let shotDir {
            try FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        }

        let summary = RefreshCompletionSummary(
            id: UUID(),
            isBatch: true,
            items: [
                RefreshNoticeItem(
                    id: UUID(), gameID: UUID(), titleID: "0100CD801CE5E000",
                    name: "Balatro", target: BuildTarget.ios, succeeded: true, imgStatus: .unchanged
                ),
                RefreshNoticeItem(
                    id: UUID(), gameID: UUID(), titleID: "0100E65002BB8000",
                    name: "Stardew Valley", target: BuildTarget.mac, succeeded: true, imgStatus: .unchanged
                ),
                RefreshNoticeItem(
                    id: UUID(), gameID: UUID(), titleID: "0100E65002BB8000",
                    name: "Stardew Valley", target: BuildTarget.ios, succeeded: true,
                    imgStatus: .transferred(imgName: "b-108c5f92c3c4.img", deviceName: "Player iPhone")
                ),
            ],
            deviceName: "Player iPhone"
        )

        for lang in [Lang.zh, Lang.en] {
            let loc = Localizer(lang)
            let pad = PadFocus()
            let sheetView = RefreshCompletionSheet(summary: summary, revealItem: { _ in }, onViewQueue: {}, close: {})
                .environmentObject(loc)
                .environmentObject(pad)
                .environment(\.colorScheme, .dark)

            let host = NSHostingView(rootView: sheetView)
            let size = host.fittingSize
            XCTAssertEqual(size.width, RefreshCompletionSheet.sheetWidth, accuracy: 2.0,
                           "RefreshCompletionSheet outer width must match DSSheet width without grey side margins")
            XCTAssertGreaterThan(size.height, 260)

            host.frame = NSRect(origin: .zero, size: size)
            let win = OffscreenWindow(size: size, styleMask: [.borderless])
            win.backgroundColor = NSColor(white: 0.7, alpha: 1.0)
            win.contentView = host
            win.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                XCTFail("Failed to create bitmapImageRepForCachingDisplay")
                return
            }
            host.cacheDisplay(in: host.bounds, to: rep)

            let midY = rep.pixelsHigh / 2
            let leftLum = pixelLuminance(rep, x: 4, y: midY)
            let rightLum = pixelLuminance(rep, x: max(0, rep.pixelsWide - 5), y: midY)
            XCTAssertLessThan(leftLum, 0.15, "Left edge must be dark DSSheet surface, not grey outer sheet margin (got \(leftLum))")
            XCTAssertLessThan(rightLum, 0.15, "Right edge must be dark DSSheet surface, not grey outer sheet margin (got \(rightLum))")

            if let shotDir {
                let suffix = lang == .zh ? "zh" : "en"
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    XCTFail("Failed to encode PNG snapshot")
                    return
                }
                try png.write(to: shotDir.appendingPathComponent("refresh-completion-\(suffix).png"))
            }
            win.orderOut(nil)
        }
    }

    private final class StubRepo: RepoLocation {
        var path: String = NSTemporaryDirectory()
        var isRepo = false
        var isGit = false
    }

    private final class StubPython: PythonLocation {
        var pythonPath: String = "/usr/bin/python3"
    }

    func testSeedCompressionSheetKeepsLastRenderedFrameOnDismissWithoutCollapsing() throws {
        let defaults = TestDefaults.make("nx2apple-sheet-polish")

        let store = SeedCompressionStore(
            runner: SystemProcessRunner(),
            repo: StubRepo(),
            python: StubPython(),
            defaults: defaults,
            seedRoot: { NSTemporaryDirectory() + "nonexistent-\(UUID().uuidString)" }
        )
        let summary = SeedCompressSummary(
            status: .completed,
            completedGames: 2,
            failedGames: 0,
            beforeBytes: 9_000_000_000,
            afterBytes: 800_000_000,
            savedBytes: 8_200_000_000,
            elapsedSec: 28,
            results: [
                SeedCompressItemResult(
                    titleID: "0100F2C0115B6000", status: "completed",
                    beforeBytes: 3_300_000_000, afterBytes: 254_000_000, savedBytes: 3_046_000_000, filesCompressed: 1
                ),
            ]
        )
        store.setGalleryState(phase: .done(summary))

        let loc = Localizer(.zh)
        let pad = PadFocus()
        let view = SeedCompressionSheet(store: store) { _ in "The Legend of Zelda: Tears of the Kingdom" }
            .environmentObject(loc)
            .environmentObject(pad)
            .environment(\.colorScheme, .dark)

        let host = NSHostingView(rootView: view)
        let initialSize = host.fittingSize
        XCTAssertEqual(initialSize.width, SeedCompressionSheet.sheetWidth, accuracy: 2.0)
        XCTAssertGreaterThan(initialSize.height, 300)

        host.frame = NSRect(origin: .zero, size: initialSize)
        let win = OffscreenWindow(size: initialSize, styleMask: [.borderless])
        win.contentView = host
        win.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(SeedCompressionSheet.displayedPhase(current: nil, cached: .done(summary)), .done(summary))

        pad.scope = "library"
        store.finishDone()
        XCTAssertNil(store.phase)
        XCTAssertFalse(store.isScanning, "finishDone must defer background scan until sheet dismissal settles")

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        let dismissedSize = host.fittingSize
        XCTAssertEqual(dismissedSize.width, SeedCompressionSheet.sheetWidth, accuracy: 2.0,
                       "Dismissing SeedCompressionSheet must keep last rendered frame width instead of collapsing to EmptyView")
        XCTAssertGreaterThan(dismissedSize.height, 300,
                             "Dismissing SeedCompressionSheet must keep last rendered frame height instead of collapsing to a black square")
        XCTAssertEqual(pad.scope, "library", "Dismissing sheet must not clobber restored pad scope")

        win.orderOut(nil)
    }

    private func pixelLuminance(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Double {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 1.0 }
        return 0.2126 * Double(color.redComponent) + 0.7152 * Double(color.greenComponent) + 0.0722 * Double(color.blueComponent)
    }
}
