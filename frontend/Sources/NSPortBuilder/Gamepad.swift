import AppKit
import GameController

/// A game controller drives the launcher, so a Mac on a TV needs no keyboard (PadFocus moves the focus). The buttons are
/// named as the game names them, by position (dm/host/front_mac.m pad_read): A on the right, B at the bottom, X at the
/// top, Y on the left. The D-pad or left stick moves (held, it repeats), A activates, B goes back, X opens the selected
/// game's launch options, L and R switch the pages. Input counts only while the launcher is the active app: a game it
/// started is in front then, and GameController gives a controller's input to the app in front, so the launcher never
/// acts behind a running game.
final class LauncherGamepad: ObservableObject {
    enum Action: Equatable { case left, right, up, down, a, b, x, y, l, r, plus }

    @Published private(set) var connected = false
    var perform: (Action) -> Void = { _ in }
    private var held: Set<String> = []   // edges, not levels: one press, one action
    private var observers: [NSObjectProtocol] = []
    private var repeatTimer: Timer?
    private var repeating: Action?

    init() {
        let center = NotificationCenter.default
        observers = [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.attach() }
        }
        attach()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver); repeatTimer?.invalidate() }

    private func attach() {
        let pads = GCController.controllers().compactMap(\.extendedGamepad)
        connected = !pads.isEmpty
        for pad in pads { pad.valueChangedHandler = { [weak self] pad, _ in self?.read(pad) } }
    }

    private func read(_ pad: GCExtendedGamepad) {
        let x = pad.dpad.xAxis.value != 0 ? pad.dpad.xAxis.value : pad.leftThumbstick.xAxis.value
        let y = pad.dpad.yAxis.value != 0 ? pad.dpad.yAxis.value : pad.leftThumbstick.yAxis.value
        let state: [(String, Bool, Action)] = [
            ("left", x < -0.5, .left), ("right", x > 0.5, .right), ("up", y > 0.5, .up), ("down", y < -0.5, .down),
            ("a", pad.buttonB.isPressed, .a), ("b", pad.buttonA.isPressed, .b),   // by position: right A, bottom B, top X, left Y
            ("x", pad.buttonY.isPressed, .x), ("y", pad.buttonX.isPressed, .y),
            ("l", pad.leftShoulder.isPressed, .l), ("r", pad.rightShoulder.isPressed, .r),
            ("plus", pad.buttonMenu.isPressed, .plus),   // the console mode's options; the desktop ignores it
        ]
        for (key, down, action) in state {
            if down, !held.contains(key) {
                held.insert(key)
                DispatchQueue.main.async { self.fire(action) }
                if [.left, .right, .up, .down].contains(action) { DispatchQueue.main.async { self.startRepeat(action) } }
            } else if !down, held.contains(key) {
                held.remove(key)
                DispatchQueue.main.async { if self.repeating == action { self.stopRepeat() } }
            }
        }
    }

    private func fire(_ action: Action) { if NSApp.isActive { perform(action) } }

    /// A held direction repeats after 0.4 s, every 0.12 s.
    private func startRepeat(_ action: Action) {
        stopRepeat()
        repeating = action
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self, self.repeating == action else { return }
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.fire(action) }
        }
    }

    private func stopRepeat() { repeatTimer?.invalidate(); repeatTimer = nil; repeating = nil }
}
