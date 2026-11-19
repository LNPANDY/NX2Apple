import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// A game of a folder that holds several, in the failure's list: the game's icon (from the artwork already on disk), its name and
/// a radio. A game nobody knows reads "Unknown game" with its title ID under it, its only name.
private struct FailureTitleRow: View {
    let titleID: String
    let name: String?
    let icon: NSImage?
    let chosen: Bool
    let choose: () -> Void
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        Button(action: choose) {
            HStack(spacing: DS.Space.s) {
                ZStack {
                    if let icon { Image(nsImage: icon).resizable().scaledToFill() }
                    else { Image(systemName: "gamecontroller").font(.system(size: 16)).foregroundStyle(DS.Color.symbolDefault) }
                }
                .frame(width: DS.Control.thumbnail, height: DS.Control.thumbnail)
                .background(DS.Color.surfaceRaised).clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.xxs / 2) {
                    Text(name ?? loc.t("fail.unknownGame")).font(DS.Font.body).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                    if name == nil { Text(titleID).font(DS.Font.mono).foregroundStyle(DS.Color.textSecondary) }
                }
                Spacer(minLength: DS.Space.s)
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16)).foregroundStyle(chosen ? DS.Color.symbolAccent : DS.Color.symbolDefault)
                    .frame(width: DS.Control.leadingSlot).accessibilityHidden(true)
            }
            .padding(.vertical, DS.Space.xs).padding(.horizontal, DS.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsRowHover()
        .help(titleID)
        .accessibilityLabel(name ?? loc.t("fail.unknownGame"))
        .accessibilityValue(titleID)
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }
}

