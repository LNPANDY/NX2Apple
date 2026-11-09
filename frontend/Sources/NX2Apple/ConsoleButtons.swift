import Foundation

/// Console mode's own buttons go by what is printed on the controller, as Xbox and PlayStation menus do: A (GameController's
/// buttonA, the bottom face button: Xbox's A, PlayStation's cross) confirms, B (the right one) goes back, Y (the top one) opens a
/// game's options, + and − (Menu, View) the console's menu, X does nothing. They do not follow the games' button mapping, which
/// is what the buttons send in games. "Swap A and B in menus" (`ConsoleState.menuSwapAB`, on the button mapping page) makes B
/// confirm and A go back, as on a Switch. The D-pad and the left stick move the focus.
enum ConsoleButtons {
    /// The buttons the console reads, in the order a role's hint looks for its button (+ before − for the menu).
    static let buttons: [LauncherGamepad.Action] = [.a, .b, .y, .x, .plus, .select, .l, .r]

    /// The Switch button the host reads a launcher button as. The launcher names GameController's buttons by label, the host by
    /// position in the Nintendo layout (front_mac.m pad_read): buttonA, at the bottom, is the Switch's B, buttonB, on the right, its
    /// A, buttonY, at the top, its X, buttonX, on the left, its Y (ControlPresets.swift).
    static func switchName(_ action: LauncherGamepad.Action) -> String? {
        switch action {
        case .a: return "B"
        case .b: return "A"
        case .x: return "Y"
        case .y: return "X"
        case .plus: return "Plus"
        case .select: return "Minus"
        case .l: return "L"
        case .r: return "R"
        case .left, .right, .up, .down: return nil
        }
    }

    /// What each button does in console mode.
    static func bindings(swapAB: Bool = false) -> [LauncherGamepad.Action: ConsoleInput] {
        [swapAB ? .b : .a: .activate, swapAB ? .a : .b: .back, .y: .options, .plus: .menu, .select: .menu]
    }

    /// The console's input for a press.
    static func input(_ action: LauncherGamepad.Action, swapAB: Bool = false) -> ConsoleInput? {
        switch action {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        default: return bindings(swapAB: swapAB)[action]
        }
    }

    /// The button that performs a role, for its hint: the first in `buttons` order (+ before − for the menu).
    static func button(for input: ConsoleInput, swapAB: Bool = false) -> LauncherGamepad.Action? {
        let map = bindings(swapAB: swapAB)
        return buttons.first { map[$0] == input }
    }

    /// The GameController element a launcher button reads, for its glyph.
    static func element(_ action: LauncherGamepad.Action) -> ConsoleGlyphs.Element? {
        switch action {
        case .a: return .a
        case .b: return .b
        case .x: return .x
        case .y: return .y
        case .plus: return .menu
        case .select: return .select
        default: return nil
        }
    }
}

extension ConsoleGlyphs {
    /// A role's glyph on the button that performs it now (ConsoleButtons): the controller's own symbol for that button, the family's,
    /// or its printed letter. The keyboard's keys do not move with the swap, so it keeps the role's key cap.
    func glyph(for role: Role, on action: LauncherGamepad.Action?) -> Glyph {
        guard family != .keyboard, let action, let element = ConsoleButtons.element(action) else { return glyph(for: role) }
        if let name = reported[element] ?? Self.table(family)[element] { return .symbol(name) }
        switch element {
        case .a: return .letter("A")
        case .b: return .letter("B")
        case .x: return .letter("X")
        case .y: return .letter("Y")
        case .menu: return .letter("+")
        case .select: return .letter("\u{2212}")
        }
    }
}
