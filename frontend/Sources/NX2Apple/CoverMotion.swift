import AppKit
import AVFoundation
import SwiftUI
import NXCore

/// One frame of a movie, for the still behind a player and for the blurred console background. Nil when the file has no picture.
/// A library refresh asks for the same files again, so a frame is kept until the file's size or date changes.
enum MoviePoster {
    private struct Hit { var stamp: String; var image: NSImage? }
    private static let lock = NSLock()
    private static var cache: [String: Hit] = [:]

    static func image(at path: String) -> NSImage? {
        guard let stamp = stamp(path) else { return nil }
        lock.lock()
        if let hit = cache[path], hit.stamp == stamp { lock.unlock(); return hit.image }
        lock.unlock()
        let image = decode(path)
        lock.lock()
        cache[path] = Hit(stamp: stamp, image: image)
        if cache.count > 64, let extra = cache.keys.first(where: { $0 != path }) { cache.removeValue(forKey: extra) }
        lock.unlock()
        return image
    }

    private static func stamp(_ path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber, let modified = attrs[.modificationDate] as? Date else { return nil }
        return "\(size.int64Value)-\(modified.timeIntervalSince1970)"
    }

    private static func decode(_ path: String) -> NSImage? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 720)
        guard let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
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
/// The next frame waits while the canvas is scrolled out of sight, and that same frame is shown again when it returns.
struct AnimatedImageFill: NSViewRepresentable {
    let path: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ClickThroughView {
        let box = ClickThroughView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.clear.cgColor
        let canvas = AspectImageView()
        canvas.autoresizingMask = [.width, .height]
        box.onVisibility = { [weak coordinator = context.coordinator] visible in
            coordinator?.setVisible(visible)
        }
        box.addSubview(canvas)
        context.coordinator.bind(path, canvas: canvas)
        return box
    }
    func updateNSView(_ box: ClickThroughView, context: Context) {
        context.coordinator.canvas?.frame = box.bounds
        if context.coordinator.path != path, let canvas = context.coordinator.canvas {
            context.coordinator.bind(path, canvas: canvas)
        }
        context.coordinator.setVisible(ClickThroughView.onScreen(box))
    }
    static func dismantleNSView(_ box: ClickThroughView, coordinator: Coordinator) {
        box.stopWatching()
        coordinator.stop()
    }

    final class Coordinator {
        private var frames: [NSImage] = []
        private var delays: [Double] = []
        private var index = 0
        private var timer: Timer?
        private var active = false
        private var failed = false
        private var loading = false
        private var wantsFrames = false
        private var generation = 0
        var path = ""
        weak var canvas: AspectImageView?

        /// Remembers the file. The frames are decoded only while the tile is on screen.
        func bind(_ path: String, canvas: AspectImageView) {
            let changed = self.path != path
            active = true
            self.path = path
            self.canvas = canvas
            if changed {
                timer?.invalidate()
                timer = nil
                frames = []
                delays = []
                index = 0
                failed = false
                loading = false
                generation += 1
                canvas.image = nil
            }
            setVisible(ClickThroughView.onScreen(canvas))
        }

        /// The host view and the canvas agree before another frame is queued. One frame stays a still.
        /// Off screen, every frame but the one on display is dropped. Coming back decodes the file again and continues.
        func setVisible(_ hostVisible: Bool) {
            guard active else { return }
            let visible = hostVisible && canvasVisible
            wantsFrames = visible
            if visible {
                if frames.isEmpty, !failed, !loading { load() }
                guard !failed, frames.count > 1, timer == nil else { return }
                show(index)
                schedule()
            } else if timer != nil || frames.count > 1 || loading {
                generation += 1
                loading = false
                timer?.invalidate()
                timer = nil
                let current = canvas?.image
                frames = []
                delays = []
                canvas?.image = current
            }
        }

