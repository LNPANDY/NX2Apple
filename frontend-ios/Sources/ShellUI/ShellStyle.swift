import SwiftUI
import CoreText

public enum ShellPalette {
    public static let background = Color(red: 0.055, green: 0.055, blue: 0.06)
    public static let surface = Color(red: 0.10, green: 0.10, blue: 0.11)
    public static let cream = Color(red: 1, green: 0.94, blue: 0.84)
    public static let ready = Color(red: 0.25, green: 0.84, blue: 0.47)
    public static let attention = Color(red: 1, green: 0.78, blue: 0.24)
    public static let muted = Color(red: 0.57, green: 0.58, blue: 0.61)
    /// Hairlines between rows and around cards.
    static let hairline = Color.white.opacity(0.08)
}

enum ShellStrings {
    static func text(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .module) }
}

@MainActor public enum ShellFonts {
    /// Register just the bundled font. No game or user files are accessed.
    private static let registered: Bool = {
        guard let url = Bundle.module.url(forResource: "Manrope", withExtension: "ttf") else { return false }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        return (CTFontManagerCopyAvailablePostScriptNames() as? [String])?.contains("Manrope") == true
    }()
    /// Manrope that follows Dynamic Type.
    public static func font(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo: Font.TextStyle = .body) -> Font {
        if registered { return .custom("Manrope", size: size, relativeTo: relativeTo).weight(weight) }
        return .system(relativeTo).weight(weight)
    }
    /// Manrope at a fixed size, for lettering that belongs to a picture rather than to the interface.
    static func fixed(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if registered { return .custom("Manrope", fixedSize: size).weight(weight) }
        return .system(size: size, weight: weight)
    }
}

extension View {
    func shellText(_ size: CGFloat = 15, _ weight: Font.Weight = .regular, relativeTo: Font.TextStyle = .body) -> some View {
        font(ShellFonts.font(size, weight: weight, relativeTo: relativeTo))
    }
    /// A settings group: the surface colour with a 1 pt hairline, as on the Mac.
    func shellCard(padding: CGFloat = 18) -> some View {
        self.padding(padding)
            .background(ShellPalette.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ShellPalette.hairline, lineWidth: 1))
    }
}

/// The small cream capitals that open a section, such as YOUR GAMES.
struct SectionHeading: View {
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).shellText(11, .bold, relativeTo: .caption).tracking(1.8)
                .foregroundStyle(ShellPalette.cream.opacity(0.72)).accessibilityAddTraits(.isHeader)
            if let trailing {
                Spacer(minLength: 8)
                Text(trailing).shellText(12, .medium, relativeTo: .caption).monospacedDigit().foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

/// The Mac's secondary button: white 0.055, a 0.10 hairline, radius 9.
struct ShellButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.shellText(14, .semibold)
            .frame(minHeight: 44).padding(.horizontal, 14)
            .foregroundStyle(.white.opacity(0.92))
            .background(.white.opacity(configuration.isPressed ? 0.13 : 0.055), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.10)))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// The one primary action of a screen: a cream capsule with black type, as the Mac hero's Play.
struct PrimaryPillStyle: ButtonStyle {
    var expands = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.shellText(17, .bold)
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 26).frame(minHeight: 50)
            .frame(maxWidth: expands ? .infinity : nil)
            .foregroundStyle(.black)
            .background(ShellPalette.cream, in: Capsule())
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Capsule())
    }
}

/// A round icon button beside the primary action, such as game settings.
struct RoundIconButtonStyle: ButtonStyle {
    var size: CGFloat = 50
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 17, weight: .medium))
            .frame(width: size, height: size)
            .foregroundStyle(active ? .black : .white)
            .background(active ? ShellPalette.cream : .white.opacity(configuration.isPressed ? 0.2 : 0.10), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(active ? 0 : 0.14)))
            .contentShape(Circle())
    }
}

/// A small capsule that sits on top of art, such as the controller count.
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.shellText(13, .semibold, relativeTo: .footnote)
            .padding(.horizontal, 14).frame(minHeight: 44)
            .foregroundStyle(.white)
            .background(.black.opacity(configuration.isPressed ? 0.55 : 0.38), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            .contentShape(Capsule())
    }
}

struct CreamToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8)) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 16) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? ShellPalette.cream : .white.opacity(0.14))
                    Circle().fill(configuration.isOn ? ShellPalette.background : .white.opacity(0.85)).padding(3)
                }.frame(width: 46, height: 28)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityValue(ShellStrings.text(configuration.isOn ? "On" : "Off"))
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// A game's picture filling whatever frame it gets: the banner, else the icon whole on a blurred copy of itself,
/// else the placeholder.
struct ArtView: View {
    let game: GameTile
    /// Draw from the small copy, for a backdrop that is blurred anyway.
    var backdrop = false
    /// The placeholder's lettering. Off where the title is set beside the art already, as in the hero.
    var lettering = true
    var body: some View {
        Color.clear.overlay {
            if let banner = game.banner {
                Image(decorative: backdrop ? banner.thumbnail : banner.image, scale: 1)
                    .resizable().interpolation(backdrop ? .medium : .high).scaledToFill()
            } else if let icon = game.icon {
                if backdrop {
                    Image(decorative: icon.thumbnail, scale: 1).resizable().scaledToFill()
                } else {
                    IconCard(icon: icon)
                }
            } else {
                PlaceholderArt(title: game.title, seed: game.id, lettering: lettering && !backdrop)
            }
        }.clipped()
    }
}

