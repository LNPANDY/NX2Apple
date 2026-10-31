import CoreText
import SwiftUI
import XCTest
@testable import NSPortBuilder

/// The hero's cream button has one size (LauncherHeroAction) whatever the game's state and the language.
final class LauncherHeroActionTests: XCTestCase {
    private let languages: [Lang] = [.zh, .en, .sv, .de]

    private func width(_ text: String) throws -> CGFloat {
        let font = try XCTUnwrap(Typography.manropeFont(size: 18, weight: .bold))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    func testPlayAndBuildFitOnOneLineInEveryLanguage() throws {
        for key in ["library.play", "library.newBuild"] {
            for lang in languages {
                let text = L10n.string(key, lang)
                XCTAssertLessThanOrEqual(try width(text), LauncherHeroAction.labelWidth, "\(lang) \(key): \(text)")
            }
        }
    }

    func testOpenOnDeviceFitsAfterShrinkingForADeviceName() throws {
        for lang in languages {
            let text = String(format: L10n.string("dev.open", lang), "iPhone")
            XCTAssertLessThanOrEqual(try width(text) * LauncherHeroAction.minimumScale, LauncherHeroAction.labelWidth, "\(lang): \(text)")
        }
    }

    @MainActor func testEveryStateHasTheSameSize() throws {
        let states: [(String, String)] = [("play.fill", "library.play"), ("hammer.fill", "library.newBuild"), ("iphone", "dev.open")]
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
}
