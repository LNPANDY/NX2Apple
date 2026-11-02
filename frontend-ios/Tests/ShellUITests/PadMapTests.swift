import Testing
@testable import ShellUI

@Suite struct PadMapTests {
    @Test func defaultsAndValidation() {
        #expect(PadMap().envValue == nil)
        #expect(PadMap(["A": "A", "Nope": "B", "X": "bad"]).entries.isEmpty)
        #expect(PadMap(["A": "B"]).swapAB == false)
        #expect(PadMap(["B": "A"]).swapAB == false)
        #expect(PadMap(["A": "B", "B": "A", "X": "none"]).swapAB)
    }
    @Test func stableEngineOrderAndNone() {
        let map = PadMap(["Down": "none", "Up": "Down", "LS": "A", "B": "A", "A": "B", "ZR": "ZL"])
        #expect(map.envValue == "A=B,B=A,LS=A,ZR=ZL,Up=Down,Down=none")
        var all = PadMap()
        for button in PadMap.buttons { all.set(button, to: "none") }
        #expect(all.envValue == PadMap.buttons.map { "\($0)=none" }.joined(separator: ","))
    }
    @Test func eachGameButtonWinsAndIdentityCancelsGlobal() {
        let global = PadMap(["A": "B", "B": "A", "X": "none"])
        #expect(PadMap.merged(global: global, game: [:]) == global)
        #expect(PadMap.merged(global: global, game: ["A": "Y"]).envValue == "A=Y,B=A,X=none")
        #expect(PadMap.merged(global: global, game: ["A": "A", "B": "B"]).envValue == "X=none")
        #expect(PadMap.merged(global: PadMap(["A": "B", "B": "A"]), game: ["A": "A", "B": "B"]).envValue == nil)
    }
    @Test func swapSetterPreservesOtherButtons() {
        var map = PadMap(["X": "none"])
        map.setSwapAB(true)
        #expect(map.swapAB && map.output(for: "X") == "none")
        map.setSwapAB(false)
        #expect(map.envValue == "X=none")
    }
}
