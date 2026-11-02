import Testing
@testable import ShellUI

@Suite struct RecentRowTests {
    /// The row does what Play does, so it wears Play's glyph for every state and never a chevron.
    @Test func glyphMatchesTheAction() {
        for state in [GameState.playable, .needsGameData, .needsAppUpdate, .broken(reason: "x")] {
            #expect(RecentRow.glyph(state) == state.actionSymbol)
            #expect(RecentRow.glyph(state) != "chevron.right")
        }
    }

    @Test func hairlineHasSpaceAndRowKeepsItsHeight() {
        #expect(RecentRow.separatorGap == 10)
        #expect(RecentRow.minHeight == 60)
    }
}