/// Under the build button after a stop the script's early checks explain: what happened in plain words, the next step, and the
/// button that does it (a dependency's own install command, or "Build anyway" for the three stops that have an override).
package struct BuildFailureCard: View {
    @ObservedObject var m: BuildStore
    /// Where the engine's failure row retries. nil for a failure of a build.
    var engine: EngineSyncStore?
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus
    /// The failure to show: the build's (`m.failure`) unless the caller passes another one, such as the engine sync's.
    var failure: BuildFailure?

    /// Names of games the launcher knows, by upper-case title ID, for the choice of several titles.
    var titleNames: [String: String] = [:]
    /// A game's icon by title ID, from the artwork already on disk (nil: the placeholder).
    var titleIcon: (String) -> NSImage? = { _ in nil }

    package init(m: BuildStore, engine: EngineSyncStore? = nil, failure: BuildFailure? = nil, titleNames: [String: String] = [:],
                 titleIcon: @escaping (String) -> NSImage? = { _ in nil }) {
        self.m = m
        self.engine = engine
        self.failure = failure
        self.titleNames = titleNames
        self.titleIcon = titleIcon
    }

    /// A stop the player fixes with a choice or a file is a warning, a broken input or an unknown failure an error.
    package static func isError(_ kind: BuildFailureKind) -> Bool {
        switch kind {
        case .damagedNSP, .a32Program, .shaderRegression, .updateMismatch, .shellDataIncomplete, .engineSync, .unknown: return true
        default: return false
        }
    }

    package var body: some View {
        if let f = failure ?? m.failure {
            VStack(alignment: .leading, spacing: 10) {
                Text(loc.t("fail.section")).font(DS.Font.headline).foregroundStyle(DS.Color.textSecondary).padding(.leading, 2)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(Self.isError(f.kind) ? DS.Color.statusError : DS.Color.statusWarning).frame(width: 7, height: 7)
                        Text(m.failureWhat(f)).font(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).fixedSize(horizontal: false, vertical: true)
                    }
                    let chooseTitle = !f.titleIDs.isEmpty && !m.experimentalBuilder
                    Text(loc.t(chooseTitle ? "fail.severalGames.choose" : f.kind.nextKey)).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 17)
                    if chooseTitle {
                        // One selectable row per game, as the files list (#1458): its icon, its name, a radio. The title ID is only
                        // the tooltip and the VoiceOver value, or the subtitle of a game nobody knows. The footer's Build game builds it.
                        VStack(spacing: 0) {
                            ForEach(Array(f.titleIDs.enumerated()), id: \.element) { index, id in
                                if index > 0 { CardDivider() }
                                FailureTitleRow(titleID: id, name: titleNames[id.uppercased()], icon: titleIcon(id), chosen: m.failureChoice == id) { m.failureChoice = id }
                                    .padTarget("set.build.failure.title." + id, scope: "main", radius: DS.Radius.chip) { m.failureChoice = id }   // choosing is always open, the footer builds
                            }
                        }
                    } else {
                        buttons(f.kind).padding(.leading, 17).padding(.top, 2)
                    }
                    if f.kind == .shellDataIncomplete, m.finderShown, let archive = m.finderArchive {
                        FinderCopySteps(archive: archive).padding(.leading, 17)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
            }
            .sheet(isPresented: Binding(get: { m.confirmingOverride != nil }, set: { if !$0 { m.cancelBuildAnyway() } })) {
                LauncherConfirmSheet(title: loc.t("fail.confirm.title"), subtitle: "",
                    note: m.confirmingOverride.map { loc.t("fail.\($0.rawValue).risk") } ?? "",
                    cancelTitle: loc.t("fail.confirm.cancel"), confirmTitle: loc.t("fail.confirm.go"), scope: "buildoverride",
                    cancel: { m.cancelBuildAnyway() }, confirm: { m.confirmBuildAnyway() }).environmentObject(focus)
            }
            .onChange(of: m.confirmingOverride) { value in focus.scope = value == nil ? "main" : "buildoverride" }
        }
    }

    @ViewBuilder private func buttons(_ kind: BuildFailureKind) -> some View {
        HStack(spacing: 10) {
            switch kind {
            case .translator:
                fix(kind, "fail.translator.button")
            case .zbic:
                fix(kind, "fail.zbic.button")
            case .iosSDK:
                fix(kind, "fail.iosSDK.button")
            case .metalToolchain:
                fix(kind, "macFail.metalToolchain.button")
                Button(loc.t("macFail.metalToolchain.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("xcodebuild -downloadComponent MetalToolchain", forType: .string)
                }
                .padTarget("set.build.failure.copyMetal", scope: "main") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString("xcodebuild -downloadComponent MetalToolchain", forType: .string)
                }
            case .cltSelected:
                if m.installedXcode != nil { fix(kind, "fail.cltSelected.button") }
            case .keys, .keysOld:
                fix(kind, "fail.keys.button")
            case .updateMismatch:
                fix(kind, "macFail.updateMismatch.button")
                Button(loc.t("fail.showFolder")) { m.showFailureFolder() }.disabled(m.running)
                    .padTarget("set.build.failure.folder", scope: "main", enabled: !m.running) { if !m.running { m.showFailureFolder() } }
            case .mngSharedFonts:
                fix(kind, "macFail.mngSharedFonts.button")
                Button(loc.t("fail.showFolder")) { m.showFailureFolder() }.disabled(m.running)
                    .padTarget("set.build.failure.folder", scope: "main", enabled: !m.running) { if !m.running { m.showFailureFolder() } }
            case .severalGames, .noTitleID, .diskFull, .staleProfile:
                fix(kind, "fail.showFolder")
            case .cloudFolder, .volumeFormat:
                fix(kind, "fail.cloudFolder.button")
            case .teamTaken, .noSigningAccount, .freeAccountLimit, .appIDLimit:
                if m.installedXcode != nil { fix(kind, "fail.openXcode") }
            case .deviceTransfer, .devicePairing:
                fix(kind, "fail.retry")
            case .shellDataIncomplete:
                fix(kind, "shell.retry")
                if m.finderArchive != nil {
                    Button(loc.t("shell.sendFinder")) {
                        withAnimation(.easeInOut(duration: 0.18)) { m.copyWithFinder(oneGame: false) }
                    }.disabled(m.running)
                    .padTarget("set.build.failure.finder", scope: "main", enabled: !m.running) { if !m.running { m.copyWithFinder(oneGame: false) } }
                }
            case .engineOffline, .engineSync:
                Button(loc.t("fail.retry")) { engine?.retrySync() }.disabled(engine?.syncing ?? false)
                    .padTarget("set.build.failure.retry", scope: "main", enabled: !(engine?.syncing ?? false)) { engine?.retrySync() }
            default: EmptyView()
            }
            if kind.overrideFlag != nil {
                Button(loc.t("fail.buildAnyway")) { m.requestBuildAnyway() }.disabled(m.running)
                    .padTarget("set.build.failure.override", scope: "main", enabled: !m.running) { if !m.running { m.requestBuildAnyway() } }
            }
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
    }

    private func fix(_ kind: BuildFailureKind, _ key: String) -> some View {
        Group {
            if m.fixBusy(kind) {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(loc.t("dep.installing")).font(DS.Font.callout).foregroundStyle(LauncherPalette.building) }
            } else {
                Button(loc.t(key)) { m.fixBuildFailure(kind) }.disabled(m.running)
                    .padTarget("set.build.failure.fix." + kind.rawValue, scope: "main", enabled: !m.running) { if !m.running { m.fixBuildFailure(kind) } }
            }
        }
    }
}

