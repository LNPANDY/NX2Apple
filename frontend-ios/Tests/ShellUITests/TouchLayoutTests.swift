import CoreGraphics
import Foundation
import Testing
@testable import ShellUI

/// The touch controls' arrangement (#414): the value the engine reads, the Swift copy of the engine's geometry, and the editor's rules.
@Suite struct TouchLayoutTests {
    private typealias Offset = TouchLayout.Offset

    // MARK: The value

    @Test func theValueIsWrittenAsTheEngineReadsIt() {
        var l = TouchLayout()
        #expect(l.encoded == "" && l.isEmpty)
        l[.twoD, .face] = Offset(dx: 0, dy: -2)
        l[.twoD, .stick] = Offset(dx: 1, dy: -1)
        l[.threeD, .a] = Offset(dx: -1, dy: 0)
        l[.threeDSplit, .zl] = Offset(dx: 99, dy: -99)   // kept inside the engine's range
        #expect(l.encoded == "1;2d/face:0,-2/stick:1,-1;3d/a:-1,0;3s/zl:64,-64")
        #expect(TouchLayout(encoded: l.encoded) == l)
        l[.threeD, .a] = .zero
        #expect(l.encoded == "1;2d/face:0,-2/stick:1,-1;3s/zl:64,-64", "a control back at 0 0 is not written")
        l.reset(.twoD); l.reset(.threeDSplit)
        #expect(l.isEmpty && l.encoded == "")
    }

    /// The same cases as the engine's test (pad_geometry_check.m): what it reads, skips and ignores whole.
    @Test func theValueIsReadAsTheEngineReadsIt() throws {
        #expect(TouchLayout(encoded: "")?.isEmpty == true)
        #expect(TouchLayout(encoded: "1")?.isEmpty == true)
        #expect(TouchLayout(encoded: "1;3d")?.isEmpty == true)
        let skipped = try #require(TouchLayout(encoded: "1;4d/a:1,1;2d/home:3,3/b:2,0"))
        #expect(skipped.encoded == "1;2d/b:2,0", "an unknown layout or control is skipped")
        for bad in ["2;2d/a:1,1", "x", "1x", "1;2d/a", "1;2d/a:", "1;2d/a:1", "1;2d/a:1,", "1;2d/a:1,1,1", "1;2d/a:+1,1", "1;2d/a:65,0", "1;2d/a:0,-65",
                    "1;2d/a:1000,0", "1;2d/a:0001,0", "1;2d/A:1,1", "1;2d/a:1,1 ", " 1;2d/a:1,1", "1;2d/a:1,1/", "1;2d/:1,1", "1;2d/a:--1,1",
                    "1;2d/a:1.5,1", "1;2d/a:1,1\n2d", "1;2d/a=1,1", "1;2d//a:1,1"] {
            #expect(TouchLayout(encoded: bad) == nil, "\(bad) is not ignored")
        }
        let long = "1;2d" + String(repeating: "/a:1,1", count: 200)
        #expect(TouchLayout(encoded: long) == nil, "too long: ignored whole")
    }

    // MARK: The geometry, pinned to the engine

    private struct Pin { var face: CGPoint; var stick: CGPoint; var dpad: CGPoint; var keys: [CGPoint]; var drops: [CGPoint]; var moved: Set<TouchLayout.Control>; var dropped: Set<TouchLayout.Control> }

    private func expect(_ g: PadGeo, _ p: Pin, _ what: String) {
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 }
        #expect(near(g.face, p.face) && near(g.stick, p.stick) && near(g.dpad, p.dpad), "\(what): \(g.face) \(g.stick) \(g.dpad)")
        for i in 0..<4 { #expect(near(g.faceKey[i], p.keys[i]) && near(g.drop[i], p.drops[i]), "\(what): key or shoulder \(i)") }
        #expect(g.moved == p.moved && g.dropped == p.dropped, "\(what): moved \(g.moved) dropped \(g.dropped)")
    }
    private func pts(_ v: [CGFloat]) -> [CGPoint] { stride(from: 0, to: v.count, by: 2).map { CGPoint(x: v[$0], y: v[$0 + 1]) } }

