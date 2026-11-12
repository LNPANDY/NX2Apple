import AppKit
import GameController
import os
import NXCore

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
    private static weak var inputOwner: LauncherGamepad?
    private var action: (Action) -> Void = { _ in }
    var perform: (Action) -> Void {
        get { action }
        set {
            if Self.inputOwner !== self {
                Self.inputOwner?.inputGeneration += 1
                inputGeneration += 1
                // GC reports went to the previous view while this one was inactive. Steam's
                // broadcast reports already kept its edges current, so preserve those held buttons.
                for id in gcControllerIDs { edges.reset(controller: id) }
            }
            action = newValue; Self.inputOwner?.stopRepeat(); Self.inputOwner = self
        }
    }
    /// The view releases its input route when it disappears, including during console transitions.
    func deactivate() {
        if Self.inputOwner === self { Self.inputOwner = nil }
        action = { _ in }; capture = nil; inputGeneration += 1; stopRepeat()
    }
    /// Sees every press with the controller it came from before it navigates. Returning true consumes it (the Controllers sheet uses
    /// this to give the next press to the player being assigned).
    var capture: ((String, Action) -> Bool)?

    struct RawPadInput {
        var dpadX: Float = 0, dpadY: Float = 0
        var leftStickX: Float = 0, leftStickY: Float = 0
        var rightStickX: Float = 0, rightStickY: Float = 0
        var a = false, b = false, x = false, y = false
        var l = false, r = false, plus = false, select = false
    }

    static func isJoyCon(category: String?, vendorName: String? = nil) -> Bool {
        let s = ((category ?? "") + " " + (vendorName ?? "")).lowercased().replacingOccurrences(of: "-", with: "")
        return s.contains("joycon")
    }

    /// Per-controller button and direction states. When `splitJoyCon` is true on a Joy-Con, Left Joy-Con (`.L`) is rotated 90°
    /// counter-clockwise and Right Joy-Con (`.R`) is rotated 90° clockwise so launcher and console mode match sideways play (#740).
    static func states(controller: String, input: RawPadInput, splitJoyCon: Bool) -> [(controller: String, state: [(String, Bool, Action)])] {
        guard splitJoyCon else {
            let x = input.dpadX != 0 ? input.dpadX : input.leftStickX
            let y = input.dpadY != 0 ? input.dpadY : input.leftStickY
            return [(controller, [
                ("left", x < -0.5, .left), ("right", x > 0.5, .right), ("up", y > 0.5, .up), ("down", y < -0.5, .down),
                ("a", input.a, .a), ("b", input.b, .b),   // by label, see `face`
                ("x", input.x, .x), ("y", input.y, .y),
                ("l", input.l, .l), ("r", input.r, .r),
                ("plus", input.plus, .plus), ("select", input.select, .select),
            ])]
        }
        // Left Joy-Con held sideways (90° CCW, rail on top): left stick rotated 90° CCW, D-pad rotated 90° CCW as face buttons (Down->A, Left->B, Right->X, Up->Y)
        let lx = -input.leftStickY, ly = input.leftStickX
        let leftState: [(String, Bool, Action)] = [
            ("left", lx < -0.5, .left), ("right", lx > 0.5, .right), ("up", ly > 0.5, .up), ("down", ly < -0.5, .down),
            ("a", input.dpadY < -0.5, .a), ("b", input.dpadX < -0.5, .b),
            ("x", input.dpadX > 0.5, .x), ("y", input.dpadY > 0.5, .y),
            ("l", input.l, .l), ("select", input.select, .select),
        ]
        // Right Joy-Con held sideways (90° CW, rail on top): right stick rotated 90° CW, ABXY rotated 90° CW (X->A, A->B, Y->X, B->Y)
        let rx = input.rightStickY, ry = -input.rightStickX
        let rightState: [(String, Bool, Action)] = [
            ("left", rx < -0.5, .left), ("right", rx > 0.5, .right), ("up", ry > 0.5, .up), ("down", ry < -0.5, .down),
            ("a", input.x, .a), ("b", input.a, .b),
            ("x", input.y, .x), ("y", input.b, .y),
            ("r", input.r, .r), ("plus", input.plus, .plus),
        ]
        return [(controller + ".L", leftState), (controller + ".R", rightState)]
    }
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
        private var splitMode: [String: Bool] = [:]
        mutating func reset(controller: String) {
            held = held.filter { !$0.hasPrefix(controller + "/") && !$0.hasPrefix(controller + ".L/") && !$0.hasPrefix(controller + ".R/") }
            splitMode.removeValue(forKey: controller)
        }
        /// Synchronizes held state without firing actions when `split` mode changes for `baseController` so a button held across the toggle does not re-fire under its new mapping.
        mutating func syncSplitMode(baseController: String, split: Bool, groups: [(controller: String, state: [(String, Bool, Action)])]) -> Bool {
            defer { splitMode[baseController] = split }
            guard let previous = splitMode[baseController], previous != split else { return false }
            held = held.filter { !$0.hasPrefix(baseController + "/") && !$0.hasPrefix(baseController + ".L/") && !$0.hasPrefix(baseController + ".R/") }
            for group in groups {
                for (key, down, _) in group.state where down {
                    held.insert(group.controller + "/" + key)
                }
            }
            return true
        }
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
    private var inputGeneration = 0
    private var gcControllerIDs: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private var repeatTimer: Timer?
    private var repeating: Action?
    private var repeatingController: String?
    private let steam: SteamLinkGamepads?
    private let appIsActive: () -> Bool
    private static let log = Logger(subsystem: "NX2Apple", category: "console.controllers")

    init(steam: SteamLinkGamepads? = .shared, observeSystem: Bool = true,
         appIsActive: @escaping () -> Bool = { NSApp?.isActive ?? false }) {
        self.steam = steam
        self.appIsActive = appIsActive
        let center = NotificationCenter.default
        observers = (observeSystem ? [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] : []).map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] note in
                if let pad = note.object as? GCController {
                    if note.name == .GCControllerDidDisconnect {   // nothing of the old instance is kept
                        pad.physicalInputProfile.valueDidChangeHandler = nil
                        self?.disconnected(String(UInt(bitPattern: ObjectIdentifier(pad).hashValue), radix: 16))
                    }
                    Self.log.debug("\(note.name.rawValue, privacy: .public): vendor \(pad.vendorName ?? "?", privacy: .public), category \(pad.productCategory, privacy: .public), extendedGamepad \(pad.extendedGamepad != nil), attached \(pad.isAttachedToDevice)")
                }
                self?.attach()
            }
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.inputGeneration += 1
            self?.stopRepeat()
        })
        if let steam {
            observers.append(center.addObserver(forName: .steamLinkPadInput, object: steam, queue: .main) { [weak self] note in
                guard let self, let input = note.userInfo?["input"] as? SteamLinkGamepads.Input else { return }
                self.read(Self.input(from: input.state), controller: input.id, isJoyCon: false)
            })
            observers.append(center.addObserver(forName: .steamLinkPadsChanged, object: steam, queue: .main) { [weak self] note in
                if let id = note.userInfo?["removed"] as? String { self?.disconnected(id) }
                self?.connected = !GCController.controllers().isEmpty || !steam.snapshots.isEmpty
            })
        }
        if observeSystem { attach() }
    }

    private func disconnected(_ id: String) {
        inputGeneration += 1
        edges.reset(controller: id)
        gcControllerIDs.remove(id)
        if let repeatingController, [id, id + ".L", id + ".R"].contains(repeatingController) { stopRepeat() }
    }

    static func input(from pad: SteamVirtualGamepad) -> RawPadInput {
        RawPadInput(dpadX: pad.dpadX, dpadY: pad.dpadY, leftStickX: pad.x, leftStickY: pad.y,
                    a: pad.buttons.contains(1), b: pad.buttons.contains(2), x: pad.buttons.contains(3), y: pad.buttons.contains(4),
                    l: pad.buttons.contains(5), r: pad.buttons.contains(6), plus: pad.buttons.contains(9), select: pad.buttons.contains(10))
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver); repeatTimer?.invalidate() }

    /// Every controller GameController lists, wired or wireless, whatever its vendor, drives the launcher: each gets a handler on its
    /// physical input profile (an extended gamepad is one, so are the simpler ones).
    private func attach() {
        let pads = GCController.controllers()
        connected = !pads.isEmpty || !(steam?.snapshots.isEmpty ?? true)
        for pad in pads {
            let id = String(UInt(bitPattern: ObjectIdentifier(pad).hashValue), radix: 16)
            let isJC = Self.isJoyCon(category: pad.productCategory, vendorName: pad.vendorName)
            Self.attach(pad, id: id, isJoyCon: isJC)
        }
    }

    // Every GC callback follows the visible view, even when an older root view handles a hotplug notification last.
    static func attach(_ pad: GCController, id: String, isJoyCon: Bool) {
        pad.physicalInputProfile.valueDidChangeHandler = { profile, _ in
            Self.inputOwner?.read(profile, controller: id, isJoyCon: isJoyCon)
        }
    }

    private func read(_ pad: GCPhysicalInputProfile, controller: String, isJoyCon: Bool) {
        gcControllerIDs.insert(controller)
        func button(_ name: String) -> Bool { pad.buttons[name]?.isPressed ?? false }
        let dpad = pad.dpads[GCInputDirectionPad], lStick = pad.dpads[GCInputLeftThumbstick], rStick = pad.dpads[GCInputRightThumbstick]
        let raw = RawPadInput(
            dpadX: dpad?.xAxis.value ?? 0, dpadY: dpad?.yAxis.value ?? 0,
            leftStickX: lStick?.xAxis.value ?? 0, leftStickY: lStick?.yAxis.value ?? 0,
            rightStickX: rStick?.xAxis.value ?? 0, rightStickY: rStick?.yAxis.value ?? 0,
            a: button(GCInputButtonA), b: button(GCInputButtonB),
            x: button(GCInputButtonX), y: button(GCInputButtonY),
            l: button(GCInputLeftShoulder), r: button(GCInputRightShoulder),
            plus: button(GCInputButtonMenu), select: button(GCInputButtonOptions)
        )
        read(raw, controller: controller, isJoyCon: isJoyCon)
    }

    private func read(_ raw: RawPadInput, controller: String, isJoyCon: Bool) {
        let eligible = appIsActive() && Self.inputOwner === self
        let generation = inputGeneration
        let groups = Self.states(controller: controller, input: raw, splitJoyCon: false)
        if edges.syncSplitMode(baseController: controller, split: false, groups: groups) {
            DispatchQueue.main.async { self.stopRepeat() }
            return
        }
        for group in groups {
            let (pressed, released) = edges.changes(controller: group.controller, state: group.state)
            for action in pressed {
                let subID = group.controller
                DispatchQueue.main.async {
                    guard eligible, generation == self.inputGeneration, self.appIsActive(), Self.inputOwner === self else { return }
                    if let capture = self.capture, capture(subID, action) { return }
                    self.fire(action)
                    if [.left, .right, .up, .down].contains(action) { self.startRepeat(action, controller: subID) }
                }
            }
            for action in released { DispatchQueue.main.async { if self.repeating == action, self.repeatingController == group.controller { self.stopRepeat() } } }
        }
    }

    private func fire(_ action: Action) { if appIsActive(), Self.inputOwner === self { perform(action) } }

    /// A held direction repeats after 0.4 s, every 0.12 s.
    private func startRepeat(_ action: Action, controller: String) {
        stopRepeat()
        repeating = action
        repeatingController = controller
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self, self.repeating == action else { return }
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.fire(action) }
        }
    }

    private func stopRepeat() { repeatTimer?.invalidate(); repeatTimer = nil; repeating = nil; repeatingController = nil }
}
