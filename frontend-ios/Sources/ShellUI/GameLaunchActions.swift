import SwiftUI

/// Content-level actions: the parent decides whether this row is inline or in its bottom safe-area inset.
struct GameLaunchActions: View {
    let game: GameTile
    let primary: () -> Void
    var settings: (() -> Void)? = nil
    var focusPrefix = "lib."
    var expands = false
    var alignment: Alignment = .leading
    var transitionDuration: Double = 0.3
    @State private var divisionInsets = EdgeInsets()
    /// Supplied when the parent coordinates actions across its adaptive layouts.
    var glassNamespace: Namespace.ID? = nil
    @Namespace private var localGlassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let glassNamespace {
                buttons(in: glassNamespace)
            } else {
                GlassEffectContainer(spacing: 12) { buttons(in: localGlassNamespace) }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: transitionDuration), value: game.state.actionTitle)
        .font(.headline)
        .padding(divisionInsets)
        .frame(maxWidth: .infinity, alignment: alignment)
        .onGeometryChange(for: EdgeInsets.self) { geometry in
            if #available(iOS 27.1, macOS 27.1, *) {
                return Self.insets(size: geometry.size, division: geometry.reservedRegions(kind: .division).first?.frame)
            }
            return EdgeInsets()
        } action: { divisionInsets = $0 }
    }
    private func buttons(in namespace: Namespace.ID) -> some View {
        HStack(spacing: 12) {
            Button(action: primary) {
                Label(game.state.actionTitle, systemImage: game.state.actionSymbol)
                    .contentTransition(.opacity)
                    .padding(.horizontal, expands ? 0 : 14)
                    .frame(maxWidth: expands ? .infinity : nil, minHeight: 26)
                    .foregroundStyle(.black)
            }
            .buttonStyle(.glassProminent)
            .tint(ShellPalette.cream)
            .controlSize(.large)
            .glassEffectID("primary", in: namespace)
            .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
            .accessibilityLabel(game.state.actionTitle + ", " + game.title)
            .accessibilityIdentifier("state.action")
            .shellTarget(focusPrefix + "play", radius: 16, action: primary)
            if game.state == .playable, let settings {
                Button(action: settings) {
                    Label(ShellStrings.text("Game settings"), systemImage: "slider.horizontal.3")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 26, minHeight: 26)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .glassEffectID("settings", in: namespace)
                .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                .accessibilityLabel(ShellStrings.text("Game settings") + ", " + game.title)
                .accessibilityIdentifier("settings.open")
                .shellTarget(focusPrefix + "settings", radius: 16, action: settings)
            }
        }
    }

    // Keep the related actions together when a system division crosses their content column.
    nonisolated static func insets(size: CGSize, division: CGRect?) -> EdgeInsets {
        guard let division, division.intersects(CGRect(origin: .zero, size: size)), division.height > division.width else { return EdgeInsets() }
        let leading = max(0, division.minX), trailing = max(0, size.width - division.maxX)
        return leading >= trailing ? EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: size.width - leading) : EdgeInsets(top: 0, leading: size.width - trailing, bottom: 0, trailing: 0)
    }
}
