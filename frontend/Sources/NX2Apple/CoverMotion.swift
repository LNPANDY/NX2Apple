import AppKit
import AVFoundation
import SwiftUI
import NXCore

/// One frame of a movie, for the still behind a player and for the blurred console background. Nil when the file has no picture.
enum MoviePoster {
    static func image(at path: String) -> NSImage? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 720)
        guard let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// The tile's cover. A still is the image. A GIF, an animated WebP or APNG, or a silent movie plays on top of it, filling the frame.
/// Reduce Motion leaves the still. The player does not take clicks, so the card and the hero buttons keep them.
struct FillingCover: View {
    let image: NSImage
    var motionPath = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack {
                Image(nsImage: image).resizable().scaledToFill().frame(width: w, height: h)
                if !reduceMotion, CoverFile.animates(motionPath) {
                    if CoverFile.isMovie(motionPath) {
                        LoopingMovieFill(url: URL(fileURLWithPath: motionPath)).frame(width: w, height: h)
                    } else {
                        AnimatedImageFill(path: motionPath).frame(width: w, height: h)
                    }
                }
            }
            .frame(width: w, height: h)
            .background(LauncherPalette.surface)
            .clipped()
        }
    }
}

/// Draws each frame scaled to cover the view, then clipped by the parent. A click falls through.
struct AnimatedImageFill: NSViewRepresentable {
    let path: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ClickThroughView {
        let box = ClickThroughView()
        let canvas = AspectImageView()
        canvas.autoresizingMask = [.width, .height]
        box.addSubview(canvas)
        context.coordinator.start(CoverFile.frames(at: path), canvas: canvas, path: path)
        return box
    }
    func updateNSView(_ box: ClickThroughView, context: Context) {
        if context.coordinator.path != path, let canvas = context.coordinator.canvas {
            context.coordinator.start(CoverFile.frames(at: path), canvas: canvas, path: path)
        }
        context.coordinator.canvas?.frame = box.bounds
    }
    static func dismantleNSView(_ box: ClickThroughView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator {
        private var frames: [NSImage] = []
        private var delays: [Double] = []
        private var index = 0
        private var timer: Timer?
        var path = ""
        weak var canvas: AspectImageView?

        func start(_ frames: [CoverFile.Frame], canvas: AspectImageView, path: String) {
            stop()
            self.path = path
            self.canvas = canvas
            self.frames = frames.map { NSImage(cgImage: $0.image, size: NSSize(width: $0.image.width, height: $0.image.height)) }
            delays = frames.map(\.seconds)
            show(0)
            guard frames.count > 1 else { return }
            schedule()
        }

        private func schedule() {
            let delay = delays.isEmpty ? 0.1 : delays[index % delays.count]
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.index = (self.index + 1) % max(1, self.frames.count)
                self.show(self.index)
                self.schedule()
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func show(_ i: Int) {
            guard frames.indices.contains(i) else { return }
            canvas?.image = frames[i]
        }

        func stop() { timer?.invalidate(); timer = nil }
    }
}

/// A silent movie, looped, scaled to cover. It does not keep the Mac awake.
struct LoopingMovieFill: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ClickThroughView {
        let box = ClickThroughView()
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspectFill
        playerView.autoresizingMask = [.width, .height]
        box.addSubview(playerView)
        context.coordinator.play(url, in: playerView)
        return box
    }
    func updateNSView(_ box: ClickThroughView, context: Context) {
        if context.coordinator.url != url, let playerView = context.coordinator.playerView {
            context.coordinator.play(url, in: playerView)
        }
        context.coordinator.playerView?.frame = box.bounds
    }
    static func dismantleNSView(_ box: ClickThroughView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator {
        private var player: AVPlayer?
        private var loop: NSObjectProtocol?
        var url: URL?
        weak var playerView: AVPlayerView?

        func play(_ url: URL, in view: AVPlayerView) {
            stop()
            self.url = url
            playerView = view
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.volume = 0
            player.preventsDisplaySleepDuringVideoPlayback = false
            self.player = player
            view.player = player
            loop = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                player.seek(to: .zero)
                player.play()
            }
            player.play()
        }

        func stop() {
            if let loop { NotificationCenter.default.removeObserver(loop) }
            loop = nil
            player?.pause()
            playerView?.player = nil
            player = nil
        }
    }
}

/// The cover sits inside a button. Clicks belong to that button.
final class ClickThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Aspect-fill. The parent clips whatever hangs past the tile.
final class AspectImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override func layout() { super.layout(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        image.draw(in: CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h))
    }
}
