import AppKit
import GameController
import os

/// A game controller drives the launcher, so a Mac on a TV needs no keyboard (PadFocus moves the focus). The buttons are
/// named by what is printed on them, which is how GameController reports them (see `face`): the A button activates, B goes
/// back, X opens the selected game's launch options and Y opens the Manage menu. On an Xbox or PlayStation controller A is the
/// bottom button (the cross), on a Nintendo-layout controller it is the one on the right, as its player expects. This is the
/// menus only: what a game receives is the Controls page's layout (By label or By position, #70), which this does not change.
/// The D-pad or left stick moves (held, it repeats), L and R switch the pages. Input counts only while the launcher is the active app: a game it
/// started is in front then, and GameController gives a controller's input to the app in front, so the launcher never
/// acts behind a running game.
final class LauncherGamepad: ObservableObject {
    enum Action: Equatable { case left, right, up, down, a, b, x, y, l, r, plus, select }

    @Published private(set) var connected = false
    /// `select` is the Select-type button (DualShock Share, DualSense Create, Xbox View, Nintendo Minus): GameController's
    /// `buttonOptions`. The system does not claim it, so it always reaches the app. The desktop launcher opens console mode with it.
    var perform: (Action) -> Void = { _ in }
    /// Sees every press with the controller it came from before it navigates. Returning true consumes it (the Controllers sheet uses
    /// this to give the next press to the player being assigned).
    var capture: ((String, Action) -> Bool)?
    /// The GameController button an action reads, in one place (the glyphs of the console mode follow it). GameController names
    /// the face buttons by label: buttonA is the bottom of Apple's diamond (GCExtendedGamepad.h), which is A on an Xbox
    /// controller and the cross on a DualSense, and a Nintendo-layout controller reports the button printed A (on the right) as
    /// buttonA too (seedds/nxnative#382). So one mapping gives every family its own confirm button.
    enum Face { case a, b, x, y }
    static func face(for action: Action) -> Face? {
        switch action {
        case .a: return .a
        case .b: return .b
        case .x: return .x
        case .y: return .y
        default: return nil
        }
    }
    /// One press, one action, per controller: a button held on one controller never hides the same button on another.
    struct Edges {
        private var held: Set<String> = []
        mutating func reset(controller: String) { held = held.filter { !$0.hasPrefix(controller + "/") } }
        /// What changed for `controller` given the state of its buttons: pressed and released actions.
        mutating func changes(controller: String, state: [(String, Bool, Action)]) -> (pressed: [Action], released: [Action]) {
            var pressed: [Action] = [], released: [Action] = []
            for (key, down, action) in state {
                let id = controller + "/" + key
                if down, !held.contains(id) { held.insert(id); pressed.append(action) }
                else if !down, held.contains(id) { held.remove(id); released.append(action) }
            }
            return (pressed, released)
        }
    }
    private var edges = Edges()
    private var observers: [NSObjectProtocol] = []
    private var repeatTimer: Timer?
    private var repeating: Action?
    private static let log = Logger(subsystem: "NX2Apple", category: "console.controllers")

    init() {
        let center = NotificationCenter.default
        observers = [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] note in
                if let pad = note.object as? GCController {
                    if note.name == .GCControllerDidDisconnect {   // nothing of the old instance is kept
                        pad.physicalInputProfile.valueDidChangeHandler = nil
                        self?.edges.reset(controller: String(UInt(bitPattern: ObjectIdentifier(pad).hashValue), radix: 16))
                    }
                    Self.log.debug("\(note.name.rawValue, privacy: .public): vendor \(pad.vendorName ?? "?", privacy: .public), category \(pad.productCategory, privacy: .public), extendedGamepad \(pad.extendedGamepad != nil), attached \(pad.isAttachedToDevice)")
                }
                self?.attach()
            }
        }
        attach()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver); repeatTimer?.invalidate() }

    /// Every controller GameController lists, wired or wireless, whatever its vendor, drives the launcher: each gets a handler on its
    /// physical input profile (an extended gamepad is one, so are the simpler ones).
    private func attach() {
        let pads = GCController.controllers()
        connected = !pads.isEmpty
        for pad in pads {
            let id = String(UInt(bitPattern: ObjectIdentifier(pad).hashValue), radix: 16)
            pad.physicalInputProfile.valueDidChangeHandler = { [weak self] profile, _ in self?.read(profile, controller: id) }
        }
    }

    private func read(_ pad: GCPhysicalInputProfile, controller: String) {
        func button(_ name: String) -> Bool { pad.buttons[name]?.isPressed ?? false }
        let dpad = pad.dpads[GCInputDirectionPad], stick = pad.dpads[GCInputLeftThumbstick]
        let x = (dpad?.xAxis.value ?? 0) != 0 ? dpad!.xAxis.value : (stick?.xAxis.value ?? 0)
        let y = (dpad?.yAxis.value ?? 0) != 0 ? dpad!.yAxis.value : (stick?.yAxis.value ?? 0)
        let state: [(String, Bool, Action)] = [
            ("left", x < -0.5, .left), ("right", x > 0.5, .right), ("up", y > 0.5, .up), ("down", y < -0.5, .down),
            ("a", button(GCInputButtonA), .a), ("b", button(GCInputButtonB), .b),   // by label, see `face`
            ("x", button(GCInputButtonX), .x), ("y", button(GCInputButtonY), .y),
            ("l", button(GCInputLeftShoulder), .l), ("r", button(GCInputRightShoulder), .r),
            ("plus", button(GCInputButtonMenu), .plus), ("select", button(GCInputButtonOptions), .select),
        ]
        let (pressed, released) = edges.changes(controller: controller, state: state)
        for action in pressed {
            DispatchQueue.main.async {
                if NSApp.isActive, let capture = self.capture, capture(controller, action) { return }
                self.fire(action)
                if [.left, .right, .up, .down].contains(action) { self.startRepeat(action) }
            }
        }
        for action in released { DispatchQueue.main.async { if self.repeating == action { self.stopRepeat() } } }
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
