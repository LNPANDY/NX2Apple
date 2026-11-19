import SwiftUI
import AppKit
import NXCore
import NXLauncher

/// A process runner for the gallery's stores: it starts nothing. A button in a scene that would run git, Python, xcodebuild or a
/// game gets "did not start" and shows that state, as on a Mac without the tool (#1459).
final class GalleryProcessRunner: ProcessRunner {
    private static let refused = ProcessResult.failedToStart("The state gallery runs no process")
    func capture(_ launch: ProcessLaunch) -> ProcessResult { Self.refused }
    func stream(_ launch: ProcessLaunch, line: @escaping (String) -> Void) -> Bool { false }
    func streamLines(_ launch: ProcessLaunch, started: @escaping (RunningProcess) -> Void, line: @escaping (String) -> Void) -> ProcessResult { Self.refused }
    func start(_ launch: ProcessLaunch, onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> RunningProcess {
        throw CocoaError(.featureUnsupported)
    }
}

/// No release, no download: the gallery never checks for an app update.
struct GalleryReleases: ReleaseSource {
    func latestRelease() async -> Data? { nil }
    func download(_ url: URL, to file: URL) async -> Bool { false }
}

/// Draws a scene into a PNG off screen: the gallery's Export and the design captures (LauncherDesignCaptureTests) use it. Liquid
/// Glass draws its static stand-in for the time of the render, since AppKit's bitmap caching cannot rasterize the material.
@MainActor enum GalleryRenderer {
    /// A window outside every display, never key or main, so rendering shows nothing to anybody.
    private final class Window: NSWindow {
        /// `titled`: the launcher's window chrome. A sheet has none: it is drawn without a title bar's safe area.
        init(size: NSSize, titled: Bool = true) {
            super.init(contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: size),
                       styleMask: titled ? [.titled, .closable, .resizable, .fullSizeContentView] : [.borderless], backing: .buffered, defer: false)
            isReleasedWhenClosed = false
            colorSpace = .sRGB
            animationBehavior = .none
            appearance = NSAppearance(named: .darkAqua)
            setFrame(NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: frame.size), display: false)
        }
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    static func png(_ scene: GalleryScene, fixtures: GalleryFixtures, size: CGSize? = nil, settle: TimeInterval = 0.8) -> Data? {
        let frame = size ?? scene.size
        let wasStatic = LauncherGlass.forceStatic
        LauncherGlass.forceStatic = true
        defer { LauncherGlass.forceStatic = wasStatic }
        let host = NSHostingView(rootView: fixtures.view(scene, size: frame))
        if scene.fitsContent { host.frame = NSRect(origin: .zero, size: host.fittingSize) }   // a sheet as high as its content
        let window = Window(size: scene.fitsContent ? host.frame.size : NSSize(width: frame.width, height: frame.height), titled: !scene.fitsContent)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
