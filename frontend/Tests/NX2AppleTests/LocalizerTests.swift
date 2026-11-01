import Combine
import XCTest
@testable import NXCore
@testable import NXModel

/// LNPANDY/NX2Apple#387, step 2: the language and the strings live in `Localizer`, which needs no SwiftUI. The choice is stored under the
/// UserDefaults key `appLanguage`, as before, so the tests put the player's own value back.
@MainActor final class LocalizerTests: XCTestCase {
    private var stored: String?

    override func setUp() {
        stored = UserDefaults.standard.string(forKey: "appLanguage")
    }

    override func tearDown() {
        if let stored { UserDefaults.standard.set(stored, forKey: "appLanguage") } else { UserDefaults.standard.removeObject(forKey: "appLanguage") }
    }

    func testTheLanguageSwitchChangesTheStrings() {
        let loc = Localizer(.en)
        XCTAssertEqual(loc.t("onboarding.start"), "Start")
        loc.lang = .de
        XCTAssertEqual(loc.t("onboarding.start"), L10n.string("onboarding.start", .de))
        loc.lang = .zh
        XCTAssertEqual(loc.t("onboarding.start"), "\u{5f00}\u{59cb}")
    }

    func testAnUnknownKeyComesBackAsItself() {
        XCTAssertEqual(Localizer(.en).t("no.such.key"), "no.such.key")
        XCTAssertEqual(Localizer(.fr).t("no.such.key"), "no.such.key")
    }

    func testAChangeAnnouncesItselfOnce() {
        let loc = Localizer(.en)
        var sent = 0
        let watch = loc.objectWillChange.sink { sent += 1 }
        loc.lang = .de
        loc.lang = .de   // the same language: no redraw
        loc.lang = .fr
        XCTAssertEqual(sent, 2)
        watch.cancel()
    }

    func testChooseStoresTheLanguageAndChangesIt() {
        let loc = Localizer(.en)
        loc.choose("sv")
        XCTAssertEqual(loc.lang, .sv)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "appLanguage"), "sv")
        XCTAssertEqual(Lang.saved, .sv)
        XCTAssertEqual(Localizer().lang, .sv, "a new launch reads the stored choice")
    }

    func testChoosingTheSystemClearsTheChoice() {
        let loc = Localizer(.en)
        loc.choose("zh")
        loc.choose("")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "appLanguage"), "")
        XCTAssertNil(Lang.saved)
        XCTAssertEqual(loc.lang, Lang.device())
    }

    func testAnyThreadCanReadTheStrings() {
        let loc = Localizer(.en)
        let done = expectation(description: "read in the background")
        DispatchQueue.global().async {
            XCTAssertEqual(loc.t("onboarding.start"), "Start")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
