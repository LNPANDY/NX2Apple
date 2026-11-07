import Foundation

package struct Stage: Identifiable {
    package let id: Int          // k, the stage number in the script's own plan
    package var name: String
    package var state: StepState = .running
    package var detail: String = ""
    package var isScanningLastShaderFiles = false
    package var percent: Double? = nil
    package var started: Date? = nil   // when the stage began here: its clock runs while the count may stand still
    package var eta: Double? = nil     // the script's estimate of the seconds left, as of etaAt
    package var etaAt: Date? = nil

    package init(id: Int, name: String, state: StepState = .running, detail: String = "", percent: Double? = nil,
                 started: Date? = nil, eta: Double? = nil, etaAt: Date? = nil) {
        self.id = id; self.name = name; self.state = state; self.detail = detail; self.percent = percent
        self.started = started; self.eta = eta; self.etaAt = etaAt
    }

    /// A stage's name in the launcher's language. The script names its stages in English (PROG.stage in
    /// build_ipa_from_nsp.py): stage.<name> in the table, "extract <name>" and "<API> shader capture" with their
    /// part kept; a name the table does not know (a newer script's) is shown as the script wrote it.
    package static func localizedName(_ name: String, _ t: (String) -> String) -> String {
        func known(_ key: String) -> String? { let s = t(key); return s == key ? nil : s }
        let key = "stage." + name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        // a bare "extract" (nxb 0.6.1 and older) has no part for the table's "extract %@"
        if let s = known(key), !s.contains("%@") { return s }
        if name.hasPrefix("extract "), let f = known("stage.extract") { return String(format: f, String(name.dropFirst("extract ".count))) }
        // A game folder packs each version into an image ("pack v458752", pack_dump.py), a NUP unpacks it ("unpack v196608", pack_nup.py)
        if name.hasPrefix("pack "), let f = known("stage.pack") { return String(format: f, String(name.dropFirst("pack ".count))) }
        if name.hasPrefix("unpack "), let f = known("stage.unpack") { return String(format: f, String(name.dropFirst("unpack ".count))) }
        if name.hasSuffix(" shader capture"), let f = known("stage.capture") { return String(format: f, String(name.dropLast(" shader capture".count))) }
        return name
    }

    /// "3:42" since the stage began, then "1 min left" while the script's estimate, counted down from when it came,
    /// lasts: the estimate only arrives with a new count, so one taken as it was would stand still with the count.
    package func clock(at now: Date, left: String) -> String {
        var parts: [String] = []
        if let started {
            let t = max(0, Int(now.timeIntervalSince(started)))
            parts.append(t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60))
        }
        if let eta, let etaAt {
            let remaining = eta - now.timeIntervalSince(etaAt)
            if remaining >= 1 { parts.append(String(format: left, BuildProgress.duration(remaining))) }
        }
        return parts.joined(separator: " · ")
    }
}

