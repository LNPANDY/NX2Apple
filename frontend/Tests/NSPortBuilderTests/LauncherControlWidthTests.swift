import CoreText
import XCTest
@testable import NSPortBuilder

/// The buttons and dropdowns in the setting rows share one width (LauncherControl.width). These measure the labels the
/// launcher ships in every language against it, in the face and size the controls use.
final class LauncherControlWidthTests: XCTestCase {
    private let languages: [Lang] = [.zh, .en, .sv, .de]

    /// The labels of the buttons at the end of a setting row.
    private let buttonKeys = [
        "library.rescan", "library.chooseFolder", "controls.customize", "console.controllersOpen", "settings.setupBtn",
        "app.restartNow", "repo.check", "repo.pull", "repo.adopt", "repo.choose", "repo.download", "dep.recheck", "dep.install",
        "dep.openAppStore", "dep.xcode.fix", "build.setup", "data.choose", "data.change", "install.reveal", "build.showLibrary",
        "diag.copy", "diag.copied",
    ]

    /// Longer than one line in some language: they wrap to a second line, which the button has room for.
    private let wrapping: Set<String> = ["repo.adopt"]

    /// The names of the dropdown choices in the Settings cards.
    private let choiceKeys = [
        "settings.language.system", "settings.language.zh", "settings.language.en", "settings.language.sv", "settings.language.de",
    ]

    private func width(_ text: String) throws -> CGFloat {
        let font = try XCTUnwrap(Typography.manropeFont(size: 13, weight: .semibold))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    func testButtonLabelsFitOnOneLine() throws {
        for key in buttonKeys where !wrapping.contains(key) {
            for lang in languages {
                let text = L10n.string(key, lang)
                XCTAssertLessThanOrEqual(try width(text), LauncherControl.buttonLabelWidth, "\(lang) \(key): \(text)")
            }
        }
    }

    func testTheLongestLabelsFitOnTwoLines() throws {
        for key in buttonKeys {
            for lang in languages {
                let text = L10n.string(key, lang)
                XCTAssertLessThanOrEqual(try width(text), 2 * LauncherControl.buttonLabelWidth - 40, "\(lang) \(key): \(text)")
            }
        }
    }

    func testDropdownChoicesFitBesideTheChevron() throws {
        let chevron: CGFloat = 8 + 10
        for key in choiceKeys {
            for lang in languages {
                let text = L10n.string(key, lang)
                XCTAssertLessThanOrEqual(try width(text), LauncherControl.buttonLabelWidth - chevron, "\(lang) \(key): \(text)")
            }
        }
    }
}
