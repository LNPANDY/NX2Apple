import CoreGraphics
import Foundation
import Testing
@testable import ShellUI

@Suite struct TouchLayoutGeometryTests {
    @MainActor @Test func onlyClosedDuoLandscapeExpandsCustomBoundsWithoutMovingDefaults() {
        for insets in [PadScreen.Insets(top: 10, left: 58, bottom: 21, right: 0),
                       PadScreen.Insets(top: 10, left: 0, bottom: 21, right: 58)] {
            let base = TouchLayoutGeometrySnapshot(bounds: CGRect(x: 0, y: 0, width: 956, height: 440),
                safeAreaInsets: insets, division: nil, hingeStatus: nil)
            var outer = base
            outer.hingeStatus = .closed
            let ordinary = PadGeo.make(base.screen, full: true)
            let expanded = PadGeo.make(outer.screen, full: true)
            for control in TouchLayout.Control.allCases {
                #expect(TouchLayoutEditing.same(ordinary.anchor(control), expanded.anchor(control)))
            }
            #expect(expanded.box(of: .r)?.within == base.bounds)
            #expect(ordinary.box(of: .r)?.within != base.bounds)
            var draft = TouchLayoutEditing(layout: TouchLayout(), kind: .threeD, screen: outer.screen)
            let control: TouchLayout.Control = insets.left > 0 ? .l : .r
            let accepted = draft.place(control, .init(dx: insets.left > 0 ? -64 : 64, dy: 0))
            #expect(accepted)
            let box = draft.geo.box(of: control)!.box
            #expect(box.minX >= -0.01 && box.maxX <= base.bounds.maxX + 0.01)
            #expect(insets.left > 0 ? box.minX < ordinary.safe.minX : box.maxX > ordinary.safe.maxX)
            outer.hingeStatus = .fullyOpen
            #expect(!outer.screen.customControlsFullBounds)
            outer.bounds.size = CGSize(width: 440, height: 956)
            outer.hingeStatus = .closed
            #expect(!outer.screen.customControlsFullBounds)
        }
    }
    @MainActor @Test func editorTitlesFollowTheLiveOrientationAndOuterDisplay() {
        let landscape = PadScreen(size: CGSize(width: 951, height: 669), insets: .init())
        let portrait = PadScreen(size: CGSize(width: 669, height: 951), insets: .init())
        #expect(TouchLayoutEditorView.layoutTitle(screen: landscape, hingeStatus: nil) == ShellStrings.text("Landscape"))
        #expect(TouchLayoutEditorView.layoutTitle(screen: landscape, hingeStatus: .fullyOpen) == ShellStrings.text("Landscape"))
        #expect(TouchLayoutEditorView.layoutTitle(screen: landscape, hingeStatus: .closed) == ShellStrings.text("Landscape (Duo outer screen)"))
        #expect(TouchLayoutEditorView.layoutTitle(screen: portrait, hingeStatus: .partiallyOpen) == ShellStrings.text("Portrait"))
    }
    @Test func aLandscapePhoneKeepsItsActualAsymmetricSafeInsets() {
        let snapshot = TouchLayoutGeometrySnapshot(
            bounds: CGRect(x: 0, y: 0, width: 956, height: 440),
            safeAreaInsets: .init(top: 0, left: 58, bottom: 0, right: 21),
            division: nil,
            hingeStatus: nil
        )

        #expect(snapshot.screen.size == CGSize(width: 956, height: 440))
        #expect(snapshot.screen.insets == PadScreen.Insets(top: 0, left: 58, bottom: 0, right: 21))
        #expect(!snapshot.screen.topSafeOnly)
    }

    @Test func aDivisionMakesTheInnerPortraitASeparateTopSafeOnlyLayout() {
        let snapshot = TouchLayoutGeometrySnapshot(
            bounds: CGRect(x: 0, y: 0, width: 669, height: 951),
            safeAreaInsets: .init(top: 62, left: 0, bottom: 34, right: 0),
            division: CGRect(x: 0, y: 455.5, width: 669, height: 40),
            hingeStatus: .unknown
        )

        #expect(snapshot.screen.topSafeOnly)
        #expect(!snapshot.screen.partiallyOpen)
        #expect(PadGeo.region(snapshot.screen).separated)
    }

