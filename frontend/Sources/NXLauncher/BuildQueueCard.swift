import SwiftUI
import NXCore
import NXModel

/// The build queue (LNPANDY/NX2Apple#943): follows the current job's progress and result, above the log. Observes the queue store.
/// Rows lead with artwork and metadata, with queue actions trailing.
package struct BuildQueueCard: View {
    @ObservedObject var queue: BuildQueueStore
    let onSelectGames: () -> Void
    let playEnabled: Bool
    let canPlay: (QueueGame) -> Bool
    let onPlay: (QueueGame) -> Void
    let showsHeading: Bool
    let artwork: (QueueEntry) -> NSImage?
    @State private var icons: [UUID: NSImage] = [:]
    @EnvironmentObject var loc: Localizer
    @Environment(\.launcherSectionTitleFont) private var titleFont
    @State private var hoveredRemoval: UUID?
    @State private var keyboardOrdering = false
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var rowDrag: QueueRowDrag?
    @GestureState private var dragging = false
    @State private var dragCancelled = false
    @State private var dragScroll: CGFloat = 0
    @State private var dragPointer: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var focus: PadFocus

    package init(queue: BuildQueueStore, showsHeading: Bool = true, artwork: @escaping (QueueEntry) -> NSImage? = { _ in nil }, onSelectGames: @escaping () -> Void, playEnabled: Bool = true, canPlay: @escaping (QueueGame) -> Bool = { _ in false }, onPlay: @escaping (QueueGame) -> Void = { _ in }) {
        self.playEnabled = playEnabled
        self.canPlay = canPlay; self.onPlay = onPlay
        self.queue = queue
        self.showsHeading = showsHeading
        self.artwork = artwork
        self.onSelectGames = onSelectGames
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeading {
                let controls = HStack(spacing: 10) {
                    if queue.hasFinished {
                        Button(loc.t("queue.clear")) { queue.clearFinished() }.buttonStyle(LauncherSecondaryButtonStyle()).fixedSize()
                            .padTarget("set.build.queue.clear", scope: "main", activate: { queue.clearFinished() })
                    }
                    if queue.paused {
                        Text(loc.t("queue.paused")).font(.manrope(13, .semibold)).foregroundStyle(LauncherPalette.building).fixedSize()
                    }
                    Button(loc.t("queue.select"), action: onSelectGames).buttonStyle(LauncherSecondaryButtonStyle()).fixedSize()
                        .padTarget("set.build.queue.select", scope: "main", activate: onSelectGames)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text(loc.t("queue.title")).font(titleFont).foregroundStyle(LauncherPalette.secondaryText).padding(.leading, 2)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 8)
                        controls
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(loc.t("queue.title")).font(titleFont).foregroundStyle(LauncherPalette.secondaryText).padding(.leading, 2)
                        HStack {
                            Spacer(minLength: 0)
                            controls
                        }
                    }
                }
            }
            CardGroup("") {
                if queue.awaitingResume {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(loc.t("queue.resumeTitle")).font(.manrope(14, .medium))
                        Text(loc.t("queue.resumeNote")).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(loc.t("queue.resume")) { queue.resume() }.buttonStyle(LauncherSecondaryButtonStyle())
                            .padTarget("set.build.queue.restore", scope: "main") { queue.resume() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 13)
                    if !queue.entries.isEmpty { CardDivider() }
                } else if queue.games.isEmpty {
                    Text(loc.t("queue.selectNote"))
                        .font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.vertical, 14)
                }
                ForEach(Array(queue.games.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { CardDivider() }
                    row(entry)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: QueueRowFrames.self, value: [entry.id: geometry.frame(in: .named("queue.rows"))])
                        })
                        .background(rowDrag?.source == entry.id ? LauncherPalette.card : .clear, in: RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(rowDrag?.source == entry.id ? 0.22 : 0), radius: 12, y: 6)
                        .scaleEffect(rowDrag?.source == entry.id && !reduceMotion ? 1.05 : 1)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: rowDrag?.source)
                        .offset(y: rowDrag?.displacement(entry.id) ?? 0)
                        .zIndex(rowDrag?.source == entry.id ? 1 : 0)
                        .animation(reduceMotion || rowDrag?.source == entry.id ? nil : .easeInOut(duration: 0.18), value: rowDrag?.displacement(entry.id))
                }
                if queue.paused {
                    HStack {
                        Spacer()
                        Button(loc.t("queue.resume")) { queue.resume() }.buttonStyle(LauncherSecondaryButtonStyle())
                            .padTarget("set.build.queue.resume", scope: "main") { queue.resume() }
                    }.padding(18)
                }
            }
        }
        .coordinateSpace(name: "queue.rows")
        .onPreferenceChange(QueueRowFrames.self) { rowFrames = $0 }
        .onChange(of: dragging) { if !$0 { rowDrag = nil; dragCancelled = false } }
        .onChange(of: queue.entries) { _ in cancelDrag() }
        .onChange(of: focus.visible) { if $0 { cancelDrag() } }
        .onDisappear { rowDrag = nil }
        .background(QueuePointerInput(cancel: cancelDrag, autoscrolling: rowDrag != nil, scrolled: { delta in
            dragScroll += delta
            rowDrag?.translation = dragPointer + dragScroll
        }) { keyboard in
            if keyboard { keyboardOrdering = true }
            else {
                guard keyboardOrdering || focus.visible else { return }
                keyboardOrdering = false
                if let id = focus.focused {
                    for direction in ["up", "down"] {
                        let prefix = "set.build.queue." + direction + "."
                        if id.hasPrefix(prefix) { focus.focused = "set.build.queue.remove." + id.dropFirst(prefix.count) }
                    }
                }
                if focus.visible { focus.hide() }
            }
        })
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: queue.games.map(\.id))
        .task(id: queue.entries.map(\.id)) {
            icons = Dictionary(uniqueKeysWithValues: queue.games.compactMap { game in artwork(game.entries[0]).map { (game.id, $0) } })
        }

    }

    private func retry(_ game: QueueGame) {
        queue.retry(game.id)
        if focus.focused == "set.build.queue.retry." + game.id.uuidString {
            focus.focused = "set.build.queue.remove." + game.id.uuidString
        }
    }

    private func row(_ game: QueueGame) -> some View {
        let entry = game.entries[0]
        let staged = game.waiting && !game.running && !game.retryable && !queue.active && !queue.paused && !queue.awaitingResume
        return HStack(spacing: 16) {
            Group {
                if let icon = icons[entry.id] { Image(nsImage: icon).resizable().scaledToFill() }
                else {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 22))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(LauncherPalette.ink(0.06))
                }
            }
            .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
            .saturation(staged || Self.outcome(game) == .success ? 1 : 0)
            .overlay(alignment: .bottomTrailing) {
                if let outcome = Self.outcome(game) { ArtworkOutcomeBadge(outcome, artworkSize: 48) }
            }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                BuildPlatformChip(targets: game.entries.map(\.target))
                Text(entry.name).font(.manrope(14, .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if !game.both && !game.retryable && entry.status != .queued && (entry.status != .done || entry.packagePending != nil) { Text(status(entry)).font(.manrope(12.5)).foregroundStyle(color(entry.status)) }
                }
                if game.both && Self.outcome(game) != .success {
                    HStack(spacing: 12) {
                        ForEach(game.entries.filter { $0.status != .queued && $0.status != .failed && $0.status != .skipped }) { job in
                            if job.status == .done && job.packagePending == nil {
                                Label(loc.t(job.target == BuildTarget.mac ? "library.section.mac" : "build.ios"), systemImage: "checkmark")
                                    .font(.manrope(12.5)).foregroundStyle(LauncherPalette.ready)
                            } else {
                                Text(loc.t(job.target == BuildTarget.mac ? "library.section.mac" : "build.ios") + " · " + status(job))
                                    .font(.manrope(12.5)).foregroundStyle(color(job.status))
                            }
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if game.waiting && !game.running && (queue.active || queue.entries.contains { $0.status != .queued }) {
                Image(systemName: "clock.fill").font(.system(size: 20)).foregroundStyle(LauncherPalette.secondaryText.opacity(0.45))
                    .accessibilityLabel(loc.t("queue.status.queued"))
            }
            if canPlay(game) {
                Button { onPlay(game) } label: { Label(loc.t("library.play"), systemImage: "play.fill") }
                    .buttonStyle(LauncherSecondaryButtonStyle()).disabled(!playEnabled)
                    .padTarget("set.build.queue.play." + game.id.uuidString, scope: "main", enabled: playEnabled, activate: { if playEnabled { onPlay(game) } })
            }
            if game.retryable {
                Button(loc.t("onboarding.retry")) { retry(game) }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .padTarget("set.build.queue.retry." + game.id.uuidString, scope: "main") { retry(game) }
            }
            if !game.running && !game.waiting {
                queueButton("xmark", title: String(format: loc.t("queue.removeNamed"), entry.name), id: "remove", entry: entry) { queue.remove(game.id) }
            }
            if game.waiting && !game.running {
                HStack(spacing: 8) {
                    if focus.visible || keyboardOrdering {
                    queueButton("arrow.up", title: String(format: loc.t("queue.moveUpNamed"), entry.name),
                                id: "up", entry: entry, enabled: queue.canMoveUp(entry.id)) { queue.moveUp(entry.id) }
                    queueButton("arrow.down", title: String(format: loc.t("queue.moveDownNamed"), entry.name),
                                id: "down", entry: entry, enabled: queue.canMoveDown(entry.id)) { queue.moveDown(entry.id) }
                    }
                    queueButton("xmark", title: String(format: loc.t("queue.removeNamed"), entry.name),
                                id: "remove", entry: entry) { queue.remove(entry.id) }
                    if !focus.visible && !keyboardOrdering { dragHandle(game) }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityValue(game.entries.map { loc.t($0.target == BuildTarget.mac ? "library.section.mac" : "build.ios") + ": " + status($0) + ($0.reason.map { ", " + $0 } ?? "") }.joined(separator: ", "))
        .help(game.entries.compactMap(\.reason).joined(separator: "\n"))
    }

    private func cancelDrag() {
        if rowDrag != nil { dragCancelled = true; rowDrag = nil }
    }

    private func dragHandle(_ game: QueueGame) -> some View {
        let movable = queue.canMoveUp(game.id) || queue.canMoveDown(game.id)
        return Image(systemName: "line.3.horizontal").font(.system(size: 20, weight: .medium))
            .foregroundStyle(LauncherPalette.secondaryText)
            .frame(width: 36, height: 36).contentShape(Rectangle())
            .opacity(movable ? 1 : 0.35).allowsHitTesting(movable)
            .background(LauncherHoverRegion(enabled: movable, cursor: .openHand) { _ in })
            .help(String(format: loc.t("queue.dragNamed"), game.name))
            .accessibilityLabel(String(format: loc.t("queue.dragNamed"), game.name))
            .accessibilityAction(named: Text(String(format: loc.t("queue.moveUpNamed"), game.name))) { queue.moveUp(game.id) }
            .accessibilityAction(named: Text(String(format: loc.t("queue.moveDownNamed"), game.name))) { queue.moveDown(game.id) }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .updating($dragging) { _, active, _ in active = true }
                .onChanged { value in
                    guard movable && !dragCancelled else { return }
                    if rowDrag == nil {
                        dragScroll = 0
                        rowDrag = QueueRowDrag(source: game.id, ids: queue.games.map(\.id),
                            movable: Set(queue.games.filter { $0.waiting && !$0.running }.map(\.id)), frames: rowFrames)
                    }
                    dragPointer = value.translation.height
                    rowDrag?.translation = dragPointer + dragScroll
                }
                .onEnded { _ in
                    guard let drag = rowDrag, let index = drag.order.firstIndex(of: drag.source) else { rowDrag = nil; return }
                    guard drag.order != drag.ids else { rowDrag = nil; return }
                    let waiting = drag.order.filter { drag.movable.contains($0) }
                    if let next = drag.order.dropFirst(index + 1).first(where: { drag.movable.contains($0) }) {
                        queue.move(drag.source, relativeTo: next, after: false)
                    } else if let previous = waiting.last(where: { $0 != drag.source }) {
                        queue.move(drag.source, relativeTo: previous, after: true)
                    }
                    rowDrag = nil
                })
    }

    static func outcome(_ game: QueueGame) -> ArtworkOutcomeBadge.Outcome? {
        if game.entries.contains(where: { $0.status == .failed || $0.status == .stopped }) { return .failure }
        if game.entries.contains(where: { $0.status == .skipped }) { return .warning }
        if game.entries.allSatisfy({ $0.status == .done && $0.packagePending == nil }) { return .success }
        return nil
    }

    private func queueButton(_ symbol: String, title: String, id: String, entry: QueueEntry,
                             enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: LauncherControl.height, height: LauncherControl.height)
                .foregroundStyle(id == "remove" ? LauncherPalette.danger : LauncherPalette.text)
                .background(id == "remove" ? LauncherPalette.danger.opacity(hoveredRemoval == entry.id ? 0.20 : 0.08) : LauncherPalette.secondaryFill, in: Circle())
                .overlay(Circle().strokeBorder(id == "remove" ? LauncherPalette.danger.opacity(hoveredRemoval == entry.id ? 0.65 : 0.25) : LauncherPalette.secondaryBorder)).contentShape(Circle())
        }
        .buttonStyle(.plain).launcherHover().disabled(!enabled)
        .background(LauncherHoverRegion(enabled: enabled && id == "remove") { over in
            if id == "remove" { hoveredRemoval = over ? entry.id : nil }
        })
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(title).help(title)
        .padTarget("set.build.queue." + id + "." + entry.id.uuidString, scope: "main", enabled: enabled, activate: action)
    }

    private func status(_ entry: QueueEntry) -> String {
        if entry.packagePending != nil { return loc.t(entry.packagePending == true ? "queue.packaging" : "queue.awaitingPackage") }
        return loc.t("queue.status." + entry.status.rawValue)
    }

    private func color(_ status: QueueEntry.Status) -> Color {
        switch status {
        case .done: return LauncherPalette.ready
        case .running: return LauncherPalette.building
        case .failed: return .red
        case .queued, .skipped, .stopped: return .secondary
        }
    }
}
