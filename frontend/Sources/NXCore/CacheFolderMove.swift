import Foundation

// The move of a cache folder to another place, for example an external drive, and back (#427). It started as the shell cache's
// move (ShellRootMove) and now also moves the nxkit work folder and the build seeds (BuildCacheRoots). The cache goes into a
// folder of its own inside the folder the player picked, so the launcher never owns, fills or removes a folder the player chose.
//
// A cache is one or more parts: a folder each, with its own place to go. The shell cache and the nxkit work folder are one
// part, the build seeds are two (`build-seeds` and its sibling `refresh-builds`), which move together or not at all. What a
// part must hold and what is fixed in its copy are its `Rules` (shell.json for the shell cache, nothing for the others).
//
// On the same volume the move is a rename of each part. On another volume every part is copied into a hidden folder beside its
// destination, every file is compared with its original, the rules fix the copy, and only then the copies take their
// destinations' names and the old files are removed. A stop or an error before that point removes the partial copies and leaves
// the old folders as they were, so they stay valid and keep being used. Nothing of an old folder is removed before its copy is
// verified.

package enum CacheFolderMove {
    /// Why the move cannot start.
    package enum Problem: Equatable {
        /// The cache is already there.
        case same
        /// The destination lies inside the cache.
        case insideCache
        /// The cache is a link, a file or an alias, not the plain folder the launcher made.
        case notPlain
        /// The cache folder holds files the launcher did not make (the rules say which).
        case unknownContent
        /// The cache's index file (shell.json) is there but cannot be read.
        case unreadableLedger
        /// Something is already at the destination.
        case destinationTaken
        case readOnly
        case noSpace(needed: Int64, free: Int64)
    }

    /// What a part must hold to be moved, and what is fixed in its copy before it takes the new place.
    package struct Rules: Equatable {
        /// The part's name in the hidden copy (`.<name>-moving-<id>`). Two rules are the same when their names are.
        package var name: String
        /// A problem with the content of the plain folder `folder` (its top-level `entries`), nil when it may move.
        package var check: (_ folder: String, _ entries: [String], _ fm: FileManager) -> Problem?
        /// Fixes the copy at `copy` for its new place (`from` → `to`). false: it could not, and the move fails.
        package var fix: (_ copy: String, _ from: String, _ to: String, _ fm: FileManager) -> Bool
        /// The folder above the part is the launcher's when it has this name (`NX2Apple-build-seeds`): it goes once the part has
        /// moved away and it is empty. nil: the folder above is never removed.
        package var ownParent: String?

        package init(name: String, ownParent: String? = nil,
                     check: @escaping (_ folder: String, _ entries: [String], _ fm: FileManager) -> Problem? = { _, _, _ in nil },
                     fix: @escaping (_ copy: String, _ from: String, _ to: String, _ fm: FileManager) -> Bool = { _, _, _, _ in true }) {
            self.name = name; self.ownParent = ownParent; self.check = check; self.fix = fix
        }

        package static func == (a: Rules, b: Rules) -> Bool { a.name == b.name && a.ownParent == b.ownParent }

        /// A cache that only the launcher and its tools write and that has no index file: the nxkit work folder (one folder
        /// per game) and the build seeds (one folder per title ID). Every visible entry is a plain folder. A loose file or a
        /// link at the top is not the launcher's, so the folder is not moved. Hidden entries (`.DS_Store`, a tool's
        /// `.<id>.staging.<pid>`) are allowed and move with it.
        package static func folders(_ name: String, ownParent: String? = nil) -> Rules {
            Rules(name: name, ownParent: ownParent, check: { folder, entries, fm in
                for entry in entries where !entry.hasPrefix(".") {
                    let path = folder + "/" + entry
                    guard (try? fm.destinationOfSymbolicLink(atPath: path)) == nil,
                          ((try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType) == .typeDirectory else { return .unknownContent }
                }
                return nil
            })
        }

        /// A plain folder the launcher fills with whatever a build leaves (`refresh-builds`: work folders, apps, IPAs): any content.
        package static func anything(_ name: String, ownParent: String? = nil) -> Rules { Rules(name: name, ownParent: ownParent) }
    }

    /// One folder of the cache and where it goes.
    package struct Part: Equatable {
        package var source: String
        package var destination: String
        package var rules: Rules
        /// The folder is there. Without it only the saved place changes.
        package var exists: Bool
        /// The size of its files, 0 when it is not there.
        package var bytes: Int64

        package init(source: String, destination: String, rules: Rules, exists: Bool, bytes: Int64) {
            self.source = source; self.destination = destination; self.rules = rules; self.exists = exists; self.bytes = bytes
        }
    }

    /// What the confirmation shows, and what `run` does.
    package struct Plan: Equatable {
        /// The first part's folder and its destination: what the confirmation names and the setting saves.
        package var source: String
        package var destination: String
        /// The size of all parts' files, 0 when there is no cache yet.
        package var bytes: Int64
        /// Free space on the destination's volume, nil when it cannot be read.
        package var free: Int64?
        /// Every destination is on its part's volume: the move is a rename.
        package var sameVolume: Bool
        /// There is a cache to move. Without one only the saved place changes.
        package var sourceExists: Bool
        package var problem: Problem?
        package var parts: [Part]

        /// A plan of one part, as the confirmation shows it (tests and the design gallery build these). `plan` makes the real ones.
        package init(source: String, destination: String, bytes: Int64, free: Int64?, sameVolume: Bool, sourceExists: Bool, problem: Problem?,
                     rules: Rules = .anything("cache")) {
            self.init(source: source, destination: destination, bytes: bytes, free: free, sameVolume: sameVolume, sourceExists: sourceExists,
                      problem: problem, parts: [Part(source: source, destination: destination, rules: rules, exists: sourceExists, bytes: bytes)])
        }

        package init(source: String, destination: String, bytes: Int64, free: Int64?, sameVolume: Bool, sourceExists: Bool, problem: Problem?,
                     parts: [Part]) {
            self.source = source; self.destination = destination; self.bytes = bytes; self.free = free
            self.sameVolume = sameVolume; self.sourceExists = sourceExists; self.problem = problem; self.parts = parts
        }
    }

    /// A part to plan: its folder, where it goes and its rules.
    package struct Move {
        package var source: String
        package var destination: String
        package var rules: Rules
        package init(_ source: String, to destination: String, rules: Rules) { self.source = source; self.destination = destination; self.rules = rules }
    }

    /// The plan of a move. The first part names the cache. Every part is checked, the first problem found stops the move.
    package static func plan(_ moves: [Move], fm: FileManager = .default) -> Plan {
        precondition(!moves.isEmpty, "a cache has at least one part")
        let moves = moves.map { Move(($0.source as NSString).standardizingPath, to: ($0.destination as NSString).standardizingPath, rules: $0.rules) }
        let first = moves[0]
        let volume = DriveCopy.volume(at: first.destination, fm: fm)
        var parts = moves.map { Part(source: $0.source, destination: $0.destination, rules: $0.rules, exists: false, bytes: 0) }
        var plan = Plan(source: first.source, destination: first.destination, bytes: 0, free: volume?.freeBytes,
                        sameVolume: moves.allSatisfy { sameVolume($0.source, $0.destination, fm: fm) }, sourceExists: false, problem: nil, parts: parts)
        if first.source == first.destination { plan.problem = .same; return plan }
        for move in moves where moves.contains(where: { move.destination == $0.source || move.destination.hasPrefix($0.source + "/") }) {
            plan.problem = .insideCache; return plan
        }
        for (i, move) in moves.enumerated() {
            let isLink = (try? fm.destinationOfSymbolicLink(atPath: move.source)) != nil
            parts[i].exists = isLink || fm.fileExists(atPath: move.source)
            guard parts[i].exists else { continue }
            guard !isLink, ((try? fm.attributesOfItem(atPath: move.source))?[.type] as? FileAttributeType) == .typeDirectory,
                  let entries = try? fm.contentsOfDirectory(atPath: move.source) else {
                plan.parts = parts; plan.sourceExists = true; plan.problem = .notPlain; return plan
            }
            if let problem = move.rules.check(move.source, entries, fm) {
                plan.parts = parts; plan.sourceExists = true; plan.problem = problem; return plan
            }
            parts[i].bytes = treeSize(move.source, fm: fm)
        }
        plan.parts = parts
        plan.sourceExists = parts.contains(where: \.exists)
        plan.bytes = parts.reduce(0) { $0 + $1.bytes }
        if moves.contains(where: { !isFree($0.destination, fm: fm) }) { plan.problem = .destinationTaken; return plan }
        if volume?.readOnly == true { plan.problem = .readOnly; return plan }
        if plan.sourceExists, !plan.sameVolume, let free = plan.free, plan.bytes > free {
            plan.problem = .noSpace(needed: plan.bytes, free: free)
        }
        return plan
    }

    package enum Phase: Equatable { case copying, checking }

    /// Why a move failed. The old folders stay and keep being used in every case.
    package enum Failure: Equatable {
        /// A file system call failed: the system's own text.
        case io(String)
        /// A file of the copy is not the same as its original: its path inside the cache.
        case mismatch(String)
        /// The rules could not fix the copy for the new place (shell.json for the shell cache).
        case ledger
    }

    package enum Outcome: Equatable {
        case moved
        /// The cache is in its new place, but these files of the old folders could not be removed.
        case movedOldStays([String])
        /// The player stopped it. The old folders are as they were.
        case stopped
        case failed(Failure)
    }

    /// Moves the cache as the plan says. `progress` gets the phase and bytes done of the total, `stop` is asked between chunks.
    /// `afterCopy` runs on each part's copy before it is checked (tests use it to damage the copy). The caller saves the new root.
    package static func run(_ plan: Plan, fm: FileManager = .default, chunk: Int = 8 << 20,
                            progress: (Phase, Int64, Int64) -> Void = { _, _, _ in }, stop: () -> Bool = { false },
                            afterCopy: (String) -> Void = { _ in }) -> Outcome {
        guard plan.problem == nil else { return .failed(.io("the move cannot start")) }
        do {
            for part in plan.parts { try fm.createDirectory(atPath: (part.destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true) }
        } catch { return .failed(.io(error.localizedDescription)) }
        let parts = plan.parts.filter(\.exists)
        guard !parts.isEmpty else { return .moved }
        guard parts.allSatisfy({ isFree($0.destination, fm: fm) }) else { return .failed(.io("the new place is taken")) }
        // A mismatch names the path inside the cache: with several parts, inside the part's folder
        func relative(_ part: Part, _ name: String) -> String { plan.parts.count > 1 ? (part.source as NSString).lastPathComponent + "/" + name : name }

        if plan.sameVolume {
            if stop() { return .stopped }
            var renamed: [Part] = []
            // A part that cannot move or whose fix fails puts every moved part back, rather than leave a split state
            func undo(_ outcome: Outcome) -> Outcome {
                for part in renamed.reversed() { try? fm.moveItem(atPath: part.destination, toPath: part.source) }
                return outcome
            }
            for part in parts {
                do {
                    try removeEmptyFolder(part.destination, fm: fm)
                    try fm.moveItem(atPath: part.source, toPath: part.destination)
                } catch { return undo(.failed(.io(error.localizedDescription))) }
                renamed.append(part)
                guard part.rules.fix(part.destination, part.source, part.destination, fm) else { return undo(.failed(.ledger)) }
            }
            progress(.copying, plan.bytes, plan.bytes)
            removeOwnParents(parts, fm: fm)
            return .moved
        }

        // Another volume: a hidden copy beside each destination, which is ours alone and may be removed on any failure
        var stagings: [String] = []
        func abandon(_ outcome: Outcome) -> Outcome { for staging in stagings { try? fm.removeItem(atPath: staging) }; return outcome }
        var entries: [[String]] = []
        do {
            for part in parts {
                entries.append(try fm.contentsOfDirectory(atPath: part.source).sorted())
                let staging = (part.destination as NSString).deletingLastPathComponent + "/.\(part.rules.name)-moving-\(UUID().uuidString)"
                try fm.createDirectory(atPath: staging, withIntermediateDirectories: false)
                stagings.append(staging)
            }
        } catch { return abandon(.failed(.io(error.localizedDescription))) }
        var done: Int64 = 0
        do {
            for (i, part) in parts.enumerated() {
                for name in entries[i] {
                    guard try copyItem(part.source + "/" + name, to: stagings[i] + "/" + name, fm: fm, chunk: chunk, done: &done,
                                       progress: { progress(.copying, $0, plan.bytes) }, stop: stop) else { return abandon(.stopped) }
                }
            }
        } catch { return abandon(.failed(.io(error.localizedDescription))) }
        stagings.forEach(afterCopy)
        var checked: Int64 = 0
        for (i, part) in parts.enumerated() {
            for name in entries[i] {
                switch compare(part.source + "/" + name, stagings[i] + "/" + name, relative: relative(part, name), fm: fm, chunk: chunk,
                               done: &checked, progress: { progress(.checking, $0, plan.bytes) }, stop: stop) {
                case .same: continue
                case .stopped: return abandon(.stopped)
                case .different(let path): return abandon(.failed(.mismatch(path)))
                }
            }
        }
        for (i, part) in parts.enumerated() where !part.rules.fix(stagings[i], part.source, part.destination, fm) { return abandon(.failed(.ledger)) }
        var placed: [Int] = []
        for i in parts.indices {
            do {
                try removeEmptyFolder(parts[i].destination, fm: fm)
                try fm.moveItem(atPath: stagings[i], toPath: parts[i].destination)
                placed.append(i)
            } catch {
                // the copies that took their place go back to being hidden copies, which abandon removes
                for j in placed { try? fm.moveItem(atPath: parts[j].destination, toPath: stagings[j]) }
                return abandon(.failed(.io(error.localizedDescription)))
            }
        }

        // The copies are checked and in place. Only now the old files go: the entries the copies hold, then the folders if empty.
        var left: [String] = []
        for (i, part) in parts.enumerated() {
            var partLeft: [String] = []
            for name in entries[i] where name != ".DS_Store" {
                do { try fm.removeItem(atPath: part.source + "/" + name) } catch { partLeft.append(part.source + "/" + name) }
            }
            if partLeft.isEmpty { try? removeEmptyFolder(part.source, fm: fm) }
            left += partLeft
        }
        if left.isEmpty { removeOwnParents(parts, fm: fm) }
        return left.isEmpty ? .moved : .movedOldStays(left)
    }

    // MARK: Pieces

    /// Nothing is at `path`, or only an empty folder (a `.DS_Store` aside).
    static func isFree(_ path: String, fm: FileManager) -> Bool {
        if (try? fm.destinationOfSymbolicLink(atPath: path)) != nil { return false }
        guard fm.fileExists(atPath: path) else { return true }
        guard ((try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType) == .typeDirectory,
              let entries = try? fm.contentsOfDirectory(atPath: path) else { return false }
        return entries.allSatisfy { $0 == ".DS_Store" }
    }

    private static func removeEmptyFolder(_ path: String, fm: FileManager) throws {
        guard fm.fileExists(atPath: path), isFree(path, fm: fm) else { return }
        try fm.removeItem(atPath: path)
    }

    /// The launcher's own folder above a part that moved away goes when nothing is left in it.
    private static func removeOwnParents(_ parts: [Part], fm: FileManager) {
        for part in parts {
            let parent = (part.source as NSString).deletingLastPathComponent
            if let own = part.rules.ownParent, (parent as NSString).lastPathComponent == own { try? removeEmptyFolder(parent, fm: fm) }
        }
    }

    /// The bytes of the regular files under `path`, links not followed.
    static func treeSize(_ path: String, fm: FileManager) -> Int64 {
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// The volume of `a` and of the nearest folder that exists above `b`.
    static func sameVolume(_ a: String, _ b: String, fm: FileManager) -> Bool {
        func existing(_ path: String) -> String {
            var probe = path
            while !fm.fileExists(atPath: probe), probe != "/", !probe.isEmpty { probe = (probe as NSString).deletingLastPathComponent }
            return probe
        }
        let key = URLResourceKey.volumeIdentifierKey
        guard let x = try? URL(fileURLWithPath: existing(a)).resourceValues(forKeys: [key]).volumeIdentifier,
              let y = try? URL(fileURLWithPath: existing(b)).resourceValues(forKeys: [key]).volumeIdentifier else { return false }
        return x.isEqual(y)
    }

    /// Copies a file, a folder (with what it holds) or a link, links as links. false: stopped.
    private static func copyItem(_ from: String, to: String, fm: FileManager, chunk: Int, done: inout Int64,
                                 progress: (Int64) -> Void, stop: () -> Bool) throws -> Bool {
        if stop() { return false }
        let attributes = try fm.attributesOfItem(atPath: from)
        let permissions = attributes[.posixPermissions]
        switch attributes[.type] as? FileAttributeType {
        case .typeSymbolicLink?:
            // setting permissions would follow the link, so a link keeps the default ones
            try fm.createSymbolicLink(atPath: to, withDestinationPath: fm.destinationOfSymbolicLink(atPath: from))
            return true
        case .typeDirectory?:
            try fm.createDirectory(atPath: to, withIntermediateDirectories: false)
            for name in try fm.contentsOfDirectory(atPath: from).sorted() {
                guard try copyItem(from + "/" + name, to: to + "/" + name, fm: fm, chunk: chunk, done: &done, progress: progress, stop: stop) else { return false }
            }
        case .typeRegular?:
            guard fm.createFile(atPath: to, contents: nil) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: to]) }
            let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: from))
            let output = try FileHandle(forWritingTo: URL(fileURLWithPath: to))
            defer { try? input.close(); try? output.close() }
            while true {
                if stop() { return false }
                guard let data = try input.read(upToCount: chunk), !data.isEmpty else { break }
                try output.write(contentsOf: data)
                done += Int64(data.count)
                progress(done)
            }
            try output.synchronize()
        default:
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSFilePathErrorKey: from])   // a socket or a device: not ours
        }
        if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: to) }
        return true
    }

    private enum Comparison { case same, stopped, different(String) }

    /// The copy holds the same entries as the original: the same kinds, the same link targets and every file byte for byte.
    private static func compare(_ a: String, _ b: String, relative: String, fm: FileManager, chunk: Int, done: inout Int64,
                                progress: (Int64) -> Void, stop: () -> Bool) -> Comparison {
        if stop() { return .stopped }
        guard let x = try? fm.attributesOfItem(atPath: a), let y = try? fm.attributesOfItem(atPath: b),
              let kind = x[.type] as? FileAttributeType, kind == y[.type] as? FileAttributeType else { return .different(relative) }
        switch kind {
        case .typeSymbolicLink:
            guard let p = try? fm.destinationOfSymbolicLink(atPath: a), p == (try? fm.destinationOfSymbolicLink(atPath: b)) else { return .different(relative) }
        case .typeDirectory:
            guard let left = try? fm.contentsOfDirectory(atPath: a).sorted(), let right = try? fm.contentsOfDirectory(atPath: b).sorted(),
                  left == right else { return .different(relative) }
            for name in left {
                let result = compare(a + "/" + name, b + "/" + name, relative: relative + "/" + name, fm: fm, chunk: chunk, done: &done,
                                     progress: progress, stop: stop)
                if case .same = result { continue }
                return result
            }
        default:
            guard (x[.size] as? NSNumber)?.int64Value == (y[.size] as? NSNumber)?.int64Value,
                  let one = FileHandle(forReadingAtPath: a), let two = FileHandle(forReadingAtPath: b) else { return .different(relative) }
            defer { try? one.close(); try? two.close() }
            while true {
                if stop() { return .stopped }
                // nil and empty both mean the end of the file
                let p = ((try? one.read(upToCount: chunk)) ?? nil) ?? Data(), q = ((try? two.read(upToCount: chunk)) ?? nil) ?? Data()
                guard p == q else { return .different(relative) }
                guard !p.isEmpty else { break }
                done += Int64(p.count)
                progress(done)
            }
        }
        return .same
    }
}
