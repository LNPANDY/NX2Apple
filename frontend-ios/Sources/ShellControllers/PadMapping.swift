import ShellUI

/// A controller's buttons as GameController names them, by label. buttonA is the bottom of Apple's diamond: A on an
/// Xbox controller, the cross on a PlayStation controller, and the button printed A (on the right) on a Nintendo
/// controller, so every family confirms with its own button. The same mapping as the Mac launcher's console mode.
public enum PadButton: Hashable, Sendable {
    case a, b, x, y, menu, options, leftShoulder, rightShoulder
}

/// One controller's state at a moment: the D-pad or left stick as x and y from -1 to 1, and the buttons held.
public struct PadState: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var buttons: Set<PadButton>
    public init(x: Float = 0, y: Float = 0, buttons: Set<PadButton> = []) {
        self.x = x
        self.y = y
        self.buttons = buttons
    }
}

/// Turns controller states into shell actions: one press, one action, per controller, so a button held on one
/// controller never hides the same button on another. The pure part of the adapter, tested without hardware.
public struct PadMapper: Sendable {
    /// How far the stick or D-pad must move before it counts as a direction.
    public static let deadzone: Float = 0.5

    private var held: [String: Set<String>] = [:]
    public init() {}

    /// The action of each button: A activates, B goes back, X and Menu open the game's settings, Y opens Controllers.
    public static func action(for button: PadButton) -> ShellInput.Action? {
        switch button {
        case .a: .activate
        case .b: .back
        case .x, .menu: .settings
        case .y: .controllers
        case .options, .leftShoulder, .rightShoulder: nil
        }
    }

    /// The direction the state points to, the stronger axis winning, inside the deadzone none.
    public static func direction(x: Float, y: Float) -> ShellInput.Action? {
        if abs(x) >= abs(y) {
            if x > deadzone { return .right }
            if x < -deadzone { return .left }
        } else {
            if y > deadzone { return .up }
            if y < -deadzone { return .down }
        }
        return nil
    }

    /// What changed for `controller`: the actions newly pressed and released.
    public mutating func changes(controller: String, state: PadState) -> (pressed: [ShellInput.Action], released: [ShellInput.Action]) {
        var now: [String: ShellInput.Action] = [:]
        if let direction = Self.direction(x: state.x, y: state.y) { now["dir.\(direction)"] = direction }
        for button in state.buttons {
            if let action = Self.action(for: button) { now["btn.\(button)"] = action }
        }
        let before = held[controller] ?? []
        let pressed = now.filter { !before.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
        let releasedKeys = before.subtracting(now.keys)
        let released = releasedKeys.compactMap { key -> ShellInput.Action? in
            guard key.hasPrefix("dir.") else { return nil }
            return Self.directionAction(key)
        }
        held[controller] = Set(now.keys)
        return (pressed, released)
    }

    /// Forget a controller, after it disconnects.
    public mutating func reset(controller: String) { held[controller] = nil }

    private static func directionAction(_ key: String) -> ShellInput.Action? {
        switch key {
        case "dir.left": .left
        case "dir.right": .right
        case "dir.up": .up
        case "dir.down": .down
        default: nil
        }
    }

    static func isDirection(_ action: ShellInput.Action) -> Bool {
        switch action {
        case .left, .right, .up, .down: true
        default: false
        }
    }
}

/// A held direction repeats like the Mac launcher's: after 0.4 s, then every 0.12 s.
public enum RepeatTiming {
    public static let delay = 0.4
    public static let interval = 0.12
    /// How many moves a direction held for `seconds` makes, the first press included.
    public static func moves(heldFor seconds: Double) -> Int {
        guard seconds >= delay else { return 1 }
        return 2 + Int(((seconds - delay) / interval).rounded(.down))
    }
}
