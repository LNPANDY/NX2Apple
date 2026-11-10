import SwiftUI
import AppKit
import NXCore
import NXModel

/// Settings, "Tools", the cache row (#400, #427): where the shell cache is, Open folder, and Move cache folder. A move opens a panel
/// under the row: the confirmation (from, to, the sizes, same drive or another), then the progress with Stop, then the result. The
/// way back to the default place is a line under the row while the cache is somewhere else. Observes the build store, whose
/// `running` flag turns the move off while a build, an install or an export runs, and keeps those off while the cache moves.
package struct ShellCacheRow: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer

    package init(build: BuildStore) { self.build = build }

    /// The column where a row's text starts (CardRow: the edge, the dot and its gap).
    private let axis: CGFloat = 37
    private let well = LauncherPalette.well

    private var moving: Bool { if case .moving = build.shellMove { return true } else { return false } }

    package var body: some View {
        let path = build.shellCachePath
        VStack(alignment: .leading, spacing: 0) {
            CardRow(loc.t("shellCache.row"), detail: loc.t("shellCache.note"), detail2: build.shortPath(path)) {
                Button(loc.t("shellCache.open")) { build.revealFolder(URL(fileURLWithPath: path)) }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                Button(loc.t("shellCache.move")) { pickFolder() }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .disabled(build.running)
                    .padTarget("set.cacheMove", scope: "main") { if !build.running { pickFolder() } }
            }
            if !build.shellCacheIsDefault, build.shellMove == .idle {
                Button(loc.t("shellCache.useDefault")) { build.prepareShellMoveToDefault() }
                    .buttonStyle(.plain).font(.manrope(12.5, .semibold)).foregroundStyle(LauncherPalette.ready)
                    .disabled(build.running)
                    .padding(.leading, axis).padding(.top, -5).padding(.bottom, 13)
            }
            if build.shellMove != .idle {
                panel.padding(.leading, axis).padding(.trailing, 18).padding(.bottom, 14)
            }
        }
    }

    private func pickFolder() {
        let d = NSOpenPanel()
        d.canChooseDirectories = true; d.canChooseFiles = false; d.canCreateDirectories = true
        d.message = loc.t("shellCache.pickMessage")
        d.prompt = loc.t("shellCache.pickButton")
        if d.runModal() == .OK, let u = d.url { build.prepareShellMove(into: u.path) }
    }

    // MARK: The panel

    @ViewBuilder private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch build.shellMove {
            case .idle:
                EmptyView()
            case .confirm(let plan):
                confirmation(plan)
            case .moving(let phase, let done, let total):
                let key = phase == .copying ? "shellCache.copying" : "shellCache.checking"
                VStack(alignment: .leading, spacing: 8) {
                    LauncherProgressBar(value: total > 0 ? Double(done) / Double(total) : 0, height: 6).frame(height: 6)
                    Text(String(format: loc.t(key), ShellInstall.sizeText(done), ShellInstall.sizeText(total)))
                        .font(.manrope(12.5)).monospacedDigit().foregroundStyle(LauncherPalette.secondaryText)
                }
                footer(.info, loc.t("shellCache.movingNote")) {
                    button(loc.t("btn.stop"), accent: LauncherPalette.building) { build.stopShellMove() }
                }
            case .moved(let root):
                footer(.done, String(format: loc.t("shellCache.moved"), build.shortPath(root))) { ok }
            case .movedOldStays(let root, let old):
                footer(.warning, String(format: loc.t("shellCache.movedOldStays"), build.shortPath(root), build.shortPath(old))) { ok }
            case .stopped(let root):
                footer(.info, String(format: loc.t("shellCache.stopped"), build.shortPath(root))) { ok }
            case .failed(let why, let root):
                footer(.warning, String(format: loc.t("shellCache.failed"), why, build.shortPath(root))) { ok }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(well, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LauncherPalette.cardBorder))
    }

    @ViewBuilder private func confirmation(_ plan: ShellRootMove.Plan) -> some View {
        Text(loc.t("shellCache.confirmTitle")).font(.manrope(14, .semibold))
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            fact("shellCache.from", build.shortPath(plan.source), path: true)
            fact("shellCache.to", build.shortPath(plan.destination), path: true)
            if plan.sourceExists { fact("shellCache.size", ShellInstall.sizeText(plan.bytes)) }
            if let free = plan.free { fact("shellCache.free", ShellInstall.sizeText(free)) }
        }
        if let problem = plan.problem {
            note(.blocked, problemText(problem))
        } else if !plan.sourceExists {
            note(.info, loc.t("shellCache.nothingYet"))
        } else {
            note(.info, loc.t(plan.sameVolume ? "shellCache.sameDrive" : "shellCache.otherDrive"))
        }
        if build.running { note(.warning, loc.t("shellCache.busy")) }
        buttons {
            button(loc.t("saves.cancel")) { build.dismissShellMove() }
            if plan.problem == nil {
                button(loc.t("shellCache.go"), accent: LauncherPalette.ready, enabled: !build.running) { build.confirmShellMove() }
            }
        }
    }

    private func fact(_ key: String, _ value: String, path: Bool = false) -> some View {
        GridRow {
            Text(loc.t(key)).font(.manrope(12.5)).foregroundStyle(LauncherPalette.secondaryText)
            Text(value).font(path ? .mono(12) : .manrope(12.5, .semibold)).monospacedDigit()
                .lineLimit(1).truncationMode(.middle).help(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func problemText(_ problem: ShellRootMove.Problem) -> String {
        switch problem {
        case .same: return loc.t("shellCache.problem.same")
        case .insideCache: return loc.t("shellCache.problem.inside")
        case .notPlain: return loc.t("shellCache.problem.notPlain")
        case .unknownContent: return loc.t("shellCache.problem.unknown")
        case .unreadableLedger: return loc.t("shellCache.problem.ledger")
        case .destinationTaken: return loc.t("shellCache.problem.taken")
        case .readOnly: return loc.t("shellCache.problem.readOnly")
        case .noSpace(let needed, let free):
            return String(format: loc.t("shellCache.problem.noSpace"), ShellInstall.sizeText(needed), ShellInstall.sizeText(free))
        }
    }

    private var ok: some View { button(loc.t("library.ok")) { build.dismissShellMove() } }

    /// A note with its button beside it, on one line when it fits: the progress and the results.
    private func footer<Content: View>(_ kind: NoteKind, _ text: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 16) { note(kind, text); content() }
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { Spacer(minLength: 0); content() }
    }

    private func button(_ title: String, accent: Color? = nil, enabled: Bool = true, _ perform: @escaping () -> Void) -> some View {
        Button(title, action: perform).buttonStyle(LauncherSecondaryButtonStyle(accent: accent)).disabled(!enabled).fixedSize()
    }

    private enum NoteKind { case done, info, warning, blocked }

    /// The launcher's note: a small symbol, then the text (as the export's notes, ExportSteps.swift).
    private func note(_ kind: NoteKind, _ text: String) -> some View {
        let (symbol, color): (String, Color) = {
            switch kind {
            case .done: return ("checkmark.circle.fill", LauncherPalette.ready)
            case .info: return ("info.circle", .secondary)
            case .warning: return ("exclamationmark.triangle.fill", LauncherPalette.building)
            case .blocked: return ("exclamationmark.triangle.fill", .red)
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color).frame(width: 13)
            Text(text).font(.manrope(12.5)).foregroundStyle(kind == .done || kind == .info ? Color.secondary : color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
