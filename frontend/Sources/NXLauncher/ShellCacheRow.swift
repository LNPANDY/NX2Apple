import SwiftUI
import AppKit
import NXCore
import NXModel

/// Settings, "Tools", the cache row (#400, #427): where the shell cache is, Open folder, and Move cache folder. The look and the pad
/// targets (`set.cache*`) are CacheFolderRow's for the shell cache.
package struct ShellCacheRow: View {
    @ObservedObject var build: BuildStore

    package init(build: BuildStore) { self.build = build }

    package var body: some View { CacheFolderRow(build: build, cache: .shell) }
}

/// Settings, "Tools", under the shell cache: the nxkit work folder and the build seeds, each a row of its own with the divider above it.
package struct BuildCacheRows: View {
    @ObservedObject var build: BuildStore

    package init(build: BuildStore) { self.build = build }

    package var body: some View {
        CardDivider()
        CacheFolderRow(build: build, cache: .nxkit)
        CardDivider()
        CacheFolderRow(build: build, cache: .seeds)
    }
}

/// A cache folder's row: where it is, Open folder, and Move. A move opens a panel under the row: the confirmation (from, to, the
/// sizes, same drive or another), then the progress with Stop, then the result. The way back to the default place is a line under
/// the row while the cache is somewhere else. A folder on a drive that is not connected says so and keeps the way back. Observes
/// the build store, whose `running` flag turns the move off while a build, an install or an export runs, and keeps those off while
/// the cache moves.
package struct CacheFolderRow: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer
    let cache: CacheFolder

    package init(build: BuildStore, cache: CacheFolder) { self.build = build; self.cache = cache }

    /// The row's own texts and the prefix of its pad targets. The panel's texts are the same for every cache.
    private struct Texts { let row, note, pickMessage, nothingYet, pad: String }

    private var texts: Texts {
        switch cache {
        case .shell: return Texts(row: "shellCache.row", note: "shellCache.note", pickMessage: "shellCache.pickMessage",
                                  nothingYet: "shellCache.nothingYet", pad: "set.cache")
        case .nxkit: return Texts(row: "nxkitCache.row", note: "nxkitCache.note", pickMessage: "nxkitCache.pickMessage",
                                  nothingYet: "nxkitCache.nothingYet", pad: "set.nxkitCache")
        case .seeds: return Texts(row: "seedCache.row", note: "seedCache.note", pickMessage: "seedCache.pickMessage",
                                  nothingYet: "seedCache.nothingYet", pad: "set.seedCache")
        }
    }

    /// The column where a row's text starts (CardRow: the edge, the dot and its gap).
    private let axis: CGFloat = 37
    private let well = LauncherPalette.well

    private var state: CacheMove { build.cacheMove(cache) }
    private var canMove: Bool { !build.running && !build.cacheFixedByEnvironment(cache) }

    package var body: some View {
        let path = build.cachePath(cache), texts = texts, unreachable = build.cacheUnreachable(cache)
        VStack(alignment: .leading, spacing: 0) {
            CardRow(loc.t(texts.row), detail: loc.t(texts.note), detail2: build.shortPath(path)) {
                Button(loc.t("shellCache.open")) { build.revealFolder(URL(fileURLWithPath: path)) }
                    .padTarget(texts.pad + "Open", scope: "main", enabled: !unreachable) { if !unreachable { build.revealFolder(URL(fileURLWithPath: path)) } }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .disabled(unreachable)
                Button(loc.t("shellCache.move")) { pickFolder() }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .disabled(!canMove)
                    .padTarget(texts.pad + "Move", scope: "main", enabled: canMove) { if canMove { pickFolder() } }
            }
            if state == .idle, unreachable || build.cacheFixedByEnvironment(cache) {
                note(.warning, loc.t(unreachable ? "shellCache.unreachable" : "seedCache.fromEnvironment"))
                    .padding(.leading, axis).padding(.trailing, 18).padding(.bottom, 10)
            }
            if !build.cacheIsDefault(cache), !build.cacheFixedByEnvironment(cache), state == .idle {
                Button(loc.t("shellCache.useDefault")) { build.prepareCacheMoveToDefault(cache) }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .disabled(build.running)
                    .padTarget(texts.pad + "Default", scope: "main", enabled: !build.running) { if !build.running { build.prepareCacheMoveToDefault(cache) } }
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 18).padding(.bottom, 13)
            }
            if state != .idle {
                panel.padding(.leading, axis).padding(.trailing, 18).padding(.bottom, 14)
            }
        }
        // CardRow's `frame(minHeight:)` lets a row shrink to its minimum height when the stack around it is short of room, and its
        // texts then spill over the lines under it (the note, the panel, the next row). The row always takes the height it needs.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func pickFolder() {
        let d = NSOpenPanel()
        d.canChooseDirectories = true; d.canChooseFiles = false; d.canCreateDirectories = true
        d.message = loc.t(texts.pickMessage)
        d.prompt = loc.t("shellCache.pickButton")
        if d.runModal() == .OK, let u = d.url { build.prepareCacheMove(cache, into: u.path) }
    }

    // MARK: The panel

    @ViewBuilder private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state {
            case .idle:
                EmptyView()
            case .confirm(let plan):
                confirmation(plan)
            case .moving(let phase, let done, let total):
                let key = phase == .copying ? "shellCache.copying" : "shellCache.checking"
                VStack(alignment: .leading, spacing: 8) {
                    LauncherProgressBar(value: total > 0 ? Double(done) / Double(total) : 0, height: 6).frame(height: 6)
                    Text(String(format: loc.t(key), ShellInstall.sizeText(done), ShellInstall.sizeText(total)))
                        .font(DS.Font.callout).monospacedDigit().foregroundStyle(LauncherPalette.secondaryText)
                }
                footer(.info, loc.t("shellCache.movingNote")) {
                    button(loc.t("btn.stop"), id: "stop", accent: LauncherPalette.building) { build.stopCacheMove() }
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

    @ViewBuilder private func confirmation(_ plan: CacheFolderMove.Plan) -> some View {
        Text(loc.t("shellCache.confirmTitle")).font(DS.Font.bodyStrong)
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            fact("shellCache.from", build.shortPath(plan.source), path: true)
            fact("shellCache.to", build.shortPath(plan.destination), path: true)
            if plan.sourceExists { fact("shellCache.size", ShellInstall.sizeText(plan.bytes)) }
            if let free = plan.free { fact("shellCache.free", ShellInstall.sizeText(free)) }
        }
        if let problem = plan.problem {
            note(.blocked, problemText(problem))
        } else if !plan.sourceExists {
            // a folder on a drive that is not connected: only the saved place changes, its files stay on that drive
            note(.info, loc.t(BuildCacheRoots.unreachable(plan.source, volumes: build.volumesRoot) ? "shellCache.oldDriveMissing" : texts.nothingYet))
        } else {
            note(.info, loc.t(plan.sameVolume ? "shellCache.sameDrive" : "shellCache.otherDrive"))
        }
        if build.running { note(.warning, loc.t("shellCache.busy")) }
        buttons {
            button(loc.t("saves.cancel"), id: "cancel") { build.dismissCacheMove(cache) }
            if plan.problem == nil {
                button(loc.t("shellCache.go"), id: "confirm", accent: LauncherPalette.ready, enabled: !build.running) { build.confirmCacheMove(cache) }
            }
        }
    }

    private func fact(_ key: String, _ value: String, path: Bool = false) -> some View {
        GridRow {
            Text(loc.t(key)).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
            Text(value).font(path ? .mono(12) : .manrope(12.5, .semibold)).monospacedDigit()
                .lineLimit(1).truncationMode(.middle).help(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func problemText(_ problem: CacheFolderMove.Problem) -> String {
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

    private var ok: some View { button(loc.t("library.ok"), id: "done") { build.dismissCacheMove(cache) } }

    /// A note with its button beside it, on one line when it fits: the progress and the results.
    private func footer<Content: View>(_ kind: NoteKind, _ text: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 16) { note(kind, text); content() }
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { Spacer(minLength: 0); content() }
    }

    private func button(_ title: String, id: String, accent: Color? = nil, enabled: Bool = true, _ perform: @escaping () -> Void) -> some View {
        Button(title, action: perform).buttonStyle(LauncherSecondaryButtonStyle(accent: accent)).disabled(!enabled).fixedSize()
            .padTarget(texts.pad + "." + id, scope: "main", enabled: enabled, activate: perform)
    }

    private enum NoteKind { case done, info, warning, blocked }

    /// The launcher's note: a small symbol, then the text (as the export's notes, ExportSteps.swift).
    private func note(_ kind: NoteKind, _ text: String) -> some View {
        let (symbol, color): (String, Color) = {
            switch kind {
            case .done: return (DSTone.success.symbol, DSTone.success.color)   // one symbol per tone (DSTone)
            case .info: return (DSTone.info.symbol, DS.Color.symbolDefault)
            case .warning: return (DSTone.warning.symbol, DSTone.warning.color)
            case .blocked: return (DSTone.error.symbol, DSTone.error.color)
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color).frame(width: 13)
            Text(text).font(DS.Font.callout).foregroundStyle(kind == .done || kind == .info ? Color.secondary : color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
