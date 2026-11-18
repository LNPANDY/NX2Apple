import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Import previews use the Library's card, status, hover and selection treatment.
@MainActor struct OnboardingGamesContent: View {
    let state: OnboardingState
    let lang: Lang
    @Binding var selected: Set<String>
    let choose: () -> Void
    let receive: (URL) -> Void
    let build: () -> Void
    @State private var available: CGFloat = 820
    @EnvironmentObject private var focus: PadFocus
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var found: [OnboardingGame] { if case let .found(games) = state.games { return games }; return [] }
    private var columns: Int { max(1, Int((available + 16) / 238)) }
    private var cardWidth: CGFloat { max(1, (available - CGFloat(columns - 1) * 16) / CGFloat(columns) - 12) }
    private func canSelect(_ game: OnboardingGame) -> Bool { !game.needsKeys || state.keys == .valid }
    private func toggle(_ game: OnboardingGame) {
        guard canSelect(game) else { return }
        if selected.contains(game.id) { selected.remove(game.id) } else { selected.insert(game.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingDropZone(label: t("onboarding.games.drop"), chooseLabel: t("onboarding.choose"), id: "games",
                enabled: state.games != .scanning, choose: choose, receive: receive)
            if state.games == .scanning {
                HStack(spacing: 12) { ProgressView().controlSize(.small); Text(t("onboarding.games.scanning")) }
            } else if !found.isEmpty {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text(String(format: t("onboarding.games.count"), found.count)).font(.manrope(14, .semibold))
                            BuildPlatformChip(targets: state.selectedPlatform == .both ? [BuildTarget.mac, BuildTarget.ios] : [state.selectedPlatform == .mac ? BuildTarget.mac : BuildTarget.ios])
                        }.environmentObject(Localizer(lang))
                        Text(t("onboarding.games.select")).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
                    }
                    Spacer(minLength: 16)
                    Button(t("onboarding.games.build"), action: build)
                        .buttonStyle(LauncherSecondaryButtonStyle()).disabled(selected.isEmpty)
                        .padTarget("onboarding.games.build", scope: "onboarding", enabled: !selected.isEmpty, activate: build)
                }
                if state.keys == .skipped && found.contains(where: \.needsKeys) {
                    Label(t("onboarding.games.needKeys"), systemImage: "key.slash.fill")
                        .font(.manrope(13)).foregroundStyle(LauncherPalette.building)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columns), alignment: .leading, spacing: 24) {
                    ForEach(found) { game in
                        LibraryGameCard(title: game.title, image: game.cover, focus: .center,
                            state: LibraryArtworkState(mac: false, ios: false, attention: .notBuilt),
                            width: cardWidth, selected: selected.contains(game.id), select: { toggle(game) })
                            .disabled(!canSelect(game))
                            .padTarget("onboarding.game." + game.id, scope: "onboarding", radius: 10,
                                       enabled: canSelect(game), activate: { toggle(game) })
                    }
                }
                .environmentObject(Localizer(lang))
            } else if state.games == .none || state.games == .found([]) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(t("onboarding.games.none"), systemImage: "folder.badge.questionmark")
                    Text(t("onboarding.games.noneHint")).foregroundStyle(LauncherPalette.secondaryText)
                }.font(.manrope(14))
            }
        }
        .background(GeometryReader { geometry in
            Color.clear.onAppear { available = geometry.size.width }
                .onChange(of: geometry.size.width) { available = $0 }
        })
        .onChange(of: state.games) { _ in
            selected.formIntersection(Set(found.filter(canSelect).map(\.id)))
            if let id = focus.focused, id.hasPrefix("onboarding.game."),
               !found.contains(where: { "onboarding.game." + $0.id == id && canSelect($0) }) {
                focus.focused = "onboarding.choose.games"
            }
        }
    }
}
