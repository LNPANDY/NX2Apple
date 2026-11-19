import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher

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

    package init(m: BuildStore, engine: EngineSyncStore? = nil, failure: BuildFailure? = nil, titleNames: [String: String] = [:]) {
        self.m = m
        self.engine = engine
        self.failure = failure
        self.titleNames = titleNames
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
                        // Side by side, wrapping on a narrow window: the game's name when it is known, its ID in mono under it (#1458)
                        DSFlowRow(spacing: DS.Space.xs) {
                            ForEach(f.titleIDs, id: \.self) { id in
                                Button { m.buildTitle(id) } label: {
                                    VStack(spacing: 0) {
                                        if let name = titleNames[id.uppercased()] { Text(name).font(DS.Font.bodyStrong).lineLimit(1) }
                                        Text(id).font(DS.Font.mono).foregroundStyle(DS.Color.textSecondary)
                                    }.padding(.vertical, titleNames[id.uppercased()] == nil ? 0 : DS.Space.xxs)
                                }
                                .buttonStyle(DSRowButtonStyle(height: titleNames[id.uppercased()] == nil ? DS.Control.height : 48))
                                .padTarget("set.build.failure.title." + id, scope: "main", enabled: m.canBuild) { if m.canBuild { m.buildTitle(id) } }
                            }
                        }
                        .padding(.leading, 17)
                        .disabled(!m.canBuild)
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
    @EnvironmentObject var loc: Localizer

    package init(engine: EngineSyncStore, m: BuildStore) {
        self.engine = engine
        self.m = m
    }

    /// The engine being fetched, as a notice (LauncherNotice). The library shows it, and the failure, in its own notice slot.
    package static func notice(_ engine: EngineSyncStore, t: (String) -> String) -> LauncherNoticeItem? {
        engine.syncing ? LauncherNoticeItem(id: "engine.syncing", tone: .info, title: t("engine.syncing"), busy: true) : nil
    }

    package var body: some View {
        if let notice = Self.notice(engine, t: loc.t) {
            LauncherNotice(notice).padding(.horizontal, 24).padding(.vertical, 10)
                .accessibilityIdentifier("engine.syncing")
        } else if let f = engine.failure {
            BuildFailureCard(m: m, engine: engine, failure: f).padding(.horizontal, 24).padding(.vertical, 10)
        }
    }
}
