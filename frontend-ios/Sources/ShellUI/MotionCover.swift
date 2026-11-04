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
    /// The app in the background is off screen too, so a cover does not keep decoding there.
    static func onScreen(_ view: UIView) -> Bool {
        guard let window = view.window, UIApplication.shared.applicationState == .active else { return false }
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
        box.isOpaque = false
        box.backgroundColor = .clear
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
        private var status: NSKeyValueObservation?
        private weak var images: UIImageView?
        private weak var box: UIView?
        private var frames: [UIImage] = []
        private var delays: [Double] = []
        private var index = 0
        private var timer: Timer?
        private var parked = CMTime.zero
        private var onScreen = false
        private var active = false
        private var movie = false
        private var failed = false
        private var loading = false
        private var generation = 0
        private var url: URL?
        private let playing = MotionPlayGate()

        /// Remembers the file. Frames and the player are created only while the tile is on screen.
        func mount(_ url: URL, in box: UIView) {
            let changed = self.url != url
            active = true
            if changed {
                index = 0
                parked = .zero
                failed = false
                loading = false
                generation += 1
                releaseFrames()
                releaseMovie(saving: false)
            }
            self.url = url
            self.box = box
            movie = MotionCover.isMovie(url)
            if !movie, images == nil {
                let view = UIImageView()
                view.contentMode = .scaleAspectFill
                view.clipsToBounds = true
                view.isUserInteractionEnabled = false
                view.isOpaque = false
                view.backgroundColor = .clear
                view.frame = box.bounds
                box.addSubview(view)
                images = view
            }
            let shown = MotionBox.onScreen(box)
            if shown { onScreen = false }
            setVisible(shown)
        }

        func layout(in box: UIView) {
            playerLayer?.frame = box.bounds
            images?.frame = box.bounds
        }

        /// Off screen the decoded frames and the player are dropped. The frame on display stays.
        /// Coming back continues from that frame, or from where the movie waited.
        func setVisible(_ visible: Bool) {
            guard active else { return }
            playing.allow = visible
            if visible {
                guard !onScreen else { return }
                guard !failed else { onScreen = true; return }
                onScreen = true
                if movie { startMovie() }
                else { startFrames() }
            } else if onScreen || player != nil || !frames.isEmpty || loading {
                onScreen = false
                generation += 1
                loading = false
                if movie { releaseMovie() }
                else { releaseFrames() }
            }
        }

        func stop() {
            active = false
            onScreen = false
            playing.allow = false
            timer?.invalidate()
            timer = nil
            frames = []
            delays = []
            generation += 1
            loading = false
            images?.image = nil
            releaseMovie(saving: false)
        }

        private func startFrames() {
            if frames.isEmpty, !failed, !loading { loadFrames() }
            guard !failed, frames.count > 1, timer == nil else { return }
            showFrame()
            schedule()
        }

        /// ImageIO runs off the main thread. A tile that leaves before the decode finishes keeps the frame it already showed.
        private func loadFrames() {
            guard let url else { return }
            loading = true
            let generation = generation
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let decoded = Self.frames(url)
                let pictures = decoded.map(\.image)
                let delays = decoded.map(\.seconds)
                DispatchQueue.main.async {
                    guard let self, self.generation == generation, self.active, self.onScreen, self.url == url else { return }
                    self.loading = false
                    self.frames = pictures.map { UIImage(cgImage: $0) }
                    self.delays = delays
                    if self.frames.isEmpty { self.failed = true; return }
                    if self.index >= self.frames.count { self.index = 0 }
                    self.showFrame()
                    if self.frames.count > 1, self.timer == nil { self.schedule() }
                }
            }
        }

        private func showFrame() {
            guard frames.indices.contains(index) else { return }
            images?.image = frames[index]
        }

        private func schedule() {
            guard active, onScreen, frames.count > 1 else { return }
            let delay = delays.isEmpty ? 0.1 : delays[index % delays.count]
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.timer = nil
                    guard self.active, self.onScreen else { return }
                    self.index = (self.index + 1) % max(1, self.frames.count)
                    self.showFrame()
                    self.schedule()
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        /// Keeps the picture on screen and drops the rest of the decoded frames.
        private func releaseFrames() {
            timer?.invalidate()
            timer = nil
            let current = images?.image
            frames = []
            delays = []
            images?.image = current
        }

        private func startMovie() {
            guard player == nil, let url, let box else { return }
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 1
            status = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                DispatchQueue.main.async { self?.noteFailure() }
            }
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
            if parked.isValid, parked.seconds > 0.05 { player.seek(to: parked) }
            let gate = playing
            loop = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                self?.parked = .zero
                player.seek(to: .zero)
                guard gate.allow else { return }
                player.play()
            }
            player.play()
        }

        /// A file that will not play stays a still. Opening it again on every scroll would keep failing.
        private func noteFailure() {
            failed = true
            onScreen = true
            releaseMovie(saving: false)
        }

        private func releaseMovie(saving time: Bool = true) {
            if time { parked = player?.currentTime() ?? parked }
            status = nil
            if let loop { NotificationCenter.default.removeObserver(loop) }
            loop = nil
            player?.pause()
            playerLayer?.removeFromSuperlayer()
            playerLayer = nil
            player = nil
        }

        private static func frames(_ url: URL) -> [(image: CGImage, seconds: Double)] {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
            let count = CGImageSourceGetCount(src)
            let maxPixel = count > 24 ? 960 : 1280
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            var out: [(image: CGImage, seconds: Double)] = []
            for i in 0..<count {
                guard let image = CGImageSourceCreateThumbnailAtIndex(src, i, options as CFDictionary) else { continue }
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
