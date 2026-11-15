import AppKit
import Combine
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Subtle banner in the Library page when one or more files in the configured folders were skipped during discovery.
struct LibrarySkippedBanner: View {
    let items: [SkippedLibraryItem]
    var enabled: Bool = true
    let openDetails: () -> Void
    var dismiss: (() -> Void)? = nil
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let title = items.count == 1
            ? loc.t("macLibDiag.bannerOne")
            : String(format: loc.t("macLibDiag.bannerMany"), items.count)
        HStack(spacing: 8) {
            Button(action: openDetails) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(LauncherPalette.building.opacity(0.14))
                        Image(systemName: "tray.full")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LauncherPalette.building)
                    }
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.manrope(13.5, .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(loc.t("macLibDiag.bannerNote"))
                            .font(.manrope(12))
                            .foregroundStyle(LauncherPalette.secondaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 12)

                    HStack(spacing: 5) {
                        Text(loc.t("macLibDiag.details"))
                            .font(.manrope(12.5, .semibold))
                            .fixedSize()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(LauncherPalette.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(LauncherPalette.menuFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(LauncherPalette.secondaryBorder))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .launcherHover(enabled: enabled)
            .padTarget("library.skippedBanner", scope: "main", radius: 8, activate: openDetails)

            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LauncherPalette.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(LauncherPalette.menuFill, in: Circle())
                        .overlay(Circle().strokeBorder(LauncherPalette.secondaryBorder))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .launcherHover(enabled: enabled)
                .help(loc.t("library.dismissSkipped"))
                .accessibilityLabel(loc.t("library.dismissSkipped"))
                .accessibilityIdentifier("library.skippedBanner.dismiss")
                .padTarget("library.skippedDismiss", scope: "main", radius: 14, activate: dismiss)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LauncherPalette.cardBorder))
    }
}

/// Modal detail panel listing every skipped file in the library folders along with its reason and remediation guidance.
struct SkippedLibraryItemsOverlay: View {
    let items: [SkippedLibraryItem]
    let openKeysSettings: () -> Void
    let close: () -> Void
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus

    private var needsKeysAction: Bool {
        items.contains { $0.reason == .unidentifiedWithoutKeys }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(loc.t("macLibDiag.sheetTitle"))
                        .font(.manrope(24, .heavy))
                        .tracking(-0.5)
                    Text(loc.t("macLibDiag.sheetNote"))
                        .font(.manrope(13))
                        .foregroundStyle(LauncherPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 16)

                Divider().opacity(0.3)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Divider().opacity(0.25).padding(.leading, 68)
                            }
                            SkippedItemRow(item: item)
                        }
                    }
                }
                .frame(maxHeight: 360)

                Divider().opacity(0.3)

                HStack(spacing: 12) {
                    Text(String(format: loc.t("macLibDiag.count"), items.count))
                        .font(.manrope(12))
                        .foregroundStyle(LauncherPalette.secondaryText)
                    Spacer(minLength: 8)
                    if needsKeysAction {
                        Button(action: openKeysSettings) {
                            Label(loc.t("macLibDiag.chooseKeys"), systemImage: "key")
                                .font(.manrope(12.5, .semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(LauncherPalette.menuFill, in: Capsule())
                                .overlay(Capsule().strokeBorder(LauncherPalette.secondaryBorder))
                        }
                        .buttonStyle(.plain)
                        .launcherHover()
                        .padTarget("skipped.keys", scope: "skipped", radius: 14, activate: openKeysSettings)
                    }
                    Button(action: close) {
                        Text(loc.t("free.done"))
                            .font(.manrope(13, .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(LauncherPalette.menuFill, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LauncherPalette.secondaryBorder))
                    }
                    .buttonStyle(.plain)
                    .launcherHover()
                    .keyboardShortcut(.cancelAction)
                    .padTarget("skipped.close", scope: "skipped", radius: 8, activate: close)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
            }
            .padScope("skipped", focus)
            .frame(width: 680)
            .background(LauncherPalette.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(LauncherPalette.cardBorder))
            .shadow(color: .black.opacity(0.45), radius: 28, y: 12)
            .padding(28)
        }
    }
}

private struct SkippedItemRow: View {
    let item: SkippedLibraryItem
    @EnvironmentObject var loc: Localizer

