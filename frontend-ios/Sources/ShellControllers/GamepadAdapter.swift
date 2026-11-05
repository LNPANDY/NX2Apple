import Foundation
import GameController
import ShellUI

/// A connected controller as the adapter sees it. The host turns it into a `ControllerInfo` with its own words.
public struct ConnectedController: Equatable, Sendable {
    public var id: String
    public var name: String
    /// 1 for the first controller connected.
    public var player: Int
    public var family: ControllerFamily
    /// 0 to 100, nil when the controller does not report it.
    public var batteryPercent: Int?
    public var charging: Bool
}

/// Real controllers for the shell, on top of GameController: every controller GameController lists, wired or wireless,
/// drives the views through `ShellInput` actions. The D-pad and the left stick move (held, they repeat), A activates,
/// B goes back, X and Menu open the game's settings, Y opens Controllers. The device family goes with each action, so the
/// hints draw that controller's own glyphs. Not part of the views: the host owns it and passes the actions on.
@MainActor public final class GamepadAdapter {
    public var onInput: (ShellInput.Action, InputDevice) -> Void = { _, _ in }
    /// A button or direction let go. The shell restarts its window for the system's echo of a controller button here,
    /// since iPadOS sends that echo as the button comes up.
    public var onRelease: (ShellInput.Action, InputDevice) -> Void = { _, _ in }
    public var onControllersChange: ([ConnectedController]) -> Void = { _ in }
    /// Every state of any controller, for the button test. Nil (the default) reports none. Set, it reports the state of
    /// the first controller at once, then each change of whichever controller moved, and again the first controller's
    /// (nil with none left) when one connects or disconnects, so a controller that went away leaves nothing held.
    public var onSnapshot: ((PadSnapshot?) -> Void)? {
        didSet { reportFirstSnapshot() }
    }
    private func reportFirstSnapshot() {
        guard let onSnapshot else { return }
        onSnapshot(GCController.controllers().first.map { Self.snapshot(of: $0.physicalInputProfile, name: Self.name(of: $0)) })
    }

    private var mapper = PadMapper()
    private var observers: [NSObjectProtocol] = []
    private var repeatTask: Task<Void, Never>?
    private var repeating: (action: ShellInput.Action, controller: String)?
    private var batteryTask: Task<Void, Never>?

    public init() {}

