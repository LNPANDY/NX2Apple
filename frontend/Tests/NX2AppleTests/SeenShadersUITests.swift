import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

@MainActor final class SeenShadersUITests: IsolatedDefaultsTestCase {
    func testTargetCardShowsFastShaderToggleOnlyForEligibleMacNxnativeGames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("seen-shaders-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stores = LauncherStores(defaults: testDefaults)
        let build = stores.build
        let pad = PadFocus()
        build.buildUpstream = .nxnative
        build.target = BuildTarget.mac
        build.seenShadersOnly = false
        build.setSeenShadersForGallery(SeenShadersInfo(seenCount: 8158, totalCount: 131427))

        let window = OffscreenWindow(size: .init(width: 900, height: 500))
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        func host() {
            window.contentView = NSHostingView(rootView: TargetCard(build: build)
                .environmentObject(stores.localizer)
                .environmentObject(pad)
                .padScope("main", pad))
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }

        // 1. Mac + nxnative + cachedSeenShaders present -> toggle visible & interactive via controller focus.
        host()
        XCTAssertNotNil(pad.frame(of: "set.build.seenShaders"))
        XCTAssertNil(pad.frame(of: "set.build.bc"))
        pad.focused = "set.build.seenShaders"
        pad.activate()
        XCTAssertTrue(build.seenShadersOnly)

        // 2. Switch to iOS -> hides fast shader toggle, shows BC toggle.
        build.target = BuildTarget.ios
        host()
        XCTAssertNil(pad.frame(of: "set.build.seenShaders"))
        XCTAssertNotNil(pad.frame(of: "set.build.bc"))

        // 3. Back to Mac with nil cachedSeenShaders (game without shader_seen.tsv) -> toggle hidden.
        build.target = BuildTarget.mac
        build.setSeenShadersForGallery(nil)
        host()
        XCTAssertNil(pad.frame(of: "set.build.seenShaders"))
    }
}
