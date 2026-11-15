import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Wiring and buttons for the desktop Activity Log sheet (#1161), kept in its own extension so `LauncherView.swift` stays compact.
extension LauncherView {
    func openActivityLog() {
        activityLogOpen = true
    }

    func activityLogButton(compact: Bool) -> some View {
        Button(action: openActivityLog) {
            if compact {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 13, weight: .semibold)).frame(height: LauncherControl.height - 18)
            } else {
                Label(loc.t("activity.button"), systemImage: "chart.bar.xaxis").frame(height: LauncherControl.height - 18)
            }
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
        .help(loc.t("activity.title")).accessibilityLabel(loc.t("activity.title"))
        .padTarget("library.activity", scope: "main", radius: 9, activate: openActivityLog)
    }

    func heroMetaText(for game: LibraryGame) -> String? {
        let versionPart = (game.playVersion ?? game.unbuiltVersion).map { String(format: loc.t("console.version"), $0) }
        let seconds = playSessions[game.titleID]?.seconds ?? 0
        let playPart = seconds >= 60 ? ConsoleTimes.duration(seconds, lang: loc.lang) : nil
        let parts = [versionPart, playPart].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension View {
    func activityLogSheet(
        isPresented: Binding<Bool>,
        store: PlaySessionStore,
        library: GameLibrary,
        artwork: [UUID: NSImage],
        loc: Localizer,
        pad: PadFocus,
        scope: @escaping () -> String,
        showInLibrary: @escaping (UUID) -> Void,
        now: Date = Date()
    ) -> some View {
        sheet(isPresented: isPresented) {
            ActivityLogSheet(
                store: store,
                owned: { id in library.games.first { $0.titleID.uppercased() == id } },
                cover: { game in artwork[game.id] },
                showInLibrary: showInLibrary,
                now: now
            )
            .environmentObject(loc)
            .environmentObject(pad)
        }
        .onChange(of: isPresented.wrappedValue) { open in
            pad.scope = open ? "activity" : scope()
        }
    }
}