        /// ImageIO runs off the main thread. A tile that leaves before the decode finishes keeps the frame it already showed.
        private func load() {
            loading = true
            let path = path
            let generation = generation
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let decoded = CoverFile.frames(at: path)
                let pictures = decoded.map(\.image)
                let delays = decoded.map(\.seconds)
                DispatchQueue.main.async {
                    guard let self, self.generation == generation, self.active, self.wantsFrames, self.path == path else { return }
                    self.loading = false
                    self.frames = pictures.map { NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width), height: CGFloat($0.height))) }
                    self.delays = delays
                    if self.frames.isEmpty { self.failed = true; return }
                    if self.index >= self.frames.count { self.index = 0 }
                    self.show(self.index)
                    if self.frames.count > 1, self.timer == nil { self.schedule() }
                }
            }
        }

        private var canvasVisible: Bool {
            guard let canvas else { return false }
            return ClickThroughView.onScreen(canvas)
        }

        private func schedule() {
            guard active, canvasVisible else { return }
            let delay = delays.isEmpty ? 0.1 : delays[index % delays.count]
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.timer = nil
                guard self.active, self.canvasVisible else { return }
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

        func stop() {
            active = false
            wantsFrames = false
            loading = false
            generation += 1
            timer?.invalidate()
            timer = nil
            frames = []
            delays = []
            canvas?.image = nil
        }
    }
}

/// A silent movie, looped, scaled to cover. It does not keep the Mac awake.
/// Off screen the player is released. Coming back plays from where it waited.
struct LoopingMovieFill: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ClickThroughView {
        let box = ClickThroughView()
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspectFill
        playerView.autoresizingMask = [.width, .height]
        playerView.isHidden = true
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.clear.cgColor
        box.onVisibility = { [weak coordinator = context.coordinator] visible in
            coordinator?.setVisible(visible)
        }
        let poster = AspectImageView()
        poster.autoresizingMask = [.width, .height]
        box.addSubview(poster)
        box.addSubview(playerView)
        context.coordinator.bind(url, poster: poster, playerView: playerView)
        return box
    }
    func updateNSView(_ box: ClickThroughView, context: Context) {
        context.coordinator.playerView?.frame = box.bounds
        context.coordinator.posterView?.frame = box.bounds
        if context.coordinator.url != url, let playerView = context.coordinator.playerView, let poster = context.coordinator.posterView {
            context.coordinator.bind(url, poster: poster, playerView: playerView)
        }
        context.coordinator.setVisible(ClickThroughView.onScreen(box))
    }
    static func dismantleNSView(_ box: ClickThroughView, coordinator: Coordinator) {
        box.stopWatching()
        coordinator.stop()
    }

    final class Coordinator {
        private var player: AVPlayer?
        private var loop: NSObjectProtocol?
        private var status: NSKeyValueObservation?
        private var playing = false
        private var active = false
        private var failed = false
        private var parked = CMTime.zero
        private var generation = 0
        var url: URL?
        weak var playerView: AVPlayerView?
        weak var posterView: AspectImageView?

        /// Remembers the file. The player is created only while the tile is on screen.
        func bind(_ url: URL, poster: AspectImageView, playerView: AVPlayerView) {
            let changed = self.url != url
            if changed {
                generation += 1
                releasePlayer(poster: false)
                parked = .zero
                failed = false
                poster.image = nil
            }
            active = true
            self.url = url
            posterView = poster
            self.playerView = playerView
            let host = playerView.superview ?? playerView
            setVisible(ClickThroughView.onScreen(host))
        }

        /// The host view is the one in the scroll view. The player view is hidden until a frame exists, and a hidden view has an empty visible rect, so it cannot be the test.
        func setVisible(_ hostVisible: Bool) {
            guard active, let url, let playerView else { return }
            if hostVisible {
                guard !failed else { return }
                if player == nil { startPlayer(url, in: playerView) }
                else if !playing {
                    playing = true
                    player?.play()
                }
            } else if player != nil {
                parked = player?.currentTime() ?? parked
                releasePlayer()
            }
        }

        func stop() {
            active = false
            releasePlayer()
            posterView?.image = nil
        }

        private func startPlayer(_ url: URL, in view: AVPlayerView) {
            generation += 1
            let token = generation
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 1
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.volume = 0
            player.preventsDisplaySleepDuringVideoPlayback = false
            self.player = player
            view.player = player
            view.updatesNowPlayingInfoCenter = false
            view.isHidden = true
            if posterView?.image == nil { posterView?.image = MoviePoster.image(at: url.path) }
            let resume = parked
            status = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let state = item.status
                DispatchQueue.main.async {
                    guard let self, self.generation == token, self.player === player else { return }
                    if state == .failed { self.noteFailure(); return }
                    guard state == .readyToPlay, view.isHidden else { return }
                    let go = {
                        guard self.generation == token else { return }
                        view.isHidden = false
                        self.playing = true
                        player.play()
                    }
                    if resume.isValid, resume.seconds > 0.05 {
                        player.seek(to: resume, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                            DispatchQueue.main.async { go() }
                        }
                    } else {
                        go()
                    }
                }
            }
            loop = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                guard let self, self.generation == token else { return }
                self.parked = .zero
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    DispatchQueue.main.async {
                        guard self.generation == token else { return }
                        guard self.active else { self.playing = false; return }
                        self.playing = true
                        player.play()
                    }
                }
            }
        }

        /// A file that will not play stays a still. Opening it again on every scroll would keep failing.
        private func noteFailure() {
            failed = true
            releasePlayer()
        }

        /// Drops the decoder. The poster is one frame, drawn under the player view once the player is gone.
        private func releasePlayer(poster show: Bool = true) {
            status = nil
            if let loop { NotificationCenter.default.removeObserver(loop) }
            loop = nil
            playing = false
            player?.pause()
            playerView?.player = nil
            player = nil
            playerView?.isHidden = true
            if show, posterView?.image == nil, let url { posterView?.image = MoviePoster.image(at: url.path) }
        }
    }
}