    /// The points the engine's own geometry gives for these cases (DmPadGeometry.h built on the Mac, printed with four decimals).
    @Test func theCopyOfTheGeometryIsTheEngines() throws {
        let proMax = PadScreen.proMax
        expect(PadGeo.make(proMax, full: true, layout: try #require(TouchLayout(encoded: "1;3d/face:-4,-4/stick:0,-3/minus:-2,2/b:0,1"))),
               Pin(face: CGPoint(x: 767.5, y: 273), stick: CGPoint(x: 110.5, y: 286.5), dpad: CGPoint(x: 260.5, y: 345),
                   keys: pts([817.5, 273, 767.5, 336.5, 767.5, 223, 717.5, 273]), drops: pts([103, 40, 103, 108, 829, 40, 829, 108]),
                   moved: [.face, .b, .stick, .minus], dropped: []), "Pro Max 3D")
        expect(PadGeo.make(proMax, full: true, size: "large", stick: "higher", layout: try #require(TouchLayout(encoded: "1;3d/stick:52,0/zl:0,-40/dpad:-30,0/r3:-2,3"))),
               Pin(face: CGPoint(x: 805.3, y: 310.6), stick: CGPoint(x: 126.7, y: 250.6), dpad: CGPoint(x: 306.7, y: 332.2),
                   keys: pts([865.3, 310.6, 805.3, 370.6, 805.3, 250.6, 745.3, 310.6]), drops: pts([111.8, 31.9895, 111.8, 129.6, 820.2, 48, 820.2, 129.6]),
                   moved: [.zl, .r3], dropped: [.stick, .dpad]), "Pro Max 3D large higher")
        expect(PadGeo.make(proMax, full: false, size: "small", stick: "inward", layout: try #require(TouchLayout(encoded: "1;2d/zr:-3,2/x:-1,-2/plus:5,1"))),
               Pin(face: CGPoint(x: 837.7, y: 343.4), stick: CGPoint(x: 142.3, y: 343.4), dpad: CGPoint(x: 262.3, y: 357.8),
                   keys: pts([877.7, 343.4, 837.7, 383.4, 826.9, 281.8, 797.7, 343.4]), drops: pts([94.2, 32, 94.2, 86.4, 837.8, 32, 837.8, 86.4]),
                   moved: [.x, .plus], dropped: [.zr]), "Pro Max 2D small inward")
        let iPad = PadScreen(size: CGSize(width: 1032, height: 1376), insets: .init(top: 24, bottom: 20))
        expect(PadGeo.make(iPad, full: false, size: "large", layout: try #require(TouchLayout(encoded: "1;2s/face:2,-3/zr:-3,2"))),
               Pin(face: CGPoint(x: 785.16, y: 1012.26), stick: CGPoint(x: 288.96, y: 1075.44), dpad: CGPoint(x: 418.44, y: 1075.44),
                   keys: pts([863.16, 1012.26, 785.16, 1090.26, 785.16, 934.26, 707.16, 1012.26]), drops: pts([68.64, 750.4, 68.64, 856.48, 963.36, 750.4, 963.36, 856.48]),
                   moved: [.face], dropped: [.zr]), "iPad upright 2D large")
        // The engine's test screens leave the Duo's topSafeOnly off: the same here.
        let duo = PadScreen(size: CGSize(width: 669, height: 951), insets: .init(top: 62, bottom: 34), division: CGRect(x: 0, y: 455.5, width: 669, height: 40))
        expect(PadGeo.make(duo, full: true, size: "small", layout: try #require(TouchLayout(encoded: "1;3s/stick:3,-2/a:1,0/x:0,-1"))),
               Pin(face: CGPoint(x: 481.68, y: 739.97), stick: CGPoint(x: 146.0331, y: 739.97), dpad: CGPoint(x: 250.7794, y: 739.97),
                   keys: pts([530.2303, 739.97, 481.68, 778.1986, 481.68, 691.4197, 443.4514, 739.97]),
                   drops: pts([33.6411, 526.0829, 33.6411, 578.0737, 635.3589, 526.0829, 635.3589, 578.0737]), moved: [.a, .x], dropped: [.stick]), "Duo upright 3D small")
        let tabletop = PadScreen(size: CGSize(width: 951, height: 669), insets: .init(left: 62, bottom: 20, right: 62), partiallyOpen: true,
                                 division: CGRect(x: 0, y: 314.5, width: 951, height: 40))
        expect(PadGeo.make(tabletop, full: true, stick: "inward", layout: try #require(TouchLayout(encoded: "1;3s/face:-6,0/dpad:4,-1/l:3,1"))),
               Pin(face: CGPoint(x: 776.1654, y: 591.641), stick: CGPoint(x: 158.5686, y: 592.8395), dpad: CGPoint(x: 298.2849, y: 595.9215),
                   keys: pts([810.4096, 591.641, 776.1654, 625.8852, 776.1654, 557.3968, 741.9212, 591.641]),
                   drops: pts([92.1349, 381.8953, 119.8727, 437.7134, 858.8651, 381.8953, 858.8651, 428.4674]), moved: [.face, .dpad, .l], dropped: []), "Duo tabletop 3D inward")
        let se = PadScreen(size: CGSize(width: 667, height: 375))
        expect(PadGeo.make(se, full: true, stick: "inward", layout: try #require(TouchLayout(encoded: "1;3d/dpad:-2,-5/l3:3,3/y:-1,0"))),
               Pin(face: CGPoint(x: 596.3605, y: 303.4884), stick: CGPoint(x: 122.9651, y: 303.4884), dpad: CGPoint(x: 253.7791, y: 319.186),
                   keys: pts([639.9651, 303.4884, 596.3605, 347.093, 596.3605, 259.8837, 540.9826, 303.4884]),
                   drops: pts([38.3721, 34.8837, 38.3721, 94.186, 628.6279, 34.8837, 628.6279, 94.186]), moved: [.y, .l3], dropped: [.dpad]), "iPhone SE 3D inward")
    }

    /// No arrangement, or a reset one, is the built-in geometry exactly.
    @Test(arguments: [PadScreen.proMax, .iPadUpright, .duoUpright])
    func aResetLayoutIsTheBuiltInOne(screen: PadScreen) {
        var l = TouchLayout()
        l[.threeD, .stick] = Offset(dx: 2, dy: -2); l[.threeDSplit, .face] = Offset(dx: -2, dy: 0)
        l.reset(.threeD); l.reset(.threeDSplit)
        #expect(PadGeo.make(screen, full: true, layout: l) == PadGeo.make(screen, full: true))
    }

    // MARK: The editor

    private func editing(_ kind: TouchLayout.Kind = .threeD, screen: PadScreen = .proMax) -> TouchLayoutEditing {
        TouchLayoutEditing(layout: TouchLayout(), kind: kind, screen: screen)
    }

    @Test func aMoveThatFitsIsKeptAndOneOntoAnotherControlIsNot() {
        var e = editing()
        let before = e.geo
        let r1 = e.nudge(.stick, dx: 0, dy: -1)
        #expect(r1 == .moved)
        #expect(e.offset(.stick) == Offset(dx: 0, dy: -1) && abs(e.geo.stick.y - (before.stick.y - 13.5)) < 0.01)
        // The stick dragged onto the diamond: refused, nothing changes.
        let kept = e.layout
        let r2 = e.place(.stick, Offset(dx: 52, dy: 0))
        #expect(!r2 && e.layout == kept)
        // A spot that covers another control's place is refused even when the engine would only push that one back.
        let r3 = e.place(.dpad, Offset(dx: -11, dy: -1))
        #expect(!r3 && e.layout == kept)
    }

    @Test func aControlDraggedPastTheEdgeStopsThereAndComesBackAtOnce() {
        var e = editing()
        let r4 = e.place(.zl, Offset(dx: 0, dy: -40))
        #expect(r4)
        let at = e.geo.drop[0]
        #expect(e.offset(.zl).dy > -40, "kept at most one step past the edge, not 40")
        let r5 = e.nudge(.zl, dx: 0, dy: -1)
        #expect(r5 == .atEdge)
        let r6 = e.nudge(.zl, dx: 0, dy: 1)
        #expect(r6 == .moved && e.geo.drop[0].y > at.y, "the first step back moves it")
    }

    @Test func theDiamondMovesTogetherOrKeyByKey() {
        var e = editing(.twoD)
        #expect(e.mover(.b) == .face)
        let r7 = e.nudge(.b, dx: -1, dy: -1)
        #expect(r7 == .moved && e.offset(.face) == Offset(dx: -1, dy: -1) && e.offset(.b).isZero)
        e.together = false
        let r8 = e.nudge(.b, dx: 0, dy: 1)
        #expect(r8 == .moved && e.offset(.b) == Offset(dx: 0, dy: 1))
        #expect(e.geo.faceSplit && e.isMoved(.a))
        e.putBack(.b)
        #expect(e.offset(.b).isZero && !e.offset(.face).isZero)
        e.together = true
        e.putBack(.a)
        #expect(e.layout.isEmpty, "putting the diamond back also puts its keys back")
    }

    @Test func resetIsOneLayoutOnly() {
        var e = editing(.twoD)
        _ = e.nudge(.l, dx: 1, dy: 1)
        e.kind = .threeD
        _ = e.nudge(.minus, dx: -1, dy: 0)
        e.reset()
        #expect(e.layout.isEmpty(.threeD) && !e.layout.isEmpty(.twoD))
    }

    /// Whatever the editor keeps, the engine draws it as the editor showed it: every kept spot is one the geometry places.
    @Test(arguments: [TouchLayout.Kind.twoD, .threeD])
    func randomEditsOnlyKeepPlacesTheEngineTakes(kind: TouchLayout.Kind) {
        var e = editing(kind)
        var rng: UInt32 = 414
        func next() -> Int { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return Int(rng % 1000) }
        let controls = TouchLayout.Control.allCases.filter { $0.drawn(full: kind.full) }
        for i in 0..<300 {
            e.together = i % 3 != 0
            let c = controls[next() % controls.count]
            if next() % 2 == 0 { _ = e.nudge(c, dx: next() % 3 - 1, dy: next() % 3 - 1) }
            else { _ = e.place(c, Offset(dx: next() % 31 - 15, dy: next() % 31 - 15)) }
            let g = e.geo
            #expect(g.dropped.isEmpty, "step \(i): the engine keeps \(g.dropped) back")
            #expect(g.fits, "step \(i): controls overlap or leave the screen")
            #expect(TouchLayout(encoded: e.layout.encoded) == e.layout)
        }
    }

    @Test func theDeviceScreensFollowTheWindow() {
        let phone = TouchLayoutScreens.device(window: CGSize(width: 440, height: 956), insets: EdgeInsetsLike.portrait, isPad: false)
        #expect(phone.sideways.size == CGSize(width: 956, height: 440) && phone.sideways.insets.left == 62 && phone.upright == nil)
        let pad = TouchLayoutScreens.device(window: CGSize(width: 1376, height: 1032), insets: .init(), isPad: true)
        #expect(pad.sideways.size.width == 1376 && pad.upright?.size == CGSize(width: 1032, height: 1376))
        let duo = TouchLayoutScreens.device(window: CGSize(width: 669, height: 951), insets: .init(top: 62, leading: 0, bottom: 34, trailing: 0), isPad: false)
        #expect(duo.upright?.topSafeOnly == true && duo.upright?.division != nil)
    }

    /// Xcode 26.6 Release builds time out type-checking when the 14-modifier chain and two inline ternaries sit inside the ForEach closure.
    @Test func accessibilityElementsSplitsClosureAndTypesTernaries() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("Sources/ShellUI/TouchLayoutEditorView.swift"), encoding: .utf8)
        #expect(source.contains("ForEach(controls, id: \\.self) { c in accessibilityElement(c, g, k: k) }"))
        #expect(source.contains("private func accessibilityElement(_ c: TouchLayout.Control, _ g: PadGeo, k: CGFloat) -> some View"))
        #expect(source.contains("let value: String ="))
        #expect(source.contains("let traits: AccessibilityTraits ="))
    }
}

import SwiftUI
private enum EdgeInsetsLike { static let portrait = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0) }
