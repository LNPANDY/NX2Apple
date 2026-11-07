import Testing
@testable import ShellUI

@Suite struct PortraitScrollDecorationTests {
    @Test func tabletopFadeMatchesTheGradientRangeAndThenStopsChanging() {
        #expect(PortraitScrollDecoration.value(offset: -12, tabletop: true, includesHero: false) == .fade(0))
        #expect(PortraitScrollDecoration.value(offset: 24, tabletop: true, includesHero: false) == .fade(0.5))
        #expect(PortraitScrollDecoration.value(offset: 48, tabletop: true, includesHero: false) == .fade(1))
        #expect(PortraitScrollDecoration.value(offset: 240, tabletop: true, includesHero: false) == .fade(1))
    }

    @Test func foldedHeroPullsDownOnlyPastTheTop() {
        #expect(PortraitScrollDecoration.value(offset: -32, tabletop: false, includesHero: true) == .pullDown(32))
        #expect(PortraitScrollDecoration.value(offset: 0, tabletop: false, includesHero: true) == .pullDown(0))
        #expect(PortraitScrollDecoration.value(offset: 80, tabletop: false, includesHero: true) == .pullDown(0))
    }

    @Test func expandedScrollDecorationIsIndependentOfOffset() {
        #expect(PortraitScrollDecoration.value(offset: -80, tabletop: false, includesHero: false) == .inactive)
        #expect(PortraitScrollDecoration.value(offset: 80, tabletop: false, includesHero: false) == .inactive)
    }

    @Test func scrollingPastTheFadeDoesNotKeepInvalidatingDecoration() {
        let offsets = (0...1_000).map { Double($0) }
        for tabletop in [false, true] {
            let values = offsets.map { PortraitScrollDecoration.value(offset: $0, tabletop: tabletop, includesHero: false) }
            let changes = zip(values, values.dropFirst()).filter { $0 != $1 }.count
            #expect(changes == (tabletop ? 48 : 0))
        }
    }
}
