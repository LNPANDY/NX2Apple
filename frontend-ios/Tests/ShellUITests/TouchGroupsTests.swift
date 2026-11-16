import CoreGraphics
import Foundation
import Testing
@testable import ShellUI

/// The touch controls' groups the game's layout editor places and sizes (DM_TOUCH_GROUPS, Adjust Gamepad Layout in the game's menu): the
/// value the engine reads, and how the shell settings keep it.
@Suite struct TouchGroupsTests {

    // MARK: The value

    @Test func theValueIsWrittenAsTheEngineWritesIt() {
        var g = TouchGroups()
        #expect(g.encoded == "" && g.isEmpty)
        g[.threeD, .rshoulder] = TouchGroups.Place(x: 1000, y: 430, size: 120)
        g[.threeD, .lshoulder] = TouchGroups.Place(x: 0, y: 430, size: 120)
        g.setAll(.threeD, 110)
        g.setSolo(.threeD, true)
        g[.twoDSplit, .center] = TouchGroups.Place(x: 0, y: 0, size: 200)
        g[.twoDSplit, .face] = TouchGroups.Place(x: 500, y: 1000, size: 50)
        let v = "1;3d/all:110/solo:1/lshoulder:0,430,120/rshoulder:1000,430,120;2s/face:500,1000,50/center:0,0,200"
        #expect(g.encoded == v, "the engine's order: layouts 2d 3d 2s 3s, then all, solo and the groups in their order")
        #expect(TouchGroups(encoded: v) == g)
        g[.threeD, .face] = TouchGroups.Place(x: 2000, y: -5, size: 999)
        #expect(g[.threeD, .face] == TouchGroups.Place(x: 1000, y: 0, size: 200), "kept inside the engine's range")
        g.setAll(.twoD, 100)
        g.setAll(.threeDSplit, 20)
        #expect(g.all(.twoD) == 100 && g.all(.threeDSplit) == 50 && g.encoded.contains(";3s/all:50") && !g.encoded.contains("2d"))
        g.setAll(.threeDSplit, 100)
        g.reset(.threeD)
        #expect(g.encoded == "1;3d/solo:1;2s/face:500,1000,50/center:0,0,200", "Reset to default keeps whether the halves move on their own")
        #expect(g.isEmpty(.threeD) && !g.isEmpty && g.solo(.threeD))
        g.reset(.twoDSplit)
        g.setSolo(.threeD, false)
        #expect(g.isEmpty && g.encoded == "")
    }

    /// The same cases as the engine's test (pad_groups_check.m): what it reads, skips and ignores whole.
    @Test func theValueIsReadAsTheEngineReadsIt() throws {
        for empty in ["", "1", "1;3d", "1;"] { #expect(TouchGroups(encoded: empty)?.isEmpty == true, "\(empty) is the built-in layout") }
        let skipped = try #require(TouchGroups(encoded: "1;4d/face:1,1,100;3d/rstick:5,5,100/tilt:3/stick:10,20,100/zoom:1,2,3,4"))
        #expect(skipped.encoded == "1;3d/stick:10,20,100", "an unknown layout, group or field is skipped")
        #expect(TouchGroups(encoded: "1;2d/all:100")?.encoded == "", "all controls at 100 is the default")
        for bad in ["2;3d/face:1,1,100", "x", "1x", "1;3d/face", "1;3d/face:", "1;3d/face:1,1", "1;3d/face:1,1,100,5", "1;3d/face:1001,0,100",
                    "1;3d/face:0,1001,100", "1;3d/face:0,0,49", "1;3d/face:0,0,201", "1;3d/face:-1,0,100", "1;3d/face:+1,0,100",
                    "1;3d/face:00001,0,100", "1;3d/all:49", "1;3d/all:151", "1;3d/all:100,1", "1;3d/solo:2", "1;3d/solo:", "1;3d/Face:1,1,100",
                    "1;3d/face:1,1,100 ", " 1;3d/face:1,1,100", "1;3d/face:1,1,100/", "1;3d/:1", "1;3d/face:1.5,1,100", "1;3d/face:1,1,100\n3d",
                    "1;3d/face=1,1,100", "1;3d//face:1,1,100", "1;3d/zoom:1,2,3,4,5", "1;3d/zoom"] {
            #expect(TouchGroups(encoded: bad) == nil, "\(bad) is not ignored")
        }
        let long = "1;3d" + String(repeating: "/face:1,2,100", count: 80)
        #expect(long.utf8.count > TouchGroups.maxLength && TouchGroups(encoded: long) == nil, "too long: ignored whole")
    }

    // MARK: The shell settings

    @Test func theGroupsGoToEveryGameAndAnUnreadableValueReadsAsBuiltIn() throws {
        let store = ShellSettingsStore(defaults: UserDefaults(suiteName: "t-groups-\(UUID().uuidString)")!)
        #expect(store.touchGroups.isEmpty && store.touchGroupsStored == nil && store.gameDefaults["DM_TOUCH_GROUPS"] == nil)
        let groups = try #require(TouchGroups(encoded: "1;3d/all:110/lshoulder:0,430,120"))
        store.storeTouchGroups(groups)
        #expect(ShellSettingsStore(defaults: store.defaults).touchGroups == groups)
        #expect(store.gameDefaults["DM_TOUCH_GROUPS"] == "1;3d/all:110/lshoulder:0,430,120")
        // The built-in layout chosen for every game is kept and passed as such (an env file does not undo it); forgotten, nothing is passed.
        store.storeTouchGroups(TouchGroups())
        #expect(store.defaults.string(forKey: ShellSettingsStore.touchGroupsKey) == "" && store.touchGroupsStored == "" && store.touchGroups.isEmpty)
        #expect(store.gameDefaults["DM_TOUCH_GROUPS"] == "")
        store.forgetTouchGroups()
        #expect(store.defaults.object(forKey: ShellSettingsStore.touchGroupsKey) == nil && store.touchGroupsStored == nil && store.gameDefaults["DM_TOUCH_GROUPS"] == nil)
        store.defaults.set("1;3d/face:5000,0,100", forKey: ShellSettingsStore.touchGroupsKey)
        #expect(store.touchGroups.isEmpty && store.touchGroupsStored == nil && store.gameDefaults["DM_TOUCH_GROUPS"] == nil,
                "a value the engine ignores reads as the built-in layout and is not passed")
    }
}
