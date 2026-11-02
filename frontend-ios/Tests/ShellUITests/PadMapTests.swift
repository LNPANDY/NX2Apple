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
    @Test func globalRowsMarkWhatDiffersFromTheDefault() {
        var map = PadMap()
        let untouched = PadMappingRows.global(map).allSatisfy { $0.fromShell }
        #expect(untouched)
        #expect(PadMappingRows.summary(PadMappingRows.global(map), game: false) == "Default")
        map.setSwapAB(true)
        let rows = PadMappingRows.global(map)
        let ids = Array(rows.map { $0.id }.prefix(3)), changed = rows.filter { !$0.fromShell }.map { $0.id }
        #expect(ids == ["swapAB", "A", "B"])
        #expect(changed == ["swapAB", "A", "B"])
        #expect(PadMappingRows.summary(rows, game: false) == "Swap A and B: On")
        map.set("X", to: "none")
        #expect(PadMappingRows.summary(PadMappingRows.global(map), game: false) == "Custom")
    }
    @Test func aGameWithoutItsOwnMappingFollowsGlobal() {
        let rows = [SettingRow(id: "pad.swapAB", label: "Swap A and B", kind: .choice([]), value: "follow", fromShell: true),
                    SettingRow(id: "pad.A", label: "A", kind: .choice([]), value: "follow", fromShell: true)]
        #expect(PadMappingRows.summary(rows, game: true) == "Follow global")
        var custom = rows
        custom[1].fromShell = false
        #expect(PadMappingRows.summary(custom, game: true) == "Custom")
    }
}