/// The cover sits inside a button. Clicks belong to that button.
/// A library row is an ordinary scroll view, so a tile that slides away stays in the window and is only clipped.
/// visibleRect is empty then. A missing window means the same. Scrolling does not resize the tile, so a short timer checks too.
final class ClickThroughView: NSView {
    override var isOpaque: Bool { false }
    var onVisibility: ((Bool) -> Void)?
    private var timer: Timer?
    private var reporting = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        arm()
        report()
    }

    override func layout() {
        super.layout()
        report()
    }

    func stopWatching() {
        onVisibility = nil
        timer?.invalidate()
        timer = nil
    }

    /// A fifth of a second catches a scroll. Common mode keeps firing while the row is dragged.
    private func arm() {
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.report() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Windows that have reported themselves on screen. A window that has never reported is not treated as covered:
    /// the occlusion value starts at zero, which is also what a fully covered window reports.
    private static let windowsSeen: NSHashTable<NSWindow> = .weakObjects()

    /// On screen means the window is open, not miniaturized, not covered after it has been seen, and the scroll view has not clipped the tile away.
    static func onScreen(_ view: NSView) -> Bool {
        guard let window = view.window, window.isVisible else { return false }
        if window.occlusionState.contains(.visible) { windowsSeen.add(window) }
        else if windowsSeen.contains(window) { return false }
        guard !view.bounds.isEmpty else { return false }
        return !view.visibleRect.isEmpty
    }

    private func report() {
        guard !reporting else { return }
        reporting = true
        onVisibility?(Self.onScreen(self))
        reporting = false
    }

    deinit { timer?.invalidate() }
}

/// Aspect-fill. The parent clips whatever hangs past the tile.
final class AspectImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func layout() { super.layout(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        image.draw(in: CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h))
    }
}
