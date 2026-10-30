import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Where the project's repository comes from. One list, tried in order: a checkout that cannot reach
/// GitHub should still download and update, so a mirror and a plain proxy sit behind it.
///
/// The list is data, not a switch in the UI: the first source that answers is used and remembered, and
/// the next one is tried when a clone or a fetch fails. A source that only mirrors the files (a proxy)
/// is harmless to fall back to — the checkout is the same repository at the same commit, and the build
/// reads `dm/`, `patches/` and `.upstream-ref` from it.
struct RepoSource: Equatable, Identifiable {
    /// Stable id, stored in UserDefaults: renaming what the player sees must not forget the choice.
    let id: String
    /// What the status line and Copy diagnostics call it ("GitHub", "GitCode", "gh-proxy").
    let name: String
    /// The clone URL (`git clone` and `git fetch` both take it).
    let url: String

    var host: String { URL(string: url)?.host ?? url }
}

enum RepoEndpoints {
    /// The official repository. Always first, always available.
    static let github = RepoSource(id: "github", name: "GitHub", url: "https://github.com/LNPANDY/NX2Apple.git")

    /// The mirror for networks that cannot reach GitHub. `nil` until the mirror exists: the id is
    /// remembered, so once it is set a player who already used it keeps it first.
    static let gitCode: RepoSource? = nil

    /// A plain prefix proxy over GitHub (public repositories only). Last, because a third party sees
    /// the requests: it is never given credentials, and it is only used to read.
    static let ghProxy = RepoSource(id: "gh-proxy", name: "gh-proxy", url: "https://gh-proxy.com/https://github.com/LNPANDY/NX2Apple.git")

    /// Every source, in the order they are tried when nothing is remembered.
    static var all: [RepoSource] { [github] + (gitCode.map { [$0] } ?? []) + [ghProxy] }

    static func source(id: String?) -> RepoSource? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// The sources to try: the remembered one first (when it is still in the list), then the rest.
    static func ordered(preferred id: String?) -> [RepoSource] {
        guard let first = source(id: id) else { return all }
        return [first] + all.filter { $0.id != first.id }
    }

    /// The first source `probe` accepts, in `ordered(preferred:)` order. Pure, so a test drives it
    /// without a network: the caller passes `answers(_:)` in the app.
    static func pick(preferred id: String?, probe: (RepoSource) -> Bool) -> RepoSource? {
        ordered(preferred: id).first(where: probe)
    }

    /// Whether `git ls-remote` answers for this source within `timeout` seconds. This is the cheap
    /// check before a multi-hundred-MB clone: it reads the refs and nothing else.
    ///
    /// `GIT_TERMINAL_PROMPT=0` so a source asking for credentials fails at once instead of waiting
    /// for input no one can give (the launcher has no terminal).
    static func answers(_ source: RepoSource, git: String, env: [String: String], timeout: TimeInterval = 8) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["ls-remote", "--heads", source.url]
        p.environment = env.merging(["GIT_TERMINAL_PROMPT": "0"]) { $1 }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        guard !p.isRunning else {                       // timed out: leave nothing running behind
            p.terminate()
            usleep(200_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            return false
        }
        return p.terminationStatus == 0
    }
}
