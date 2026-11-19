import Foundation
#if canImport(AVKit) && os(iOS)
import AVFoundation
import AVKit
import CoreMedia
import UIKit
#endif

/// Snapshot describing a floating Home Screen Shortcuts walkthrough session.
public struct HomeScreenGuideRequest: Equatable, Sendable {
    public var gameTitle: String
    public var iconPNG: Data?
    public var steps: [String]
    public var hintText: String

    public init(gameTitle: String, iconPNG: Data? = nil, steps: [String], hintText: String) {
        self.gameTitle = gameTitle
        self.iconPNG = iconPNG
        self.steps = steps
        self.hintText = hintText
    }
}

/// Pure step state machine shared by the floating PiP guide and unit tests.
public struct HomeScreenGuideStepper: Equatable, Sendable {
    public let gameTitle: String
    public let steps: [String]
    public private(set) var currentIndex: Int

    public init(gameTitle: String, steps: [String], initialIndex: Int = 0) {
        self.gameTitle = gameTitle
        self.steps = steps
        self.currentIndex = steps.isEmpty ? 0 : min(max(0, initialIndex), steps.count - 1)
    }

    public var totalSteps: Int { steps.count }
    public var currentStepNumber: Int { steps.isEmpty ? 0 : currentIndex + 1 }
    public var currentStepText: String { steps.isEmpty ? "" : steps[currentIndex] }
    public var progressText: String { steps.isEmpty ? "0 / 0" : "\(currentStepNumber) / \(totalSteps)" }
    public var canStepBackward: Bool { currentIndex > 0 }
    public var canStepForward: Bool { currentIndex + 1 < steps.count }

    @discardableResult
    public mutating func stepForward() -> Bool {
        guard canStepForward else { return false }
        currentIndex += 1
        return true
    }

    @discardableResult
    public mutating func stepBackward() -> Bool {
        guard canStepBackward else { return false }
        currentIndex -= 1
        return true
    }

    /// Maps PiP forward/backward skip controls (`skipByInterval`) to step navigation.
    @discardableResult
    public mutating func applySkip(seconds: Double) -> Bool {
        if seconds > 0 { return stepForward() }
        if seconds < 0 { return stepBackward() }
        return false
    }
}

/// Platform-neutral audio-session snapshot & restore guard used by `HomeScreenGuidePiPController`.
/// Snapshots the prior `(category, mode, options)` before switching to `.moviePlayback`, rolls back
/// immediately if activation fails, and deactivates before restoring on `stop()` so game audio
/// sessions are never left polluted.
internal final class HomeScreenGuideAudioSessionGuard<Snapshot> {
    private let capture: () -> Snapshot
    private let applyGuideCategory: () throws -> Void
    private let restoreCategory: (Snapshot) throws -> Void
    private let setActive: (_ active: Bool, _ notifyOthers: Bool) throws -> Void

    private var savedSnapshot: Snapshot?
    private(set) var isActivated = false

    init(
        capture: @escaping () -> Snapshot,
        applyGuideCategory: @escaping () throws -> Void,
        restoreCategory: @escaping (Snapshot) throws -> Void,
        setActive: @escaping (_ active: Bool, _ notifyOthers: Bool) throws -> Void
    ) {
        self.capture = capture
        self.applyGuideCategory = applyGuideCategory
        self.restoreCategory = restoreCategory
        self.setActive = setActive
    }

    @discardableResult
    func activate() -> Bool {
        let snapshot = capture()
        do {
            try applyGuideCategory()
            try setActive(true, false)
            savedSnapshot = snapshot
            isActivated = true
            return true
        } catch {
            try? restoreCategory(snapshot)
            savedSnapshot = nil
            isActivated = false
            return false
        }
    }

    func deactivateAndRestore() {
        guard isActivated else { return }
        isActivated = false
        let snapshot = savedSnapshot
        savedSnapshot = nil
        try? setActive(false, true)
        if let snapshot {
            try? restoreCategory(snapshot)
        }
    }
}

