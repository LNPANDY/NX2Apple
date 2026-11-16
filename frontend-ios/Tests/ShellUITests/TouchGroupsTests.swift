import CoreGraphics
import Foundation
import Testing
@testable import ShellUI

/// The touch controls' groups the game's layout editor places and sizes (DM_TOUCH_GROUPS, Adjust Gamepad Layout in the game's menu): the
/// value the engine reads, the copy of its geometry, and what the shell's own layout editor does with them (draws them as the game does,
/// keeps them, puts them back with Reset all).
@Suite struct TouchGroupsTests {
    private typealias Offset = TouchLayout.Offset

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

    // MARK: The geometry, pinned to the engine

    private struct Pin {
        var face: CGPoint, stick: CGPoint, dpad: CGPoint
        var keys: [CGFloat], drops: [CGFloat]
        var faceR: CGFloat, stickR: CGFloat
        var gs: [CGFloat]
        var placed: Set<TouchGroups.Group>, keptBack: Set<TouchGroups.Group> = []
        var moved: Set<TouchLayout.Control> = [], dropped: Set<TouchLayout.Control> = []
    }

    private func expect(_ g: PadGeo, _ p: Pin, _ what: String) {
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }
        func closePoint(_ a: CGPoint, _ b: CGPoint) -> Bool { close(a.x, b.x) && close(a.y, b.y) }
        #expect(closePoint(g.face, p.face) && closePoint(g.stick, p.stick) && closePoint(g.dpad, p.dpad), "\(what): \(g.face) \(g.stick) \(g.dpad)")
        for i in 0..<4 {
            #expect(closePoint(g.faceKey[i], CGPoint(x: p.keys[2 * i], y: p.keys[2 * i + 1])), "\(what): key \(i) at \(g.faceKey[i])")
            #expect(closePoint(g.drop[i], CGPoint(x: p.drops[2 * i], y: p.drops[2 * i + 1])), "\(what): shoulder \(i) at \(g.drop[i])")
        }
        #expect(close(g.faceR, p.faceR) && close(g.stickR, p.stickR), "\(what): radii \(g.faceR) \(g.stickR)")
        #expect(g.gs.count == p.gs.count && zip(g.gs, p.gs).allSatisfy { pair in close(pair.0, pair.1) }, "\(what): sizes \(g.gs)")
        #expect(g.groupMoved == p.placed && g.groupDropped == p.keptBack, "\(what): placed \(g.groupMoved), kept back \(g.groupDropped)")
        #expect(g.moved == p.moved && g.dropped == p.dropped, "\(what): moved \(g.moved), dropped \(g.dropped)")
    }

    /// The points the engine's own geometry gives for these cases (DmPadGeometry.h with DM_TOUCH_GROUPS, printed with four decimals).
    @Test func theCopyOfTheGroupsGeometryIsTheEngines() throws {
        // Pro Max 3D: the shoulders lowered and larger, A B X Y larger and further in; the stick asked next to the D-pad keeps its place.
        let proMax = try #require(TouchGroups(encoded: "1;3d/lshoulder:0,300,120/rshoulder:1000,300,120/face:800,900,110/stick:150,900,110"))
        let g1 = PadGeo.make(.proMax, full: true, groups: proMax)
        expect(g1, Pin(face: CGPoint(x: 677.08, y: 300.34), stick: CGPoint(x: 110.5, y: 327), dpad: CGPoint(x: 260.5, y: 345),
                       keys: [732.08, 300.34, 677.08, 355.34, 677.08, 245.34, 622.08, 300.34],
                       drops: [90.9895, 111.9727, 90.9895, 193.5727, 841.0105, 111.9727, 841.0105, 193.5727],
                       faceR: 29.7, stickR: 77, gs: [1.2, 1.2, 1, 1, 1.1, 1], placed: [.lshoulder, .rshoulder, .face], keptBack: [.stick]), "Pro Max 3D")
        #expect(abs(g1.clickR[0] - 20.4) < 0.01 && abs(g1.clickR[1] - 20.4) < 0.01, "L3 and R3 grow with their shoulders")
        #expect(TouchPadPreviewGeometry(size: "medium", groups: proMax).shapes.contains(.circle(g1.click[0], g1.clickR[0], label: "L3")))
        // Pro Max 2D small, the stick inward and single moves: all controls at 110 %, the moves go along inside their groups.
        let g2 = PadGeo.make(.proMax, full: false, size: "small", stick: "inward",
                             layout: try #require(TouchLayout(encoded: "1;2d/zr:-3,2/x:-1,-2/plus:5,1")),
                             groups: try #require(TouchGroups(encoded: "1;2d/all:110/face:1000,1000,90/center:500,0,130")))
        expect(g2, Pin(face: CGPoint(x: 841.516, y: 348.016), stick: CGPoint(x: 153.58, y: 336.84), dpad: CGPoint(x: 285.58, y: 352.68),
                       keys: [881.116, 348.016, 841.516, 387.616, 830.824, 287.032, 801.916, 348.016],
                       drops: [97.72, 35.2, 97.72, 95.04, 834.28, 35.2, 834.28, 95.04],
                       faceR: 21.384, stickR: 67.76, gs: [1, 1, 1, 1, 0.9, 1.3], placed: [.face, .center], moved: [.x, .plus], dropped: [.zr]),
               "Pro Max 2D small inward")
        // iPad upright, the controls below the picture: the stick and A B X Y at the bottom corners, half as large again.
        let g3 = PadGeo.make(.iPadUpright, full: false, size: "large",
                             groups: try #require(TouchGroups(encoded: "1;2s/stick:0,1000,150/face:1000,1000,150/lshoulder:0,0,80")))
        expect(g3, Pin(face: CGPoint(x: 851.82, y: 1175.82), stick: CGPoint(x: 180.18, y: 1175.82), dpad: CGPoint(x: 418.44, y: 1075.44),
                       keys: [968.82, 1175.82, 851.82, 1292.82, 851.82, 1058.82, 734.82, 1175.82],
                       drops: [33.2691, 721.2691, 33.2691, 806.1331, 963.36, 750.4, 963.36, 856.48],
                       faceR: 63.18, stickR: 180.18, gs: [0.8, 1, 1.5, 1, 1.5, 1], placed: [.lshoulder, .stick, .face]), "iPad upright 2D large")
        // iPad Pro 11 sideways, all controls at 120 %: A B X Y asked at 200 % come down to the largest size that fits.
        let pro11 = PadScreen(size: CGSize(width: 1194, height: 834), insets: .init(top: 24, bottom: 20))
        let g4 = PadGeo.make(pro11, full: true, stick: "higher", layout: try #require(TouchLayout(encoded: "1;3d/face:-4,-4/stick:0,-3")),
                             groups: try #require(TouchGroups(encoded: "1;3d/all:120/dpad:300,800,130/face:700,500,200")))
        expect(g4, Pin(face: CGPoint(x: 630.7536, y: 288.428), stick: CGPoint(x: 126.36, y: 513.7), dpad: CGPoint(x: 399.5075, y: 594.0387),
                       keys: [751.6536, 288.428, 630.7536, 409.328, 630.7536, 167.528, 509.8536, 288.428],
                       drops: [68.64, 86.4, 68.64, 192.48, 1125.36, 86.4, 1125.36, 192.48],
                       faceR: 65.286, stickR: 120.12, gs: [1, 1, 1, 1.3, 1.55, 1], placed: [.dpad, .face], moved: [.face, .stick]), "iPad Pro 11 3D")
        // iPhone SE: A B X Y twice as large in the corner; the right shoulders asked smaller keep their size (R3's target is already
        // under 44 points) and move to the corner.
        let se = PadScreen(size: CGSize(width: 667, height: 375))
        let g5 = PadGeo.make(se, full: true, groups: try #require(TouchGroups(encoded: "1;3d/face:1000,1000,200/rshoulder:1000,0,60")))
        expect(g5, Pin(face: CGPoint(x: 532.6977, y: 240.6977), stick: CGPoint(x: 70.6395, y: 303.4884), dpad: CGPoint(x: 201.4535, y: 319.186),
                       keys: [619.907, 240.6977, 532.6977, 327.907, 532.6977, 153.4884, 445.4884, 240.6977],
                       drops: [38.3721, 34.8837, 38.3721, 94.186, 643.7518, 23.2482, 643.7518, 82.5505],
                       faceR: 47.093, stickR: 67.1512, gs: [1, 1, 1, 1, 2, 1], placed: [.rshoulder, .face]), "iPhone SE 3D")
    }

    /// A phone held sideways: the stick and A B X Y lifted beside the sensor housing keep out of the side insets (the engine's
    /// dm_pad_group_keep_off_sides, pinned to what it computes): the stick's ring starts at the safe area's left side (59 points), A on the right
    /// ends at its right side, where built in they reach halfway into the insets (x 106.5 and 825.5).
    @Test func liftedCornerGroupsKeepOffTheSideInsets() throws {
        let g = PadGeo.make(.proMax, full: false, groups: try #require(TouchGroups(encoded: "1;2d/stick:0,700,100/face:1000,700,100")))
        expect(g, Pin(face: CGPoint(x: 796, y: 255.5), stick: CGPoint(x: 136, y: 255.5), dpad: CGPoint(x: 260.5, y: 345),
                      keys: [846, 255.5, 796, 305.5, 796, 205.5, 746, 255.5],
                      drops: [103, 40, 103, 108, 829, 40, 829, 108],
                      faceR: 27, stickR: 77, gs: [1, 1, 1, 1, 1, 1], placed: [.stick, .face]), "Pro Max 2D lifted")
    }

    /// All controls never take a touch target under 44 points across (the engine's dm_pad_all_floor, pinned to what it computes): asked at 50 %
    /// they are drawn at 77 % on the iPad Pro 11, where − and + are then 44 points tall, as if asked at 77 %; above that, as asked; on the Pro Max,
    /// whose − and + are 44 points at 100 % already, they stay at 100 %.
    @Test func allControlsStopAtTheTouchTargetFloor() throws {
        let pro11 = PadScreen(size: CGSize(width: 1194, height: 834), insets: .init(top: 24, bottom: 20))
        #expect(PadGeo.placed(pro11, full: true, scale: 1, stick: "corner").allFloor == 77)
        let half = PadGeo.make(pro11, full: true, groups: try #require(TouchGroups(encoded: "1;3d/all:50")))
        let atFloor = PadGeo.make(pro11, full: true, groups: try #require(TouchGroups(encoded: "1;3d/all:77")))
        #expect(half == atFloor && abs(half.u - 1.001) < 1e-9, "all controls at 50 % drawn at u \(half.u)")
        #expect(abs(half.face.x - 1112.919) < 0.01 && abs(half.face.y - 731.918) < 0.01 && abs(half.pill[0].height - 28.028) < 0.01)
        let ninety = PadGeo.make(pro11, full: true, groups: try #require(TouchGroups(encoded: "1;3d/all:90")))
        #expect(abs(ninety.u - 1.17) < 1e-9, "above the floor, as asked")
        let proMax = PadGeo.make(.proMax, full: true, groups: try #require(TouchGroups(encoded: "1;3d/all:60")))
        #expect(proMax == PadGeo.make(.proMax, full: true), "the Pro Max keeps 100 %")
        let upright = PadGeo.make(.iPadUpright, full: false, groups: try #require(TouchGroups(encoded: "1;2s/all:50")))
        #expect(abs(upright.u - 1.001) < 1e-9 && abs(upright.face.x - 743.04) < 0.01, "below the picture too: u \(upright.u)")
    }

    /// A value that places nothing on this screen, or only in other layouts, is the built-in geometry exactly.
    @Test(arguments: [PadScreen.proMax, .iPadUpright, .duoUpright])
    func groupsOfOtherLayoutsChangeNothing(screen: PadScreen) throws {
        for full in [false, true] {
            let builtIn = PadGeo.make(screen, full: full, size: "large")
            let solo = try #require(TouchGroups(encoded: "1;2d/solo:1;3d/solo:1;2s/solo:1;3s/solo:1"))
            #expect(PadGeo.make(screen, full: full, size: "large", groups: solo) == builtIn)
            let kind = TouchLayout.Kind.of(full: full, split: PadGeo.region(screen).separated)
            var others = TouchGroups()
            for k in TouchLayout.Kind.allCases where k != kind {
                others[k, .face] = TouchGroups.Place(x: 0, y: 0, size: 150)
                others.setAll(k, 130)
            }
            #expect(PadGeo.make(screen, full: full, size: "large", groups: others) == builtIn, "another layout's groups change nothing here")
        }
    }

    // MARK: The shell's layout editor

    private func editing(_ groups: String) throws -> TouchLayoutEditing {
        TouchLayoutEditing(layout: TouchLayout(), kind: .threeD, screen: .proMax, groups: try #require(TouchGroups(encoded: groups)))
    }

    @Test func aSingleMoveGoesAlongWithItsGroup() throws {
        let groups = try #require(TouchGroups(encoded: "1;3d/face:800,900,110"))
        var e = try editing("1;3d/face:800,900,110")
        let before = e.geo
        #expect(before.groupMoved == [.face] && abs(before.gs[TouchGroups.Group.face.index] - 1.1) < 1e-9)
        // One step of the diamond in a group at 110 %: 1.1 steps of the built-in size on the screen (the engine: 677.08 to 662.23).
        let step = e.nudge(.face, dx: -1, dy: 0)
        #expect(step == .moved)
        #expect(abs(e.geo.face.x - 662.23) < 0.01 && abs(e.geo.screenStep(.face) - 14.85) < 1e-9 && abs(e.geo.step - 13.5) < 1e-9)
        #expect(e.groups == groups && e.geo.groupMoved == [.face], "the groups are kept as they are")
        // A drag counts the group's steps: 74.25 points are 5 of them here (5.5 of the built-in size).
        #expect(e.dragged(.face, from: .zero, by: CGSize(width: -74.25, height: 0)) == Offset(dx: -5, dy: 0))
        #expect(e.dragged(.stick, from: .zero, by: CGSize(width: 0, height: 27)) == Offset(dx: 0, dy: 2), "the stick's group is built in")
    }

    @Test func aSingleMoveThatWouldSendAGroupBackIsRefused() throws {
        var e = try editing("1;3d/stick:250,500,100")
        #expect(e.geo.groupMoved == [.stick])
        let kept = e.layout
        // The D-pad a step up leaves no room for the stick where its group is: the engine would put the stick back. Refused.
        let up = e.place(.dpad, Offset(dx: 0, dy: -1))
        #expect(!up && e.layout == kept)
        // A step down leaves the stick where its group is: kept.
        let down = e.place(.dpad, Offset(dx: 0, dy: 1))
        #expect(down)
        #expect(e.geo.groupMoved == [.stick] && e.geo.groupDropped.isEmpty && e.offset(.dpad) == Offset(dx: 0, dy: 1))
    }

    @MainActor @Test func theEditorOpensOnTheGroupsKeepsThemAndResetsThemWithTheLayout() throws {
        let store = ShellSettingsStore(defaults: UserDefaults(suiteName: "t-groups-\(UUID().uuidString)")!)
        let saved = try #require(TouchGroups(encoded: "1;2d/all:120;3d/face:800,900,110"))
        store.storeTouchGroups(saved)
        let model = TouchLayoutEditorModel(store: store, kind: .threeD)
        #expect(model.editing.groups == saved && model.hasGroups && !model.layoutIsBuiltIn && !model.hasChanges)
        #expect(model.geo.groupMoved == [.face])
        model.select(.stick)
        #expect(model.nudge(dx: 0, dy: -1) == .moved)
        // The game saves new groups while the editor is open: a save that did not change them keeps the game's.
        let fromGame = try #require(TouchGroups(encoded: "1;2d/all:120;3d/center:500,0,120"))
        store.storeTouchGroups(fromGame)
        model.commit()
        #expect(store.touchGroups == fromGame && !store.touchLayout.isEmpty)
        // Reset all puts the shown layout's groups back with its controls, and keeps the other layouts'.
        let again = TouchLayoutEditorModel(store: store, kind: .threeD)
        again.askReset()
        #expect(again.confirmingReset)
        again.reset()
        #expect(again.layoutIsBuiltIn && !again.hasGroups && again.hasChanges)
        again.commit()
        #expect(store.touchGroups.encoded == "1;2d/all:120" && store.touchLayout.isEmpty(.threeD))
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