/// A square icon in a wide frame: whole and sharp in the middle, on a blurred and darkened copy of itself.
private struct IconCard: View {
    let icon: Artwork
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.height * 0.74, geometry.size.width * 0.74)
            ZStack {
                Image(decorative: icon.thumbnail, scale: 1).resizable().interpolation(.medium).scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .blur(radius: max(8, geometry.size.height * 0.14), opaque: true)
                    .saturation(1.15)
                    .overlay(Color.black.opacity(0.3))
                Image(decorative: icon.image, scale: 1).resizable().interpolation(.high).scaledToFit()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.1))
                    .shadow(color: .black.opacity(0.35), radius: side * 0.06, y: side * 0.03)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// For a game without a picture: a deep tone from its name, a soft disc and the title set like a book cover.
/// It has to read as a deliberate cover, not as missing data.
struct PlaceholderArt: View {
    let title: String
    let seed: String
    var lettering = true
    var body: some View {
        let hash = stableHash(seed)
        let hue = Double(hash % 360) / 360
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.42, brightness: 0.36),
                                        Color(hue: hue, saturation: 0.55, brightness: 0.13)],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
                Circle().fill(Color(hue: hue, saturation: 0.30, brightness: 0.62).opacity(0.30))
                    .frame(width: side * 1.1, height: side * 1.1)
                    .position(x: geometry.size.width * 0.8, y: geometry.size.height * 0.22)
                if lettering {
                    Text(title).font(ShellFonts.fixed(max(9, side * 0.16), weight: .heavy)).tracking(-side * 0.004)
                        .foregroundStyle(ShellPalette.cream.opacity(0.92))
                        .lineLimit(2).minimumScaleFactor(0.5).multilineTextAlignment(.leading)
                        .padding(side * 0.11)
                }
            }
        }
    }
}

/// A 16:9 card with the hairline every picture gets, so dark art keeps its edge on the dark page.
struct CoverView: View {
    let game: GameTile
    var radius: CGFloat = 10
    var body: some View {
        ArtView(game: game)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.10)))
            .accessibilityHidden(true)
    }
}

extension GameState {
    var title: String {
        switch self {
        case .playable: ShellStrings.text("Ready to play")
        case .needsGameData: ShellStrings.text("Needs game data")
        case .needsAppUpdate: ShellStrings.text("App update needed")
        case .broken: ShellStrings.text("Unavailable")
        }
    }
    var color: Color {
        switch self {
        case .playable: ShellPalette.ready
        case .needsGameData, .needsAppUpdate: ShellPalette.attention
        case .broken: ShellPalette.muted
        }
    }
    var explanation: String {
        switch self {
        case .playable: ""
        case .needsGameData: ShellStrings.text("Choose this game's data to get ready to play.")
        case .needsAppUpdate: ShellStrings.text("Install a newer version of this app to play this game.")
        case .broken(let reason): reason
        }
    }
    var actionTitle: String {
        switch self {
        case .playable: ShellStrings.text("Play")
        case .needsGameData: ShellStrings.text("Choose game data…")
        case .needsAppUpdate: ShellStrings.text("Update app")
        case .broken: ShellStrings.text("Show log")
        }
    }
    var actionSymbol: String {
        switch self {
        case .playable: "play.fill"
        case .needsGameData: "folder"
        case .needsAppUpdate: "arrow.up.circle"
        case .broken: "doc.text"
        }
    }
}

/// The Mac's status: a small coloured dot and the words. Prominent is the hero's capitals.
struct StatusLabel: View {
    let state: GameState
    var prominent = false
    var body: some View {
        HStack(spacing: prominent ? 8 : 6) {
            Circle().fill(state.color).frame(width: prominent ? 7 : 6, height: prominent ? 7 : 6)
            Text(prominent ? state.title.uppercased() : state.title)
                .shellText(prominent ? 11.5 : 12, prominent ? .bold : .medium, relativeTo: .caption)
                .tracking(prominent ? 1.4 : 0)
                .foregroundStyle(state.color)
                .lineLimit(prominent ? 2 : 1)
        }.accessibilityElement(children: .combine)
    }
}

/// A controller button as the Mac console draws it: the letter in a small rounded square.
struct ButtonGlyph: View {
    let letter: String
    var body: some View {
        Text(letter).font(ShellFonts.fixed(11, weight: .bold))
            .frame(width: 20, height: 20)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.45), lineWidth: 1.2))
            .accessibilityHidden(true)
    }
}

struct GlyphHint: View {
    let letter: String
    let label: String
    var body: some View {
        HStack(spacing: 8) {
            ButtonGlyph(letter: letter)
            Text(label).shellText(13, .medium, relativeTo: .footnote)
        }.foregroundStyle(.white.opacity(0.6))
    }
}
