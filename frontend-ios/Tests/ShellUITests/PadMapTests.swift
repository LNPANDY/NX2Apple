import Foundation
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
        #expect(PadMappingRows.summary(rows, game: false) == "A and B swapped")
        map.set("X", to: "none")
        #expect(PadMappingRows.summary(PadMappingRows.global(map), game: false) == "Custom")
    }
    @Test func aGameWithoutItsOwnMappingFollowsGlobal() {
        let rows = [SettingRow(id: "pad.swapAB", label: "Swap A and B", kind: .choice([]), value: "follow", fromShell: true),
                    SettingRow(id: "pad.A", label: "A", kind: .choice([]), value: "follow", fromShell: true),
                    SettingRow(id: "pad.B", label: "B", kind: .choice([]), value: "follow", fromShell: true)]
        #expect(PadMappingRows.summary(rows, game: true) == "Default")
        var custom = rows
        custom[1].fromShell = false
        #expect(PadMappingRows.summary(custom, game: true) == "Custom")
        // A game that keeps A and B where they are while all games swap them says so.
        var kept = rows
        kept[0].value = "off"
        for i in kept.indices { kept[i].fromShell = false }
        kept[1].value = "A"
        kept[2].value = "B"
        #expect(PadMappingRows.summary(kept, game: true) == "A and B not swapped")
    }
    @Test func aRowThatFollowsShowsWhatAllGamesSend() {
        let global = PadMap(["A": "B", "B": "A", "X": "none"])
        let follows = SettingRow(id: "pad.X", label: "X", kind: .choice([]), value: "follow", fromShell: true)
        let own = SettingRow(id: "pad.A", label: "A", kind: .choice([]), value: "A", fromShell: false)
        #expect(PadMappingRows.button(of: follows) == "X" && PadMappingRows.output(of: follows, inherited: global) == "none")
        #expect(PadMappingRows.output(of: own, inherited: global) == "A")
        // The shell's own rows go by the button and hold what it sends.
        let shellRow = PadMappingRows.global(global)[1]
        #expect(PadMappingRows.button(of: shellRow) == "A" && PadMappingRows.output(of: shellRow, inherited: nil) == "B")
    }
    @Test func everyButtonHasItsPlaceOnTheDrawing() {
        for button in PadMap.buttons {
            let element = PadMap.element(of: button)
            #expect(element != nil && element.flatMap(PadMap.button(at:)) == button, "\(button)")
        }
        // By position, as the engine maps a controller: Xbox's B (right) is A, its A (bottom) is B.
        #expect(PadMap.button(at: .b) == "A" && PadMap.button(at: .a) == "B" && PadMap.button(at: .y) == "X" && PadMap.button(at: .x) == "Y")
        #expect(PadMap.button(at: .home) == nil)
    }
    @Test func aTouchPicksTheNearestButton() {
        for element in PadElement.allCases where element != .home {
            #expect(XboxControllerDiagram.nearest(to: XboxControllerDiagram.frame(element).center) == element, "\(element)")
        }
        // Between the right and the bottom face button, nearer the right one.
        #expect(XboxControllerDiagram.nearest(to: CGPoint(x: 256, y: 99)) == .b)
        // The outer end of a bumper, where it wraps the body's corner, is the bumper, the paddle above it the trigger.
        #expect(XboxControllerDiagram.nearest(to: CGPoint(x: 40, y: 55)) == .leftBumper)
        #expect(XboxControllerDiagram.nearest(to: CGPoint(x: 280, y: 55)) == .rightBumper)
        #expect(XboxControllerDiagram.nearest(to: CGPoint(x: 64, y: 8)) == .leftTrigger)
        // The controller's body, away from every button, and the Xbox button pick nothing.
        #expect(XboxControllerDiagram.nearest(to: CGPoint(x: 160, y: 200)) == nil)
        #expect(XboxControllerDiagram.nearest(to: CGPoint(x: 50, y: 150)) == nil)
        #expect(XboxControllerDiagram.nearest(to: XboxControllerDiagram.frame(.home).center) == nil)
    }
    @Test func theShouldersAreFourShapesApartAndMirrored() throws {
        let shoulders: [PadElement] = [.leftBumper, .rightBumper, .leftTrigger, .rightTrigger]
        for e in shoulders {
            let outline = try #require(XboxControllerDiagram.shoulder(e))
            // The frame the hotspot and the ring use is the outline's bounds, inside the drawing.
            let f = XboxControllerDiagram.frame(e)
            #expect(abs(f.center.x - outline.boundingRect.midX) < 0.01 && abs(f.size.width - outline.boundingRect.width) < 0.01)
            #expect(outline.boundingRect.minY >= 0 && outline.boundingRect.maxX <= XboxControllerDiagram.design.width)
        }
        // A trigger and its bumper do not touch: there is a gap between the paddle and the slab.
        for (trigger, bumper) in [(PadElement.leftTrigger, PadElement.leftBumper), (.rightTrigger, .rightBumper)] {
            let paddle = try #require(XboxControllerDiagram.shoulder(trigger)), slab = try #require(XboxControllerDiagram.shoulder(bumper))
            // Even the bounds keep apart: the paddle ends above the slab's highest point.
            #expect(paddle.boundingRect.maxY + 3 < slab.boundingRect.minY, "\(paddle.boundingRect) \(slab.boundingRect)")
        }
        // The right side mirrors the left.
        let left = XboxControllerDiagram.frame(.leftBumper), right = XboxControllerDiagram.frame(.rightBumper)
        #expect(abs(left.center.x + right.center.x - XboxControllerDiagram.design.width) < 0.01 && abs(left.center.y - right.center.y) < 0.01)
        // The other elements have no outline of their own.
        #expect(XboxControllerDiagram.shoulder(.a) == nil)
    }
    /// The pulled part of a trigger is cut along the paddle's own tilted axis and bounded by its outline: 0 fills nothing,
    /// 1 fills every point of the paddle, a half pull about half (a little more, the paddle is rounder on top), and every
    /// point of the paddle is either pulled or rest, never both and never neither.
    @Test func aTriggerFillsItsOwnOutline() throws {
        for trigger in [PadElement.leftTrigger, .rightTrigger] {
            let outline = try #require(XboxControllerDiagram.shoulder(trigger))
            let box = outline.boundingRect
            let inside = stride(from: box.minX, through: box.maxX, by: 0.5).flatMap { x in
                stride(from: box.minY, through: box.maxY, by: 0.5).map { CGPoint(x: x, y: $0) }
            }.filter { outline.contains($0) }
            #expect(inside.count > 1000)
            func share(_ level: Double) -> Double {
                let fill = XboxControllerDiagram.triggerFill(trigger, level: level)
                return Double(inside.filter { fill.contains($0) }.count) / Double(inside.count)
            }
            #expect(share(0) == 0)
            #expect(share(1) == 1)
            let half = share(0.5), quarter = share(0.25), most = share(0.75)
            #expect(half > 0.48 && half < 0.66, "\(half)")
            #expect(quarter > 0.2 && quarter < half && most > half && most < 1, "\(quarter) \(most)")
            let fill = XboxControllerDiagram.triggerFill(trigger, level: 0.5), rest = XboxControllerDiagram.triggerRest(trigger, level: 0.5)
            let both = inside.filter { fill.contains($0) && rest.contains($0) }.count
            let neither = inside.filter { !fill.contains($0) && !rest.contains($0) }.count
            // A point on the cut itself may count either way: allow a sliver, nothing more.
            #expect(Double(both + neither) / Double(inside.count) < 0.02, "\(both) \(neither)")
            // The cut tilts with the paddle: its outer end (where the shoulder slopes down) sits lower in the drawing than
            // its inner end, never a flat line across.
            let pulled = inside.filter { fill.contains($0) }
            let leftTop = pulled.filter { $0.x < box.minX + box.width * 0.3 }.map(\.y).min() ?? 0
            let rightTop = pulled.filter { $0.x > box.maxX - box.width * 0.3 }.map(\.y).min() ?? 0
            let outerTop = trigger == .leftTrigger ? leftTop : rightTop, innerTop = trigger == .leftTrigger ? rightTop : leftTop
            #expect(outerTop > innerTop + 2, "\(outerTop) \(innerTop)")
        }
    }
    @Test func theCardGroupsEveryButtonOnce() {
        let grouped = PadMap.groups.flatMap(\.buttons)
        #expect(grouped.count == PadMap.buttons.count && Set(grouped) == Set(PadMap.buttons))
    }
    /// The texts were only in the string catalog, where the next run of tools/l10n_shell_catalogs.py would have dropped
    /// them. Now they are lines of frontend/l10n, and Chinese has every one.
    @Test func everyMappingTextIsInChinese() throws {
        // English here (the tests run in English, in parallel, so the shared capture bundle stays untouched), looked up in zh.
        let path = try #require(ShellStrings.bundle.path(forResource: "zh-Hans", ofType: "lproj"))
        let zh = try #require(Bundle(path: path))
        let english = PadMap.groups.map(\.title) + PadMap.buttons.map(PadMap.place)
            + ["Button mapping", "Swap A and B", "Default", "Reset", "Changed", "Button test", "Hold B to close", "Close"]
        for text in english {
            let chinese = zh.localizedString(forKey: text, value: "", table: nil)
            #expect(chinese.unicodeScalars.contains { $0.value >= 0x4E00 }, "\(text): \(chinese)")
        }
    }
}
