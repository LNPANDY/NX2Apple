import SwiftUI
import NXCore
import NXLauncher

/// A game's page (#816, A on a tile), over the whole screen in console mode's look: its title, the tabs on L and R (Overview, Saves,
/// Build, Cheats) and what each holds, from data and actions console mode already has. Overview: Play (Resume for a paused game, the
/// way to the desktop for one that is not built), when it was last played, for how long and where its save stands, then Controls,
/// Launch options (the options Y opens) and Manage.
@MainActor struct ConsoleGamePage<Driver: ConsoleDriver>: View {
    @ObservedObject var driver: Driver
    let game: ConsoleGame
    let lang: Lang
    let glyphs: ConsoleGlyphs
    let compact: Bool
    @Binding var editing: String?
    @EnvironmentObject private var pad: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var scope: String { "console.gamePage" }
    private var scope: String { Self.scope }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var inset: CGFloat { compact ? 24 : 64 }
    private var state: ConsoleState { driver.state }
    private var paused: Bool { state.pausedGameID == game.id }

    /// Where the focus starts: the main action.
    static func firstTarget(_ game: ConsoleGame?, paused: Bool) -> String { "console.gamePage.primary" }

    /// Where the focus goes when a tab opens: its first row.
    static func tabTarget(_ tab: ConsoleGameTab, game: ConsoleGame) -> String {
        switch tab {
        case .overview: return "console.gamePage.primary"
        case .saves: return "console.gamePage.cloudSaves"
        case .build: return "console.gamePage.desktop"
        case .cheats: return game.cheats.map { $0.note == nil || !$0.items.isEmpty } == true ? "console.cheats.master" : "console.gamePage.close"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsolePageHeader(title: game.title, subtitle: subtitle, compact: compact, closeLabel: t("console.close"),
                              closeID: "console.gamePage.close", scope: scope) { driver.back() }
            tabs.padding(.horizontal, inset).padding(.bottom, compact ? 16 : 28)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Group {
                            switch state.gameTab {
                            case .overview: overview
                            case .saves: saves
                            case .build: build
                            case .cheats: cheats
                            }
                        }
                        .padding(.horizontal, inset).padding(.bottom, compact ? 24 : 40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.consoleScrollContent()
                }
                .consoleScrollFade()
                .onChange(of: pad.focused) { id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            hints.padding(.horizontal, inset).padding(.bottom, compact ? 20 : 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LauncherPalette.background)
        .onChange(of: state.gameTab) { tab in pad.focused = Self.tabTarget(tab, game: game) }
    }

    /// What the buttons do on this page: X plays (resumes a paused game), Y opens the options, − the quick menu, B goes back.
    static func hintIDs(_ game: ConsoleGame) -> [String] {
        (game.status == .ready ? ["console.gamePage.hint.play", "console.gamePage.hint.options"] : []) + ["console.gamePage.hint.quick", "console.gamePage.hint.back"]
    }

    private var hints: some View {
        let g = { (role: ConsoleGlyphs.Role) in glyphs.hintGlyph(role, swapAB: state.menuSwapAB) }
        return HStack(spacing: compact ? 12 : 32) {
            if game.status == .ready {
                ConsoleHint(glyph: g(.play), label: t(paused ? "console.resume" : "console.play"), id: "console.gamePage.hint.play", scope: scope,
                            compact: compact) { paused ? driver.resume(game.id) : driver.play(game.id) }
                ConsoleHint(glyph: g(.options), label: t("console.options"), id: "console.gamePage.hint.options", scope: scope,
                            compact: compact) { driver.openOptions(game.id) }
            }
            ConsoleHint(glyph: g(.quickMenu), label: t("console.quickMenu"), id: "console.gamePage.hint.quick", scope: scope,
                        compact: compact) { driver.openQuickMenu() }
            Spacer(minLength: 0)
            ConsoleHint(glyph: g(.back), label: t("console.back"), id: "console.gamePage.hint.back", scope: scope, compact: compact) { driver.back() }
        }
    }

    private var subtitle: String {
        let status = paused ? t("console.paused") : t(game.status.labelKey) + (game.status == .ready && game.olderTools ? " \u{00b7} " + t("library.olderTools") : "")
        return game.version.isEmpty ? status : status + " \u{00b7} " + String(format: t("console.version"), game.version)
    }

    // MARK: Tabs

    /// The tabs between L and R, the open one cream. A click opens one too.
    private var tabs: some View {
        HStack(spacing: compact ? 8 : 12) {
            ConsoleGlyphView(glyph: glyphs.hintGlyph(.previousTab, swapAB: state.menuSwapAB), size: compact ? 20 : 24).foregroundStyle(.white.opacity(0.7))
            ForEach(ConsoleGameTab.allCases, id: \.self) { tab in
                let on = tab == state.gameTab
                Button { driver.stepGameTab(tabIndex(tab) - tabIndex(state.gameTab)) } label: {
                    Text(t(tab.titleKey)).font(.manrope(compact ? 15 : 18, .semibold)).lineLimit(1)
                        .foregroundStyle(on ? LauncherPalette.background : .white.opacity(0.8))
                        .padding(.horizontal, compact ? 14 : 20).frame(height: compact ? 36 : 44)
                        .background(on ? LauncherPalette.cream : .white.opacity(0.075), in: Capsule()).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
            ConsoleGlyphView(glyph: glyphs.hintGlyph(.nextTab, swapAB: state.menuSwapAB), size: compact ? 20 : 24).foregroundStyle(.white.opacity(0.7))
        }
    }

    private func tabIndex(_ tab: ConsoleGameTab) -> Int { ConsoleGameTab.allCases.firstIndex(of: tab) ?? 0 }

    // MARK: Overview

    private var overview: some View {
        HStack(alignment: .top, spacing: 48) {
            VStack(alignment: .leading, spacing: 16) {
                primary
                if game.status == .ready {
                    facts([(t("console.lastPlayed"), game.lastPlayed.map { ConsoleTimes.relative($0, now: state.time, lang: lang) } ?? t("console.notPlayed")),
                           (t("console.playTime"), game.playSeconds > 0 ? ConsoleTimes.duration(game.playSeconds, lang: lang) : t("console.notPlayed")),
                           (t("console.menu.saves"), game.save.map { t($0.status.key) } ?? t("console.saves.status.off"))])
                }
                if game.status == .ready {
                    ConsoleMenuRow(id: "console.gamePage.controls", scope: scope, symbol: "gamecontroller", title: t("console.gamePage.controls"),
                                   note: t(game.hasControllerSettings ? "console.gamePad.note" : "console.menu.mappingNote"), compact: compact) {
                        game.hasControllerSettings ? driver.openGamePad(game.id) : driver.openMapping()
                    }
                    ConsoleMenuRow(id: "console.gamePage.options", scope: scope, symbol: "slider.horizontal.3", title: t("console.gamePage.options"),
                                   note: t("console.gamePage.optionsNote"), compact: compact) { driver.openOptions(game.id) }
                }
                ConsoleMenuRow(id: "console.gamePage.manage", scope: scope, symbol: "ellipsis.circle", title: t("console.manage"),
                               note: t("console.manage.note"), compact: compact) { driver.openManage(game.id) }
            }
            .frame(maxWidth: 680, alignment: .leading)
            if !compact {
                ConsoleArtwork(image: game.artwork, title: game.title, focus: game.artworkFocus).aspectRatio(1.8, contentMode: .fit)
                    .frame(maxWidth: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .accessibilityHidden(true)
            }
        }
    }

    /// Play, Resume for the paused game, or for a game this Mac cannot play why, and the way to the desktop.
    @ViewBuilder private var primary: some View {
        if paused {
            ConsolePrimaryButton(label: t("console.resume"), id: "console.gamePage.primary", scope: scope) { driver.resume(game.id) }.frame(maxWidth: 360)
        } else if game.status == .ready {
            ConsolePrimaryButton(label: t("console.play"), id: "console.gamePage.primary", scope: scope) { driver.play(game.id) }.frame(maxWidth: 360)
        } else {
            Text(t(game.status.explanationKey ?? "console.ready")).font(.manrope(compact ? 17 : 21)).foregroundStyle(LauncherPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ConsolePrimaryButton(label: t("console.openOnDesktop"), id: "console.gamePage.primary", scope: scope) { driver.openOnDesktop(game.id) }
                .frame(maxWidth: 360)
        }
    }

    /// Read-only facts side by side (one column on a narrow window), quieter than the rows the focus can land on.
    private func facts(_ items: [(String, String)]) -> some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            ForEach(items, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).font(.manrope(compact ? 13 : 15)).foregroundStyle(LauncherPalette.secondaryText).lineLimit(1)
                    Text(value).font(.manrope(compact ? 16 : 19, .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LauncherPalette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Saves

    private var saves: some View {
        VStack(alignment: .leading, spacing: 12) {
            facts([(t("console.gamePage.lastSave"), game.lastSave.map { ConsoleTimes.absolute($0, lang: lang) } ?? t("console.stopped.noSave")),
                   (t("console.menu.saves"), game.save.map { t($0.status.key) } ?? t("console.saves.status.off"))])
            if let detail = game.save?.detail, !detail.isEmpty {
                Text(detail).font(.manrope(compact ? 14 : 16)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            ConsoleMenuRow(id: "console.gamePage.cloudSaves", scope: scope, symbol: "icloud", title: t("console.menu.saves"),
                           note: t("console.menu.savesNote"), compact: compact) { driver.openCloudSaves() }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    // MARK: Build

    private var build: some View {
        VStack(alignment: .leading, spacing: 12) {
            facts([(t("console.gamePage.version"), game.version.isEmpty ? t("console.gamePage.unknown") : game.version),
                   (t("console.gamePage.platforms"), game.platforms.map { t($0.labelKey) }.joined(separator: ", ")),
                   (t("console.gamePage.status"), t(game.status.labelKey))])
            if game.olderTools {
                Text(t("library.olderToolsHelp")).font(.manrope(compact ? 14 : 16)).foregroundStyle(LauncherPalette.building)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
            ConsoleMenuRow(id: "console.gamePage.desktop", scope: scope, symbol: "macwindow", title: t("console.openOnDesktop"),
                           note: t("console.gamePage.desktopNote"), compact: compact) { driver.openOnDesktop(game.id) }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    // MARK: Cheats

    private var cheats: some View {
        VStack(alignment: .leading, spacing: 12) {
            if game.cheats.map({ $0.note == nil || !$0.items.isEmpty }) == true {
                ConsoleCheatsSection(driver: driver, game: game, lang: lang, compact: compact, scope: scope)
            } else {
                Text(game.cheats?.note ?? t("console.gamePage.noCheats")).font(.manrope(compact ? 16 : 19)).foregroundStyle(LauncherPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 12) {
            Text(game.title).font(.manrope(compact ? 19 : 24, .semibold)).foregroundStyle(LauncherPalette.cream).padding(.bottom, 12)
            ConsoleMenuRow(id: "console.manage.desktop", scope: "console.manage", symbol: "macwindow", title: t("console.openOnDesktop"),
                           note: t("console.gamePage.desktopNote"), compact: compact) { driver.openOnDesktop(game.id) }
            if game.status == .ready {
                ConsoleMenuRow(id: "console.manage.saves", scope: "console.manage", symbol: "icloud", title: t("console.menu.saves"),
                               note: t("console.menu.savesNote"), compact: compact) { driver.openCloudSaves() }
            }
            if game.canReset {
                ConsoleMenuRow(id: "console.manage.reset", scope: "console.manage", symbol: "arrow.counterclockwise", title: t("console.reset.title"),
                               note: t("console.reset.note"), compact: compact) { driver.askResetOptions(game.id) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 24 : 40).padding(.bottom, compact ? 24 : 40)
    }
}
