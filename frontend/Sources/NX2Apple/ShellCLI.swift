import Foundation
import NXCore

/// `NSPortBuilder --install-shell ...`: steps 3 to 7 without a window and without questions, for a terminal or a script.
enum ShellCLI {
    static let usage = "NSPortBuilder --install-shell --framework <path> --archive <games/TITLEID folder> --title-id <id> --name <name> "
        + "--device <udid> --team <team> --repo <repo> [--shell-root <dir>] [--python <path>]"

    /// The options as a dictionary, nil when an option has no value.
    static func parse(_ args: [String]) -> [String: String]? {
        var options: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--install-shell" { i += 1; continue }
            guard a.hasPrefix("--"), i + 1 < args.count else { return nil }
            options[String(a.dropFirst(2))] = args[i + 1]
            i += 2
        }
        return options
    }

    /// Exit status: 0 installed, 1 failed (or wrong usage). `out` gets every line, stage lines and tool output alike.
    /// `--xcrun` is for the tests, which stand in for xcodebuild and devicectl.
    static func run(_ args: [String], defaults: UserDefaults = .standard, out: @escaping (String) -> Void = { fputs($0, stdout); fflush(stdout) }) -> Int32 {
        let required = ["framework", "archive", "title-id", "name", "device", "team", "repo"]
        guard let o = parse(args), required.allSatisfy({ !(o[$0] ?? "").isEmpty }) else {
            out("usage: " + usage + "\n")
            return 1
        }
        let archive = o["archive"]!
        let root = o["shell-root"] ?? ShellLibrary.resolveRoot(
            defaults: defaults, parent: ((archive as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent)
        let python = o["python"] ?? Toolchain.findPython().path
        var installer = ShellInstaller(xcrun: o["xcrun"] ?? "/usr/bin/xcrun", repo: o["repo"]!, python: python, root: root,
                                       device: o["device"]!, team: o["team"]!)
        installer.deviceName = o["device"]!
        installer.toolPath = BundledTools.path("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", python: python)
        installer.log = out
        installer.stage = { s in
            switch s.state {
            case .running: if s.detail.isEmpty { out("==> \(s.name)\n") }
            case .done: out("==> \(s.name): done\n")
            case .failed: out("==> \(s.name): FAILED \(s.detail)\n")
            case .pending: break
            }
        }
        let result = installer.install(framework: o["framework"]!, titleID: o["title-id"]!, name: o["name"]!, archive: archive)
        out((result.ok ? "OK: " : "FAIL: ") + result.message + "\n")
        return result.ok ? 0 : 1
    }
}
