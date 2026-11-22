import Foundation
import ShellUI

extension ShellHostModel {
    var activeHostLocale: Locale {
        if let code = HostStrings.captureBundle?.bundleURL.deletingPathExtension().lastPathComponent, !code.isEmpty {
            return Locale(identifier: code)
        }
        return ShellFormat.activeLocale
    }

    func effectiveLastPlayed(_ id: String) -> Date? {
        let defaultsDate = LastPlayedStore(defaults: config.defaults(id)).date
        let historyDate = playHistory[id]?.lastPlayed
        switch (defaultsDate, historyDate) {
        case let (a?, b?):
            return a.timeIntervalSinceReferenceDate >= b.timeIntervalSinceReferenceDate ? a : b
        case let (a?, nil):
            return a
        case let (nil, b?):
            return b
        case (nil, nil):
            return nil
        }
    }

    func rebuildActivityLog() {
        var calendar = Calendar.current
        let locale = activeHostLocale
        calendar.locale = locale
        activityLog = playHistory.makeSnapshot(
            installedDetails: details,
            now: config.now(),
            calendar: calendar,
            locale: locale
        )
    }

    func recordSessionDidStart(for game: LaunchableGame) {
        playHistory.sessionDidStart(titleID: game.titleID, title: game.name, at: config.now())
        refreshHostGame(game.titleID)
    }

    /// Flushes accrued foreground play time and pauses accumulation when the scene resigns active.
    public func pauseActiveSession() {
        playHistory.sessionWillPause(at: config.now())
    }

    /// Checkpoints any active foreground play slice when entering background.
    public func checkpointActiveSession() {
        playHistory.checkpoint(at: config.now())
        playHistory.sessionWillPause(at: config.now())
    }

    /// Resumes foreground accumulation when the active game scene returns to the foreground.
    public func resumeActiveSession() {
        playHistory.sessionDidResume(at: config.now())
    }

    /// Closes the active gameplay session when returning from a game to the shell library.
    public func endActiveSession() {
        playHistory.sessionDidEnd(at: config.now())
        refreshAll()
    }
}
