import SwiftUI
import NXCore
import NXLauncher

/// A game's page (#816), the content column of its full-screen page (ConsolePageLayout puts its artwork, title and status on the
/// left and the hint bar under it): one segmented control for the tabs on L and R (Overview, Saves, Build, Cheats), then what each
/// holds. Overview: one stats card (last played, play time, cloud saves) and one grouped list (Controls, Launch options, Manage).
/// X plays (the hint bar says so), Y opens the launch options, − the quick menu, B goes back.
@MainActor struct ConsoleGamePage<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let game: ConsoleGame
    let lang: Lang
    let glyphs: ConsoleGlyphs
    let compact: Bool
    var embedded = false
    @Binding var editing: String?
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var scope: String { "console.gamePage" }
    private var scope: String { Self.scope }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var inset: CGFloat { compact ? DS.Console.Space.l : DS.Console.Space.xl }
    private var state: ConsoleState { driver.state }
    private var paused: Bool { state.pausedGameID == game.id }

    /// Where the focus starts: the first row of the Overview (Controls for a game this Mac plays, else what it needs).
    static func firstTarget(_ game: ConsoleGame?, paused: Bool) -> String {
        game?.status == .ready ? "console.gamePage.controls" : "console.gamePage.primary"
    }

    /// Where the focus goes when a tab opens: its first row, nil when the tab has none.
    static func tabTarget(_ tab: ConsoleGameTab, game: ConsoleGame, building: Bool = false) -> String? {
        switch tab {
        case .overview: return firstTarget(game, paused: false)
        case .saves: return "console.gamePage.cloudSaves"
        case .build: return game.status != .needsBuild ? "console.gamePage.desktop" : (building ? "console.gamePage.queue" : "console.gamePage.build")
        case .cheats: return game.cheats.map { $0.note == nil || !$0.items.isEmpty } == true ? "console.cheats.master" : nil
        }
    }

    /// The tabs' pad ids, which a click or A on a segment reaches too.
    static func hintIDs(_ game: ConsoleGame, embedded: Bool = false) -> [String] {
        ConsoleGameTab.allCases.map { "console.gamePage.tab." + $0.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabs.padding(.horizontal, inset).padding(.bottom, DS.Console.Space.xl)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: DS.Console.Space.xl) {
                        switch state.gameTab {
                        case .overview: overview
                        case .saves: saves
                        case .build: build
                        case .cheats: cheats
                        }
                    }
                    .padding(.horizontal, inset).padding(.bottom, DS.Console.Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .consoleScrollContent()
                }
                .consoleScrollFade()
                .onChange(of: pad.focused) { id in
                    guard let id, !id.hasPrefix("console.gamePage.tab.") else { return }
                    withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: state.gameTab) { tab in pad.focused = Self.tabTarget(tab, game: game, building: state.builds.running) }
    }

    // MARK: Tabs

    private var tabs: some View {
        let all = ConsoleGameTab.allCases
        return ConsoleSegmentedControl(segments: all.map { ($0.rawValue, t($0.titleKey)) }, selected: all.firstIndex(of: state.gameTab) ?? 0,
                                       previousGlyph: glyphs.hintGlyph(.previousTab, swapAB: state.menuSwapAB),
                                       nextGlyph: glyphs.hintGlyph(.nextTab, swapAB: state.menuSwapAB),
                                       scope: scope, idPrefix: "console.gamePage.tab.") { index in
            driver.stepGameTab(index - (all.firstIndex(of: state.gameTab) ?? 0))
        }
    }

    // MARK: Overview

    /// A game nxkit built without a game profile (v0lumehi/nxkit#54): what that means, what nxkit detected, and Report, which opens the
    /// prefilled issue in the browser. On the Overview above everything, since the game may not start or may render wrong.
    @ViewBuilder private var genericBuildNotice: some View {
        if game.status == .ready, let profile = game.genericBuild {
            let detected = NxkitGenericBuildRow.detected(profile, t)
            ConsoleNoticeCard(tone: .warning, title: t("nxkit.generic.title"),
                              detail: t("nxkit.generic.note") + (detected.isEmpty ? "" : "\n" + detected),
                              action: genericReportAction)
        }
    }

    private var genericReportAction: (title: String, id: String, scope: String, perform: () -> Void)? {
        guard game.genericReport != nil else { return nil }
        let driver = driver, id = game.id
        return (title: t("nxkit.feedback.report"), id: "console.gamePage.genericReport", scope: scope,
                perform: { driver.openGenericBuildReport(id) })
    }

    @ViewBuilder private var overview: some View {
        genericBuildNotice
        if game.status == .ready {
            ConsoleStatsCard(items: [
                (t("console.lastPlayed"), game.lastPlayed.map { ConsoleTimes.relative($0, now: state.time, lang: lang) } ?? t("console.notPlayed")),
                (t("console.playTime"), game.playSeconds > 0 ? ConsoleTimes.duration(game.playSeconds, lang: lang) : t("console.notPlayed")),
                (t("console.menu.saves"), game.save.map { t($0.status.key) } ?? t("console.saves.status.off")),
            ])
            ConsoleGroupedList {
                ConsoleListRow(id: "console.gamePage.controls", scope: scope, title: t("console.gamePage.controls"),
                               subtitle: t(game.hasControllerSettings ? "console.gamePad.note" : "console.menu.mappingNote")) {
                    game.hasControllerSettings ? driver.openGamePad(game.id) : driver.openMapping()
                }
                ConsoleRowDivider()
                ConsoleListRow(id: "console.gamePage.options", scope: scope, title: t("console.gamePage.options"),
                               subtitle: t("console.gamePage.optionsNote")) { driver.openOptions(game.id) }
                if game.builtMacEngines.count > 1,
                   let active = game.activeMacEngine ?? game.builtMacEngines.first,
                   let nextIndex = game.builtMacEngines.firstIndex(of: active).map({ ($0 + 1) % game.builtMacEngines.count }) {
                    let nextEngine = game.builtMacEngines[nextIndex]
                    ConsoleRowDivider()
                    ConsoleListRow(id: "console.gamePage.defaultEngine", scope: scope,
                                   title: String(format: t("console.manage.setDefault"), active.displayName),
                                   subtitle: String(format: t("library.setDefaultEngine"), nextEngine.displayName)) {
                        driver.setDefaultMacEngine(game.id, upstream: nextEngine)
                    }
                }
                ConsoleRowDivider()
                manageRow
            }
        } else {
            ConsoleNoticeCard(tone: .warning, title: t(game.status.explanationKey ?? "console.ready"))
            ConsoleGroupedList {
                ConsoleListRow(id: "console.gamePage.primary", scope: scope,
                               title: t(game.status == .needsBuild ? (state.builds.running ? "queue.add" : "console.build") : "console.openOnDesktop"),
                               subtitle: t(game.status == .needsBuild ? (state.builds.running ? "console.gamePage.queueNote" : "console.gamePage.buildNote") : "console.gamePage.desktopNote")) {
                    if game.status == .needsBuild { driver.buildGame(game.id, queueOnly: state.builds.running) }
                    else { driver.openOnDesktop(game.id) }
                }
                ConsoleRowDivider()
                manageRow
            }
        }
    }

    private var manageRow: some View {
        ConsoleListRow(id: "console.gamePage.manage", scope: scope, title: t("console.manage"), subtitle: t("console.manage.note")) { driver.openManage(game.id) }
    }

    // MARK: Saves

    @ViewBuilder private var saves: some View {
        ConsoleStatsCard(items: [
            (t("console.gamePage.lastSave"), game.lastSave.map { ConsoleTimes.absolute($0, lang: lang) } ?? t("console.stopped.noSave")),
            (t("console.menu.saves"), game.save.map { t($0.status.key) } ?? t("console.saves.status.off")),
        ])
        if let detail = game.save?.detail, !detail.isEmpty {
            Text(detail).font(DS.Console.Font.callout).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        ConsoleGroupedList {
            ConsoleListRow(id: "console.gamePage.cloudSaves", scope: scope, title: t("console.menu.saves"),
                           subtitle: t("console.menu.savesNote")) { driver.openCloudSaves() }
        }
    }

    // MARK: Build

    @ViewBuilder private var build: some View {
        ConsoleStatsCard(items: [
            (t("console.gamePage.version"), game.version.isEmpty ? t("console.gamePage.unknown") : game.version),
            (t("console.gamePage.platforms"), game.platforms.map { t($0.labelKey) }.joined(separator: ", ")),
            (t("console.gamePage.status"), t(game.status.labelKey)),
        ])
        if game.olderTools { ConsoleNoticeCard(tone: .warning, title: t("library.olderToolsHelp")) }
        if game.status == .ready, let profile = game.genericBuild {
            // the same note, short: who opens the build sees it was built without a game profile
            ConsoleNoticeCard(tone: .warning, title: t("nxkit.generic.title"), detail: NxkitGenericBuildRow.detected(profile, t),
                              action: genericReportAction)
        }
        ConsoleGroupedList {
            // A game that is not built builds from here (#1111): now when nothing builds, after the running build otherwise
            if game.status == .needsBuild && !state.builds.running {
                ConsoleListRow(id: "console.gamePage.build", scope: scope, title: t("console.build"), subtitle: t("console.gamePage.buildNote")) {
                    driver.buildGame(game.id, queueOnly: false)
                }
                ConsoleRowDivider()
            } else if game.status == .needsBuild {
                ConsoleListRow(id: "console.gamePage.queue", scope: scope, title: t("queue.add"), subtitle: t("console.gamePage.queueNote")) {
                    driver.buildGame(game.id, queueOnly: true)
                }
                ConsoleRowDivider()
            }
            ConsoleListRow(id: "console.gamePage.desktop", scope: scope, title: t("console.openOnDesktop"), subtitle: t("console.gamePage.desktopNote")) {
                driver.openOnDesktop(game.id)
            }
        }
    }

    // MARK: Cheats

    @ViewBuilder private var cheats: some View {
        if game.cheats.map({ $0.note == nil || !$0.items.isEmpty }) == true {
            ConsoleCheatsSection(driver: driver, game: game, lang: lang, compact: compact, scope: scope)
        } else {
            ConsoleNoticeCard(tone: .info, title: game.cheats?.note ?? t("console.gamePage.noCheats"))
        }
    }
}

