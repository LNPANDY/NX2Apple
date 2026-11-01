import GameController
import SwiftUI

/// The button glyphs the console mode shows, for the input used last. The launcher reads the face buttons by label
/// (`LauncherGamepad.face`): Play is GameController's buttonA, Back is buttonB, Controllers is buttonY and options is
/// buttonMenu. GameController documents the diamond as A at the bottom, B right, X left, Y top (GCExtendedGamepad.h), so on a
/// DualSense A is the cross, B the circle, X the square and Y the triangle. The glyph is the element's own `sfSymbolsName`
/// (input remapping included), a per-family table when it reports none, a key cap for the keyboard, and our own neutral letter
/// when nothing is known. The Controls page's layout (By label) only changes what a game receives (DM_PAD_MAP), so it does not
/// move these glyphs. No logos.
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
    /// A button as GameController names it.
    enum Element: Hashable { case a, b, x, y, menu, select }
    enum Role {
        case activate, back, options, controllers
        /// The desktop launcher's own: X opens a game's launch options and Y its Manage menu (LauncherView.padAction).
        case launchOptions, manage
        /// The Select-type button (Share, Create, View, Minus): opens console mode from the desktop.
        case select
        var element: Element {
            switch self {
            case .activate: return Self.element(of: .a)
            case .back: return Self.element(of: .b)
            case .options: return .menu
            case .select: return .select
            case .controllers, .manage: return Self.element(of: .y)
            case .launchOptions: return Self.element(of: .x)
            }
        }
        /// The element that performs a launcher action, taken from the one mapping Gamepad.swift reads, so glyph and button cannot differ.
        private static func element(of action: LauncherGamepad.Action) -> Element {
            switch LauncherGamepad.face(for: action) {
            case .a?: return .a
            case .b?: return .b
            case .x?: return .x
            case .y?, nil: return .y
            }
        }
        var keyCap: String {
            switch self { case .activate: return "return"; case .back: return "escape"; case .options, .launchOptions: return "O"; case .controllers, .manage: return "Y"; case .select: return "\u{2325}\u{2318}K" }
        }
        /// Keys drawn as an SF Symbol in their cap (Return, Escape) instead of a word.
        var keySymbol: Bool {
            switch self { case .activate, .back: return true; default: return false }
        }
        var letter: String {
            switch self { case .activate: return "A"; case .back: return "B"; case .options: return "+"; case .launchOptions: return "X"; case .controllers, .manage: return "Y"; case .select: return "\u{2212}" }
        }
    }
    enum Glyph: Equatable { case symbol(String), key(String), keySymbol(String), letter(String) }

    var family: Family
    /// SF Symbols names the controller itself reports for its elements.
    var reported: [Element: String] = [:]

    static let keyboard = ConsoleGlyphs(family: .keyboard)
    static let neutral = ConsoleGlyphs(family: .neutral)

    func glyph(for role: Role) -> Glyph {
        if family == .keyboard { return role.keySymbol ? .keySymbol(role.keyCap) : .key(role.keyCap) }
        if let name = reported[role.element] ?? Self.table(family)[role.element] { return .symbol(name) }
        return .letter(role.letter)
    }

    /// What a family's elements are printed with, for a controller that reports no symbol of its own.
    static func table(_ family: Family) -> [Element: String] {
        switch family {
        case .xbox: return [.a: "a.circle", .b: "b.circle", .x: "x.circle", .y: "y.circle", .menu: "line.3.horizontal.circle", .select: "minus.circle"]
        case .playStation: return [.a: "xmark.circle", .b: "circle.circle", .x: "square.circle", .y: "triangle.circle", .menu: "line.3.horizontal.circle", .select: "minus.circle"]
        case .nintendo: return [.a: "a.circle", .b: "b.circle", .x: "x.circle", .y: "y.circle", .menu: "plus.circle", .select: "minus.circle"]
        case .keyboard: return [:]
        case .neutral: return [.select: "minus.circle"]
        }
    }

    init(family: Family, reported: [Element: String] = [:]) { self.family = family; self.reported = reported }

    init(controller: GCController) {
        family = Family(category: controller.productCategory)
        if let pad = controller.extendedGamepad {
            let elements: [(Element, GCControllerButtonInput)] = [(.a, pad.buttonA), (.b, pad.buttonB), (.x, pad.buttonX), (.y, pad.buttonY), (.menu, pad.buttonMenu)]
            for (element, button) in elements { if let name = button.sfSymbolsName { reported[element] = name } }
            // The system's own symbol for the Select-type button, whatever the controller calls it
            if let name = pad.buttonOptions?.sfSymbolsName { reported[.select] = name }
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
        case .symbol(let requested):
            // a symbol this macOS does not have draws nothing: a plain circle stands in
            let name = NSImage(systemSymbolName: requested, accessibilityDescription: nil) == nil ? "circle" : requested
            Image(systemName: name).font(.system(size: size, weight: .medium)).accessibilityHidden(true)
        case .key(let cap):
            keyCap { Text(cap).font(.manrope(size * 0.62, .bold)) }
        case .keySymbol(let name):
            keyCap { Image(systemName: name).font(.system(size: size * 0.6, weight: .bold)) }
        case .letter(let letter):
            Text(letter).font(.manrope(size * 0.62, .bold)).frame(width: size, height: size)
                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5)).accessibilityHidden(true)
        }
    }
}

extension ConsoleGlyphView {
    /// Every keyboard cap has the same height, weight and outline, whatever it holds.
    private func keyCap<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(minWidth: size * 0.75).padding(.horizontal, size * 0.22).frame(height: size * 1.15)
            .overlay(RoundedRectangle(cornerRadius: size * 0.28).strokeBorder(.white.opacity(0.5), lineWidth: 1.5)).accessibilityHidden(true)
    }
}
