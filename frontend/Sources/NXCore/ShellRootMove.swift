import Foundation

// LNPANDY/NX2Apple#427, part 2: the player moves the shell cache (frameworks, shell.json, the banner cache, the shell project and
// its derived data) to another folder, for example an external drive, and back to the default place. The cache goes into a folder
// `NX2Apple-shell` inside the folder the player picked, so the launcher never owns, fills or removes a folder the player chose as a
// whole. The rules of the migration hold here too: a plain folder (no link), a readable shell.json, a free destination.
//
// The file work is CacheFolderMove's, which the nxkit work folder and the build seeds use too (BuildCacheRoots). What is the
// shell's own are its rules: the folder holds a readable shell.json (or nothing yet), and shell.json is rewritten in the copy for
// the new place before the copy takes the destination's name.

package enum ShellRootMove {
    /// Set in the defaults when the saved root is one the player chose, so the migration at launch never moves it back.
    package static let pickedKey = "shellRootPicked"

    /// The cache folder inside the folder the player picked.
    package static func destination(inside folder: String) -> String {
        (folder as NSString).standardizingPath + "/" + ShellRootMigration.legacyName
    }

    package typealias Problem = CacheFolderMove.Problem
    package typealias Plan = CacheFolderMove.Plan
    package typealias Phase = CacheFolderMove.Phase
    package typealias Failure = CacheFolderMove.Failure
    package typealias Outcome = CacheFolderMove.Outcome

    /// A shell cache holds a readable shell.json, or nothing at all yet (a `.DS_Store` aside). The copy's shell.json is rewritten
    /// to name the new place.
    package static let rules = CacheFolderMove.Rules(name: ShellRootMigration.legacyName, check: { folder, entries, fm in
        if entries.contains("shell.json") {
            guard let data = fm.contents(atPath: ShellLibrary.stateFile(root: folder)),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return .unreadableLedger }
        } else if !entries.filter({ $0 != ".DS_Store" }).isEmpty {
            return .unknownContent
        }
        return nil
    }, fix: { copy, from, to, fm in
        ShellRootMigration.rewritePaths(root: copy, from: from, to: to, fm: fm)
    })

    package static func plan(from source: String, to destination: String, fm: FileManager = .default) -> Plan {
        CacheFolderMove.plan([CacheFolderMove.Move(source, to: destination, rules: rules)], fm: fm)
    }

    /// Moves the cache as the plan says. `progress` gets the phase and bytes done of the total, `stop` is asked between chunks.
    /// `afterCopy` runs on the copy before it is checked (tests use it to damage the copy). The caller saves the new root.
    package static func run(_ plan: Plan, fm: FileManager = .default, chunk: Int = 8 << 20,
                            progress: (Phase, Int64, Int64) -> Void = { _, _, _ in }, stop: () -> Bool = { false },
                            afterCopy: (String) -> Void = { _ in }) -> Outcome {
        CacheFolderMove.run(plan, fm: fm, chunk: chunk, progress: progress, stop: stop, afterCopy: afterCopy)
    }
}
