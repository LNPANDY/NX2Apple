import Foundation
import NXCore

/// `NSPortBuilder --install-shell ...`: steps 3 to 7 without a window and without questions, for a terminal or a script.
/// Pass `--artwork <titleID>=<path>` once per game whose own cover should be used.
enum ShellCLI {
    static let usage = "NSPortBuilder --install-shell --framework <path> --archive <games/TITLEID folder> --title-id <id> --name <name> "
        + "--device <udid> --team <team> --repo <repo> [--shell-root <dir>] [--python <path>] [--artwork <titleID>=<path>]"

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

    /// Cover paths from repeated `--artwork <titleID>=<path>` flags.
    /// The title id is stored lowercased and the path is everything after the first equals.
    /// A value with no equals, an empty title id, or an empty path is left out.
    static func covers(_ args: [String]) -> [String: String] {
        var covers: [String: String] = [:]
        var i = 0
        while i < args.count {
            if args[i] == "--artwork", i + 1 < args.count {
                let value = args[i + 1]
                if let eq = value.firstIndex(of: "=") {
                    let id = String(value[..<eq])
                    let path = String(value[value.index(after: eq)...])
                    if !id.isEmpty, !path.isEmpty { covers[id.lowercased()] = path }
                }
                i += 2
                continue
            }
            i += 1
        }
        return covers
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
        // Each --artwork line supplies one game's cover. A title with no line returns nil and the install keeps the cached eShop banner.
        let covers = Self.covers(args)
        installer.artworkForTitle = { covers[$0.lowercased()] }
        let result = installer.install(framework: o["framework"]!, titleID: o["title-id"]!, name: o["name"]!, archive: archive)
        out((result.ok ? "OK: " : "FAIL: ") + result.message + "\n")
        return result.ok ? 0 : 1
    }
}
