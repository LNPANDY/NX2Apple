import Foundation
import NXCore

// nxkit as a build engine (LNPANDY/NX2Apple#1460): `nxb build` from the binaries the launcher installed. The rules (release, checksums, command line)
// are NxkitBuilder in NXCore, the install is NxkitInstall.swift. The stage list comes from nxb's `--progress json` events, which BuildStore.handleEvent reads.

package enum NxkitUpdateState: Equatable, Sendable {
    case unknown
    case checking
    case upToDate
    case available(String)   // the tag of the newer release
    case failed
}

extension BuildStore {
    package var isNxkitSelected: Bool {
        NxkitBuilder.featureEnabled && buildUpstream == .nxkit
    }

    /// The selected engine makes Mac apps only, so the iPhone and iPad target is not offered.
    package var isMacOnlyUpstreamSelected: Bool {
        isUpstreamEnabled(buildUpstream) && buildUpstream.buildsMacOnly
    }

    package var macOnlyNoteKey: String {
        buildUpstream.macOnlyNoteKey ?? "upstream.mngMacOnly"
    }

    func isUpstreamEnabled(_ kind: EngineUpstreamKind) -> Bool {
        switch kind {
        case .nxnative: return true
        case .macNativeGames: return MacNativeGamesBuilder.featureEnabled
        case .s2arm: return S2ArmBuilder.featureEnabled
        case .nxkit: return NxkitBuilder.featureEnabled
        }
    }

    /// Where the installed nxkit lives: `upstreams/nxkit/`.
    package var nxkitPath: String {
        UpstreamEngineStore(root: upstreamsRootURL).directory(for: .nxkit)?.path ?? ""
    }

    /// nxb and `nxkit-host` are both there. A release ZIP without the runtime installs nxb alone and cannot build apps.
    package var nxkitCanBuildApps: Bool {
        nxkitInstalled && NxkitBuilder.canBuildApps(nxkitPath)
    }

    /// Reads what is installed again: after an install, at start and when the folder of upstreams may have changed.
    package func refreshNxkit() {
        let path = nxkitPath
        nxkitInstalled = NxkitBuilder.isUsableTree(path)
        nxkitInfo = nxkitInstalled ? NxkitBuilder.readInfo(in: path) : nil
    }

    /// Asks GitHub for the latest nxkit release and compares it with the installed one.
    @discardableResult
    package func checkNxkitUpdate() -> Task<Void, Never> {
        guard NxkitBuilder.featureEnabled, nxkitUpdate != .checking else { return Task {} }
        nxkitUpdate = .checking
        let store = UpstreamEngineStore(root: upstreamsRootURL)
        let transport = upstreamTransport
        return Task { [weak self] in
            let release = await Task.detached { store.latestNxkitRelease(transport: transport) }.value
            guard let self else { return }
            guard let release else {
                self.nxkitUpdate = .failed
                return
            }
            let installed = self.nxkitInfo?.tag ?? ""
            self.nxkitUpdate = NxkitBuilder.isNewer(release.tag, than: installed) ? .available(release.tag) : .upToDate
        }
    }

    /// Why the build cannot start with nxkit, in the player's words. nil when it can (or nxkit is not selected).
    func nxkitProblem() -> String? {
        guard isNxkitSelected else { return nil }
        guard target == BuildTarget.mac else { return t("upstream.nxkitMacOnly") }
        guard nxkitInstalled else { return t("upstream.nxkitMissing") }
        guard nxkitCanBuildApps else { return String(format: t("upstream.nxkitNoHost"), nxkitInfo?.tag ?? "") }
        if let folder = gameFolder, folder.nup == nil { return t("upstream.nxkitNoDumpFolder") }
        return nil
    }

    /// The folder `nxb build` reads: the picked files' folder, or a folder of links when the files, or other games' packages, lie apart or together.
    /// nil when the links could not be made. A NUP goes by its own path, not through here.
    func nxkitSourceFolder(workDir: String) -> String? {
        let baseDir = inputFolder
        let allPaths = [basePath, updatePath] + dlcPaths
        let dirs = Set(allPaths.filter { !$0.isEmpty }.map { ($0 as NSString).deletingLastPathComponent })
        let picked = Set(allPaths.filter { !$0.isEmpty }.map { ($0 as NSString).lastPathComponent })
        let unpicked = ((try? FileManager.default.contentsOfDirectory(atPath: baseDir)) ?? []).filter {
            ["nsp", "xci", "nsz", "xcz"].contains(($0 as NSString).pathExtension.lowercased()) && !picked.contains($0)
        }
        var staged = allPaths
        if let base = selectedTitleID.flatMap({ UInt64($0, radix: 16) }) ?? TitleID.parse(basePath) {
            let app = base & ~0xFFF
            for f in unpicked {
                guard let tid = TitleID.parse(f) else { continue }
                let low = tid & 0xFFF
                let owner = low == 0 ? tid : (low == 0x800 ? tid & ~0xFFF : (tid & ~0xFFF) - 0x1000)
                guard owner == app else { continue }
                if low == 0x800 && !updatePath.isEmpty { continue }
                if low != 0 && low != 0x800 && tid <= app { continue }
                staged.append(baseDir + "/" + f)
            }
        }
        guard dirs.count > 1 || !unpicked.isEmpty || staged.contains(where: InputStaging.needsLowercaseName) else {
            staging = nil
            return baseDir
        }
        let tmp = InputStaging.folder(workDir: workDir)
        guard InputStaging.sync(files: staged, into: tmp) > 0 else { return nil }
        staging = tmp
        if !unpicked.isEmpty {
            say(String(format: t("msg.stagedFromSharedFolder"), (basePath as NSString).lastPathComponent))
        }
        return tmp
    }

    func nxkitLaunch(input: String, nup: String?, workDir: String, outputAppPath: String) -> ProcessLaunch {
        let args = NxkitBuilder.arguments(
            input: input,
            nup: nup,
            keysPath: keysPath,
            outputAppPath: outputAppPath,
            workDir: workDir,
            titleID: selectedTitleID ?? gameTitleID
        )
        let nxb = NxkitBuilder.builderPath(in: nxkitPath)
        say(String(format: t("msg.running"), nxb) + " " + args.joined(separator: " "))
        lastBuildCommand = [nxb] + args
        let base = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
                    "USER": NSUserName(), "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
        return ProcessLaunch(executable: nxb, arguments: args, environment: NxkitBuilder.environment(tree: nxkitPath, base: base), directory: nxkitPath)
    }

    /// Stop: nxb is not started in a group of its own (that needs Python, which nxkit does not), and it ends on SIGINT with its own exit code 130.
    /// What is left after 5 s is killed.
    func endNxkitProcess(_ pid: pid_t) {
        guard pid > 1 else { return }
        kill(pid, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }
}
