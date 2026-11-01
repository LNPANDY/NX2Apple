import Foundation

/// Counts the launcher's costly work on the main thread: Info.plist reads, Manrope fonts made, game cards built and frame time recordings parsed. LauncherPerformanceTests reads the counts per interaction (a tab
/// switch, Options, Manage, a redraw), so a change that does this work for every game on every redraw fails there. Only debug
/// builds (`swift test`) count. In a release build `count` is empty.
package enum LauncherWork {
    package enum Kind: CaseIterable { case infoPlistRead, font, card, frameTimesParse }

    #if DEBUG
    /// Written on the main thread only, so no lock is needed.
    package private(set) static var counts: [Kind: Int] = [:]
    package static func reset() { counts = [:] }
    #endif

    @inline(__always) package static func count(_ kind: Kind) {
        #if DEBUG
        if Thread.isMainThread { counts[kind, default: 0] += 1 }
        #endif
    }
}
