import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// One current record per title. Artifact presence never implies a live mobile installation.
struct BuildInventoryEntry: Identifiable {
    let game: LibraryGame
    let mac: Bool
    let mobile: Mobile
    let installed: Bool
    /// Read once here: the Mac package's version reads the bundle, and a table cell is drawn again on every redraw.
    let version: String?
    /// The name shown in the table, set by the view for its language (`named(_:)`). The sort and every cell read it, so the
    /// game's name, which cleans the file name with regular expressions, is worked out once per game, not per comparison.
    private(set) var displayName = ""
    enum Mobile { case none, app, ipa }
    var id: UUID { game.id }
    init(_ game: LibraryGame) {
        self.game = game
        let app = game.playableMacBundle   // one read for `isReady` and `playVersion`
        mac = app != nil
        installed = game.onDevice
        mobile = game.hasIOSApp ? .app : (game.hasIPA ? .ipa : .none)
        version = app?.version ?? (mac ? nil : game.unbuiltVersion)   // `playVersion ?? unbuiltVersion`, which is nil for a Mac build
    }
    func named(_ lang: Lang) -> Self {
        var entry = self
        entry.displayName = game.displayName(lang)
        return entry
    }
}

struct BuildInventoryView: View {
    @ObservedObject var library: GameLibrary
    @ObservedObject var build: BuildStore
    @ObservedObject var repo: RepoStore
    @ObservedObject var dependencies: DependencyStore
    let onOpenSettings: () -> Void
    private var needsSetup: Bool { (!repo.isRepo && !build.usesExternalUpstreamRepo) || !dependencies.allPresent }
    let hasDraft: Bool
    let inventory: [BuildInventoryEntry]
    let filter: BuildInventoryFilter
    let search: String
    let artwork: [UUID: NSImage]
    let managedID: UUID?
    let configure: (LibraryGame) -> Void
    let buildPlatform: (LibraryGame, String) -> Void
    let selectGames: () -> Void
    let manage: (LibraryGame) -> Void
    let setFilter: (BuildInventoryFilter) -> Void
    let resume: () -> Void
    let newBuild: () -> Void
    let supportedGames: () -> Void
    @ObservedObject var queue: BuildQueueStore
    private var queuedCount: Int { queue.queued.count }
    let chooseFolder: () -> Void
    @State private var selection: UUID?
    @StateObject private var tableNavigation = BuildTableNavigation()
    @ObservedObject var pad: PadFocus
    @EnvironmentObject private var loc: Localizer

