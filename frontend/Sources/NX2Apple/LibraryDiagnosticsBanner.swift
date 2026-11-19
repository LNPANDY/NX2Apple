import AppKit
import Combine
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Modal detail panel listing every skipped file in the library folders along with its reason and remediation guidance, on the
/// sheet layout (the header, one card of rows, the button row) over a dimmed launcher.
struct SkippedLibraryItemsOverlay: View {
    let items: [SkippedLibraryItem]
    let openKeysSettings: () -> Void
    let close: () -> Void
    /// The panel alone, without the dimmed launcher behind it: the gallery's scene.
    var panelOnly = false
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus

    private var needsKeysAction: Bool {
        items.contains { $0.reason == .unidentifiedWithoutKeys }
    }

    var body: some View {
        if panelOnly { panel } else { dimmed }
    }

    private var dimmed: some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            panel
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sheet))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.sheet).strokeBorder(DS.Color.separator))
                .shadow(color: .black.opacity(0.45), radius: 28, y: 12)
                .padding(DS.Space.l)
        }
    }

    /// The panel itself, which the gallery draws alone.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSheetHeader(title: loc.t("macLibDiag.sheetTitle"), message: loc.t("macLibDiag.sheetNote"))
                .padding(.horizontal, DSSheetInsets.horizontal).padding(.top, DSSheetInsets.vertical).padding(.bottom, DSSheetInsets.gap)
            ScrollView {
                DSSection("") {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { DSRowDivider() }
                        SkippedItemRow(item: item)
                    }
                }
                .padding(.horizontal, DSSheetInsets.horizontal).padding(.vertical, DS.Space.xxs)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            DSSheetButtonRow {
                Text(String(format: loc.t("macLibDiag.count"), items.count)).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
            } buttons: {
                if needsKeysAction {
                    Button(action: openKeysSettings) { Label(loc.t("macLibDiag.chooseKeys"), systemImage: "key") }
                        .buttonStyle(DSSecondaryButtonStyle())
                        .padTarget("skipped.keys", scope: "skipped", activate: openKeysSettings)
                }
                Button(action: close) { Text(loc.t("free.done")).font(DS.Font.bodyStrong).padding(.horizontal, DS.Space.m) }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .padTarget("skipped.close", scope: "skipped", focusColor: DS.Color.accentOn, activate: close)
            }
            .padding(.horizontal, DSSheetInsets.horizontal).padding(.top, DSSheetInsets.buttons).padding(.bottom, DSSheetInsets.vertical)
        }
        .padScope("skipped", focus)
        .frame(width: 680)
        .dsSheetSurface()
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
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Color.symbolDefault)
                .frame(width: DS.Control.leadingSlot)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                    Text(item.name)
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(DS.Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.path)
                    DSTag(reasonTitle)
                }
                Text(guidanceText)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DS.Space.xs)

            Button(action: revealInFinder) { Image(systemName: "folder") }
                .buttonStyle(DSIconButtonStyle(size: 28))
                .help(loc.t("macLibDiag.reveal"))
                .accessibilityLabel(loc.t("macLibDiag.reveal"))
        }
        .padding(.leading, DS.Space.xs).padding(.trailing, DS.Space.m)
        .padding(.vertical, DS.Space.s)
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
