import Foundation

/// One row of the dependency panel.
package struct Dep: Identifiable {
    package let id: String
    package let name: String      // an L10n key
    package let hint: String      // an L10n key
    package var present: Bool
    package var installing = false
    package var detail = ""
    package var lastError = ""   // the tool's own first error line after a failed install (brew's, pip's)
    package var fixHint = ""     // an L10n key: what to type or click, chosen from that line
    package var actionLabel = "" // an L10n key for the button when the action is not a plain install ("Fix")
    package var warning = false  // present, but with a caveat the row's error and hint lines explain (the Metal compiler is not the tested one)
    package let installCmd: [String]      // run via bash; empty = manual (Xcode from the App Store)

    package init(id: String, name: String, hint: String, present: Bool, installing: Bool = false, detail: String = "",
                 lastError: String = "", fixHint: String = "", actionLabel: String = "", warning: Bool = false,
                 installCmd: [String]) {
        self.id = id; self.name = name; self.hint = hint; self.present = present; self.installing = installing
        self.detail = detail; self.lastError = lastError; self.fixHint = fixHint; self.actionLabel = actionLabel
        self.warning = warning; self.installCmd = installCmd
    }
}

/// Probing this Mac for what a build needs: Python and its venv, dotnet, Xcode and the Homebrew tools. A GUI app does not inherit the
/// shell's PATH, so these look in the places the tools live. The rows they make are `Dep`. Pure over their inputs where they can be
/// (`xcodeState`, `parseDotnetRoot`, `toolDeps`, `pythonDetail`), the rest runs the tools and reads the disk.
package enum Toolchain {
    /// A GUI app does not inherit the shell's PATH, so look where the tools actually
    /// live instead of trusting `which` — that is why .NET (in ~/.dotnet) and the
    /// Python packages (in /usr/local/bin/python3, not /usr/bin/python3) used to show
    /// as missing while a terminal could see them.
    package static func runOK(_ tool: String, _ args: [String], env: [String: String]? = nil) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let env { p.environment = env }
        p.standardOutput = Pipe(); p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    package static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The Python that actually has lz4/capstone/fontTools/zbic/backports.zstd — the one
    /// the build must run under, not whatever /usr/bin/python3 happens to be.
    /// The minimum the build scripts need. /usr/bin/python3 is 3.9 on a stock Mac and has none of
    /// the packages; picking it made a build fail with a syntax error deep inside the script
    /// (an f-string only 3.12 can parse) instead of a clear message here.
    ///
    /// 3.12 is the script's own floor, not a guess: build_ipa_from_nsp.py:1911 raises "Direct
    /// RomFS image builds require Python 3.12 or newer". This said 3.9 — the comment above even
    /// said 3.12 — so findPython() was happy to return Apple's 3.9 and the build then died inside
    /// the script with a message the user could not act on (issue #53).
    package static let minPython = (3, 12)

    /// The Homebrew formulae the dependency check offers, with the localization key of each row. The repo-root
    /// Brewfile lists the same formulae (BrewfileTests keeps the two equal).
    /// `binary` is the file the formula puts in the Homebrew bin folder (glslang installs glslangValidator, which the
    /// NSP script's environment check requires).
    package static let brewDeps: [(formula: String, binary: String, key: String)] = [
        ("xcodegen", "xcodegen", "dep.xcodegen"),
        ("zstd", "zstd", "dep.zstd"),
        ("spirv-cross", "spirv-cross", "dep.spirv"),
        ("glslang", "glslangValidator", "dep.glslang"),
    ]

    /// The interpreter probe: lz4 / capstone / fontTools / zbic always, and zstd from either source —
    /// `compression.zstd` is built in from Python 3.14 and `backports.zstd` (which declares
    /// Python < 3.14) is the only option before that. Requiring the backport unconditionally
    /// rejected an otherwise working Homebrew Python 3.15 (issue #1).
    /// zbic is required although only a game with system 22.0.0+ modules (ZBIC segments, Nintendo's zstd variant) needs it:
    /// the launcher cannot know that before the extraction, and the build stops late without it (issue #251).
    /// nsz is deliberately not required here: it is only needed for NSZ / XCZ dumps, and the
    /// pipeline says so by name when one shows up. The venv installs it anyway so that a player
    /// who downloads a compressed dump never meets that error.
    package static let importProbe = """
        import lz4, capstone, fontTools, zbic
        try:
            from compression import zstd
        except ImportError:
            from backports import zstd
        """

    /// The interpreter the packages are installed into when no system Python has them. A venv
    /// rather than `pip install --user`: Homebrew's Python is externally managed (PEP 668) and
    /// refuses --user, and this leaves the user's environment untouched. Injectable so tests can
    /// use a scratch directory.
    package static var venvDir = NSHomeDirectory() + "/Library/Application Support/NS Port Builder/venv"

    package static func venvPython() -> String { venvDir + "/bin/python3" }

    /// Where uv keeps the Pythons it installs (`uv python install`): the shims in `~/.local/bin`
    /// and the store the real binaries live in, which `UV_PYTHON_INSTALL_DIR` moves. A uv user
    /// often has neither python.org's framework nor Homebrew, and a GUI launch's PATH is
    /// /usr/bin:/bin:/usr/sbin:/sbin, so neither `which` nor the locations below see them: a
    /// working uv Python 3.12 was reported as "No Python 3.12 or newer found". Injectable so a
    /// test can point them at a scratch tree.
    package static var uvShimDir = NSHomeDirectory() + "/.local/bin"
    package static var uvPythonRoot: String = {
        let dir = ProcessInfo.processInfo.environment["UV_PYTHON_INSTALL_DIR"] ?? ""
        return dir.isEmpty ? NSHomeDirectory() + "/.local/share/uv/python" : dir
    }()

    /// Where mise and asdf keep the Pythons they install, and mise's shims. `MISE_DATA_DIR` and
    /// `ASDF_DATA_DIR` move them. A GUI launch's PATH does not include the shims directory, so a
    /// Python managed by either was not found at all (issue #113). Injectable for tests.
    package static var miseDataDir: String = {
        let dir = ProcessInfo.processInfo.environment["MISE_DATA_DIR"] ?? ""
        return dir.isEmpty ? NSHomeDirectory() + "/.local/share/mise" : dir
    }()
    package static var asdfDataDir: String = {
        let dir = ProcessInfo.processInfo.environment["ASDF_DATA_DIR"] ?? ""
        return dir.isEmpty ? NSHomeDirectory() + "/.asdf" : dir
    }()

    package static func importsOK(_ py: String) -> Bool {
        runOK(py, ["-c", importProbe], env: ProcessInfo.processInfo.environment.merging(BundledTools.environment(for: py)) { $1 })
    }

    /// backports.zstd declares Python < 3.14, so it is only installed where it is needed.
    /// nsz is always installed: NSZ / XCZ dumps are accepted by the pipeline now, and a player who
    /// downloads one should not have to run pip by hand (it is a few hundred KB).
    package static func pipPackages(_ version: (Int, Int)) -> [String] {
        version < (3, 14) ? ["lz4", "capstone", "fonttools", "zbic", "backports.zstd", "nsz"]
                          : ["lz4", "capstone", "fonttools", "zbic", "nsz"]
    }

    /// Create the venv (reusing an existing one) and install the packages into it. Returns the
    /// combined output so a failure can be shown instead of swallowed — the pip output used to go
    /// to a pipe nobody read, and `externally-managed-environment` never reached the user.
    package static func makeVenv(base: String) -> (ok: Bool, log: String) {
        var log = ""
        func run(_ exe: String, _ args: [String]) -> Bool {
            let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
            p.environment = ["PATH": BundledTools.path("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", python: base), "HOME": NSHomeDirectory()].merging(BundledTools.environment(for: base)) { $1 }
            do { try p.run() } catch { log += "could not start \(exe): \(error.localizedDescription)\n"; return false }
            // both pipes are drained on this thread (before waitUntilExit, so the child cannot
            // block on a full pipe), and the log string keeps a single owner
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            log += String(data: outData, encoding: .utf8) ?? ""
            log += String(data: errData, encoding: .utf8) ?? ""
            return p.terminationStatus == 0
        }
        let vpy = venvPython()
        // An existing venv below minPython (built from Apple's 3.9 by an older app, issue #75) is
        // moved aside and rebuilt: pip into it would "succeed" and the build would still fail.
        // Moved, never deleted, because the folder is the user's. Only when a usable base exists,
        // so a Mac with no new Python keeps its old venv instead of losing it for nothing.
        if FileManager.default.isExecutableFile(atPath: vpy), pythonVersion(vpy).map({ $0 < minPython }) ?? true {
            guard let interp = venvBase(preferred: base), interp != vpy else {
                return (false, log + "\(venvDir) is older than Python \(minPython.0).\(minPython.1) and no newer Python was found to rebuild it from\n")
            }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = venvDir + ".old-" + stamp
            do { try FileManager.default.moveItem(atPath: venvDir, toPath: aside) } catch {
                return (false, log + "could not move \(venvDir) aside: \(error.localizedDescription)\n")
            }
            log += "moved the old venv (Python below \(minPython.0).\(minPython.1)) to \(aside)\n"
        }
        if !FileManager.default.isExecutableFile(atPath: vpy) {
            // findPython() returns the venv path it hopes to create when no interpreter was
            // found, and the panel hands that to this function. It cannot be a base: `-m venv`
            // failed with "could not start …" and the Python row never recovered.
            guard let interp = venvBase(preferred: base) else {
                return (false, log + "no Python \(minPython.0).\(minPython.1) or newer to create \(venvDir) from\n")
            }
            if interp != base { log += "\(base) is not a usable interpreter; using \(interp)\n" }
            log += "$ \(interp) -m venv \(venvDir)\n"
            try? FileManager.default.createDirectory(atPath: (venvDir as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard run(interp, ["-m", "venv", venvDir]) else { return (false, log + "venv creation failed\n") }
        }
        let pkgs = pipPackages(pythonVersion(vpy) ?? minPython).joined(separator: " ")
        log += "$ \(vpy) -m pip install \(pkgs)\n"
        let ok = run(vpy, ["-m", "pip", "install"] + pipPackages(pythonVersion(vpy) ?? minPython))
        return (ok && importsOK(vpy), log)
    }

    /// "3.12.4" → (3, 12). nil when the interpreter cannot be run.
    package static func pythonVersion(_ path: String) -> (Int, Int)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-c", "import sys; print('%d.%d' % sys.version_info[:2])"]
        p.environment = ProcessInfo.processInfo.environment.merging(BundledTools.environment(for: path)) { $1 }
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
        return (a, b)
    }

    /// The interpreter to create the venv from. `preferred` is what the panel picked; when
    /// findPython() found nothing that is the venv path it hopes to create, which cannot be a
    /// base (see makeVenv). So a base that does not run at the required version falls back to
    /// the newest candidate that does. nil when this Mac has no such interpreter at all.
    package static func venvBase(preferred: String) -> String? {
        if FileManager.default.isExecutableFile(atPath: preferred),
           let v = pythonVersion(preferred), v >= minPython {
            return preferred
        }
        return pythonCandidates().first {
            FileManager.default.isExecutableFile(atPath: $0)
                && (pythonVersion($0).map { $0 >= minPython } ?? false)
        }
    }

    /// The `python3` / `python3.x` names in a directory, newest version first.
    package static func pythonNames(in dir: String, matching pattern: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.range(of: pattern, options: .regularExpression) != nil }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    /// uv's managed Pythons: the shims in `uvShimDir` and every install under `uvPythonRoot`
    /// (`cpython-3.12.13-macos-aarch64-none/bin/python3.12`). A uv user often has neither
    /// python.org's framework nor Homebrew, and a GUI launch's PATH does not contain
    /// `~/.local/bin`, so nothing else on this Mac finds them.
    package static func uvPythonCandidates() -> [String] {
        var out = pythonNames(in: uvShimDir, matching: #"^python3(\.\d+)?$"#).map { uvShimDir + "/" + $0 }
        let installs = (try? FileManager.default.contentsOfDirectory(atPath: uvPythonRoot)) ?? []
        for d in installs.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
            let bin = uvPythonRoot + "/" + d + "/bin"
            out += pythonNames(in: bin, matching: #"^python3(\.\d+)?$"#).map { bin + "/" + $0 }
        }
        return out
    }

    /// Pythons managed by mise (installs, then its shims) and asdf (installs only: an asdf shim is
    /// a script that needs `asdf` on the PATH, which a GUI launch lacks). Only the interpreter
    /// names are taken, never `python3-config` and the other files that share the folder.
    package static func versionManagerPythonCandidates() -> [String] {
        var out: [String] = []
        let strict = #"^python3(\.\d+)?$"#
        for root in [miseDataDir + "/installs/python", asdfDataDir + "/installs/python"] {
            let installs = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for d in installs.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                let bin = root + "/" + d + "/bin"
                out += pythonNames(in: bin, matching: strict).map { bin + "/" + $0 }
            }
        }
        let shims = miseDataDir + "/shims"
        out += pythonNames(in: shims, matching: strict).map { shims + "/" + $0 }
        return out
    }

    /// Every interpreter a build could run under, best first: python.org's framework, Homebrew,
    /// /usr/local, uv's store, mise and asdf, then whatever `which` can see. Probed by hand because a GUI app
    /// does not inherit the shell's PATH — the same reason .NET (in ~/.dotnet) used to show as
    /// missing while a terminal saw it.
    package static func pythonCandidates() -> [String] {
        var cands: [String] = []
        let fw = "/Library/Frameworks/Python.framework/Versions"
        if let vers = try? FileManager.default.contentsOfDirectory(atPath: fw) {
            for v in vers.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                cands.append(fw + "/" + v + "/bin/python3")
            }
        }
        cands += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        // Homebrew's python@3.x is always python3.x, but the bare python3 link exists only for
        // the formula that is linked: a 3.12 beside an unlinked default would go unseen.
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            cands += pythonNames(in: dir, matching: #"^python3\.\d+$"#).map { dir + "/" + $0 }
        }
        cands += uvPythonCandidates()
        cands += versionManagerPythonCandidates()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["-a", "python3"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            cands += out.split(separator: "\n").map(String.init)
        }
        return cands
    }

    /// Every python3 on this Mac, newest-looking first, each tried for a usable version and the
    /// packages. Returns the one to build with, plus why the others were rejected for the message.
    package static func findPython(resources: URL? = BundledTools.resources) -> (path: String, ok: Bool) {
        // The release app's own Python (BundledTools.swift) has every package and is the one the build is tested with: it wins over
        // any Python on this Mac and needs no venv. One that does not run (a damaged copy) falls through to the search below
        // (uv's Pythons, the other candidates, then the venv).
        if let bundled = BundledTools.python(in: resources), pythonVersion(bundled).map({ $0 >= minPython }) == true, importsOK(bundled) {
            return (bundled, true)
        }
        var seen = Set<String>()
        var fallback: (String, (Int, Int))? = nil   // newest with an acceptable version but no packages
        for c in pythonCandidates() where !c.isEmpty && seen.insert(c).inserted {
            guard FileManager.default.isExecutableFile(atPath: c), let v = pythonVersion(c) else { continue }
            guard v >= minPython else { continue }
            if importsOK(c) { return (c, true) }
            if fallback == nil || v > fallback!.1 { fallback = (c, v) }
        }
        // No system interpreter has the packages: the venv (existing, or created by 安装) is next.
        let vpy = venvPython()
        // A venv below minPython is not ready however complete its packages are: an older app
        // version made it from Apple's 3.9, and the build script refuses that (issue #75). It
        // falls through to the candidates above, or to the row saying the Python is too old.
        if FileManager.default.isExecutableFile(atPath: vpy), let v = pythonVersion(vpy), v >= minPython {
            if importsOK(vpy) { return (vpy, true) }
            return (vpy, false)   // exists but incomplete: 安装 finishes it
        }
        return (fallback?.0 ?? vpy, false)
    }

    /// The runtime root of a dotnet installation, parsed from `dotnet --list-runtimes`. It cannot
    /// be assumed to be the binary's directory: Homebrew's /opt/homebrew/bin/dotnet is a symlink
    /// into Cellar, and the runtime lives in …/libexec, so a hardcoded ~/.dotnet left the apphost
    /// without a runtime and nx_extract died with exit code 131 (issue #2).
    package static func parseDotnetRoot(_ listRuntimes: String) -> String? {
        for ln in listRuntimes.split(separator: "\n") {
            guard ln.hasPrefix("Microsoft.NETCore.App"), let a = ln.firstIndex(of: "["), let b = ln.lastIndex(of: "]") else { continue }
            let p = String(ln[ln.index(after: a)..<b])
            for suffix in ["/shared/Microsoft.NETCore.App", "\\shared\\Microsoft.NETCore.App"] where p.hasSuffix(suffix) {
                return String(p.dropLast(suffix.count))
            }
            return p
        }
        return nil
    }

    package static func dotnetRoot(for dotnet: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: dotnet)
        p.arguments = ["--list-runtimes"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = Pipe(); p.standardInput = FileHandle.nullDevice
        p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // No directory fallback: for Homebrew's symlink layout the binary's directory is not the root,
        // and a wrong DOTNET_ROOT is worse than none (the apphost stops searching once it is set).
        // When this returns nil the pipeline derives and verifies a root itself.
        return parseDotnetRoot(out)
    }

    package static func findDotnet() -> (path: String, ok: Bool) {
        let cands = [NSHomeDirectory() + "/.dotnet/dotnet",
                     "/usr/local/share/dotnet/dotnet",
                     "/opt/homebrew/bin/dotnet",
                     "/usr/local/bin/dotnet"]
        if let d = firstExisting(cands) {
            // the extractor targets net10.0, so an SDK (not just a runtime) is needed
            let ok = runOK(d, ["--list-sdks"], env: ["DOTNET_ROOT": (d as NSString).deletingLastPathComponent,
                                                      "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(),
                                                      "TMPDIR": NSTemporaryDirectory()])
            return (d, ok)
        }
        return ("dotnet", false)
    }

    /// Whether the selected developer directory exists (`xcode-select -p`), which is the same
    /// source of truth xcodebuild and xcrun use — so an Xcode beta, a custom location, or a
    /// Command Line Tools-only setup is reported for what it is instead of "no Xcode".
    package static func developerDir() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let dir = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dir.isEmpty else { return nil }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue ? dir : nil
    }

    package static func developerDirExists() -> Bool { developerDir() != nil }

    /// An Xcode.app that is installed but not selected: an App Store download arrives as
    /// /Applications/Xcode.app and stays unused until someone opens it or points xcode-select at
    /// it, so `xcode-select -p` keeps saying CommandLineTools and xcodebuild fails later.
    package static func installedXcode() -> String? {
        for app in ["/Applications/Xcode.app", "/Applications/Xcode-beta.app"]
        where FileManager.default.isExecutableFile(atPath: app + "/Contents/Developer/usr/bin/xcodebuild") {
            return app
        }
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        for name in apps.sorted() where name.hasPrefix("Xcode") && name.hasSuffix(".app") {
            let app = "/Applications/" + name
            if FileManager.default.isExecutableFile(atPath: app + "/Contents/Developer/usr/bin/xcodebuild") { return app }
        }
        return nil
    }

    /// What the Xcode row is looking at: the selected developer directory, the Xcode that is only
    /// installed, and whether the iOS SDK answers. Pure, so the four cases are tested.
    package enum XcodeState: Equatable {
        case ready
        case noIOSSDK(selected: String)              // Xcode selected, its iOS platform not downloaded
        case commandLineToolsOnly(xcode: String)     // Xcode.app installed, xcode-select still on the CLT
        case notInstalled
    }

    package static func xcodeState(selected: String?, xcodeApp: String?, iosSDK: Bool) -> XcodeState {
        if let selected, selected.contains(".app/Contents/Developer") {
            return iosSDK ? .ready : .noIOSSDK(selected: selected)
        }
        if let xcodeApp { return .commandLineToolsOnly(xcode: xcodeApp) }
        return iosSDK ? .ready : .notInstalled   // a CLT whose xcrun does answer the SDK is usable
    }

    /// The commands that fetch Xcode's two downloadable parts; the setup panel and the guided setup run the same ones.
    package static let metalToolchainCmd = ["/usr/bin/xcodebuild", "-downloadComponent", "MetalToolchain"]
    package static let iosPlatformCmd = ["/usr/bin/xcodebuild", "-downloadPlatform", "iOS"]

    /// One admin prompt runs both steps: switch the toolchain to this Xcode, then let it finish its first launch (license and
    /// components) - a fresh App Store download has neither. The Xcode row and the failure card run the same command.
    package static func selectXcodeCmd(_ xcode: String) -> [String] {
        let script = "xcode-select -s '" + xcode + "/Contents/Developer' && xcodebuild -runFirstLaunch"
        let apple = "do shell script \"" + script.replacingOccurrences(of: "\"", with: "\\\"") + "\" with administrator privileges"
        return ["/usr/bin/osascript", "-e", apple]
    }

    /// The rows for the build tools (xcodegen, zstd, spirv-cross, glslangValidator) and the Homebrew row they may need.
    /// A tool the app carries counts as present and says "bundled"; otherwise Homebrew's copy counts (`installed` answers
    /// a binary name with its path in a Homebrew folder, or nil). The Homebrew row appears only when some tool is neither
    /// bundled nor installed (with a bundle; with none the row stays, as before): it is the way to get that one.
    package static func toolDeps(resources: URL?, installed: (String) -> String?, brew: String?) -> [Dep] {
        var rows: [Dep] = []
        var needsBrew = false, anyBundled = false
        for (pkg, binary, key) in brewDeps {
            let bundled = BundledTools.tool(binary, in: resources) != nil
            let path = bundled ? nil : installed(binary)
            if !bundled && path == nil { needsBrew = true }
            if bundled { anyBundled = true }
            // A bundled tool is named by the tool; "brew: …" says where a Homebrew copy comes from, so it stays for the rows that
            // refer to one (installed there, or missing with the install button)
            rows.append(Dep(id: "brew:" + pkg, name: bundled ? "dep.tool." + binary : key, hint: key + ".hint", present: bundled || path != nil,
                            detail: bundled ? "dep.bundled" : (path ?? ""),
                            installCmd: [(brew ?? "/opt/homebrew/bin/brew"), "install", pkg]))
        }
        guard needsBrew || !anyBundled else { return rows }   // without a bundle the row is always there, as it was
        return [Dep(id: "brew", name: "dep.brew", hint: "dep.brew.hint", present: brew != nil,
                    installCmd: ["/bin/bash", "-c",
                      "NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""])] + rows
    }

    /// First line of a tool's output (the Metal compiler's version line), nil when it does not run or says nothing.
    package static func firstOutputLine(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out; p.standardError = Pipe(); p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
    }

    package static func pythonDetail(py: String, ok: Bool) -> String {
        let pyVer = pythonVersion(py).map { "\($0.0).\($0.1)" } ?? "?"
        let minVer = "\(minPython.0).\(minPython.1)"
        return ok ? (py == BundledTools.python() ? "dep.bundled" : py)
            : pythonVersion(py).map { $0 >= minPython
                ? "dep.python.missing:\(py) (\(pyVer))"
                : "dep.python.old:\(pyVer):\(minVer)" }
            ?? "dep.python.notFound:\(minVer):\(minVer)"
    }
}