/// The state of one stage of a build. Its colour is in the app (`StepState.color`).
package enum StepState: Equatable {
    case pending, running, done, failed
    package var icon: String {
        switch self {
        case .pending: return "circle"
        case .running: return "spinner"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
}

/// Offline pipeline archive (`pso_offline.py`) batch progress inspected from its work directory.
package struct PSOArchiveProgress: Equatable, Sendable {
    package let done: Int
    package let total: Int
    package let merging: Bool

    package init(done: Int, total: Int, merging: Bool = false) {
        self.done = done
        self.total = total
        self.merging = merging
    }
}

/// Reading what a build prints: the script's stage lines and JSON events, durations, the steps of Xcode and the install, and what
/// a failed install says. Pure functions of the text.
package enum BuildProgress {
    private static let basesCacheLock = NSLock()
    nonisolated(unsafe) private static var basesCache: (key: String, count: Int)?

    /// Batch progress of `pso_offline.py` read from its log or work directory (`<work>/pso/mac-work` on macOS,
    /// `<work>/ipa/build/ios/pso/work` on iOS) when the script has not emitted native JSON batch counts.
    /// Returns `nil` when no batch compilation is active (e.g. single-invocation `metal-tt` without `batches.<arch>`).
    package static func psoArchiveProgress(workDir: String, batchSize: Int = 1000) -> PSOArchiveProgress? {
        guard !workDir.isEmpty, batchSize > 0 else { return nil }
        let fm = FileManager.default
        let candidates = [workDir + "/pso/mac-work", workDir + "/ipa/build/ios/pso/work"]
        var chosenWork = ""
        var rootMtime = Date.distantPast
        var rootSize: UInt64 = 0
        for dir in candidates {
            let js = dir + "/bases.mtl4-json"
            guard let attr = try? fm.attributesOfItem(atPath: js),
                  let size = attr[.size] as? UInt64, size > 0,
                  let mtime = attr[.modificationDate] as? Date else { continue }
            if mtime >= rootMtime {
                chosenWork = dir; rootMtime = mtime; rootSize = size
            }
        }
        guard !chosenWork.isEmpty else { return nil }
        let cutoff = rootMtime.addingTimeInterval(-2)

        // 1. Prefer `pso_offline.py`'s own batch log lines (`pso_offline: <arch>: batch i/N: ...` / `merging N batches`),
        // which carry the exact batch total without reading `bases.mtl4-json` or assuming a fixed batch size.
        if let fromLog = psoProgressFromLogs(workDir: workDir, cutoff: cutoff, fm: fm) {
            return fromLog
        }

        // 2. Fall back to inspecting `batches.<arch>/NNNNN/`. If no `batches.*` folder exists yet, return nil
        // immediately without reading the (potentially large) `bases.mtl4-json` or showing a misleading "0 / N" at 0%.
        guard let entries = try? fm.contentsOfDirectory(atPath: chosenWork) else { return nil }
        let archDirs = entries.filter { $0.hasPrefix("batches.") && $0.count > "batches.".count }
        var chosenArch = ""
        var latestArchMtime = Date.distantPast
        for name in archDirs {
            let p = chosenWork + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
            let mtime = (try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? .distantPast
            if chosenArch.isEmpty || mtime >= latestArchMtime {
                chosenArch = String(name.dropFirst("batches.".count))
                latestArchMtime = mtime
            }
        }
        guard !chosenArch.isEmpty else { return nil }
        let batchesRoot = chosenWork + "/batches." + chosenArch
        let firstBatchJS = batchesRoot + "/00001/bases.mtl4-json"
        guard let firstAttr = try? fm.attributesOfItem(atPath: firstBatchJS),
              let firstMtime = firstAttr[.modificationDate] as? Date,
              firstMtime >= cutoff else { return nil }

        let jsPath = chosenWork + "/bases.mtl4-json"
        let cacheKey = "\(jsPath)|\(rootSize)|\(rootMtime.timeIntervalSince1970)"
        let basesCount: Int = {
            basesCacheLock.lock()
            if let cached = basesCache, cached.key == cacheKey {
                basesCacheLock.unlock()
                return cached.count
            }
            basesCacheLock.unlock()
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsPath), options: .mappedIfSafe) else { return 0 }
            let token = Data("\"vertex_function_descriptor\"".utf8)
            var count = 0
            var searchRange = data.startIndex..<data.endIndex
            while let r = data.range(of: token, options: [], in: searchRange) {
                count += 1
                searchRange = r.upperBound..<data.endIndex
            }
            if count > 0 {
                basesCacheLock.lock()
                basesCache = (cacheKey, count)
                basesCacheLock.unlock()
            }
            return count
        }()
        guard basesCount > batchSize else { return nil }
        let total = (basesCount - 1) / batchSize + 1
        var done = 0
        for index in 1...total {
            let batchDir = batchesRoot + "/" + String(format: "%05d", index)
            let batchJS = batchDir + "/bases.mtl4-json"
            guard let bAttr = try? fm.attributesOfItem(atPath: batchJS),
                  let bMtime = bAttr[.modificationDate] as? Date,
                  bMtime >= cutoff else { break }
            let keyPath = batchDir + "/key." + chosenArch
            let archivePath = batchDir + "/" + chosenArch + ".mtl4a"
            let partialPath = archivePath + ".partial"
            if fm.fileExists(atPath: partialPath) || !fm.fileExists(atPath: keyPath) {
                break
            }
            guard let aAttr = try? fm.attributesOfItem(atPath: archivePath),
                  let aSize = aAttr[.size] as? UInt64, aSize > 0 else { break }
            done = index
        }
        let packLog = chosenWork + "/metal-pack." + chosenArch + ".log"
        let packMtime = (try? fm.attributesOfItem(atPath: packLog)[.modificationDate] as? Date) ?? .distantPast
        let merging = done == total && packMtime >= cutoff
        return PSOArchiveProgress(done: done, total: total, merging: merging)
    }

    private static func psoProgressFromLogs(workDir: String, cutoff: Date, fm: FileManager) -> PSOArchiveProgress? {
        let logNames = ["pso_offline_mac.log", "build_ipa.log", "build_framework.log", "prepare_xcode.log"]
        var bestLog = ""
        var bestMtime = Date.distantPast
        for name in logNames {
            let p = workDir + "/logs/" + name
            guard let attr = try? fm.attributesOfItem(atPath: p),
                  let mtime = attr[.modificationDate] as? Date,
                  mtime >= cutoff else { continue }
            if bestLog.isEmpty || mtime >= bestMtime {
                bestLog = p; bestMtime = mtime
            }
        }
        guard !bestLog.isEmpty,
              let text = try? String(contentsOfFile: bestLog, encoding: .utf8) else { return nil }
        guard let batchRe = try? NSRegularExpression(pattern: #"pso_offline: \S+: batch (\d+)/(\d+): (ready|\d+ bases)"#),
              let mergeRe = try? NSRegularExpression(pattern: #"pso_offline: \S+: merging (\d+) batches"#) else { return nil }
        var done = 0
        var total = 0
        var merging = false
        for line in text.split(separator: "\n") {
            let s = String(line)
            let ns = s as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = batchRe.firstMatch(in: s, range: range),
               let idx = Int(ns.substring(with: m.range(at: 1))),
               let tot = Int(ns.substring(with: m.range(at: 2))), tot > 0 {
                let kind = ns.substring(with: m.range(at: 3))
                total = tot
                done = kind == "ready" ? idx : max(0, idx - 1)
                merging = false
            } else if let m = mergeRe.firstMatch(in: s, range: range),
                      let tot = Int(ns.substring(with: m.range(at: 1))), tot > 0 {
                total = tot
                done = tot
                merging = true
            }
        }
        guard total > 0 else { return nil }
        return PSOArchiveProgress(done: done, total: total, merging: merging)
    }
    /// The last line of the log that says something: not blank, not a progress event. Used for the
    /// failure note, where the exit code on its own is not actionable (issue #52).
    package static func lastMeaningfulLine(_ log: String) -> String? {
        for line in log.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("{") { continue }   // a --progress json event
            return String(s.prefix(200))
        }
        return nil
    }

    /// shader_split.py reports completed batches of up to 16 files. Its fraction is capped at 99% even when all files are done.
    package static func isScanningLastShaderFiles(_ event: [String: Any]) -> Bool {
        guard event["name"] as? String == "shader split", event["step"] as? String == "splitting",
              event["unit"] as? String == "files", event["est"] as? Bool != true,
              let done = event["done"] as? Int, let total = event["total"] as? Int,
              done > 0, total > done else { return false }
        return total - done <= 16
    }

    /// "splitting · 1.2 / 3.4 GB", "1,203 / 19,592 shaders", "2,301 files": the step and the count (the time left is the Stage's clock).
    package static func progressDetail(_ e: [String: Any]) -> String {
        let step = e["step"] as? String ?? "", unit = e["unit"] as? String ?? "", note = e["note"] as? String ?? ""
        let done = (e["done"] as? NSNumber)?.doubleValue, total = (e["total"] as? NSNumber)?.doubleValue
        let estimate = (e["est"] as? Bool ?? false) ? "~" : ""
        var count = ""
        if let done {
            if unit == "B" {
                let bytes = { (v: Double) in ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file) }
                count = total.map { "\(bytes(done)) / \(estimate)\(bytes($0))" } ?? bytes(done)
            } else {
                let number = { (v: Double) in NumberFormatter.localizedString(from: NSNumber(value: Int(v)), number: .decimal) }
                count = (total.map { "\(number(done)) / \(estimate)\(number($0))" } ?? number(done)) + (unit.isEmpty ? "" : " \(unit)")
            }
        }
        return [step, count, note].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    package static func duration(_ seconds: Double) -> String {
        // Formatted by hand, not DateComponentsFormatter: the formatter follows the system
        // locale, so a Chinese macOS wrote "4秒" into a log whose every other line was English
        // (and the test that pinned "4s" failed on any non-English machine). The abbreviations
        // are the interface language's, via the same string table as everything else.
        let s = max(Int(seconds.rounded(.up)), 1)
        if s >= 3600 {
            let h = s / 3600, m = (s % 3600) / 60
            return h > 0 && m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        if s >= 60 {
            let m = s / 60, sec = s % 60
            return sec > 0 ? "\(m)m \(sec)s" : "\(m)m"
        }
        return "\(s)s"
    }

    package static func parseStage(_ line: String) -> (k: Int, name: String, state: StepState, detail: String, percent: Double?)? {
        guard let re = try? NSRegularExpression(pattern: #"\[(\d+)/(\d+)\] (.+)$"#) else { return nil }
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        guard let k = Int(ns.substring(with: m.range(at: 1))) else { return nil }
        var rest = ns.substring(with: m.range(at: 3))

        if let pct = rest.range(of: #"(\d+)%"#, options: .regularExpression) {
            let v = Double(rest[pct].dropLast()) ?? 0
            var name = String(rest[..<pct.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " :·"))
            if let dot = name.range(of: " · ", options: .backwards) { name = String(name[..<dot.lowerBound]) }
            let after = String(rest[pct.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ", :"))
            return (k, name, .running, after, v)
        }
        let ok = line.contains("✓") || line.contains("⚠"), bad = line.contains("✗")
        if ok || bad {
            var detail = ""
            if let r = rest.range(of: "): ") { detail = String(rest[r.upperBound...]); rest = String(rest[..<r.lowerBound]) + ")" }
            if let r = rest.range(of: " (", options: .backwards) { rest = String(rest[..<r.lowerBound]) }
            return (k, rest, bad ? .failed : .done, detail, 100)
        }
        if rest.hasSuffix(" …") {
            rest = String(rest.dropLast(2))
            if let dot = rest.range(of: " · ", options: .backwards), !rest.hasPrefix("survey") { rest = String(rest[..<dot.lowerBound]) }
            return (k, rest, .running, "", nil)
        }
        var detail = ""
        if let col = rest.range(of: ": ") {
            detail = String(rest[col.upperBound...]).trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<col.lowerBound])
        }
        if let dot = rest.range(of: " · ", options: .backwards), !rest.hasPrefix("survey") { rest = String(rest[..<dot.lowerBound]) }
        return (k, rest, .running, detail, nil)
    }

    /// What xcodebuild is doing, from the actions it prints.
    package static func xcodeStep(_ line: String) -> (detail: String, percent: Double?)? {
        let actions = [("CompileC ", "compiling"), ("SwiftCompile ", "compiling"), ("Ld ", "linking"),
                       ("PhaseScriptExecution ", "copying resources"), ("CodeSign ", "signing"), ("ProcessProductPackaging ", "provisioning")]
        return actions.first { line.hasPrefix($0.0) }.map { ($0.1, nil) }
    }

    /// devicectl's install progress ("… 45%").
    package static func installStep(_ line: String) -> (detail: String, percent: Double?)? {
        guard let range = line.range(of: #"(\d{1,3})%"#, options: .regularExpression), let n = Double(line[range].dropLast()) else { return nil }
        return ("installing", min(n, 100))
    }

    /// The line a failed install should show, and the fix to offer beside it.
    ///
    /// A GUI user sees a spinner turn back into a button; the reason (brew refusing a directory it
    /// does not own is the common one) lived only in the log. Prefer the tool's own `Error:` line,
    /// and map the few causes we can name to the exact command.
    package static func failureInfo(_ lines: [String]) -> (error: String, fix: String) {
        let meaningful = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let error = meaningful.first { $0.hasPrefix("Error:") }
            ?? meaningful.first { $0.lowercased().contains("error") }
            ?? meaningful.last ?? ""
        let lower = lines.joined(separator: "\n").lowercased()
        let fix: String
        if lower.contains("/opt/homebrew is not writable") || lower.contains("permission denied @ dir_initialize")
            || lower.contains("/usr/local is not writable") {
            fix = "dep.fix.brewOwner"
        } else if lower.contains("command not found") || lower.contains("brew: not found") {
            fix = "dep.fix.brewMissing"
        } else if lower.contains("agreeing to the xcode license") || lower.contains("xcode license") {
            fix = "dep.fix.xcodeLicense"
        } else if lower.contains("could not resolve host") || lower.contains("failed to download")
            || lower.contains("operation timed out") {
            fix = "dep.fix.network"
        } else {
            fix = "dep.fix.log"
        }
        return (error, fix)
    }
}
