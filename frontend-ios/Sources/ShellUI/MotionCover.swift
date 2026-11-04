import SwiftUI
import ImageIO
import CoreGraphics
import AVFoundation

#if os(iOS)
import UIKit
#endif

/// A GIF, an animated WebP or APNG, or a silent MP4, MOV or M4V copied in as the game's banner.
/// On the phone it loops, filling the tile, with no sound and no controls. A still banner is left to `ArtView`.
/// Reduce Motion, and a Mac build of these views, keeps the still picture underneath.
struct MotionCover: View {
    let url: URL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        #if os(iOS)
        if !reduceMotion, Self.plays(url) {
            MotionHost(url: url).allowsHitTesting(false)
        }
        #else
        EmptyView()
        #endif
    }

    static func plays(_ url: URL) -> Bool {
        if Self.isMovie(url) { return true }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 1
    }

    static func isMovie(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }

    /// The first picture of a movie, so the blurred backdrop has something to draw. Nil when the file has none.
    static func poster(_ url: URL) -> CGImage? {
        guard isMovie(url) else { return nil }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 720)
        return try? gen.copyCGImage(at: .zero, actualTime: nil)
    }
}

#if os(iOS)
/// The phone's rows are ordinary scroll views, so a tile that leaves the screen stays in the hierarchy.
/// Its bounds, moved into the window, miss the window once it has scrolled away. A missing window means the same.
private final class MotionBox: UIView {
    var onVisibility: ((Bool) -> Void)?
    private var timer: Timer?
    private var reporting = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        arm()
        report()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        report()
    }

    func stopWatching() {
        onVisibility = nil
        timer?.invalidate()
        timer = nil
    }

    /// A tile with no size yet is not on screen. A point rectangle can still intersect the window.
    static func onScreen(_ view: UIView) -> Bool {
        guard let window = view.window else { return false }
        let rect = view.convert(view.bounds, to: window)
        return !rect.isEmpty && rect.intersects(window.bounds)
    }

    /// Scrolling does not resize the tile, so layout is not enough. Common mode keeps firing while the row is dragged.
    private func arm() {
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func report() {
        guard !reporting else { return }
        reporting = true
        onVisibility?(Self.onScreen(self))
        reporting = false
    }

    deinit { timer?.invalidate() }
}

/// The movie's end loop reads this from the main queue, alongside the player.
private final class MotionPlayGate: @unchecked Sendable {
    var allow = false
}

private struct MotionHost: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let box = MotionBox()
        box.clipsToBounds = true
        box.isUserInteractionEnabled = false
        box.onVisibility = { [weak coordinator = context.coordinator] visible in
            coordinator?.setVisible(visible)
        }
        context.coordinator.mount(url, in: box)
        return box
    }
    func updateUIView(_ box: UIView, context: Context) {
        context.coordinator.layout(in: box)
        context.coordinator.setVisible(MotionBox.onScreen(box))
    }
    static func dismantleUIView(_ box: UIView, coordinator: Coordinator) {
        (box as? MotionBox)?.stopWatching()
        coordinator.stop()
    }

    final class Coordinator {
        private var player: AVPlayer?
        private var playerLayer: AVPlayerLayer?
        private var loop: NSObjectProtocol?
        private weak var images: UIImageView?
        private var onScreen = false
        private var active = false
        private let playing = MotionPlayGate()

        func mount(_ url: URL, in box: UIView) {
            active = true
            if MotionCover.isMovie(url) { mountMovie(url, in: box) }
            else { mountFrames(url, in: box) }
            let shown = MotionBox.onScreen(box)
            if shown { onScreen = false }
            setVisible(shown)
        }

        func layout(in box: UIView) {
            playerLayer?.frame = box.bounds
            images?.frame = box.bounds
        }

        /// Off screen the movie pauses and the frames stop. Back on screen they continue. A still frame is not started again.
        func setVisible(_ visible: Bool) {
            guard active else { return }
            playing.allow = visible
            if visible {
                guard !onScreen else { return }
                onScreen = true
                if (images?.animationImages?.count ?? 0) > 1 { images?.startAnimating() }
                player?.play()
            } else {
                if onScreen { images?.stopAnimating() }
                onScreen = false
                if let player, player.timeControlStatus != .paused { player.pause() }
            }
        }

        func stop() {
            active = false
            onScreen = false
            playing.allow = false
            if let loop { NotificationCenter.default.removeObserver(loop) }
            loop = nil
            player?.pause()
            player = nil
            images?.stopAnimating()
        }

        private func mountMovie(_ url: URL, in box: UIView) {
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.volume = 0
            player.preventsDisplaySleepDuringVideoPlayback = false
            self.player = player
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            layer.frame = box.bounds
            box.layer.addSublayer(layer)
            playerLayer = layer
            let gate = playing
            loop = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                player.seek(to: .zero)
                guard gate.allow else { return }
                player.play()
            }
        }

        private func mountFrames(_ url: URL, in box: UIView) {
            let view = UIImageView()
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.isUserInteractionEnabled = false
            view.frame = box.bounds
            box.addSubview(view)
            images = view
            let frames = Self.frames(url)
            guard !frames.isEmpty else { return }
            view.animationImages = frames.map { UIImage(cgImage: $0.image) }
            view.image = view.animationImages?.first
            view.animationDuration = max(0.1, frames.reduce(0) { $0 + $1.seconds })
            view.animationRepeatCount = 0
        }

        private static func frames(_ url: URL) -> [(image: CGImage, seconds: Double)] {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
            var out: [(image: CGImage, seconds: Double)] = []
            for i in 0..<CGImageSourceGetCount(src) {
                guard let image = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
                out.append((image, delay(src, i)))
            }
            return out
        }

        /// GIF, WebP and APNG delays of 0 mean "as fast as you like". 0.1s is the usual stand-in, and the floor for a missing delay.
        private static func delay(_ src: CGImageSource, _ index: Int) -> Double {
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] else { return 0.1 }
            let raw = frameDelay(props, kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime)
                ?? frameDelay(props, kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
                ?? frameDelay(props, kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)
                ?? 0.1
            return raw < 0.02 ? 0.1 : raw
        }

        /// Nil when this format does not give a delay. The unclamped value wins, then the clamped one.
        private static func frameDelay(_ props: [CFString: Any], _ dictionary: CFString, _ unclamped: CFString, _ clamped: CFString) -> Double? {
            guard let bag = props[dictionary] as? [CFString: Any] else { return nil }
            return seconds(bag[unclamped]) ?? seconds(bag[clamped])
        }

        private static func seconds(_ value: Any?) -> Double? {
            if let value = value as? Double { return value }
            if let value = value as? NSNumber { return value.doubleValue }
            return nil
        }
    }
}
#endif
