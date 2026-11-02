import Foundation
import Combine
import NXCore

// The build run: the script's arguments and environment, the process, and what happens when it ends (LNPANDY/NX2Apple#387).

extension BuildStore {
    package func startBuild() {
        guard !running else { return }
        // The shared app needs a device this Mac knows. Found out here, before an hour of building, not after it.
        if target != BuildTarget.mac, !shellDeviceChecked {
            guard installsDirectly else { doneNote = t("shell.needsDevice"); done = false; return }
            verifyShellDevice()
            return
        }
        shellDeviceChecked = false
        if target != BuildTarget.mac, askAboutStaleFrameworks() { return }   // StaleFrameworksPrompt.swift (#449)
        stopping = false
        running = true; done = false; doneNote = ""; stages = []; log.clear(); chainNoteShown = false
        failure = nil; confirmingOverride = nil
        let override = takeOverrideFlag()   // for this build only: the next one asks again
        installedOn = ""; installedAppPath = ""
        guard repo.isRepo else {
            fail(repo.path.isEmpty ? t("msg.repoInvalidEmpty") : String(format: t("msg.repoInvalid"), shortPath(repo.path)))
            return
        }
        // Resolve the interpreter here if the dependency check has not landed yet. checkDeps()
        // runs on a background queue and startBuild() can beat it — for a moment deps.pythonPath is
        // empty, and the old fallback was Apple's /usr/bin/python3 (3.9), which the script then
        // rejected with "require Python 3.12 or newer" whatever the machine actually had (#53).
        let py = deps.pythonPath.isEmpty ? Toolchain.findPython().path : deps.pythonPath
        // engine/ is the only engine and is stale or missing (#214): make it, then start again
        if EngineLayout.needsSyncBeforeBuild(repo.path) {
            _ = engine.syncEngine { ok in
                self.running = false
                if ok && !EngineLayout.needsSyncBeforeBuild(self.repo.path) { self.startBuild() }
                else { self.fail(String(format: self.t("msg.toolsOld"), "engine/ (python3 tools/engine.py sync, see the log)")) }
            }
            return
        }
        // The tools this app runs, before a build that takes an hour finds one missing at its last step (#87)
        let missing = RepoLayout.missingTools(in: repo.path)
        if !missing.isEmpty {
            fail(String(format: t("msg.toolsOld"), missing.joined(separator: ", ")))
            return
        }

        // One folder when everything lives together; otherwise a staging folder of symlinks. A folder
        // that holds other games too (a ROMs folder with one file per game) is staged as well: the
        // script takes one game per folder and refuses one with several ("more than one game in the
        // folder"), even when only the base game was picked (issue #58; ufooer's PR #31).
        let baseDir = (basePath as NSString).deletingLastPathComponent
        let allPaths = [basePath, updatePath] + dlcPaths
        let dirs = Set(allPaths.filter { !$0.isEmpty }.map { ($0 as NSString).deletingLastPathComponent })
        let picked = Set(allPaths.filter { !$0.isEmpty }.map { ($0 as NSString).lastPathComponent })
        let unpicked = ((try? FileManager.default.contentsOfDirectory(atPath: baseDir)) ?? []).filter {
            ["nsp", "xci", "nsz", "xcz"].contains(($0 as NSString).pathExtension.lowercased()) && !picked.contains($0)
        }
        // Staged, the folder's own update and add-on content would be left behind, where the script
        // used to find them unpicked: bring along those whose file name carries this game's title ID
        // exactly as build_ipa_from_nsp.py:445 reads it: the low 12 bits are 0x000 for a base game,
        // 0x800 for its update, and anything else is add-on content below the base.
        var staged = allPaths
        if let base = TitleID.parse((basePath as NSString).lastPathComponent) {
            let app = base & ~0xFFF
            for f in unpicked {
                guard let tid = TitleID.parse(f) else { continue }
                let low = tid & 0xFFF
                let owner = low == 0 ? tid : (low == 0x800 ? tid & ~0xFFF : (tid & ~0xFFF) - 0x1000)
                guard owner == app else { continue }
                if low == 0x800 && !updatePath.isEmpty { continue }   // the update was picked already
                if low != 0 && low != 0x800 && tid <= app { continue }   // add-on content sits above its base
                staged.append(baseDir + "/" + f)
            }
        }
        let tidHex = TitleID.buildKey(basePath)
        let workDir = (outDir.isEmpty ? baseDir : outDir) + "/" + tidHex + "_build"
        // The build's signing step refuses the attributes a cloud folder adds, after the long steps: stop here instead.
        if cloudFolderCheck(workDir) {
            failure = BuildFailure(kind: .cloudFolder, gameName: nil, detail: workDir)
            fail(failureWhat(failure!))
            return
        }
        var inputDir = baseDir
        if dirs.count > 1 || !unpicked.isEmpty {
            // A stable folder per game (#132): the script's fingerprints name its files and its profile path.
            let tmp = InputStaging.folder(workDir: workDir)
            let linked = InputStaging.sync(files: staged, into: tmp)
            if linked == 0 { fail(t("msg.stagingFailed")); return }
            staging = tmp; inputDir = tmp
            if !unpicked.isEmpty {
                say(String(format: t("msg.stagedFromSharedFolder"), (basePath as NSString).lastPathComponent))
            }
        } else { staging = nil }

        // This fork's --work-dir keeps the build folder (extracted files, shader cache, the romfs
        // archive) outside the NSPs' folder. An upstream checkout or an older ZIP does not have the
        // option and would stop with "unrecognized arguments" (issue #5), so ask the script; without
        // it the script's own default (<input>/<title ID>_build) is used and the archive step follows
        // whatever folder the build reports.
        let hasWorkDir = RepoLayout.supportsWorkDir(repo.path)
        if !hasWorkDir {
            say(t("msg.noWorkDir"))
        }
        // A compressed dump (NSZ / XCZ) needs nsz in the interpreter the build runs under; it is not
        // part of the dependency probe (most builds never see one), so install it here, once, only
        // when such a file is actually selected — otherwise the build stops with "pip install nsz".
        let compressed = ([basePath, updatePath] + dlcPaths).contains {
            let e = ($0 as NSString).pathExtension.lowercased()
            return e == "nsz" || e == "xcz"
        }
        if compressed, !Toolchain.runOK(py, ["-c", "import nsz"]) {
            say(t("msg.installingNsz"))
            let r = runner.runCaptured([py, "-m", "pip", "install", "nsz"],
                                     env: ["PATH": BuildCommands.toolPath(python: py),
                                           "HOME": NSHomeDirectory()].merging(BundledTools.environment(for: py)) { $1 }) { @Sendable line in
                hop { self.append(line + "\n") }
            }
            if !r {
                fail(String(format: t("msg.nszFailed"), py))
                return
            }
        }
        let engine = EngineLayout.root(repo.path)   // the checkout's engine/ (#214)
        var args = [engine + "/" + RepoLayout.buildScript, inputDir, "-k", keysPath,
                    "--progress", "json"]
        // A compatibility switch the player turned on: written to a small env file the pipeline
        // copies into the app bundle (main.m sets one variable per line at boot). Only for an iPhone or iPad build;
        // a Mac app runs on this Mac's GPU, which always has BC support.
        if bcOnCPU && target != BuildTarget.mac {
            let envPath = NSTemporaryDirectory() + "nspb-env-\(UUID().uuidString.prefix(8)).txt"
            do {
                try "DM_TEX_BC_CPU=1\n".write(toFile: envPath, atomically: true, encoding: .utf8)
                args += ["--env-file", envPath]
                say(t("msg.bcOn"))
            } catch {
                say(String(format: t("msg.bcEnvFailed"), error.localizedDescription))
            }
        }
        if hasWorkDir { args += ["--work-dir", workDir] }
        let macApp = target == BuildTarget.mac
        if macApp {
            // -o names the .app; the RomFS goes inside it, so the archive step is skipped below.
            args += ["--platform", "mac-app"]
            macAppPath = (outDir.isEmpty ? baseDir : outDir) + "/" + tidHex + ".app"
            args += ["-o", macAppPath]
        } else {
            // Only the game's framework: the one shared app is made and signed after the script (installShell)
            args += ShellInstall.buildArguments(workDir: workDir, team: devices.signingTeam)
        }
        // The archive step packs whatever folder the build reported; without --work-dir that is the
        // script's default, which is the same workDir unless a separate output folder was chosen.
        effectiveWorkDir = hasWorkDir ? workDir : (inputDir as NSString).appendingPathComponent(tidHex + "_build")
        args = BuildFailureClassifier.arguments(args, adding: override)
        if let override { say(String(format: t("fail.override.note"), override)) }
        say(String(format: t("msg.running"), py) + " " + args.joined(separator: " "))
        lastBuildCommand = [py] + args

        // The root of the runtime the apphost looks for: derived from the detected installation,
        // not assumed to be ~/.dotnet (Homebrew keeps it in …/opt/dotnet/libexec). Only set when the
        // derivation actually answered — a wrong root is worse than none, and the pipeline derives
        // and verifies its own (DOTNET_ROOT, build_ipa_from_nsp.py) when this is absent.
        // TMPDIR as well: .NET 10 on macOS keeps the named mutex its first-run configure takes
        // (NuGet-Migrations) under $TMPDIR/.dotnet/shm, and with no TMPDIR it stats "" and dies with
        // 'NuGet-Migrations' + lstat("") == ENOENT before any project is read. NSTemporaryDirectory()
        // is the per-user temp folder whether or not the app's own environment carries one.
        var denv: [String: String] = ["PATH": BuildCommands.toolPath("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", python: py),
                                      "USER": NSUserName(), "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8",
                                      "TMPDIR": NSTemporaryDirectory()]
        if let droot = Toolchain.dotnetRoot(for: deps.dotnetPath.isEmpty ? "dotnet" : deps.dotnetPath) {
            denv["DOTNET_ROOT"] = droot   // both variables carry the same root, as the apphost checks the arch-specific one first
            denv["DOTNET_ROOT_ARM64"] = droot
        }
        // The bundled Python lives inside the signed app: a .pyc written there would change what the signature seals
        // (the packages are compiled at bundle time), and a user site must not shadow its pinned packages.
        denv.merge(BundledTools.environment(for: py)) { $1 }
        let launch = ProcessLaunch(executable: py, arguments: args, environment: denv, directory: engine, groupPython: py)
        let onExit: @Sendable (Int32) -> Void = { [weak self] status in
            hop {
                guard let self else { return }
                self.running = false
                self.flushLines()
                if self.stopping {
                    self.stopping = false
                    self.resetProgress()
                    self.doneNote = self.t("msg.stopped")
                    self.cleanupStaging()
                    return
                }
                if status == 0 {
                    self.markAllDone()
                    if self.target == BuildTarget.mac {
                        // The .app is self-contained (its RomFS is inside), and the marker file
                        // beside it (.nx2apple-library, a dot file the Finder hides) tells the
                        // game's launcher that this folder is a library: its saves and log live
                        // here, and they follow the folder if it moves. No image copy — the .app
                        // already carries one, and a second multi-GB file was pure duplication.
                        let made = !self.macAppPath.isEmpty &&
                                   FileManager.default.fileExists(atPath: self.macAppPath)
                        self.done = made
                        self.doneNote = self.t(made ? "msg.macAppDone" : "msg.macAppMissing")
                        if made {
                            try? Data().write(to: URL(fileURLWithPath:
                                (self.macAppPath as NSString).deletingLastPathComponent +
                                "/.nx2apple-library"))
                        }
                        self.running = false
                        self.cleanupStaging()
                    } else {
                        // The game's archive, then its framework into the one shared app on the device
                        let tid = TitleID.buildKey(self.basePath)
                        let name = ((self.basePath as NSString).lastPathComponent as NSString).deletingPathExtension
                        let fw = ShellInstall.frameworkPath(workDir: self.effectiveWorkDir, titleID: tid)
                        self.packArchive(workDir: self.effectiveWorkDir) {
                            self.installShell(framework: fw, titleID: tid, name: name, archive: $0)
                        }
                    }
                } else {
                    if let i = self.stages.lastIndex(where: { $0.state == .running }) {
                        self.stages[i].state = .failed
                        self.stages[i].detail = String(format: self.t("msg.exitCode"), status)
                        self.noteFailure()
                    } else {
                        // The last real line says more than the exit code alone, and the message
                        // points at the log: "Build failed (exit code 1)" with nothing else sent a
                        // reporter looking for a log that a short window had below the fold (#52)
                        self.doneNote = String(format: self.t("msg.buildFailed"), status)
                        if let last = BuildProgress.lastMeaningfulLine(self.logTail) {
                            self.doneNote = String(format: self.t("msg.buildFailedReason"), last)
                        }
                        self.noteFailure()
                    }
                    self.cleanupStaging()
                }
            }
        }
        do {
            proc = try runner.start(launch, onOutput: { @Sendable [weak self] d in
                guard let s = String(data: d, encoding: .utf8) else { return }
                hop { self?.ingest(s) }
            }, onExit: onExit)
        } catch { fail(String(format: t("msg.launchFailed"), error.localizedDescription)) }
    }

    /// Looks the device up in `devicectl list devices` (in the background), then starts the build, or says how to pair it.
    package func verifyShellDevice() {
        running = true; done = false; doneNote = ""; failure = nil; stages = []
        let xcrun = devices.xcrun, device = devices.installDevice, runner = runner
        DispatchQueue.global(qos: .userInitiated).async {
            let link = ShellInstall.connection(of: device, in: DeviceTools.devices(xcrun: xcrun, timeout: 20, runner: runner))
            hop {
                self.running = false
                if link == .notPaired {
                    self.failure = BuildFailure(kind: .devicePairing, gameName: nil)
                    self.doneNote = String(format: self.t("shell.notPaired"), self.devices.deviceName(device))
                    return
                }
                self.shellDeviceChecked = true
                self.startBuild()
            }
        }
    }
}