/// Above every page of the launcher while the engine is fetched and patched (tools/engine.py sync, run for a checkout at launch and after
/// updates), and its failure row when that stops: what happened, what to do, and Try again.
package struct EngineSyncBanner: View {
    @ObservedObject var engine: EngineSyncStore
    let m: BuildStore
    /// In a page's content column (Settings): no inset of its own, the column gives the width.
    let inContent: Bool
    @EnvironmentObject var loc: Localizer

    package init(engine: EngineSyncStore, m: BuildStore, inContent: Bool = false) {
        self.engine = engine
        self.m = m
        self.inContent = inContent
    }

    /// The engine being fetched, as a notice (LauncherNotice). The library shows it, and the failure, in its own notice slot.
    package static func notice(_ engine: EngineSyncStore, t: (String) -> String) -> LauncherNoticeItem? {
        engine.syncing ? LauncherNoticeItem(id: "engine.syncing", tone: .info, title: t("engine.syncing"), busy: true) : nil
    }

    /// The engine's failure as an error notice with its own title ("The engine could not be downloaded"), not the build failure
    /// card: no build ran. Try again where that is the fix.
    package static func failureNotice(_ engine: EngineSyncStore, m: BuildStore, t: (String) -> String) -> LauncherNoticeItem? {
        guard !engine.syncing, let failure = engine.failure else { return nil }
        let retry = failure.kind == .engineOffline || failure.kind == .engineSync
        return LauncherNoticeItem(id: "engine.failure", tone: .error, title: m.failureWhat(failure), detail: t(failure.kind.nextKey),
                                  action: retry ? .init(title: t("fail.retry"), padID: "set.build.failure.retry") { engine.retrySync() } : nil)
    }

    /// Both notices, for a page's notice slot: inside its content column, scrolling with it (Settings puts them there).
    package static func notices(_ engine: EngineSyncStore, m: BuildStore, t: (String) -> String) -> [LauncherNoticeItem] {
        [notice(engine, t: t), failureNotice(engine, m: m, t: t)].compactMap { $0 }
    }

    package var body: some View {
        let items = Self.notices(engine, m: m, t: loc.t)
        if !items.isEmpty {
            // in the content column's width, never across the whole window over the page title
            LauncherNoticeStack(items)
                .frame(maxWidth: inContent ? .infinity : DS.Control.contentWidth)
                .padding(.horizontal, inContent ? 0 : DS.Space.l).padding(.vertical, inContent ? 0 : DS.Space.xs)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(engine.syncing ? "engine.syncing" : "engine.failure")
        }
    }
}