/// A game's Manage panel (#816): what console mode can do for it, and the way to the desktop for the rest (building again, its
/// artwork and files, removing it), which needs the Finder.
@MainActor struct ConsoleManagePanel<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let game: ConsoleGame
    let lang: Lang
    let compact: Bool
    private func t(_ key: String) -> String { L10n.string(key, lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Console.Space.xl) {
            if game.builtMacEngines.count > 1 {
                let active = game.activeMacEngine ?? game.builtMacEngines.first
                ConsoleGroupedList(title: t("console.manage.engineBuilds")) {
                    ForEach(Array(game.builtMacEngines.enumerated()), id: \.element) { index, upstream in
                        if index > 0 { ConsoleRowDivider() }
                        ConsoleListRow(
                            id: "console.manage.launch." + upstream.rawValue,
                            scope: "console.manage",
                            title: String(format: t("library.launchWithEngine"), upstream.displayName),
                            subtitle: upstream == active ? t("library.defaultBuildTag") : String(format: t("library.setDefaultEngine"), upstream.displayName)
                        ) {
                            driver.launchWithMacEngine(game.id, upstream: upstream)
                        }
                    }
                    ForEach(game.builtMacEngines.filter { $0 != active }, id: \.self) { upstream in
                        ConsoleRowDivider()
                        ConsoleListRow(
                            id: "console.manage.default." + upstream.rawValue,
                            scope: "console.manage",
                            title: String(format: t("library.setDefaultEngine"), upstream.displayName)
                        ) {
                            driver.setDefaultMacEngine(game.id, upstream: upstream)
                        }
                    }
                }
            }
            ConsoleGroupedList(title: t("console.tab.build")) {
                ConsoleListRow(id: "console.manage.desktop", scope: "console.manage", title: t("console.openOnDesktop")) { driver.openOnDesktop(game.id) }
            }
            if game.status == .ready || game.canReset {
                ConsoleGroupedList(title: t("console.options.manageSection")) {
                    if game.status == .ready {
                        ConsoleListRow(id: "console.manage.saves", scope: "console.manage", title: t("console.menu.saves")) { driver.openCloudSaves() }
                    }
                    if game.canReset {
                        if game.status == .ready { ConsoleRowDivider() }
                        ConsoleListRow(id: "console.manage.reset", scope: "console.manage", title: t("console.reset.title")) { driver.askResetOptions(game.id) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? DS.Console.Space.l : DS.Console.Space.xl).padding(.bottom, DS.Console.Space.xl)
    }
}
