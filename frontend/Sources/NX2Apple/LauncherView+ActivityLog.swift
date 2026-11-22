import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Wiring and buttons for the desktop Activity Log sheet (#1161), kept in its own extension so `LauncherView.swift` stays compact.
extension LauncherView {
    func openActivityLog() {
        activityLogOpen = true
    }

    func activityLogButton() -> some View {
        Button(loc.t("activity.button"), action: openActivityLog)
            .buttonStyle(LauncherSecondaryButtonStyle())
            .help(loc.t("activity.title"))
            .padTarget("library.activity", scope: "main", activate: openActivityLog)
    }

    /// The game's total play time for the hero's metadata tags, nil below a minute.
    func heroPlayTime(for game: LibraryGame) -> String? {
        let seconds = playSessions[game.titleID]?.seconds ?? 0
        return seconds >= 60 ? ConsoleTimes.duration(seconds, lang: loc.lang) : nil
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
