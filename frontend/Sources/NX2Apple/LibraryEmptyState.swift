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
                    .launcherHover(lightBrightness: 0)
                    .padTarget("library.empty.primary", scope: "main", enabled: !m.running) { if !m.running { newBuild() } }
                    heroUtilityButton("folder", label: loc.t("builds.empty.addBuilds"), id: "library.empty.folder", action: chooseLibraryFolder)
                }
            }

        }
        .padding(.horizontal, 34).padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A branded fallback uses the same backdrop blur and edge treatment as game artwork.
struct LibraryFallbackArtwork: View {
    let size: CGSize
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            LauncherPalette.background
            if let image = LauncherBrandMark.backdropImage {
                Image(nsImage: image).resizable().renderingMode(.template).scaledToFit()
                    .foregroundStyle(LauncherPalette.cream)
                    .frame(width: size.width * 0.8, height: size.height * 0.9)
                    .offset(x: size.width * 0.22, y: -size.height * 0.1)
                    .opacity(scheme == .light ? 0.12 : 0.23)
            }
        }
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