    private var iconName: String {
        switch item.reason {
        case .orphanSupplement:
            return "puzzlepiece.extension"
        case .unextractedArchiveOrSplit:
            return "doc.zipper"
        case .unidentifiedWithoutKeys:
            return "key"
        }
    }

    private var iconColor: Color {
        switch item.reason {
        case .orphanSupplement, .unidentifiedWithoutKeys:
            return LauncherPalette.building
        case .unextractedArchiveOrSplit:
            return LauncherPalette.accent
        }
    }

    private var reasonTitle: String {
        switch item.reason {
        case .orphanSupplement:
            return loc.t("macLibDiag.orphanTitle")
        case .unextractedArchiveOrSplit:
            return loc.t("macLibDiag.archiveTitle")
        case .unidentifiedWithoutKeys:
            return loc.t("macLibDiag.noKeysTitle")
        }
    }

    private var guidanceText: String {
        switch item.reason {
        case .orphanSupplement:
            return String(format: loc.t("macLibDiag.orphanHint"), item.expectedBaseTitleID ?? "")
        case .unextractedArchiveOrSplit:
            return loc.t("macLibDiag.archiveHint")
        case .unidentifiedWithoutKeys:
            return loc.t("macLibDiag.noKeysHint")
        }
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(iconColor.opacity(0.14))
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 28, height: 28)
            .padding(.top, 2)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.name)
                        .font(.manrope(13.5, .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(reasonTitle)
                        .font(.manrope(11, .semibold))
                        .foregroundStyle(iconColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(iconColor.opacity(0.12), in: Capsule())
                        .lineLimit(1)
                }
                Text(guidanceText)
                    .font(.manrope(12))
                    .foregroundStyle(LauncherPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(action: revealInFinder) {
                Image(systemName: "folder")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LauncherPalette.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(LauncherPalette.menuFill, in: Circle())
                    .overlay(Circle().strokeBorder(LauncherPalette.secondaryBorder))
            }
            .buttonStyle(.plain)
            .launcherHover()
            .help(loc.t("macLibDiag.reveal"))
            .accessibilityLabel(loc.t("macLibDiag.reveal"))
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 12)
    }
}

private struct LibraryDiagnosticsModifier: ViewModifier {
    @ObservedObject var library: GameLibrary
    @ObservedObject var repo: RepoStore
    @ObservedObject var engine: EngineSyncStore
    @ObservedObject var verified: VerifiedProfilesTracker
    @Binding var skippedOpen: Bool
    let pad: PadFocus
    let scope: () -> String
    let openKeysSettings: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                verified.refresh(engineRoot: EngineLayout.root(repo.path))
            }
            .onChange(of: repo.path) { newPath in
                verified.refresh(engineRoot: EngineLayout.root(newPath))
            }
            .onReceive(repo.$busy.removeDuplicates().dropFirst()) { busy in
                if !busy {
                    verified.refresh(engineRoot: EngineLayout.root(repo.path))
                }
            }
            .onReceive(engine.$syncing.removeDuplicates().dropFirst()) { syncing in
                if !syncing {
                    verified.refresh(engineRoot: EngineLayout.root(repo.path))
                }
            }
            .onChange(of: library.skippedItems.isEmpty) { isEmpty in
                if isEmpty, skippedOpen {
                    skippedOpen = false
                }
            }
            .onChange(of: skippedOpen) { isOpen in
                pad.scope = isOpen ? "skipped" : scope()
                if isOpen, pad.visible {
                    DispatchQueue.main.async { pad.show(default: "skipped.close") }
                }
            }
            .overlay {
                if skippedOpen, !library.skippedItems.isEmpty {
                    SkippedLibraryItemsOverlay(
                        items: library.skippedItems,
                        openKeysSettings: openKeysSettings,
                        close: { skippedOpen = false }
                    )
                }
            }
    }
}

extension View {
    func libraryDiagnosticsWiring(
        library: GameLibrary,
        repo: RepoStore,
        engine: EngineSyncStore,
        verified: VerifiedProfilesTracker,
        skippedOpen: Binding<Bool>,
        pad: PadFocus,
        scope: @escaping () -> String,
        openKeysSettings: @escaping () -> Void
    ) -> some View {
        modifier(
            LibraryDiagnosticsModifier(
                library: library,
                repo: repo,
                engine: engine,
                verified: verified,
                skippedOpen: skippedOpen,
                pad: pad,
                scope: scope,
                openKeysSettings: openKeysSettings
            )
        )
    }
}
