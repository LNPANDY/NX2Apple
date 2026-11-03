import Foundation

// LNPANDY/NX2Apple#427, part 2: the player moves the shell cache (frameworks, shell.json, the banner cache, the shell project and
// its derived data) to another folder, for example an external drive, and back to the default place. The cache goes into a folder
// `NX2Apple-shell` inside the folder the player picked, so the launcher never owns, fills or removes a folder the player chose as a
// whole. The rules of the migration hold here too: a plain folder (no link), a readable shell.json, a free destination.
//
// On the same volume the move is a rename. On another volume the files are copied into a hidden folder beside the destination,
// every file is compared with its original, shell.json is rewritten in the copy, and only then the copy takes the destination's
// name and the old files are removed. A stop or an error before that point removes the partial copy and leaves the old folder
// as it was, so it stays valid and keeps being used. Nothing of the old folder is removed before the copy is verified.

package enum ShellRootMove {
    /// Set in the defaults when the saved root is one the player chose, so the migration at launch never moves it back.
    package static let pickedKey = "shellRootPicked"

    /// The cache folder inside the folder the player picked.
    package static func destination(inside folder: String) -> String {
        (folder as NSString).standardizingPath + "/" + ShellRootMigration.legacyName
    }

    /// Why the move cannot start.
    package enum Problem: Equatable {
        /// The cache is already there.
        case same
        /// The destination lies inside the cache.
        case insideCache
        /// The cache is a link, a file or an alias, not the plain folder the launcher made.
        case notPlain
        /// The cache folder holds files and no shell.json, so it is not a cache the launcher knows.
        case unknownContent
        /// shell.json is there but cannot be read.
        case unreadableLedger
        /// Something is already at the destination.
        case destinationTaken
        case readOnly
        case noSpace(needed: Int64, free: Int64)
    }

    /// What the confirmation shows, and what `run` does.
    package struct Plan: Equatable {
        package var source: String
        package var destination: String
        /// The size of the cache's files, 0 when there is no cache yet.
        package var bytes: Int64
        /// Free space on the destination's volume, nil when it cannot be read.
        package var free: Int64?
        /// The destination is on the cache's volume: the move is a rename.
        package var sameVolume: Bool
        /// There is a cache to move. Without one only the saved place changes.
        package var sourceExists: Bool
        package var problem: Problem?

        package init(source: String, destination: String, bytes: Int64, free: Int64?, sameVolume: Bool, sourceExists: Bool, problem: Problem?) {
            self.source = source; self.destination = destination; self.bytes = bytes; self.free = free
            self.sameVolume = sameVolume; self.sourceExists = sourceExists; self.problem = problem
        }
    }

    package static func plan(from source: String, to destination: String, fm: FileManager = .default) -> Plan {
        let source = (source as NSString).standardizingPath, destination = (destination as NSString).standardizingPath
        let volume = DriveCopy.volume(at: destination, fm: fm)
        var plan = Plan(source: source, destination: destination, bytes: 0, free: volume?.freeBytes,
                        sameVolume: sameVolume(source, destination, fm: fm), sourceExists: false, problem: nil)
        if source == destination { plan.problem = .same; return plan }
        if destination.hasPrefix(source + "/") { plan.problem = .insideCache; return plan }
        let isLink = (try? fm.destinationOfSymbolicLink(atPath: source)) != nil
        plan.sourceExists = isLink || fm.fileExists(atPath: source)
        if plan.sourceExists {
            guard !isLink, ((try? fm.attributesOfItem(atPath: source))?[.type] as? FileAttributeType) == .typeDirectory else {
                plan.problem = .notPlain; return plan
            }
            guard let entries = try? fm.contentsOfDirectory(atPath: source) else { plan.problem = .notPlain; return plan }
            if entries.contains("shell.json") {
                guard let data = fm.contents(atPath: ShellLibrary.stateFile(root: source)),
                      (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { plan.problem = .unreadableLedger; return plan }
            } else if !entries.filter({ $0 != ".DS_Store" }).isEmpty {
                plan.problem = .unknownContent; return plan
            }
            plan.bytes = treeSize(source, fm: fm)
        }
        if !isFree(destination, fm: fm) { plan.problem = .destinationTaken; return plan }
        if volume?.readOnly == true { plan.problem = .readOnly; return plan }
        if plan.sourceExists, !plan.sameVolume, let free = plan.free, plan.bytes > free {
            plan.problem = .noSpace(needed: plan.bytes, free: free)
        }
        return plan
    }

    package enum Phase: Equatable { case copying, checking }

    /// Why a move failed. The old folder stays and keeps being used in every case.
    package enum Failure: Equatable {
        /// A file system call failed: the system's own text.
        case io(String)
        /// A file of the copy is not the same as its original: its path inside the cache.
        case mismatch(String)
        /// shell.json could not be rewritten for the new place.
        case ledger
    }

    package enum Outcome: Equatable {
        case moved
        /// The cache is in its new place, but these files of the old folder could not be removed.
        case movedOldStays([String])
        /// The player stopped it. The old folder is as it was.
        case stopped
        case failed(Failure)
    }

    /// Moves the cache as the plan says. `progress` gets the phase and bytes done of the total, `stop` is asked between chunks.
    /// `afterCopy` runs on the copy before it is checked (tests use it to damage the copy). The caller saves the new root.
    package static func run(_ plan: Plan, fm: FileManager = .default, chunk: Int = 8 << 20,
                            progress: (Phase, Int64, Int64) -> Void = { _, _, _ in }, stop: () -> Bool = { false },
                            afterCopy: (String) -> Void = { _ in }) -> Outcome {
        guard plan.problem == nil else { return .failed(.io("the move cannot start")) }
        let source = plan.source, destination = plan.destination
        let parent = (destination as NSString).deletingLastPathComponent
        do { try fm.createDirectory(atPath: parent, withIntermediateDirectories: true) } catch { return .failed(.io(error.localizedDescription)) }
        guard plan.sourceExists else { return .moved }
        guard isFree(destination, fm: fm) else { return .failed(.io("the new place is taken")) }

        if plan.sameVolume {
            if stop() { return .stopped }
            do {
                try removeEmptyFolder(destination, fm: fm)
                try fm.moveItem(atPath: source, toPath: destination)
            } catch { return .failed(.io(error.localizedDescription)) }
            guard ShellRootMigration.rewritePaths(root: destination, from: source, to: destination, fm: fm) else {
                // shell.json still names the old place: put the folder back rather than leave a split state
                try? fm.moveItem(atPath: destination, toPath: source)
                return .failed(.ledger)
            }
            progress(.copying, plan.bytes, plan.bytes)
            return .moved
        }

        // Another volume: a hidden copy beside the destination, which is ours alone and may be removed on any failure
        let staging = parent + "/.\(ShellRootMigration.legacyName)-moving-\(UUID().uuidString)"
        func abandon(_ outcome: Outcome) -> Outcome { try? fm.removeItem(atPath: staging); return outcome }
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: source)
            try fm.createDirectory(atPath: staging, withIntermediateDirectories: false)
        } catch { return abandon(.failed(.io(error.localizedDescription))) }
        var done: Int64 = 0
        do {
            for name in entries.sorted() {
                guard try copyItem(source + "/" + name, to: staging + "/" + name, fm: fm, chunk: chunk, done: &done,
                                   progress: { progress(.copying, $0, plan.bytes) }, stop: stop) else { return abandon(.stopped) }
            }
        } catch { return abandon(.failed(.io(error.localizedDescription))) }
        afterCopy(staging)
        var checked: Int64 = 0
        for name in entries.sorted() {
            switch compare(source + "/" + name, staging + "/" + name, relative: name, fm: fm, chunk: chunk, done: &checked,
                           progress: { progress(.checking, $0, plan.bytes) }, stop: stop) {
            case .same: continue
            case .stopped: return abandon(.stopped)
            case .different(let path): return abandon(.failed(.mismatch(path)))
            }
        }
        guard ShellRootMigration.rewritePaths(root: staging, from: source, to: destination, fm: fm) else { return abandon(.failed(.ledger)) }
        do {
            try removeEmptyFolder(destination, fm: fm)
            try fm.moveItem(atPath: staging, toPath: destination)
        } catch { return abandon(.failed(.io(error.localizedDescription))) }

        // The copy is checked and in place. Only now the old files go: the entries the copy holds, then the folder if it is empty.
        var left: [String] = []
        for name in entries where name != ".DS_Store" {
            do { try fm.removeItem(atPath: source + "/" + name) } catch { left.append(source + "/" + name) }
        }
        if left.isEmpty { try? removeEmptyFolder(source, fm: fm) }
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
