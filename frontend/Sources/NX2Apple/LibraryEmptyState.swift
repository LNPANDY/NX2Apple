import SwiftUI
import NXCore
import NXModel
import NXLauncher

extension LauncherView {
    func emptyLibraryHero(width: CGFloat) -> some View {
        let firstUse = library.games.isEmpty
        return VStack(alignment: .leading, spacing: 14) {
            Text(loc.t(firstUse ? "library.empty.title" : search.isEmpty ? "console.allGames.empty" : "library.noResults"))
                .font(.manrope(min(60, max(30, width * 0.045)), .heavy))
                .tracking(-1).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if firstUse {
                HStack(spacing: 12) {
                    Button(action: newBuild) {
                        LauncherHeroActionLabel(title: loc.t("library.firstBuild"), symbol: "plus")
                    }
                    .buttonStyle(LauncherActionButtonStyle()).fixedSize().disabled(m.running)
                    .launcherHover()
                    .padTarget("library.empty.primary", scope: "main", enabled: !m.running) { if !m.running { newBuild() } }
                    heroUtilityButton("folder", label: loc.t("builds.empty.addBuilds"), id: "library.empty.folder", action: chooseLibraryFolder)
                }
            }

        }
        .padding(.horizontal, 34).padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The backdrop where a game has no artwork (an empty library, the onboarding): the surface fading into the page, no mark and no
/// blur (LNPANDY/NX2Apple#1458).
struct LibraryFallbackArtwork: View {
    let size: CGSize
    var body: some View {
        LinearGradient(colors: [LauncherPalette.surface, LauncherPalette.background], startPoint: .top, endPoint: .bottom)
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true).allowsHitTesting(false)
    }
}

/// Static empty slots, not loading progress. Geometry and typography match the actual carousel card.
struct LibraryCarouselPlaceholder: View {
    let width: CGFloat
    @EnvironmentObject private var loc: Localizer
    var body: some View {
        VStack(alignment: .leading, spacing: LibraryCardLayout.titleSpacing) {
            RoundedRectangle(cornerRadius: 5)
                .fill(LauncherPalette.ink(0.06))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(LauncherPalette.ink(0.04)))
                .frame(width: width, height: width / LibraryCardLayout.aspect)
            Text(loc.t("library.yourLibrary")).font(.manrope(16, .semibold)).lineLimit(1).hidden()
                .overlay(alignment: .leading) {
                    Capsule().fill(LauncherPalette.ink(0.08)).frame(width: width * 0.62, height: 7)
                }
        }
        .frame(width: width, alignment: .leading).padding(LibraryCardLayout.inset)
        .accessibilityHidden(true).allowsHitTesting(false)
    }
}