/// Manages a zero-extension `AVPictureInPictureController` floating step card while the player works in Shortcuts.
@MainActor public final class HomeScreenGuidePiPController {
    public private(set) var activeStepper: HomeScreenGuideStepper?
    public private(set) var isPrepared = false
    public private(set) var hasRequestedStart = false
    public private(set) var isActive = false
    internal private(set) var startGeneration: UInt64 = 0

    internal func isCurrentGeneration(_ generation: UInt64) -> Bool {
        startGeneration == generation
    }

    public static var isSupported: Bool {
        #if canImport(AVKit) && os(iOS)
        return AVPictureInPictureController.isPictureInPictureSupported()
        #else
        return false
        #endif
    }

    public init() {}

    #if canImport(AVKit) && os(iOS)
    private struct SavedAudioSessionState {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    private var hostView: SampleBufferHostView?
    private var pipController: AVPictureInPictureController?
    private var delegateBridge: PiPDelegateBridge?
    private var possibleObservation: NSKeyValueObservation?
    private lazy var audioSessionGuard = HomeScreenGuideAudioSessionGuard<SavedAudioSessionState>(
        capture: {
            let session = AVAudioSession.sharedInstance()
            return SavedAudioSessionState(
                category: session.category,
                mode: session.mode,
                options: session.categoryOptions
            )
        },
        applyGuideCategory: {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        },
        restoreCategory: { saved in
            try AVAudioSession.sharedInstance().setCategory(saved.category, mode: saved.mode, options: saved.options)
        },
        setActive: { active, notifyOthers in
            if active {
                try AVAudioSession.sharedInstance().setActive(true)
            } else {
                try AVAudioSession.sharedInstance().setActive(false, options: notifyOthers ? .notifyOthersOnDeactivation : [])
            }
        }
    )

