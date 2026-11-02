import XCTest
@testable import NXCore

/// LNPANDY/NX2Apple#320: the shader popup opens on upstream's note, not on patch 0006's. The Qt tests check the same lines.
final class BuildNotesTests: XCTestCase {
    func testANewTranslatorShowsThePopup() {
        XCTAssertTrue(BuildNotes.chainChanged("[NOTE] cached shader libraries cannot be reused (b-4e0dd2535996 -> b-b7cd656abd7c): "
                                              + "the translation chain changed; 65 base libraries scheduled"))
    }

    func testOtherLinesDoNot() {
        for line in ["[NOTE] cached shader libraries cannot be reused (3f1c -> 9a20): the game profile's shader inputs changed",
                     "[NOTE] chain-changed: b-4e0dd2535996 -> b-b7cd656abd7c: the upstream update changed the shader translator",
                     "[5/9] shaders"] {
            XCTAssertFalse(BuildNotes.chainChanged(line), line)
        }
    }
}
