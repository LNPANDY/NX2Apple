import SwiftUI
import XCTest
@testable import NXLauncher

/// The launcher's controls under the system's Reduce Motion setting (#591).
final class LauncherMotionTests: XCTestCase {
    func testReduceMotionRemovesTheAnimation() {
        for animation in [Animation.easeOut(duration: 0.15), .easeInOut(duration: 0.18), .spring(response: 0.25, dampingFraction: 0.8)] {
            XCTAssertNil(LauncherMotion.animation(animation, reduceMotion: true))
        }
    }

    func testWithoutReduceMotionTheAnimationStays() {
        let animation = Animation.easeOut(duration: 0.15)
        XCTAssertEqual(LauncherMotion.animation(animation, reduceMotion: false), animation)
    }
}
