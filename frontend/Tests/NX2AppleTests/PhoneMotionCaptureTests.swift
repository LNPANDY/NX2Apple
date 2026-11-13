import XCTest
import SwiftUI
import AppKit
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

final class PhoneMotionCaptureTests: IsolatedDefaultsTestCase {
    @MainActor func testRenderPhoneMotionSettings() throws {
        guard let directory=ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set capture directory for visual review") }
        let output=URL(fileURLWithPath:directory)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let stores=LauncherStores(defaults:testDefaults)
        stores.localizer.lang = .en
        NSApplication.shared.setActivationPolicy(.accessory)
        for after in [false,true] {
            let view=VStack(spacing:18) {
                ControlsCard(controlChanges:0,padMerge:.constant(false),consolePrompt:.constant(true),startInConsole:.constant(false),onOpenControls:{},onOpenControllers:{})
                if after {
                    CardGroup(stores.localizer.t("motion.title")) {
                        CardRow(stores.localizer.t("motion.devices"),detail:stores.localizer.t("motion.note")) {
                            Button(stores.localizer.t("motion.open")) {}
                        }
                    }
                }
            }.padding(24).frame(width:900).background(Color(white:0.09)).foregroundStyle(.white).environmentObject(stores.localizer).environmentObject(PadFocus()).environment(\.colorScheme,.dark)
            let host=NSHostingView(rootView:view)
            host.frame=NSRect(origin:.zero,size:host.fittingSize)
            let window=OffscreenWindow(size:host.frame.size);window.contentView=host;window.orderFront(nil)
            RunLoop.main.run(until:Date().addingTimeInterval(0.3));host.layoutSubtreeIfNeeded()
            let rep=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:rep)
            try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent(after ? "phone-motion-after.png":"phone-motion-before.png"))
            window.orderOut(nil)
        }
    }
}
