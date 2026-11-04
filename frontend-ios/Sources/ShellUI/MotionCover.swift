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
private struct MotionHost: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.clipsToBounds = true
        box.isUserInteractionEnabled = false
        context.coordinator.mount(url, in: box)
        return box
    }
    func updateUIView(_ box: UIView, context: Context) { context.coordinator.layout(in: box) }
    static func dismantleUIView(_ box: UIView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator {
        private var player: AVPlayer?
        private var playerLayer: AVPlayerLayer?
        private var loop: NSObjectProtocol?
        private weak var images: UIImageView?

        func mount(_ url: URL, in box: UIView) {
            if MotionCover.isMovie(url) { mountMovie(url, in: box) }
            else { mountFrames(url, in: box) }
        }

        func layout(in box: UIView) {
            playerLayer?.frame = box.bounds
            images?.frame = box.bounds
        }

        func stop() {
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
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            layer.frame = box.bounds
            box.layer.addSublayer(layer)
            self.player = player
            playerLayer = layer
            loop = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                player.seek(to: .zero)
                player.play()
            }
            player.play()
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
            if frames.count > 1 { view.startAnimating() }
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

        private static func delay(_ src: CGImageSource, _ index: Int) -> Double {
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any],
                  let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
            let raw = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            return raw < 0.02 ? 0.1 : raw
        }
    }
}
#endif
