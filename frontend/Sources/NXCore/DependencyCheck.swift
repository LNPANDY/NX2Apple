import Foundation

/// Looking at this Mac for what a build needs, as the rows of the dependency panel (`Dep`). The probing itself is `Toolchain`. This
/// is the list: which rows there are, in which order, and what each one runs to install. `DependencyStore` (NXModel) calls it.
package enum DependencyCheck {
    /// What one detection found: the rows, and the interpreter and the dotnet the build runs under.
    package struct Result {
        package var deps: [Dep]
        package var python: String
        package var dotnet: String   // empty when none runs

        package init(deps: [Dep], python: String, dotnet: String) {
            self.deps = deps; self.python = python; self.dotnet = dotnet
        }
    }

    /// The Metal toolchain row. A compiler that does not run is the missing-toolchain row with its install button. One that differs from the
    /// lock's pin is a warning and not a blocker: the row stays present, and its error and hint lines (the install failures' fields) say that
    /// NVN games will stop. Pure over its inputs, so tests give it version strings.
    package static func metalDep(runs: Bool, lock: String?, now: [String: String?], needsIOS: Bool) -> Dep {
        var dep = Dep(id: "metal", name: "dep.metal", hint: "dep.metal.hint", present: runs, installCmd: Toolchain.metalToolchainCmd)
        guard runs, let lock, let m = MetalPin.mismatches(lock: lock, now: now, iOS: needsIOS).first else { return dep }
        dep.warning = true
        dep.detail = "dep.metal.other:" + m.now + ":" + m.pinned
        dep.lastError = "metal_" + m.sdk + ": " + m.now
        dep.fixHint = "dep.fix.metalPin"
        return dep
    }

    /// The dotnet installer's command (into ~/.dotnet, where `Toolchain.findDotnet` looks).
    package static let dotnetInstallCmd = ["/bin/bash", "-c",
        "curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/di.sh && chmod +x /tmp/di.sh && /tmp/di.sh --channel 10.0 --install-dir $HOME/.dotnet"]

    /// The rows. `needsIOS`: the xcode row asks for the iOS SDK. `repo`: the checkout whose lock pins the Metal compiler ("" for none).
    package static func detect(needsIOS: Bool, repo: String = "") -> [Dep] {
        var out: [Dep] = []

        // Xcode.app alone is not enough: since Xcode 15 the iOS platform ships as a separate
        // download, so a fresh install has xcodebuild but no iOS SDK and the build dies deep in
        // xcodebuild. Ask for the SDK version itself — that is the check that matches the name.
        // And ask xcode-select where Xcode is, not a fixed path: a beta lives at
        // /Applications/Xcode-beta.app and the hard-coded check called that "no Xcode" (#21).
        let selected = Toolchain.developerDir()
        let xcodeApp = Toolchain.installedXcode()
        let sdkenv = Toolchain.runOK("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-version"])
        // A Mac-only setup does not need the iOS platform (onboarding's platform choice, #120); a
        // Mac build still needs a selected Xcode, so the CommandLineTools state is reported either way.
        switch Toolchain.xcodeState(selected: selected, xcodeApp: xcodeApp, iosSDK: !needsIOS || sdkenv) {
        case .ready:
            out.append(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: true, installCmd: []))
        case .noIOSSDK:
            out.append(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false,
                           detail: "dep.xcode.noSDK", installCmd: Toolchain.iosPlatformCmd))
        case .commandLineToolsOnly(let xcode):
            out.append(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false,
                           detail: "dep.xcode.notSelected", actionLabel: "dep.xcode.fix",
                           installCmd: Toolchain.selectXcodeCmd(xcode)))
        case .notInstalled:
            out.append(Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: false, installCmd: []))
        }

        let macMetal = Toolchain.firstOutputLine("/usr/bin/xcrun", ["-sdk", "macosx", "metal", "--version"])
        let lock = repo.isEmpty ? nil : try? String(contentsOfFile: EngineLayout.root(repo) + "/" + MetalPin.lockPath, encoding: .utf8)
        let iosMetal = needsIOS && lock != nil ? Toolchain.firstOutputLine("/usr/bin/xcrun", ["-sdk", "iphoneos", "metal", "--version"]) : nil
        out.append(metalDep(runs: macMetal != nil, lock: lock, now: ["macosx": macMetal, "iphoneos": iosMetal], needsIOS: needsIOS))

        out += Toolchain.toolDeps(resources: BundledTools.resources,
                        installed: { Toolchain.firstExisting(["/opt/homebrew/bin/\($0)", "/usr/local/bin/\($0)"]) },
                        brew: Toolchain.firstExisting(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]))

        let (dn, dnOK) = Toolchain.findDotnet()
        out.append(Dep(id: "dotnet", name: "dep.dotnet", hint: "dep.dotnet.hint",
                       present: dnOK, detail: dnOK ? dn : "dep.dotnet.missing",
                       installCmd: dotnetInstallCmd))

        let (py, pyOK) = Toolchain.findPython()
        // A too-old interpreter is a different problem from a missing package: say which one it is,
        // because the fix differs (install a newer Python vs pip install into this one).
        // A version we cannot read means no interpreter ran at all (py is then the venv
        // that does not exist yet), which is not the same as one that is too old.
        let pyDetail = Toolchain.pythonDetail(py: py, ok: pyOK)
        out.append(Dep(id: "python", name: "dep.python", hint: "dep.python.hint",
                       present: pyOK, detail: pyDetail,
                       installCmd: [py, "-m", "pip", "install", "--user", "lz4", "capstone", "fonttools", "zbic", "backports.zstd"]))
        return out
    }

    /// The rows and the paths of the interpreter and of dotnet the build runs under.
    package static func scan(needsIOS: Bool, repo: String) -> Result {
        let deps = detect(needsIOS: needsIOS, repo: repo)
        let (py, _) = Toolchain.findPython()
        let (dn, _) = Toolchain.findDotnet()
        return Result(deps: deps, python: py, dotnet: FileManager.default.isExecutableFile(atPath: dn) ? dn : "")
    }

    /// Write what the panel just decided beside library.json (`deps-check.txt`).
    ///
    /// The panel is the only place those verdicts appear, so "it says Python is missing" cannot be
    /// checked afterwards: the interpreter that was tried, and the environment a Finder launch
    /// gives the app (its PATH is /usr/bin:/bin:/usr/sbin:/sbin, unlike the terminal's), are both
    /// invisible in a bug report. This file has them — paths and versions only, never key material.
    package static func writeReport(_ deps: [Dep], appVersion: String) {
        let dir = (Toolchain.venvDir as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var out = "NX2Apple \(appVersion) dependency check\n"
        out += "date: \(ISO8601DateFormatter().string(from: Date()))\n"
        out += "HOME: \(NSHomeDirectory())\n"
        out += "PATH: \(ProcessInfo.processInfo.environment["PATH"] ?? "(unset)")\n"
        let chosen = Toolchain.findPython()
        let bundled = BundledTools.python()
        out += "python chosen: \(chosen.path) (\(chosen.ok ? "ok" : "not usable")\(chosen.path == bundled ? ", bundled with the app" : ""))\n"
        out += "bundled python: \(bundled ?? "(none: not the release app)")\n"
        out += "python candidates (after the bundled one, in search order):\n"
        for c in Toolchain.pythonCandidates() { out += "  \(c)\n" }
        out += "rows:\n"
        for d in deps { out += "  \(d.id): \(d.present ? "ok" : "MISSING") \(d.detail)\n" }
        try? out.write(toFile: dir + "/deps-check.txt", atomically: true, encoding: .utf8)
    }

    /// The command line of an install, run by bash: words with a space are quoted.
    package static func shellCommand(_ cmd: [String]) -> [String] {
        ["/bin/bash", "-c", cmd.map { $0.contains(" ") ? "'" + $0 + "'" : $0 }.joined(separator: " ")]
    }

    /// The environment an install runs in: Homebrew's folders in front, and no prompt.
    package static func installEnvironment() -> [String: String] {
        ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
         "HOME": NSHomeDirectory(), "NONINTERACTIVE": "1", "USER": NSUserName()]
    }
}