    private var entries: [BuildInventoryEntry] {
        inventory.filter { filter.includes($0) && $0.game.matches(search: search, lang: loc.lang) }.map { $0.named(loc.lang) }.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.game.titleID < $1.game.titleID : order == .orderedAscending
        }
    }

    var body: some View {
        let entries = self.entries
        let controller = pad, localizer = loc
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                CardPageHeading(loc.t("nav.builds"), note: "")
                Spacer()
                Button(action: supportedGames) {
                    Label(loc.t("supported.title"), systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .padTarget("builds.supported", scope: "main", activate: supportedGames)
                Button(action: newBuild) {
                    Label {
                        Text(loc.t("library.newBuild")).font(.manrope(13, .semibold))
                    } icon: {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 18).frame(height: LauncherControl.height)
                }
                .buttonStyle(LauncherActionButtonStyle())
                .disabled(build.running || needsSetup)
                .padTarget("builds.first", scope: "main", focusColor: LauncherPalette.onCream, enabled: !build.running && !needsSetup, activate: { if !build.running && !needsSetup { newBuild() } })

            }
            EngineSwitcherCard(build: build)
            SetupHintCard(repo: repo, dependencies: dependencies, usesExternalUpstream: build.usesExternalUpstreamRepo, onOpenSettings: onOpenSettings)
            Group {
                CurrentBuildEntry(build: build, hasDraft: hasDraft, artwork: inventory.first(where: { $0.game.titleID == build.gameTitleID }).flatMap { artwork[$0.id] },
                                  title: inventory.first(where: { $0.game.titleID == build.gameTitleID })?.game.displayName(loc.lang), resume: resume)
            }
            if !queue.entries.isEmpty {
                HStack {
                    Label(loc.t("queue.title") + " · " + String(format: loc.t("queue.count"), queuedCount), systemImage: "list.bullet")
                    Spacer()
                    Button(loc.t("library.viewBuild"), action: resume).buttonStyle(LauncherSecondaryButtonStyle())
                        .padTarget("builds.queue", scope: "main", activate: resume)
                }.padding(18).background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
            }
            if library.games.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Label(loc.t("builds.empty.title"), systemImage: "shippingbox")
                        .font(.manrope(22, .semibold))
                    Text(loc.t("builds.empty.note")).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 660, alignment: .leading)
                    HStack(spacing: 12) {
                        Button(loc.t("builds.empty.addBuilds"), action: chooseFolder)
                            .padTarget("builds.folder", scope: "main", activate: chooseFolder)
                    }.buttonStyle(LauncherSecondaryButtonStyle())
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            } else {
                HStack {
                    LauncherSegmented(options: BuildInventoryFilter.allCases.map { ($0.rawValue, loc.t($0.labelKey)) }, selection: filter.rawValue) {
                        if let value = BuildInventoryFilter(rawValue: $0) { setFilter(value) }
                    }.fixedSize()
                        .padTarget("builds.filter", scope: "main", activate: {
                            setFilter(filter == .notBuilt ? .owned : filter.adjusted(1))
                        }, adjust: { setFilter(filter.adjusted($0)) })
                    Spacer()
                    Button(loc.t("queue.select"), action: selectGames)
                        .buttonStyle(LauncherSecondaryButtonStyle())
                        .disabled(build.running || needsSetup)
                        .padTarget("builds.batch", scope: "main", enabled: !build.running && !needsSetup, activate: { if !build.running && !needsSetup { selectGames() } })
                }
                Table(entries, selection: $selection) {
                    TableColumn(loc.t("builds.game")) { entry in
                        HStack(spacing: 12) {
                            if let image = artwork[entry.id] {
                                Image(nsImage: image).resizable().scaledToFill().frame(width: 72, height: 40).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 5)).accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.displayName).font(.manrope(14, .semibold)).lineLimit(2)
                                if let version = entry.version {
                                    Text(version)
                                        .font(.manrope(11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }.padding(.vertical, 8)
                            .padTarget("builds.game." + entry.id.uuidString, scope: "main", radius: 5, activate: {
                                if !build.running { configure(entry.game) }
                            }, vertical: { moveFocus(from: entry.id, direction: $0, entries: entries, manage: false) })
                            .background(BuildTableProbe(navigation: tableNavigation))
                            .environmentObject(controller)
                    }.width(min: 220, ideal: 320)
                    TableColumn(loc.t("library.section.mac")) { entry in
                        platformCell(entry, target: BuildTarget.mac, entries: entries).environmentObject(localizer).environmentObject(controller)
                    }.width(100)
                    TableColumn(loc.t("library.section.mobile")) { entry in
                        platformCell(entry, target: BuildTarget.ios, entries: entries).environmentObject(localizer).environmentObject(controller)
                    }.width(160)
                    TableColumn("") { entry in
                            Button { manage(entry.game) } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: LauncherControl.height, height: LauncherControl.height)
                                    .contentShape(Rectangle())
                            }
                                .buttonStyle(.plain).launcherHover()
                                .accessibilityLabel(loc.t("library.manage") + ": " + entry.game.name)
                                .anchorPreference(key: ManageAnchorKey.self, value: .bounds) { managedID == entry.id ? $0 : nil }
                                .padTarget("builds.manage." + entry.id.uuidString, scope: "main", activate: { manage(entry.game) },
                                           vertical: { moveFocus(from: entry.id, direction: $0, entries: entries, manage: true) })
                            .environmentObject(controller)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }.width(52)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                // The table's first row height guess. At AppKit's 24 points it builds about twice the rows that fit, and opening the
                // tab costs that. 44 is the lowest row there is (the 36 point Manage button and the row inset), so no row changes.
                .environment(\.defaultMinListRowHeight, LauncherControl.height + 8)
                .scrollContentBackground(.hidden)
                .background(LauncherPalette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(LauncherPalette.cardBorder, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .contextMenu(forSelectionType: UUID.self) { selected in
                    if let id = selected.first, let entry = entries.first(where: { $0.id == id }) {
                        Button(loc.t("builds.configure")) { configure(entry.game) }.disabled(build.running || needsSetup)
                        if let path = entry.game.revealTarget {
                            Button(loc.t("install.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        }
                    }
                } primaryAction: { selected in
                    guard !build.running, let id = selected.first, let entry = entries.first(where: { $0.id == id }) else { return }
                    configure(entry.game)
                }
                .overlay {
                    if entries.isEmpty { Text(loc.t(search.isEmpty ? "console.allGames.empty" : "library.noResults")).foregroundStyle(.secondary).allowsHitTesting(false) }
                }
                .onChange(of: entries.map(\.id)) { ids in
                    if let selection, !ids.contains(selection) { self.selection = nil }
                    if pad.scope == "main", let id = pad.focused, id.hasPrefix("builds."),
                       let uuid = UUID(uuidString: String(id.suffix(36))), !ids.contains(uuid) { pad.focused = "builds.filter" }
                }
                .onChange(of: selection) { id in if let id { library.selectedID = id } }
                .onChange(of: pad.focused) { id in
                    guard pad.scope == "main", let id, id.hasPrefix("builds."),
                          let uuid = UUID(uuidString: String(id.suffix(36))), entries.contains(where: { $0.id == uuid }) else { return }
                    selection = uuid
                }
            }
        }
        .padding(.horizontal, 40).padding(.vertical, 32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    @ViewBuilder private func platformCell(_ entry: BuildInventoryEntry, target: String, entries: [BuildInventoryEntry]) -> some View {
        let built = target == BuildTarget.mac ? entry.mac : entry.mobile != .none
        if built {
            BuildArtifactStatus(built: true, ipaOnly: target == BuildTarget.ios && entry.mobile == .ipa)
        } else {
            Button { buildPlatform(entry.game, target) } label: {
                Text(loc.t("builds.buildMissing")).font(.manrope(13, .semibold))
                    .frame(minHeight: LauncherControl.height).padding(.horizontal, 6)
                    .contentShape(Capsule())
            }
                .buttonStyle(.plain).launcherHover()
                .disabled(build.running || needsSetup)
                .accessibilityLabel([loc.t("builds.buildMissing"), entry.displayName,
                                     loc.t(target == BuildTarget.mac ? "library.section.mac" : "library.section.mobile")].joined(separator: ", "))
                .accessibilityValue(loc.t("filter.notBuilt"))
                .padTarget("builds.platform." + target + "." + entry.id.uuidString, scope: "main", enabled: !build.running && !needsSetup, activate: {
                    if !build.running && !needsSetup { buildPlatform(entry.game, target) }
                }, vertical: { direction in
                    guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
                    let indices = direction > 0 ? Array(entries.indices.dropFirst(index + 1)) : Array(entries.indices.prefix(index).reversed())
                    guard let next = indices.first(where: { target == BuildTarget.mac ? !entries[$0].mac : entries[$0].mobile == .none }) else { return false }
                    selection = entries[next].id
                    tableNavigation.reveal(row: next)
                    pad.focused = "builds.platform." + target + "." + entries[next].id.uuidString
                    return true
                })
        }
    }

    private func moveFocus(from id: UUID, direction: Int, entries: [BuildInventoryEntry], manage: Bool) -> Bool {
        guard let at = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(at + direction) else { return false }
        let row = at + direction, next = entries[row].id
        selection = next
        tableNavigation.reveal(row: row)
        pad.focused = (manage ? "builds.manage." : "builds.game.") + next.uuidString
        return true
    }

}

struct BuildArtifactStatus: View {
    let built: Bool
    var ipaOnly = false
    @EnvironmentObject private var loc: Localizer
    var body: some View {
        HStack(spacing: 7) {
            if built {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(LauncherPalette.ready)
                    .accessibilityLabel(loc.t("filter.built"))
                if ipaOnly { Text(loc.t("builds.ipaExport")).foregroundStyle(.secondary) }
            } else { Text(loc.t("filter.notBuilt")).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .combine)
    }
}

struct CurrentBuildEntry: View {
    @ObservedObject var build: BuildStore
    let hasDraft: Bool
    let artwork: NSImage?
    let title: String?
    let resume: () -> Void
    @EnvironmentObject private var loc: Localizer
    private var status: some View {
        Group {
            if build.running { ProgressView().controlSize(.small) }
            else if build.failure != nil { ArtworkOutcomeBadge(.failure, artworkSize: 48) }
            else if build.done { ArtworkOutcomeBadge(build.completionStatus == .needsData ? .warning : .success, artworkSize: 48) }
            else { Image(systemName: "hammer").foregroundStyle(LauncherPalette.cream) }
        }
    }

    var body: some View {
        if hasDraft || build.running || build.done || !build.basePath.isEmpty || !build.gameDir.isEmpty {
            HStack(spacing: 18) {
                ZStack {
                    if let artwork { Image(nsImage: artwork).resizable().scaledToFill() }
                    else { status.font(.system(size: 20, weight: .medium)) }
                }
                .frame(width: 48, height: 48)
                .background(LauncherPalette.ink(0.06), in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomTrailing) {
                    if artwork != nil {
                        if build.failure != nil { ArtworkOutcomeBadge(.failure, artworkSize: 48) }
                        else if build.done { ArtworkOutcomeBadge(build.completionStatus == .needsData ? .warning : .success, artworkSize: 48) }
                        else if build.running { status.padding(4).background(.black, in: Circle()).offset(x: 4, y: 4) }
                    }
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t(build.running ? "builds.current.running" : build.done ? "builds.current.complete" : "builds.current.draft"))
                        .font(.manrope(15, .semibold))
                    Text(title ?? build.gameName).foregroundStyle(.secondary).lineLimit(1)
                    if build.running {
                        Text(build.stages.last(where: { $0.state == .running })?.name ?? loc.t("library.preparing"))
                            .font(.manrope(12.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if build.running, let progress = build.overallProgress {
                    ProgressView(value: progress).frame(width: 120).tint(LauncherPalette.accent)
                        .accessibilityLabel(loc.t("prog.stageProgress"))
                }
                Button(loc.t(build.running || build.done ? "library.viewBuild" : "builds.resume"), action: resume)
                    .buttonStyle(LauncherSecondaryButtonStyle()).padTarget("builds.resume", scope: "main", activate: resume)
            }.padding(18).background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
