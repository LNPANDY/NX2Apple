import GameController
import SwiftUI

/// The button glyphs the console mode shows, for the input used last. The launcher's controller navigation is by position
/// (Gamepad.swift: Action.a is GameController's buttonB, the east face button, Action.b is buttonA at the south, Y is buttonX at
/// the west, and + is buttonMenu), so each action resolves to a physical element and the glyph is whatever that element is
/// printed with on the controller: Apple's per-element `sfSymbolsName`, a per-family table when the controller reports none, a
/// key cap for the keyboard, and our own neutral letter when nothing is known. The Controls page's layout (By label, #70) only
/// changes what a game receives (DM_PAD_MAP), never what the launcher's menus do, so it does not move these glyphs. No logos.
struct ConsoleGlyphs: Equatable {
    enum Family: Equatable {
        case xbox, playStation, nintendo, keyboard, neutral

        /// From GCController.productCategory ("DualSense", "DualShock 4", "Xbox One", "Switch Pro Controller", "Nintendo Switch JoyCon (L/R)", ...).
        init(category: String?) {
            let c = (category ?? "").lowercased().replacingOccurrences(of: "-", with: "")
            if c.contains("dual") || c.contains("playstation") { self = .playStation }
            else if c.contains("xbox") { self = .xbox }
            else if c.contains("nintendo") || c.contains("switch") || c.contains("joycon") { self = .nintendo }
            else { self = .neutral }
        }
    }
    /// A physical button, by position.
    enum Element: Hashable { case east, south, west, north, menu }
    enum Role {
        case activate, back, options, controllers
        var element: Element {
            switch self {
            case .activate: return .east
            case .back: return .south
            case .options: return .menu
            case .controllers: return .west
            }
        }
        var keyCap: String {
            switch self { case .activate: return "Return"; case .back: return "Esc"; case .options: return "O"; case .controllers: return "Y" }
        }
        var letter: String {
            switch self { case .activate: return "A"; case .back: return "B"; case .options: return "+"; case .controllers: return "Y" }
        }
    }
    enum Glyph: Equatable { case symbol(String), key(String), letter(String) }

    var family: Family
    /// SF Symbols names the controller itself reports for its elements.
    var reported: [Element: String] = [:]

    static let keyboard = ConsoleGlyphs(family: .keyboard)
    static let neutral = ConsoleGlyphs(family: .neutral)

    func glyph(for role: Role) -> Glyph {
        if family == .keyboard { return .key(role.keyCap) }
        if let name = reported[role.element] ?? Self.table(family)[role.element] { return .symbol(name) }
        return .letter(role.letter)
    }

    /// What a family's elements are printed with, for a controller that reports no symbol of its own.
    static func table(_ family: Family) -> [Element: String] {
        switch family {
        case .xbox: return [.east: "b.circle", .south: "a.circle", .west: "x.circle", .north: "y.circle", .menu: "line.3.horizontal.circle"]
        case .playStation: return [.east: "circle.circle", .south: "xmark.circle", .west: "square.circle", .north: "triangle.circle", .menu: "line.3.horizontal.circle"]
        case .nintendo: return [.east: "a.circle", .south: "b.circle", .west: "y.circle", .north: "x.circle", .menu: "plus.circle"]
        case .keyboard, .neutral: return [:]
        }
    }

    init(family: Family, reported: [Element: String] = [:]) { self.family = family; self.reported = reported }

    init(controller: GCController) {
        family = Family(category: controller.productCategory)
        if let pad = controller.extendedGamepad {
            let elements: [(Element, GCControllerButtonInput)] = [(.east, pad.buttonB), (.south, pad.buttonA), (.west, pad.buttonX), (.north, pad.buttonY), (.menu, pad.buttonMenu)]
            for (element, button) in elements { if let name = button.sfSymbolsName { reported[element] = name } }
        }
    }

    /// The controller used last, else the first one connected, else the keyboard.
    static func current() -> ConsoleGlyphs {
        let pads = GCController.controllers().filter { $0.extendedGamepad != nil }
        if let pad = GCController.current.flatMap({ c in pads.contains(c) ? c : nil }) ?? pads.first { return ConsoleGlyphs(controller: pad) }
        return .keyboard
    }
}

struct ConsoleGlyphView: View {
    let glyph: ConsoleGlyphs.Glyph
    var size: CGFloat = 22
    var body: some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: size, weight: .medium)).accessibilityHidden(true)
        case .key(let cap):
            Text(cap).font(.manrope(size * 0.62, .bold)).padding(.horizontal, size * 0.3).frame(minWidth: size, minHeight: size)
                .overlay(RoundedRectangle(cornerRadius: size * 0.28).strokeBorder(.white.opacity(0.5), lineWidth: 1.5)).accessibilityHidden(true)
        case .letter(let letter):
            Text(letter).font(.manrope(size * 0.62, .bold)).frame(width: size, height: size)
                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5)).accessibilityHidden(true)
        }
    }
}
