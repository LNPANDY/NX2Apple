import Foundation

/// Captures the library game context passed into a build so an existing iOS game framework can refresh in place
/// without requiring the original Switch package files.
package struct RefreshCandidate: Equatable, Sendable {
    package var gameID: UUID?
    package var titleID: String
    package var name: String
    package var archivePath: String
    package var recordedBase: String
    package var recordedUpdate: String
    package var recordedDLC: [String]

    package init(gameID: UUID? = nil, titleID: String = "", name: String = "", archivePath: String = "",
                 recordedBase: String = "", recordedUpdate: String = "", recordedDLC: [String] = []) {
        self.gameID = gameID
        self.titleID = titleID
        self.name = name
        self.archivePath = archivePath
        self.recordedBase = recordedBase
        self.recordedUpdate = recordedUpdate
        self.recordedDLC = recordedDLC
    }
}

/// Fast iOS game-framework refresh from retained intermediate caches (`<workDir>/extract/v<N>/ExeFS`, `<workDir>/shader/ios`,
/// `<workDir>/shader/cache`) and an existing `romfs.img`, bypassing package extraction, decryption keys, RomFS packing,
/// and shader compilation whenever cached iOS shaders remain valid for the active engine.
package enum FrameworkRefresh {
    /// Exit status returned by the refresh driver when cached iOS shaders are stale for the active engine chain or profile inputs.
    package static let staleExitCode: Int32 = 75
    package static let staleMarker = "[NX2APPLE_SHADERS_STALE]"

    package enum StaleReason: Equatable, Sendable {
        case missingShaders
        case chainMismatch(have: String, want: String)
        case inputsMismatch
    }

    package struct Plan: Equatable, Sendable, Codable {
        package var titleID: String
        package var workDir: String
        package var version: String
        package var exeDir: String
        package var romfsPath: String
        package var archiveDir: String
        package var graphicsAPI: String
        package var chain: String
        package var profileDir: String?
        package var controlPath: String
        package var baseControlPath: String
        package var iconPath: String?
        package var aocDir: String?

        package init(titleID: String, workDir: String, version: String, exeDir: String, romfsPath: String,
                     archiveDir: String, graphicsAPI: String, chain: String, profileDir: String? = nil,
                     controlPath: String, baseControlPath: String, iconPath: String? = nil, aocDir: String? = nil) {
            self.titleID = titleID
            self.workDir = workDir
            self.version = version
            self.exeDir = exeDir
            self.romfsPath = romfsPath
            self.archiveDir = archiveDir
            self.graphicsAPI = graphicsAPI
            self.chain = chain
            self.profileDir = profileDir
            self.controlPath = controlPath
            self.baseControlPath = baseControlPath
            self.iconPath = iconPath
            self.aocDir = aocDir
        }
    }

    package enum Status: Equatable, Sendable {
        case ready(Plan)
        case shadersStale(StaleReason)
        case unavailable
    }

    /// Cheap, synchronous probe (no subprocesses): checks whether cached ExeFS, shaders, a `romfs.img`, and a game profile
    /// exist locally for `titleID`.
    package static func canAttempt(workDirs: [String], romfsCandidates: [String], repo: String,
                                   titleID: String, fm: FileManager = .default) -> Bool {
        let tid = normalizedTitleID(titleID)
        guard !tid.isEmpty, !repo.isEmpty else { return false }
        let engineRoot = EngineLayout.root(repo)
        for workDir in deduplicated(workDirs) {
            guard locateExtractedVersion(in: [workDir], fm: fm) != nil,
                  hasProfile(titleID: tid, engineRoot: engineRoot, workDir: workDir, fm: fm),
                  hasAnyIOSShaders(in: workDir, fm: fm),
                  firstValidRomFS(in: romfsCandidates, workDirs: [workDir], fm: fm) != nil else { continue }
            return true
        }
        return false
    }

    /// Inspects cached artifacts against the current engine repository and returns whether an incremental framework refresh
    /// is `.ready`, blocked by `.shadersStale`, or `.unavailable`.
    package static func inspect(workDirs: [String], romfsCandidates: [String], fallbackArchiveDir: String,
                                repo: String, titleID: String, fm: FileManager = .default) -> Status {
        let tid = normalizedTitleID(titleID)
        guard !tid.isEmpty, !repo.isEmpty else { return .unavailable }
        let engineRoot = EngineLayout.root(repo)
        guard let matchedWork = deduplicated(workDirs).first(where: {
            locateExtractedVersion(in: [$0], fm: fm) != nil && hasProfile(titleID: tid, engineRoot: engineRoot, workDir: $0, fm: fm)
        }),
        let extracted = locateExtractedVersion(in: [matchedWork], fm: fm),
        let romfsPath = firstValidRomFS(in: romfsCandidates, workDirs: [matchedWork] + workDirs, fm: fm) else {
            return .unavailable
        }

        let workDir = extracted.workDir
        let version = extracted.version
        let versionDir = workDir + "/extract/" + version
        let exeDir = versionDir + "/ExeFS"
        let profileDir = locateProfileDir(workDir: workDir, titleID: tid, fm: fm)
        let v0Dir = workDir + "/extract/v0"
        let controlPath = firstExistingFile([versionDir + "/control.nacp", v0Dir + "/control.nacp"], fm: fm) ?? (versionDir + "/control.nacp")
        let baseControlPath = firstExistingFile([v0Dir + "/control.nacp", versionDir + "/control.nacp"], fm: fm) ?? controlPath
        let iconPath = firstExistingFile([versionDir + "/icon.jpg", v0Dir + "/icon.jpg"], fm: fm)
        let archiveDir = resolvedArchiveDir(for: romfsPath, workDir: workDir, fallbackArchiveDir: fallbackArchiveDir, titleID: tid)
        let aocDir = firstExistingDirectory([archiveDir + "/aoc", workDir + "/aoc"], fm: fm)

        let shaderIOS = workDir + "/shader/ios"
        let vkLib = shaderIOS + "/vk/vk_shaders.metallib"
        let glLib = shaderIOS + "/gl/gl_shaders.metallib"
        if fm.fileExists(atPath: vkLib) {
            return .ready(Plan(titleID: tid, workDir: workDir, version: version, exeDir: exeDir, romfsPath: romfsPath,
                               archiveDir: archiveDir, graphicsAPI: "vulkan", chain: "", profileDir: profileDir,
                               controlPath: controlPath, baseControlPath: baseControlPath, iconPath: iconPath, aocDir: aocDir))
        }
        if fm.fileExists(atPath: glLib) {
            return .ready(Plan(titleID: tid, workDir: workDir, version: version, exeDir: exeDir, romfsPath: romfsPath,
                               archiveDir: archiveDir, graphicsAPI: "gl", chain: "", profileDir: profileDir,
                               controlPath: controlPath, baseControlPath: baseControlPath, iconPath: iconPath, aocDir: aocDir))
        }

        guard let chain = EngineLayout.shaderChain(repo: repo), !chain.isEmpty else { return .unavailable }
        let iosChainExists = hasChainLibrary(in: shaderIOS, chain: chain, fm: fm)
        let cacheChainExists = hasChainLibrary(in: workDir + "/shader/cache", chain: chain, fm: fm)
        if iosChainExists && cacheChainExists {
            return .ready(Plan(titleID: tid, workDir: workDir, version: version, exeDir: exeDir, romfsPath: romfsPath,
                               archiveDir: archiveDir, graphicsAPI: "nvn", chain: chain, profileDir: profileDir,
                               controlPath: controlPath, baseControlPath: baseControlPath, iconPath: iconPath, aocDir: aocDir))
        }

        if let staleHave = firstOtherChain(in: shaderIOS, current: chain, fm: fm) {
            return .shadersStale(.chainMismatch(have: staleHave, want: "b-" + chain))
        }
        return .shadersStale(.missingShaders)
    }

    /// Builds a `ProcessLaunch` that executes the Python refresh driver inside the active engine checkout.
    package static func makeLaunch(plan: Plan, repo: String, python: String, teamID: String, fallbackName: String,
                                   envFile: String? = nil, environment: [String: String]) -> ProcessLaunch {
        let engineRoot = EngineLayout.root(repo)
        var payload: [String: Any] = [
            "title_id": plan.titleID,
            "work_dir": plan.workDir,
            "version": plan.version,
            "exe_dir": plan.exeDir,
            "romfs_path": plan.romfsPath,
            "archive_dir": plan.archiveDir,
            "graphics_api": plan.graphicsAPI,
            "chain": plan.chain,
            "control_path": plan.controlPath,
            "base_control_path": plan.baseControlPath,
            "team_id": teamID,
            "fallback_name": fallbackName
        ]
        if let profileDir = plan.profileDir { payload["profile_dir"] = profileDir }
        if let iconPath = plan.iconPath { payload["icon_path"] = iconPath }
        if let aocDir = plan.aocDir { payload["aoc_dir"] = aocDir }
        if let envFile, !envFile.isEmpty { payload["env_file"] = envFile }
        let jsonData = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        let jsonText = String(data: jsonData, encoding: .utf8) ?? "{}"
        return ProcessLaunch(
            executable: python,
            arguments: ["-c", driverScript, engineRoot, jsonText],
            environment: environment,
            directory: engineRoot,
            mergesErrors: true,
            groupPython: python
        )
    }

    package static func romfsCandidates(archivePath: String, outDir: String, inputFolder: String,
                                        titleID: String, workDirs: [String]) -> [String] {
        let tid = normalizedTitleID(titleID)
        var raw: [String] = []
        if !archivePath.isEmpty { raw.append(archivePath + "/romfs.img") }
        let root = outDir.isEmpty ? inputFolder : outDir
        if !root.isEmpty, !tid.isEmpty {
            raw.append(root + "/games/" + tid + "/romfs.img")
            raw.append(root + "/games/" + tid.lowercased() + "/romfs.img")
        }
        for workDir in deduplicated(workDirs) {
            if let v = latestExtractedVersion(in: workDir + "/extract", fm: .default) {
                raw.append(workDir + "/extract/" + v + "/RomFS.img")
            }
        }
        return deduplicated(raw)
    }

    // MARK: - Private helpers

    private static func normalizedTitleID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count == 16, trimmed.allSatisfy(\.isHexDigit) else { return "" }
        return trimmed
    }

    private static func deduplicated(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in list where !item.isEmpty {
            let clean = URL(fileURLWithPath: item).standardizedFileURL.path
            if seen.insert(clean).inserted { result.append(clean) }
        }
        return result
    }

    private static func locateProfileDir(workDir: String, titleID: String, fm: FileManager) -> String? {
        for name in [titleID, titleID.lowercased()] {
            let tsv = workDir + "/profile/" + name + "/game.tsv"
            if fm.fileExists(atPath: tsv) { return workDir + "/profile" }
        }
        return nil
    }

    private static func hasProfile(titleID: String, engineRoot: String, workDir: String, fm: FileManager) -> Bool {
        if locateProfileDir(workDir: workDir, titleID: titleID, fm: fm) != nil { return true }
        for name in [titleID.lowercased(), titleID] {
            if fm.fileExists(atPath: engineRoot + "/dm/games/" + name + "/game.tsv") { return true }
        }
        return false
    }

    private static func latestExtractedVersion(in extractDir: String, fm: FileManager) -> String? {
        let entries = (try? fm.contentsOfDirectory(atPath: extractDir)) ?? []
        return entries
            .filter { $0.hasPrefix("v") && fm.fileExists(atPath: extractDir + "/" + $0 + "/ExeFS/main") }
            .sorted { (Int($0.dropFirst()) ?? -1) < (Int($1.dropFirst()) ?? -1) }
            .last
    }

    private static func locateExtractedVersion(in workDirs: [String], fm: FileManager) -> (workDir: String, version: String)? {
        for workDir in deduplicated(workDirs) {
            if let version = latestExtractedVersion(in: workDir + "/extract", fm: fm) {
                return (workDir, version)
            }
        }
        return nil
    }

    private static func isValidRomFS(_ path: String, fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return false }
        return size >= 40
    }

    private static func firstValidRomFS(in candidates: [String], workDirs: [String], fm: FileManager) -> String? {
        var expanded = candidates
        for workDir in deduplicated(workDirs) {
            if let version = latestExtractedVersion(in: workDir + "/extract", fm: fm) {
                expanded.append(workDir + "/extract/" + version + "/RomFS.img")
            }
        }
        return deduplicated(expanded).first { isValidRomFS($0, fm: fm) }
    }

    private static func resolvedArchiveDir(for romfsPath: String, workDir: String,
                                           fallbackArchiveDir: String, titleID: String) -> String {
        let extractPrefix = URL(fileURLWithPath: workDir + "/extract").standardizedFileURL.path + "/"
        if romfsPath.hasPrefix(extractPrefix) {
            if !fallbackArchiveDir.isEmpty { return fallbackArchiveDir }
            return (workDir as NSString).deletingLastPathComponent + "/games/" + titleID
        }
        return (romfsPath as NSString).deletingLastPathComponent
    }

    private static func hasChainLibrary(in folder: String, chain: String, fm: FileManager) -> Bool {
        fm.fileExists(atPath: folder + "/b-" + chain) || fm.fileExists(atPath: folder + "/b-" + chain + ".img")
    }

    private static func firstOtherChain(in folder: String, current: String, fm: FileManager) -> String? {
        let currentDir = "b-" + current
        let currentImg = currentDir + ".img"
        let items = (try? fm.contentsOfDirectory(atPath: folder)) ?? []
        return items.sorted().first { item in
            item.hasPrefix("b-") && item != currentDir && item != currentImg
        }
    }

    private static func hasAnyIOSShaders(in workDir: String, fm: FileManager) -> Bool {
        let shaderIOS = workDir + "/shader/ios"
        if fm.fileExists(atPath: shaderIOS + "/vk/vk_shaders.metallib")
            || fm.fileExists(atPath: shaderIOS + "/gl/gl_shaders.metallib") {
            return true
        }
        let items = (try? fm.contentsOfDirectory(atPath: shaderIOS)) ?? []
        return items.contains { $0.hasPrefix("b-") }
    }

    private static func firstExistingFile(_ paths: [String], fm: FileManager) -> String? {
        paths.first { path in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
        }
    }

    private static func firstExistingDirectory(_ paths: [String], fm: FileManager) -> String? {
        paths.first { path in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// Inline Python driver matching `build_ipa_from_nsp.py`'s rewriter and `build_ipa.sh`'s `DM_FRAMEWORK_ONLY` contract.
    private static let driverScript = #"""
import collections
import getpass
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

STALE_EXIT = 75
STALE_MARKER = "[NX2APPLE_SHADERS_STALE]"

def emit(obj):
    print(json.dumps(obj, separators=(",", ":")), flush=True)

def say(msg):
    emit({"ev": "say", "msg": msg})

def file_digest(h, path):
    h.update(str(path).encode())
    h.update(b"\0")
    try:
        with open(path, "rb") as f:
            while chunk := f.read(1 << 20):
                h.update(chunk)
    except OSError:
        h.update(b"MISSING")

def build_id(path):
    try:
        data = Path(path).read_bytes()
    except OSError:
        return ""
    if len(data) < 0x50 or data[:4] != b"NSO0":
        return ""
    return data[0x40:0x50].hex()

def patch_files(repo, exe_dir, mods, game_id, env):
    ids = {build_id(exe_dir / m) for m in mods}
    ids.discard("")
    extra = [
        p
        for d in env.get("DM_GAMES_DIR", "").split(os.pathsep)
        if d
        for p in sorted(Path(d).glob("*/patches.py"))
    ]
    shared = [repo / "dm/tools/sdk_patches.py", repo / "dm/tools/engine_patches.py"]
    seen = {}
    for p in shared + sorted((repo / "dm/games").glob("*/patches.py")) + extra:
        seen.setdefault(p.resolve(), p)
    selected = []
    for p in seen.values():
        if p in shared or p.parent.name.lower() == game_id.lower():
            selected.append(p)
            continue
        try:
            text = p.read_text(errors="replace")
        except OSError:
            continue
        if any(i in text for i in ids):
            selected.append(p)
    return selected

def ensure_nvn_shaders(repo, work, g, chain, env, logs):
    msl_ios = work / "shader/ios" / f"b-{chain}"
    msl_mac = work / "shader/cache" / f"b-{chain}"
    sys.path.insert(0, str(repo / "dm/tools"))
    import shader_lib
    r = subprocess.run(
        [sys.executable, str(repo / "dm/gfx/tools/dmsh_chain.py"), "--inputs"],
        env=dict(env, DM_GAME=g.id),
        capture_output=True,
        text=True,
    )
    in_digest = r.stdout.split()[-1] if r.returncode == 0 and r.stdout.split() else ""
    if not in_digest:
        say(STALE_MARKER + " missing dmsh_chain input digest")
        sys.exit(STALE_EXIT)
    ios_stamp = shader_lib.read_stamp(msl_ios)
    if ios_stamp.get("game") != g.id or ios_stamp.get("inputs") != in_digest:
        say(STALE_MARKER + f" ios shader stamp mismatch for {g.id}")
        sys.exit(STALE_EXIT)
    mac_stamp = shader_lib.read_stamp(msl_mac)
    if mac_stamp.get("inputs") != in_digest:
        say(STALE_MARKER + " Mac shader inputs stamp mismatch")
        sys.exit(STALE_EXIT)
    want_head = shader_lib.table_head(msl_mac)
    for name, tool in (("c1_full.tsv", "c1_guard.py"), ("cb_extent.tsv", "cb_extent.py")):
        target = g.table(name)
        try:
            head = target.read_text(errors="replace").partition("\n")[0]
        except OSError:
            head = ""
        if head.startswith(want_head + " "):
            continue
        rc = subprocess.run(
            [sys.executable, str(repo / "dm/gfx/tools" / tool), str(msl_mac), str(target)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        if rc.returncode != 0:
            sys.stderr.write(rc.stdout)
            sys.exit(rc.returncode or 1)

def run_rewrite(repo, work, version, exe_dir, g, env, logs):
    t0 = time.monotonic()
    emit({"ev": "stage", "k": 1, "n": 2, "name": "rewrite", "step": "checking the inputs"})
    out = work / f"patched_{version}"
    nro_dir = work / f"nro_{version}"
    manifest = nro_dir / "nro.tsv"
    nros = {}
    if manifest.is_file():
        for line in manifest.read_text(encoding="utf-8", errors="replace").splitlines():
            if not line or line.startswith("#") or line.startswith("refused\t"):
                continue
            mod = line.split("\t", 1)[0]
            cand = nro_dir / f"{mod}.nro"
            if cand.is_file():
                nros[mod] = cand
    mods = g.modules_in(exe_dir)
    src = {m: exe_dir / m for m in mods}
    src.update(nros)
    names = list(src)
    tool_names = (
        "patch_nso.py", "nso.py", "nso_code.py", "nso_asm.py", "nso_match.py",
        "ue_cvar.py", "ue_malloc.py", "ue_region.py", "ue_ring.py", "snowdrop_pools.py",
        "loader_census.py", "fps_target.py", "ue_fixed_rate.py", "unity_fps.py", "unity_bucket.py",
    )
    h = hashlib.sha256()
    for path in [repo / "dm/tools" / f for f in tool_names]:
        file_digest(h, path)
    for path in patch_files(repo, exe_dir, mods, g.id, env):
        file_digest(h, path)
    for path in list(src.values()) + ([manifest] if manifest.is_file() else []):
        file_digest(h, path)
    for k in ("DM_PATCH_FRONT", "DM_GAME"):
        h.update(f"{k}={env.get(k, '')}\n".encode())
    h.update((g.id + "\n").encode())
    for row in g.dir.joinpath("game.tsv").read_text(encoding="utf-8", errors="replace").splitlines():
        if row.startswith(("build\t", "snowdrop_pools\t")):
            h.update((row + "\n").encode())
    digest = h.hexdigest()
    key_file = work / f"patched_{version}.refresh.key"
    ready = (
        all((out / f"{m}.patched.bin").is_file() and (out / f"{m}.fixups.tsv").is_file() for m in names)
        and key_file.is_file()
        and key_file.read_text(errors="replace").strip() == digest
    )
    summary = ", ".join(mods) + (f" and {len(nros)} NROs" if nros else "")
    if ready:
        emit({"ev": "stage_end", "k": 1, "n": 2, "name": "rewrite", "ok": True,
              "summary": f"{summary}, reused (inputs unchanged)", "elapsed": time.monotonic() - t0})
        return out
    tmp = work / f"patched_{version}.partial"
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)
    logs.mkdir(parents=True, exist_ok=True)
    if manifest.is_file():
        shutil.copyfile(manifest, tmp / "nro.tsv")
    emit({"ev": "progress", "k": 1, "n": 2, "name": "rewrite", "done": 0, "total": len(names), "unit": "modules", "frac": 0.0})
    cores = max(2, os.cpu_count() or 4)
    jobs = max(1, min(cores, 2 * cores // max(1, len(names))))
    rewrite_env = dict(env, DM_REWRITE_J=env.get("DM_REWRITE_J") or str(jobs))
    procs, logf, todo = {}, {}, list(names)
    done_count = 0
    try:
        while todo or procs:
            while todo and len(procs) < cores:
                m = todo.pop(0)
                f = open(logs / f"rewrite_{m}.log", "w")
                logf[m] = f
                procs[m] = subprocess.Popen(
                    [sys.executable, str(repo / "dm/tools/patch_nso.py"), str(src[m]), str(tmp), m],
                    env=rewrite_env, stdout=f, stderr=subprocess.STDOUT,
                )
            for m in [x for x in list(procs) if procs[x].poll() is not None]:
                p = procs.pop(m)
                logf.pop(m).close()
                done_count += 1
                emit({"ev": "progress", "k": 1, "n": 2, "name": "rewrite", "done": done_count,
                      "total": len(names), "unit": "modules", "frac": done_count / max(1, len(names))})
                if p.returncode != 0:
                    log_path = logs / f"rewrite_{m}.log"
                    tail = "".join(collections.deque(open(log_path, errors="replace"), maxlen=40)).rstrip("\n")
                    say(f"---- last lines of {log_path} ----\n{tail}")
                    emit({"ev": "stage_end", "k": 1, "n": 2, "name": "rewrite", "ok": False,
                          "summary": f"exit code {p.returncode}", "elapsed": time.monotonic() - t0})
                    sys.exit(p.returncode or 1)
            if procs:
                time.sleep(0.15)
    finally:
        for p in procs.values():
            if p.poll() is None:
                p.terminate()
                p.wait()
        for f in logf.values():
            f.close()
    if out.exists():
        shutil.rmtree(out)
    tmp.replace(out)
    old_key = work / f"patched_{version}.key"
    if old_key.exists():
        shutil.rmtree(old_key) if old_key.is_dir() else old_key.unlink()
    key_file.write_text(digest + "\n")
    emit({"ev": "stage_end", "k": 1, "n": 2, "name": "rewrite", "ok": True, "summary": summary, "elapsed": time.monotonic() - t0})
    return out

def main():
    repo = Path(sys.argv[1]).resolve()
    plan = json.loads(sys.argv[2])
    work = Path(plan["work_dir"]).resolve()
    version = plan["version"]
    exe_dir = Path(plan["exe_dir"]).resolve()
    romfs_path = Path(plan["romfs_path"]).resolve()
    gfx = plan["graphics_api"]
    chain = plan.get("chain", "")
    title_id = plan["title_id"]
    logs = work / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env.setdefault("USER", getpass.getuser())
    env.setdefault("J", str(os.cpu_count() or 8))
    if pdir := plan.get("profile_dir"):
        env["DM_GAMES_DIR"] = os.pathsep.join([pdir] + [d for d in env.get("DM_GAMES_DIR", "").split(os.pathsep) if d and d != pdir])
        if (repo / "dm/games" / title_id.lower()).is_dir():
            env["DM_GAMES_FIRST"] = "1"
    sys.path.insert(0, str(repo / "dm/games"))
    sys.path.insert(0, str(repo / "dm/tools"))
    import game as gamemod
    import nacp
    g = gamemod.by_title(int(title_id, 16))
    if g is None and env.get("DM_GAMES_DIR"):
        try:
            g = gamemod.load(title_id.upper())
        except SystemExit:
            g = None
    if g is None:
        say(f"no game profile for {title_id}")
        sys.exit(1)
    if gfx == "nvn":
        ensure_nvn_shaders(repo, work, g, chain, env, logs)
    patched = run_rewrite(repo, work, version, exe_dir, g, env, logs)

    t_fw = time.monotonic()
    emit({"ev": "stage", "k": 2, "n": 2, "name": "game framework", "step": "starting"})
    base_nacp = plan["base_control_path"]
    ver_nacp = plan["control_path"]
    app_name = nacp.name(base_nacp) or plan.get("fallback_name") or title_id
    app_version = nacp.version(ver_nacp) or nacp.version(base_nacp) or "1.0"
    shell_fw = work / "shell-framework"
    ipa_env = dict(
        env,
        GAME=g.id,
        W=str(work / "ipa"),
        PATCHED=str(patched),
        ROMFS=str(romfs_path),
        MSL_IOS=str(work / "shader/ios"),
        GFXAPI=gfx,
        FONT_PY=sys.executable,
        DM_DISPLAY_NAME=app_name,
        DM_APP_VERSION=app_version,
        DM_BUNDLE_ID="org.nxnative." + g.id.lower(),
        AOC=plan.get("aoc_dir") or "",
        DM_XCODE_DERIVED_DATA=str(work / "xcode-derived-data"),
        DM_TEAM_ID=plan.get("team_id") or "",
        DM_LANG="en-US",
        CONTROL=str(ver_nacp),
        DM_COPY_ROMFS="NO",
        DM_SHOW_FPS="0",
        DM_FRAMEWORK_ONLY=str(shell_fw),
    )
    if icon_path := plan.get("icon_path"):
        ipa_env["DM_ICON"] = icon_path
    if env_file := plan.get("env_file"):
        ipa_env["DM_ENV_FILE"] = env_file
    fw_log = logs / "build_framework.log"
    proc = subprocess.Popen(
        ["bash", str(repo / "dm/ios/tools/build_ipa.sh")],
        cwd=str(repo),
        env=ipa_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
    )
    last_step = ""
    with open(fw_log, "w", encoding="utf-8") as lf:
        for raw in proc.stdout:
            lf.write(raw)
            line = raw.rstrip("\n")
            print(line, flush=True)
            s = re.sub(r"^\[[\d:]+\] ", "", line)
            step = None
            if s.startswith("generate Gen/"):
                step = "generating sources"
            elif s.startswith("pipeline archive for"):
                step = "pipeline archive (metal-tt)"
            elif s.startswith("xcodebuild"):
                step = "compiling"
            elif s.startswith("copying resources into"):
                step = "copying resources"
            if step and step != last_step:
                last_step = step
                emit({"ev": "step", "k": 2, "n": 2, "step": step})
    rc = proc.wait()
    if rc != 0:
        emit({"ev": "stage_end", "k": 2, "n": 2, "name": "game framework", "ok": False,
              "summary": f"exit code {rc}", "elapsed": time.monotonic() - t_fw})
        sys.exit(rc)
    fw = shell_fw / f"DmGame{g.id.upper()}.framework"
    if not (fw / "game.manifest.json").is_file():
        say(f"no game framework at {fw}")
        emit({"ev": "stage_end", "k": 2, "n": 2, "name": "game framework", "ok": False,
              "summary": "missing framework", "elapsed": time.monotonic() - t_fw})
        sys.exit(1)
    emit({"ev": "stage_end", "k": 2, "n": 2, "name": "game framework", "ok": True,
          "summary": fw.name, "elapsed": time.monotonic() - t_fw})

if __name__ == "__main__":
    main()
"""#
}
