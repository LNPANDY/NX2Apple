import Foundation

/// Turnkey macOS bootstrap helpers for S2Arm external engine trees:
/// 1. Initializes a clean single-commit local Git repository when an extracted S2Arm snapshot lacks `.git` and `engine.json`.
/// 2. Locates or builds a modern GNU Bash (>= 4, Bash 5.2.37) and symlinks it into `<s2arm>/.nx2apple-shims/bash`.
/// 3. Validates `cmake`/`meson`/`ninja` inside the S2Arm Python venv and prepares `<s2arm>/build/rewriter-deps`.
package enum S2ArmBootstrap {
    package static let requiredBuildTools = ["cmake", "meson", "ninja"]
    package static let bashVersion = "5.2.37"
    package static let bashTarballPrimaryURL = "https://ftpmirror.gnu.org/gnu/bash/bash-\(bashVersion).tar.gz"
    package static let bashTarballFallbackURL = "https://ftp.gnu.org/gnu/bash/bash-\(bashVersion).tar.gz"

    package static let gitExcludeEntries = [
        "/.venv/",
        "/.nx2apple-shims/",
        "/.upstream-version.json",
        "/build/",
    ]

    private static let gitPathspecExcludes = [
        ":(exclude).venv",
        ":(exclude).nx2apple-shims",
        ":(exclude).upstream-version.json",
        ":(exclude)build",
    ]

    private static func normalizedPrefix(_ dir: String) -> String {
        dir.hasSuffix("/") ? dir : dir + "/"
    }

    // MARK: - 1. Local Git repository bootstrap for ZIP snapshots

    /// Appends launcher-managed ignore entries to `<s2arm>/.git/info/exclude` when `.git` is a directory.
    package static func ensureGitExclude(in s2armTree: String, fileManager fm: FileManager = .default) {
        guard !s2armTree.isEmpty else { return }
        let prefix = normalizedPrefix(s2armTree)
        let gitPath = prefix + ".git"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: gitPath, isDirectory: &isDir), isDir.boolValue else { return }
        let infoDir = gitPath + "/info"
        let excludePath = infoDir + "/exclude"
        try? fm.createDirectory(atPath: infoDir, withIntermediateDirectories: true)
        let existing = (try? String(contentsOfFile: excludePath, encoding: .utf8)) ?? ""
        var lines = existing.split(whereSeparator: \.isNewline).map(String.init)
        var changed = !fm.fileExists(atPath: excludePath)
        for entry in gitExcludeEntries where !lines.contains(entry) {
            lines.append(entry)
            changed = true
        }
        guard changed else { return }
        let body = lines.joined(separator: "\n") + "\n"
        try? Data(body.utf8).write(to: URL(fileURLWithPath: excludePath), options: .atomic)
    }

    /// Initializes a clean single-commit local Git repository inside `<s2arm>` when neither `.git`
    /// nor `engine.json` exists, so S2Arm's `git rev-parse HEAD:...` and `git ls-tree HEAD` checks work.
    @discardableResult
    package static func ensureGitRepo(
        in s2armTree: String,
        runner: ProcessRunner = SystemProcessRunner(),
        fileManager fm: FileManager = .default
    ) -> Bool {
        guard !s2armTree.isEmpty else { return false }
        let prefix = normalizedPrefix(s2armTree)
        if fm.fileExists(atPath: prefix + "engine.json") {
            return true
        }
        let gitPath = prefix + ".git"
        if fm.fileExists(atPath: gitPath) {
            ensureGitExclude(in: s2armTree, fileManager: fm)
            return true
        }

        let gitExe = fm.isExecutableFile(atPath: "/usr/bin/git") ? "/usr/bin/git" : "git"
        let gitEnv: [String: String] = [
            "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
        ]

        let initRes = runner.capture(ProcessLaunch(
            executable: gitExe,
            arguments: ["-C", s2armTree, "init", "-q", "--template="],
            environment: gitEnv
        ))
        guard initRes.ok else { return false }

        ensureGitExclude(in: s2armTree, fileManager: fm)

        _ = runner.capture(ProcessLaunch(
            executable: gitExe,
            arguments: ["-C", s2armTree, "config", "gc.auto", "0"],
            environment: gitEnv
        ))
        _ = runner.capture(ProcessLaunch(
            executable: gitExe,
            arguments: ["-C", s2armTree, "config", "maintenance.auto", "false"],
            environment: gitEnv
        ))

        let addRes = runner.capture(ProcessLaunch(
            executable: gitExe,
            arguments: ["-C", s2armTree, "add", "--force", "--all", "--", "."] + gitPathspecExcludes,
            environment: gitEnv
        ))
        guard addRes.ok else {
            try? fm.removeItem(atPath: gitPath)
            return false
        }

        let commitRes = runner.capture(ProcessLaunch(
            executable: gitExe,
            arguments: [
                "-C", s2armTree,
                "-c", "commit.gpgsign=false",
                "-c", "core.hooksPath=/dev/null",
                "-c", "user.name=S2Arm",
                "-c", "user.email=bundle@localhost",
                "commit", "-qm", "Bundled S2Arm engine inputs",
            ],
            environment: gitEnv
        ))
        guard commitRes.ok else {
            try? fm.removeItem(atPath: gitPath)
            return false
        }
        return true
    }

    // MARK: - 2. Modern GNU Bash (>= 4) lookup, build, and shim

    package static func managedBashPath(home: String = NSHomeDirectory()) -> String {
        normalizedPrefix(home) + "Library/Application Support/NX2Apple/tools/bin/bash"
    }

    package static func bashCandidates(home: String = NSHomeDirectory()) -> [String] {
        [
            managedBashPath(home: home),
            "/opt/homebrew/bin/bash",
            "/usr/local/bin/bash",
        ]
    }

    package static func bashMajorVersion(_ path: String, runner: ProcessRunner = SystemProcessRunner()) -> Int? {
        guard !path.isEmpty else { return nil }
        let res = runner.capture(ProcessLaunch(
            executable: path,
            arguments: ["-c", "echo \"${BASH_VERSINFO[0]}\""],
            environment: ["PATH": "/usr/bin:/bin"]
        ))
        guard res.ok else { return nil }
        let first = res.out
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Int(first)
    }

    package static func findModernBash(
        candidates: [String]? = nil,
        home: String = NSHomeDirectory(),
        runner: ProcessRunner = SystemProcessRunner(),
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let list = candidates ?? bashCandidates(home: home)
        for cand in list where !cand.isEmpty && exists(cand) {
            if let major = bashMajorVersion(cand, runner: runner), major >= 4 {
                return cand
            }
        }
        return nil
    }

    private static func shellQuote(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    package static func bashBuildScript(installTarget: String) -> String {
        let quotedTarget = shellQuote(installTarget)
        let quotedPrimary = shellQuote(bashTarballPrimaryURL)
        let quotedFallback = shellQuote(bashTarballFallbackURL)
        let ver = bashVersion
        return """
        set -euo pipefail
        WORK="$(mktemp -d /tmp/nx2apple-bash5-XXXXXX)"
        trap 'rm -rf "$WORK"' EXIT
        TAR="$WORK/bash-\(ver).tar.gz"
        if ! /usr/bin/curl -fsSL --retry 2 --connect-timeout 20 \(quotedPrimary) -o "$TAR"; then
          /usr/bin/curl -fsSL --retry 2 --connect-timeout 20 \(quotedFallback) -o "$TAR"
        fi
        /usr/bin/tar -xzf "$TAR" -C "$WORK"
        cd "$WORK/bash-\(ver)"
        ./configure --without-bash-malloc --disable-nls
        /usr/bin/make -j8
        MAJOR="$("$WORK/bash-\(ver)/bash" -c 'echo "${BASH_VERSINFO[0]}"')"
        if [ -z "$MAJOR" ] || [ "$MAJOR" -lt 4 ]; then
          echo "Built bash version check failed: $MAJOR" >&2
          exit 1
        fi
        TARGET=\(quotedTarget)
        TARGET_DIR="$(dirname "$TARGET")"
        mkdir -p "$TARGET_DIR"
        TMP_BIN="$TARGET_DIR/.bash.tmp.$$"
        cp "$WORK/bash-\(ver)/bash" "$TMP_BIN"
        chmod 0755 "$TMP_BIN"
        mv -f "$TMP_BIN" "$TARGET"
        """
    }

    /// Finds an existing Bash >= 4 or downloads and builds GNU Bash 5.2.37 into
    /// `~/Library/Application Support/NX2Apple/tools/bin/bash`.
    package static func ensureModernBash(
        home: String = NSHomeDirectory(),
        candidates: [String]? = nil,
        runner: ProcessRunner = SystemProcessRunner(),
        fileManager fm: FileManager = .default,
        onLine: (@Sendable (String) -> Void)? = nil
    ) -> String? {
        if let found = findModernBash(
            candidates: candidates,
            home: home,
            runner: runner,
            exists: { fm.isExecutableFile(atPath: $0) }
        ) {
            return found
        }

        let target = managedBashPath(home: home)
        var env = ProxyEnvironment.merged(into: DependencyCheck.installEnvironment())
        env["HOME"] = home
        if let devDir = Toolchain.developerDir(runner: runner), !devDir.isEmpty {
            env["DEVELOPER_DIR"] = devDir
        }

        let cmd = ["/bin/bash", "-c", bashBuildScript(installTarget: target)]
        let ok: Bool
        if let onLine {
            ok = runner.runCaptured(cmd, env: env, line: onLine)
        } else {
            ok = runner.capture(ProcessLaunch(executable: "/bin/bash", arguments: ["-c", cmd[2]], environment: env)).ok
        }
        guard ok else { return nil }
        return findModernBash(
            candidates: [target],
            home: home,
            runner: runner,
            exists: { fm.isExecutableFile(atPath: $0) }
        )
    }

    package static func shimDirectory(in s2armTree: String) -> String {
        normalizedPrefix(s2armTree) + ".nx2apple-shims"
    }

    /// Symlinks `modernBash` at `<s2arm>/.nx2apple-shims/bash` and returns the shim directory path.
    @discardableResult
    package static func linkBashShim(
        modernBash: String,
        in s2armTree: String,
        fileManager fm: FileManager = .default
    ) -> String? {
        guard !modernBash.isEmpty, !s2armTree.isEmpty else { return nil }
        let dir = shimDirectory(in: s2armTree)
        let link = dir + "/bash"
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: link) || (try? fm.attributesOfItem(atPath: link)) != nil {
                try fm.removeItem(atPath: link)
            }
            try fm.createSymbolicLink(atPath: link, withDestinationPath: modernBash)
            return dir
        } catch {
            return nil
        }
    }

    // MARK: - 3. Build tools lookup and `build/rewriter-deps`

    /// Checks whether `cmake`, `meson`, and `ninja` exist alongside `python` or anywhere on `pathEnv`.
    package static func missingBuildTools(
        python: String,
        pathEnv: String,
        fileManager fm: FileManager = .default
    ) -> [String] {
        var dirs: [String] = []
        if !python.isEmpty {
            let pyBin = (python as NSString).deletingLastPathComponent
            if !pyBin.isEmpty { dirs.append(pyBin) }
        }
        dirs += pathEnv.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        return requiredBuildTools.filter { tool in
            !dirs.contains { dir in
                fm.isExecutableFile(atPath: normalizedPrefix(dir) + tool)
            }
        }
    }

    package static func rewriterDepsDirectory(in s2armTree: String) -> String {
        normalizedPrefix(s2armTree) + "build/rewriter-deps"
    }

    package static func isRewriterDepsReady(in s2armTree: String, fileManager fm: FileManager = .default) -> Bool {
        guard !s2armTree.isEmpty else { return false }
        let deps = normalizedPrefix(rewriterDepsDirectory(in: s2armTree))
        return fm.fileExists(atPath: deps + "capstone-5.0.7/src/CMakeLists.txt")
            && fm.fileExists(atPath: deps + "lz4-4.4.5/lz4libs/lz4.c")
    }

    /// Prepares `<s2arm>/build/rewriter-deps` via `runtime/rewriter/prepare_deps.py` when missing.
    /// Removes any partial `build/rewriter-deps` directory first so `prepare_deps.py` never refuses a stale tree.
    package static func ensureRewriterDeps(
        in s2armTree: String,
        python: String,
        environment: [String: String],
        runner: ProcessRunner = SystemProcessRunner(),
        fileManager fm: FileManager = .default,
        onLine: (@Sendable (String) -> Void)? = nil
    ) -> (ok: Bool, skipped: Bool, log: String) {
        guard !s2armTree.isEmpty else { return (false, false, "S2Arm directory is empty") }
        if isRewriterDepsReady(in: s2armTree, fileManager: fm) {
            return (true, true, "")
        }
        let script = normalizedPrefix(s2armTree) + "runtime/rewriter/prepare_deps.py"
        guard fm.fileExists(atPath: script) else {
            return (true, true, "")
        }

        let depsDir = rewriterDepsDirectory(in: s2armTree)
        if fm.fileExists(atPath: depsDir) {
            try? fm.removeItem(atPath: depsDir)
        }
        try? fm.createDirectory(
            atPath: (depsDir as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        let env = ProxyEnvironment.merged(into: environment)
        let launch = ProcessLaunch(
            executable: python,
            arguments: [script, depsDir],
            environment: env,
            directory: s2armTree
        )
        if let onLine {
            final class LineBox: @unchecked Sendable {
                private let lock = NSLock()
                var lines: [String] = []
                func add(_ line: String) {
                    lock.lock()
                    lines.append(line)
                    lock.unlock()
                }
            }
            let box = LineBox()
            let ok = runner.stream(launch) { line in
                box.add(line)
                onLine(line)
            }
            let combined = box.lines.joined(separator: "\n")
            return (ok && isRewriterDepsReady(in: s2armTree, fileManager: fm), false, combined)
        }
        let res = runner.capture(launch)
        let combined = res.out + (res.err.isEmpty ? "" : "\n" + res.err)
        return (res.ok && isRewriterDepsReady(in: s2armTree, fileManager: fm), false, combined)
    }
}