    @MainActor @Test func ordinaryPhonePortraitEditsNativelyWithoutLandscapeFallback() {
        let portrait = TouchLayoutGeometrySnapshot(
            bounds: CGRect(x: 0, y: 0, width: 402, height: 874),
            safeAreaInsets: .init(top: 62, left: 0, bottom: 34, right: 0),
            division: nil,
            hingeStatus: nil
        )
        let context = TouchLayoutEditorView.editorContext(geometry: portrait, isPad: false)
        #expect(!context.phonePortraitFallback)
        #expect(context.screen.size == CGSize(width: 402, height: 874))
        #expect(PadGeo.region(context.screen).separated)

        let landscape = TouchLayoutGeometrySnapshot(
            bounds: CGRect(x: 0, y: 0, width: 956, height: 440),
            safeAreaInsets: .init(top: 0, left: 58, bottom: 0, right: 21),
            division: nil,
            hingeStatus: nil
        )
        let live = TouchLayoutEditorView.editorContext(geometry: landscape, isPad: false)
        #expect(!live.phonePortraitFallback)
        #expect(live.screen.insets == landscape.safeAreaInsets)
        #expect(!PadGeo.region(live.screen).separated)
    }

    @MainActor @Test func partiallyOpenTabletopUsesLiveDivisionAndHingeStatus() {
        let snapshot = TouchLayoutGeometrySnapshot(
            bounds: CGRect(x: 0, y: 0, width: 951, height: 669),
            safeAreaInsets: .init(top: 0, left: 62, bottom: 20, right: 62),
            division: CGRect(x: 0, y: 314.5, width: 951, height: 40),
            hingeStatus: .partiallyOpen
        )
        let context = TouchLayoutEditorView.editorContext(geometry: snapshot, isPad: false)

        #expect(!context.phonePortraitFallback)
        #expect(context.screen.partiallyOpen)
        #expect(context.screen.division == snapshot.division)
        #expect(PadGeo.region(context.screen).separated)
    }
    @MainActor @Test func aClosedDuoOuterPortraitEditsInPortraitAsOrdinaryPhone() {
        let outer = TouchLayoutGeometrySnapshot(bounds: CGRect(x: 0, y: 0, width: 402, height: 874),
            safeAreaInsets: .init(top: 62, left: 0, bottom: 34, right: 0), division: nil, hingeStatus: .closed)
        let context = TouchLayoutEditorView.editorContext(geometry: outer, isPad: false)
        #expect(!context.phonePortraitFallback)
        #expect(context.screen.size == CGSize(width: 402, height: 874))
        #expect(PadGeo.region(context.screen).separated)
    }

    @Test func portraitKeeps43PictureSlotAndFixedControlsBetweenFitAndFill() {
        let fit = PadGeo.region(.proMaxPortrait, pictureFill: false)
        let fill = PadGeo.region(.proMaxPortrait, pictureFill: true)
        #expect(fit.separated && fill.separated)
        #expect(abs(fit.gameClip.width / fit.gameClip.height - 4.0 / 3.0) < 0.002)
        #expect(fit.gameClip == fill.gameClip)
        #expect(fit.controls == fill.controls)
        #expect(abs(fill.game.height - fill.gameClip.height) < 0.01)
        #expect(abs(fill.game.width / fill.game.height - 16.0 / 9.0) < 0.001)
        #expect(fill.game.minX < fill.gameClip.minX && fill.game.maxX > fill.gameClip.maxX)

        let fourThreeFill = PadGeo.region(.proMaxPortrait, pictureFill: true, aspect: 4.0 / 3.0)
        #expect(fourThreeFill.game == fourThreeFill.gameClip)

        let iPadFit = PadGeo.region(.iPadUpright, pictureFill: false)
        #expect(iPadFit.gameClip == iPadFit.upper)

        let stdPt = PadGeo.region(.proMaxPortrait, pictureFill: false, portraitEdgeToEdge: false)
        let edgePt = PadGeo.region(.proMaxPortrait, pictureFill: false, portraitEdgeToEdge: true, aspect: 430.0 / 466.0)
        #expect(edgePt.separated)
        #expect(edgePt.upper.minY == 0 && edgePt.gameClip.minY == 0)
        #expect(edgePt.gameClip.maxY == edgePt.controls.minY)
        #expect(edgePt.game == edgePt.gameClip)
        #expect(edgePt.controls == stdPt.controls)
    }

}
