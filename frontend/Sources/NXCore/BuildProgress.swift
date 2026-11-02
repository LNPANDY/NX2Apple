import Foundation

package struct Stage: Identifiable {
    package let id: Int          // k, the stage number in the script's own plan
    package var name: String
    package var state: StepState = .running
    package var detail: String = ""
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
        if let s = known(key) { return s }
        if name.hasPrefix("extract "), let f = known("stage.extract") { return String(format: f, String(name.dropFirst("extract ".count))) }
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

/// Reading what a build prints: the script's stage lines and JSON events, durations, the steps of Xcode and the install, and what
/// a failed install says. Pure functions of the text.
package enum BuildProgress {
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
        let ok = line.contains("✓"), bad = line.contains("✗")
        if ok || bad {
            var detail = ""
            if let r = rest.range(of: "): ") { detail = String(rest[r.upperBound...]); rest = String(rest[..<r.lowerBound]) + ")" }
            if let r = rest.range(of: " (", options: .backwards) { rest = String(rest[..<r.lowerBound]) }
            return (k, rest, bad ? .failed : .done, detail, 100)
        }
        if rest.hasSuffix(" …") { rest = String(rest.dropLast(2)) }
        if let dot = rest.range(of: " · ", options: .backwards), !rest.hasPrefix("survey") { rest = String(rest[..<dot.lowerBound]) }
        return (k, rest, .running, "", nil)
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