    /// Pre-warms the hidden `AVSampleBufferDisplayLayer` and `AVPictureInPictureController` when the guide sheet opens
    /// so `isPictureInPicturePossible` is already `true` by the time the player taps Save Icon & Open Shortcuts.
    public func prepare(_ request: HomeScreenGuideRequest) {
        guard Self.isSupported, !request.steps.isEmpty, let window = Self.activeKeyWindow() else { return }
        let stepper = HomeScreenGuideStepper(gameTitle: request.gameTitle, steps: request.steps)
        guard let initialBuffer = Self.makeSampleBuffer(stepper: stepper, iconPNG: request.iconPNG, hintText: request.hintText) else {
            return
        }

        if isPrepared, !hasRequestedStart, !isActive,
           let view = hostView, view.window === window,
           let controller = pipController,
           let bridge = delegateBridge {
            bridge.update(stepper: stepper, iconPNG: request.iconPNG, hintText: request.hintText)
            view.resetTimebaseMidpoint()
            view.enqueue(initialBuffer)
            controller.invalidatePlaybackState()
            activeStepper = stepper
            return
        }

        stop()
        startGeneration &+= 1
        guard audioSessionGuard.activate() else {
            return
        }

        let view = SampleBufferHostView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        window.addSubview(view)
        view.configureTimebase()
        view.enqueue(initialBuffer)

        let bridge = PiPDelegateBridge(stepper: stepper, iconPNG: request.iconPNG, hintText: request.hintText)
        bridge.onStepChanged = { [weak self] updated, iconPNG, hintText in
            guard let self, let view = self.hostView else { return }
            self.activeStepper = updated
            if let sample = Self.makeSampleBuffer(stepper: updated, iconPNG: iconPNG, hintText: hintText) {
                view.resetTimebaseMidpoint()
                view.enqueue(sample)
            }
            self.pipController?.invalidatePlaybackState()
        }
        bridge.onDidStop = { [weak self] in
            self?.stop()
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: view.displayLayer,
            playbackDelegate: bridge
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = bridge
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = false

        hostView = view
        delegateBridge = bridge
        pipController = controller
        activeStepper = stepper
        isPrepared = true
        hasRequestedStart = false
        isActive = false
    }

    /// Tears down a pre-warmed session only if the player never triggered `start(_)`.
    public func cancelPrepared() {
        guard isPrepared, !hasRequestedStart, !isActive else { return }
        stop()
    }

    @discardableResult
    public func start(_ request: HomeScreenGuideRequest) async -> Bool {
        guard Self.isSupported, !request.steps.isEmpty else { return false }

        if isPrepared, !isActive,
           let view = hostView, view.window != nil,
           let controller = pipController,
           let bridge = delegateBridge {
            let stepper = HomeScreenGuideStepper(gameTitle: request.gameTitle, steps: request.steps)
            if let sample = Self.makeSampleBuffer(stepper: stepper, iconPNG: request.iconPNG, hintText: request.hintText) {
                bridge.update(stepper: stepper, iconPNG: request.iconPNG, hintText: request.hintText)
                view.resetTimebaseMidpoint()
                view.enqueue(sample)
                controller.invalidatePlaybackState()
                activeStepper = stepper
            }
        } else {
            stop()
            prepare(request)
            guard isPrepared else { return false }
        }

        startGeneration &+= 1
        let gen = startGeneration
        hasRequestedStart = true
        isActive = true

        guard let controller = pipController else { return false }

        if !controller.isPictureInPicturePossible {
            possibleObservation?.invalidate()
            possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { _, _ in }
            let possibleDeadline = ContinuousClock.now + .milliseconds(1200)
            while !controller.isPictureInPicturePossible && ContinuousClock.now < possibleDeadline {
                try? await Task.sleep(for: .milliseconds(40))
                guard isCurrentGeneration(gen), let current = pipController else { return false }
                if current.isPictureInPicturePossible { break }
            }
            possibleObservation?.invalidate()
            possibleObservation = nil
        }

        guard isCurrentGeneration(gen), let current = pipController else { return false }

        if current.isPictureInPicturePossible {
            if !current.isPictureInPictureActive {
                current.startPictureInPicture()
            }
            let startDeadline = ContinuousClock.now + .milliseconds(450)
            while ContinuousClock.now < startDeadline {
                guard isCurrentGeneration(gen), let latest = pipController else { return false }
                if latest.isPictureInPictureActive || (delegateBridge?.hasStartedOrWillStart == true) {
                    try? await Task.sleep(for: .milliseconds(80))
                    return isCurrentGeneration(gen) && isActive
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }

        return isCurrentGeneration(gen) && isActive
    }

    public func stop() {
        startGeneration &+= 1
        possibleObservation?.invalidate()
        possibleObservation = nil
        if let controller = pipController {
            controller.canStartPictureInPictureAutomaticallyFromInline = false
            if controller.isPictureInPictureActive {
                controller.stopPictureInPicture()
            }
            controller.delegate = nil
        }
        pipController = nil
        delegateBridge?.invalidate()
        delegateBridge = nil
        hostView?.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        hostView?.removeFromSuperview()
        hostView = nil
        activeStepper = nil
        isPrepared = false
        hasRequestedStart = false
        isActive = false
        audioSessionGuard.deactivateAndRestore()
    }

    private static func activeKeyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
    }

    private static func makeSampleBuffer(stepper: HomeScreenGuideStepper, iconPNG: Data?, hintText: String) -> CMSampleBuffer? {
        guard let pb = HomeScreenGuideCardRenderer.renderPixelBuffer(stepper: stepper, iconPNG: iconPNG, hintText: hintText) else { return nil }
        var desc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &desc) == noErr, let desc else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: 150, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: desc, sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let sb else { return nil }
        sb.sampleAttachments[0][.displayImmediately] = true
        return sb
    }
    #else
    public func prepare(_ request: HomeScreenGuideRequest) {
        guard !request.steps.isEmpty else { return }
        let stepper = HomeScreenGuideStepper(gameTitle: request.gameTitle, steps: request.steps)
        if isPrepared && !hasRequestedStart && !isActive {
            activeStepper = stepper
            return
        }
        stop()
        startGeneration &+= 1
        activeStepper = stepper
        isPrepared = true
        hasRequestedStart = false
        isActive = false
    }

    public func cancelPrepared() {
        guard isPrepared, !hasRequestedStart, !isActive else { return }
        stop()
    }

    @discardableResult
    public func start(_ request: HomeScreenGuideRequest) async -> Bool {
        if !isPrepared {
            stop()
        }
        startGeneration &+= 1
        hasRequestedStart = true
        isActive = false
        return false
    }

    public func stop() {
        startGeneration &+= 1
        activeStepper = nil
        isPrepared = false
        hasRequestedStart = false
        isActive = false
    }
    #endif
}

#if canImport(AVKit) && os(iOS)
private final class SampleBufferHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    override init(frame: CGRect) { super.init(frame: frame); displayLayer.videoGravity = .resizeAspect }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configureTimebase() {
        var tb: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb) == noErr, let tb else { return }
        displayLayer.controlTimebase = tb
        CMTimebaseSetTime(tb, time: CMTime(seconds: 150, preferredTimescale: 600))
        CMTimebaseSetRate(tb, rate: 0.001)
    }