    public func start() {
        stop()
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let disconnected = note.name == .GCControllerDidDisconnect
                let gone = disconnected ? (note.object as? GCController) : nil
                gone?.physicalInputProfile.valueDidChangeHandler = nil
                let id = gone.map(Self.id(of:))
                MainActor.assumeIsolated {
                    if let id {
                        self?.mapper.reset(controller: id)
                        if self?.repeating?.controller == id { self?.stopRepeat() }
                    }
                    self?.attach()
                }
            })
        }
        attach()
        // Battery levels change slowly and GameController does not announce them: a look every 30 seconds.
        batteryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.publish()
            }
        }
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for pad in GCController.controllers() { pad.physicalInputProfile.valueDidChangeHandler = nil }
        stopRepeat()
        batteryTask?.cancel()
        batteryTask = nil
    }

    private nonisolated static func id(of controller: GCController) -> String {
        String(UInt(bitPattern: ObjectIdentifier(controller).hashValue), radix: 16)
    }

    private func attach() {
        for pad in GCController.controllers() {
            let id = Self.id(of: pad)
            let family = ControllerFamily(productCategory: pad.productCategory)
            let name = Self.name(of: pad)
            pad.physicalInputProfile.valueDidChangeHandler = { [weak self] profile, _ in
                let state = Self.state(of: profile)
                let snapshot = Self.snapshot(of: profile, name: name)
                MainActor.assumeIsolated {
                    self?.onSnapshot?(snapshot)
                    self?.read(state, controller: id, family: family)
                }
            }
        }
        publish()
        reportFirstSnapshot()
    }

    private nonisolated static func state(of pad: GCPhysicalInputProfile) -> PadState {
        func pressed(_ name: String) -> Bool { pad.buttons[name]?.isPressed ?? false }
        let dpad = pad.dpads[GCInputDirectionPad], stick = pad.dpads[GCInputLeftThumbstick]
        let dx = dpad?.xAxis.value ?? 0, dy = dpad?.yAxis.value ?? 0
        let x = dx != 0 ? dx : (stick?.xAxis.value ?? 0)
        let y = dy != 0 ? dy : (stick?.yAxis.value ?? 0)
        var buttons: Set<PadButton> = []
        let names: [(String, PadButton)] = [(GCInputButtonA, .a), (GCInputButtonB, .b), (GCInputButtonX, .x), (GCInputButtonY, .y),
                                            (GCInputButtonMenu, .menu), (GCInputButtonOptions, .options),
                                            (GCInputLeftShoulder, .leftShoulder), (GCInputRightShoulder, .rightShoulder)]
        for (name, button) in names where pressed(name) { buttons.insert(button) }
        return PadState(x: x, y: y, buttons: buttons)
    }

    private nonisolated static func name(of pad: GCController) -> String { pad.vendorName ?? pad.productCategory }

    /// Everything the button test draws, by GameController's names: buttonA is the bottom face button on the drawing.
    private nonisolated static func snapshot(of pad: GCPhysicalInputProfile, name: String) -> PadSnapshot {
        func pressed(_ name: String) -> Bool { pad.buttons[name]?.isPressed ?? false }
        let names: [(String, PadElement)] = [(GCInputButtonA, .a), (GCInputButtonB, .b), (GCInputButtonX, .x), (GCInputButtonY, .y),
                                             (GCInputLeftShoulder, .leftBumper), (GCInputRightShoulder, .rightBumper),
                                             (GCInputLeftTrigger, .leftTrigger), (GCInputRightTrigger, .rightTrigger),
                                             (GCInputLeftThumbstickButton, .leftStick), (GCInputRightThumbstickButton, .rightStick),
                                             (GCInputButtonOptions, .view), (GCInputButtonMenu, .menu), (GCInputButtonHome, .home)]
        var held = Set(names.filter { pressed($0.0) }.map(\.1))
        if let dpad = pad.dpads[GCInputDirectionPad] {
            if dpad.up.isPressed { held.insert(.up) }
            if dpad.down.isPressed { held.insert(.down) }
            if dpad.left.isPressed { held.insert(.left) }
            if dpad.right.isPressed { held.insert(.right) }
        }
        func stick(_ name: String) -> CGPoint {
            guard let s = pad.dpads[name] else { return .zero }
            return CGPoint(x: Double(s.xAxis.value), y: Double(s.yAxis.value))
        }
        return PadSnapshot(name: name, pressed: held, leftStick: stick(GCInputLeftThumbstick), rightStick: stick(GCInputRightThumbstick),
                           leftTrigger: Double(pad.buttons[GCInputLeftTrigger]?.value ?? 0),
                           rightTrigger: Double(pad.buttons[GCInputRightTrigger]?.value ?? 0))
    }

    private func read(_ state: PadState, controller: String, family: ControllerFamily) {
        let (pressed, released) = mapper.changes(controller: controller, state: state)
        for action in released {
            if repeating?.action == action && repeating?.controller == controller { stopRepeat() }
            onRelease(action, .controller(family))
        }
        for action in pressed {
            onInput(action, .controller(family))
            if PadMapper.isDirection(action) { startRepeat(action, controller: controller, family: family) }
        }
    }

    private func startRepeat(_ action: ShellInput.Action, controller: String, family: ControllerFamily) {
        stopRepeat()
        repeating = (action, controller)
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RepeatTiming.delay))
            while !Task.isCancelled {
                self?.onInput(action, .controller(family))
                try? await Task.sleep(for: .seconds(RepeatTiming.interval))
            }
        }
    }

    private func stopRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
        repeating = nil
    }

    private func publish() {
        let pads = GCController.controllers()
        onControllersChange(pads.enumerated().map { index, pad in
            let battery = pad.battery
            let level = battery.map { Int(($0.batteryLevel * 100).rounded()) }
            return ConnectedController(id: Self.id(of: pad), name: pad.vendorName ?? pad.productCategory,
                                       player: index + 1, family: ControllerFamily(productCategory: pad.productCategory),
                                       batteryPercent: battery?.batteryState == .unknown ? nil : level,
                                       charging: battery?.batteryState == .charging)
        })
    }
}
