import Darwin
import Foundation

/// "Did it work?" after an nxkit build and after the first start of an nxkit app (LNPANDY/NX2Apple#1460): either answer opens a new issue in
/// v0lumehi/nxkit, prefilled through its issue form (`.github/ISSUE_TEMPLATE/game_report.yml`, v0lumehi/nxkit#34). The launcher only opens the
/// URL in the browser, it never sends anything. The report carries no keys and no paths: the home folder becomes `~`, the user name `user`, any other
/// path its last part, and long hex strings (keys) are cut out.
package enum NxkitFeedback {
    /// The issue form's field ids, in one place: the form in v0lumehi/nxkit may rename them.
    package enum Field {
        package static let template = "template"
        package static let templateName = "game_report.yml"
        package static let title = "title"
        package static let titleID = "title_id"
        package static let gameVersion = "game_version"
        package static let result = "result"
        package static let nxkitVersion = "nxkit_version"
        package static let engineBuild = "engine_build"
        package static let exitCode = "exit_code"
        package static let macModel = "mac_model"
        package static let macOSVersion = "macos_version"
        package static let log = "log"
    }

    package static let newIssueURL = "https://github.com/v0lumehi/nxkit/issues/new"
    /// GitHub and browsers take longer URLs, but 8 KB is where some proxies stop.
    package static let maxURLLength = 8000
    package static let maxLogLines = 200

    /// The form's `result` dropdown: the option texts exactly.
    package enum Result: String, CaseIterable, Sendable {
        case works = "Works"
        case problems = "Problems"
        case doesNotStart = "Does not start"
    }

    package struct Report: Equatable, Sendable {
        package var gameName: String
        package var titleID: String
        package var gameVersion: String
        package var nxkitVersion: String
        package var engineBuild: String
        package var result: Result
        package var exitCode: Int32?
        package var log: String
        package var macModel: String
        package var macOSVersion: String

        package init(gameName: String, titleID: String, gameVersion: String, nxkitVersion: String, engineBuild: String, result: Result,
                     exitCode: Int32?, log: String, macModel: String = NxkitFeedback.macModel, macOSVersion: String = NxkitFeedback.macOSVersion) {
            self.gameName = gameName; self.titleID = titleID; self.gameVersion = gameVersion; self.nxkitVersion = nxkitVersion
            self.engineBuild = engineBuild; self.result = result; self.exitCode = exitCode; self.log = log
            self.macModel = macModel; self.macOSVersion = macOSVersion
        }
    }

    /// This Mac's model identifier ("Mac15,8").
    package static var macModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    package static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    // MARK: The log

    /// One line without the player's paths and keys.
    package static func scrub(_ line: String, home: String, user: String) -> String {
        var s = line
        if !home.isEmpty { s = s.replacingOccurrences(of: home, with: "~") }
        // any path: its last part only (the game's file name stays, the folders go)
        s = replace(#"(?<![^\s"'=(\[:])~?(?:/[^\s"'\]),:;]+)+"#, in: s) { match in
            let last = (match as NSString).lastPathComponent
            return last.isEmpty || last == "/" ? "" : last
        }
        if !user.isEmpty { s = replace("\\b" + NSRegularExpression.escapedPattern(for: user) + "\\b", in: s) { _ in "user" } }
        // keys and other long hex strings
        s = replace("\\b[0-9A-Fa-f]{32,}\\b", in: s) { _ in "[hex]" }
        return s
    }

    private static func replace(_ pattern: String, in s: String, with: (String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += with(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// The last up to 200 lines of the build's output, scrubbed.
    package static func logLines(_ log: String, home: String, user: String) -> [String] {
        NxkitBuilder.outputTail(log, count: maxLogLines).map { scrub($0, home: home, user: user) }
    }

    // MARK: The URL

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    package static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// "Send feedback" with nxkit (Beta) chosen, outside any build: the same issue form, prefilled only with what this Mac knows
    /// (nxkit version, engine build, Mac model, macOS). The player picks the game and the result in the form.
    package static func feedbackURL(nxkitVersion: String, engineBuild: String, macModel: String = NxkitFeedback.macModel,
                                    macOSVersion: String = NxkitFeedback.macOSVersion) -> URL {
        let fields: [(String, String)] = [
            (Field.template, Field.templateName),
            (Field.nxkitVersion, nxkitVersion),
            (Field.engineBuild, engineBuild),
            (Field.macModel, macModel),
            (Field.macOSVersion, macOSVersion),
        ].filter { !$0.1.isEmpty }
        let url = newIssueURL + "?" + fields.map { $0.0 + "=" + encode($0.1) }.joined(separator: "&")
        return URL(string: url) ?? URL(string: newIssueURL)!
    }

    /// "Report" for an app nxkit built without a game profile (NxkitBuildProfile): the same issue form, prefilled only with what this
    /// launcher knows, the title "[Game] <name>" as issueURL writes it. An empty value is left out, the player fills in the rest and the
    /// result in the form.
    package static func genericBuildReportURL(gameName: String, titleID: String, gameVersion: String, nxkitVersion: String,
                                              macModel: String = NxkitFeedback.macModel,
                                              macOSVersion: String = NxkitFeedback.macOSVersion,
                                              home: String = NSHomeDirectory(), user: String = NSUserName()) -> URL {
        let name = scrub(gameName, home: home, user: user)
        let fields: [(String, String)] = [
            (Field.template, Field.templateName),
            (Field.title, name.isEmpty ? "" : "[Game] " + name),
            (Field.titleID, titleID.uppercased()),
            (Field.gameVersion, gameVersion),
            (Field.nxkitVersion, nxkitVersion),
            (Field.macModel, macModel),
            (Field.macOSVersion, macOSVersion),
        ].filter { !$0.1.isEmpty }
        let url = newIssueURL + "?" + fields.map { $0.0 + "=" + encode($0.1) }.joined(separator: "&")
        return URL(string: url) ?? URL(string: newIssueURL)!
    }

    /// The new-issue URL. The log is cut from the top until the whole URL is under `maxURLLength`.
    package static func issueURL(_ r: Report, home: String = NSHomeDirectory(), user: String = NSUserName()) -> URL {
        let name = scrub(r.gameName, home: home, user: user)
        var fields: [(String, String)] = [
            (Field.template, Field.templateName),
            (Field.title, "[Game] " + name),
            (Field.titleID, r.titleID.uppercased()),
            (Field.gameVersion, r.gameVersion),
            (Field.result, r.result.rawValue),
            (Field.nxkitVersion, r.nxkitVersion),
            (Field.engineBuild, r.engineBuild),
            (Field.macModel, r.macModel),
            (Field.macOSVersion, r.macOSVersion),
        ]
        if let code = r.exitCode { fields.append((Field.exitCode, String(code))) }
        let base = newIssueURL + "?" + fields.map { $0.0 + "=" + encode($0.1) }.joined(separator: "&")
        var lines = logLines(r.log, home: home, user: user)
        var url = base
        while true {
            url = lines.isEmpty ? base : base + "&" + Field.log + "=" + encode(lines.joined(separator: "\n"))
            if url.count <= maxURLLength || lines.isEmpty { break }
            // drop as many lines from the top as the excess needs, at least one
            let excess = url.count - maxURLLength
            var dropped = 0, removed = 0
            while removed < excess, dropped < lines.count { removed += encode(lines[dropped] + "\n").count; dropped += 1 }
            lines.removeFirst(max(1, dropped))
        }
        return URL(string: url) ?? URL(string: newIssueURL)!
    }
}