    func resetTimebaseMidpoint() {
        if let tb = displayLayer.controlTimebase {
            CMTimebaseSetTime(tb, time: CMTime(seconds: 150, preferredTimescale: 600))
            CMTimebaseSetRate(tb, rate: 0.001)
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let renderer = displayLayer.sampleBufferRenderer
        renderer.flush()
        renderer.enqueue(sampleBuffer)
    }
}

/// Thread-safe delegate bridge so nonisolated AVKit callbacks never trip Swift 6 `@MainActor` queue assertions.
private final class PiPDelegateBridge: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var stepper: HomeScreenGuideStepper
    private var iconPNG: Data?
    private var hintText: String
    private var invalidated = false
    private var startedOrWillStart = false
    var onStepChanged: (@MainActor @Sendable (HomeScreenGuideStepper, Data?, String) -> Void)?
    var onDidStop: (@MainActor @Sendable () -> Void)?

    init(stepper: HomeScreenGuideStepper, iconPNG: Data?, hintText: String) {
        self.stepper = stepper
        self.iconPNG = iconPNG
        self.hintText = hintText
    }

    var hasStartedOrWillStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return startedOrWillStart && !invalidated
    }

    func update(stepper: HomeScreenGuideStepper, iconPNG: Data?, hintText: String) {
        lock.lock()
        self.stepper = stepper
        self.iconPNG = iconPNG
        self.hintText = hintText
        self.startedOrWillStart = false
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        startedOrWillStart = false
        onStepChanged = nil
        onDidStop = nil
        lock.unlock()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(seconds: 3600, preferredTimescale: 600))
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        lock.lock()
        if !invalidated { startedOrWillStart = true }
        lock.unlock()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        lock.lock()
        if !invalidated { startedOrWillStart = true }
        lock.unlock()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        lock.lock()
        let active = !invalidated
        var updated = stepper
        if active { _ = updated.applySkip(seconds: skipInterval.seconds); stepper = updated }
        let callback = active ? onStepChanged : nil
        let png = iconPNG
        let hint = hintText
        lock.unlock()
        guard let callback else { completionHandler(); return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { callback(updated, png, hint) }
            completionHandler()
        } else {
            struct CompletionBox: @unchecked Sendable { let run: () -> Void }
            let box = CompletionBox(run: completionHandler)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { callback(updated, png, hint) }
                box.run()
            }
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { notifyStop() }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) { notifyStop() }
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        notifyStop()
        completionHandler(true)
    }

    private func notifyStop() {
        lock.lock()
        let callback = invalidated ? nil : onDidStop
        lock.unlock()
        guard let callback else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { callback() } }
    }
}
#endif
