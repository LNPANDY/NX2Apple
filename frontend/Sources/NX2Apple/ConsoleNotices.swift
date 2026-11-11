import Foundation

/// The console's one queue of passing messages (LNPANDY/NX2Apple#1004): a controller arrived, Identify, a failed start. They are
/// information only. A notice never takes the focus, never borrows a controller button for itself (an action offered by a banner that
/// goes away by itself would move under the player's thumb), and never carries a time estimate.
///
/// One notice shows at a time and the others wait their turn. A notice of a kind that is already showing or waiting replaces it
/// (two controllers that connect one after the other read as the latest one), so a burst does not build a line. While a game
/// starts nothing shows and nothing waits.
struct ConsoleNoticeQueue {
    struct Notice: Equatable, Identifiable {
        let id = UUID()
        var kind: String
        var message: String
        var glyph: ConsoleGlyphs.Glyph?
    }

    static let duration: TimeInterval = 3

    private(set) var current: Notice?
    /// When the notice on screen goes.
    private(set) var until: Date?
    private(set) var waiting: [Notice] = []

    mutating func post(kind: String, message: String, glyph: ConsoleGlyphs.Glyph? = nil, now: Date, suppressed: Bool) {
        guard !suppressed else { clear(); return }
        let notice = Notice(kind: kind, message: message, glyph: glyph)
        if current?.kind == kind {
            current = notice
            until = now.addingTimeInterval(Self.duration)
        } else if let index = waiting.firstIndex(where: { $0.kind == kind }) {
            waiting[index] = notice
        } else {
            waiting.append(notice)
        }
        advance(now: now, suppressed: false)
    }

    /// Time passed, or a game began to start: the notice whose time is up goes and the next one comes.
    mutating func advance(now: Date, suppressed: Bool) {
        if suppressed { clear(); return }
        if let until, now.timeIntervalSinceReferenceDate >= until.timeIntervalSinceReferenceDate { current = nil; self.until = nil }
        if current == nil, !waiting.isEmpty {
            current = waiting.removeFirst()
            until = now.addingTimeInterval(Self.duration)
        }
    }

    mutating func clear() { current = nil; until = nil; waiting = [] }
}
