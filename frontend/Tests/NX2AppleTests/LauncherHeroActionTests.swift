import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

final class LauncherHeroActionTests: IsolatedDefaultsTestCase {
    @MainActor func testLocalizedHeroActionsKeepTheirHeightAndSizeToContent() {
        for lang in Lang.all {
            for key in ["library.play", "library.setUpBuild", "dev.open", "console.build"] {
                let title = String(format: L10n.string(key, lang), "iPhone 17 Pro Max")
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
}
