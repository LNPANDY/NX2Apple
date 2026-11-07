import CoreGraphics
import Testing
@testable import ShellUI

@Suite struct TouchPadDrawingPathTests {
    @Test func roundedPathsStayWithinTheirEngineCenterEnvelopes() {
        let shapes = TouchPadPreviewGeometry(size: "large").shapes
        for shape in shapes {
            let path = PadDrawing.outline(shape)
            let bounds = path.boundingRect
            #expect(TouchPadPreviewGeometry.bounds(shape) == bounds)

            switch shape {
            case .drop(let center, let radius, _, _):
                let tipDistance = radius * 1.45
                let envelope = CGRect(x: center.x - tipDistance, y: center.y - tipDistance,
                                      width: 2 * tipDistance, height: 2 * tipDistance).insetBy(dx: -0.01, dy: -0.01)
                #expect(envelope.contains(bounds), "the rounded tip remains within its original center envelope")
            case .dpad(let center, let radius):
                let envelope = CGRect(x: center.x - radius, y: center.y - radius,
                                      width: 2 * radius, height: 2 * radius).insetBy(dx: -0.01, dy: -0.01)
                #expect(envelope.contains(bounds), "rounded arms remain within the D-pad's original center envelope")
            default:
                break
            }
        }
    }
}
