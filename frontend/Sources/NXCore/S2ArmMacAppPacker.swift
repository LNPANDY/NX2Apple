import CryptoKit
import Foundation

/// Builds/caches the S2Arm macOS host binaries and packages a standard `.app` bundle
/// that NX2Apple's GameLibrary (`MacGameBundle`) discovers and launches out of the box.
package enum S2ArmMacAppPacker {
    package struct HostBinaries: Equatable, Sendable {
        package let hostExecutable: URL
        package let vaGuardDylib: URL
        package let ns2Helper: URL?
        package let cacheDirectory: URL

        package init(hostExecutable: URL, vaGuardDylib: URL, ns2Helper: URL?, cacheDirectory: URL) {
            self.hostExecutable = hostExecutable
            self.vaGuardDylib = vaGuardDylib
            self.ns2Helper = ns2Helper
            self.cacheDirectory = cacheDirectory
        }
    }

    package enum PackError: Error, LocalizedError, Equatable, Sendable {
        case hostBuildFailed(String)
        case missingHostArtifact(String)
        case launcherCompileFailed(String)
        case bundleWriteFailed(String)
        case codesignFailed(String)

        package var errorDescription: String? {
            switch self {
            case .hostBuildFailed(let detail): return "S2Arm Mac host build failed: \(detail)"
            case .missingHostArtifact(let name): return "S2Arm Mac host artifact missing: \(name)"
            case .launcherCompileFailed(let detail): return "Failed to compile s2arm-launch: \(detail)"
            case .bundleWriteFailed(let detail): return "Failed to package S2Arm Mac app: \(detail)"
            case .codesignFailed(let detail): return "Failed to sign S2Arm Mac app: \(detail)"
            }
        }
    }

    /// True when the S2Arm tree carries the macOS host build rules (`Makefile` + `launchers/macos/build.mk`).
    package static func canPackHost(in s2armTree: String, fileManager fm: FileManager = .default) -> Bool {
        guard !s2armTree.isEmpty else { return false }
        let prefix = s2armTree.hasSuffix("/") ? s2armTree : s2armTree + "/"
        return fm.fileExists(atPath: prefix + "Makefile")
            && fm.fileExists(atPath: prefix + "launchers/macos/build.mk")
    }

    /// Cache key derived from `.upstream-version.json` commit SHA, or representative source mtime.
    package static func hostCacheKey(s2armTree: String, fileManager fm: FileManager = .default) -> String {
        let dirURL = URL(fileURLWithPath: s2armTree, isDirectory: true)
        if let receipt = UpstreamVersion.readReceipt(in: dirURL, fileManager: fm),
           let commit = UpstreamVersion.normalizedCommit(receipt.commit) {
            return String(commit.prefix(12))
        }
        let markers = ["launchers/macos/build.mk", "runtime/rewriter/rewriter.c", "Makefile"]
        var latestMtime: Int64 = 0
        for rel in markers {
            let p = dirURL.appendingPathComponent(rel).path
            if let attrs = try? fm.attributesOfItem(atPath: p),
               let date = attrs[.modificationDate] as? Date {
                latestMtime = max(latestMtime, Int64(date.timeIntervalSince1970))
            }
        }
        return latestMtime > 0 ? "mtime-\(latestMtime)" : "local"
    }

    private static func findArtifact(named targetName: String, in root: URL, fileManager fm: FileManager) -> URL? {
        let direct = root.appendingPathComponent(targetName)
        if fm.fileExists(atPath: direct.path) {
            return direct
        }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let url as URL in enumerator {
            if enumerator.level > 3 {
                enumerator.skipDescendants()
                continue
            }
            if url.lastPathComponent == targetName {
                return url
            }
        }
        return nil
    }

    private static let cacheEnvKeys = [
        "S2A_CS_CACHE",
        "S2A_VPX_CACHE",
        "S2A_OPUS_CACHE",
        "S2A_DAV1D_CACHE",
        "S2A_RUN_ROOT",
    ]

    /// Returns a space-free symlink alias for `path` when it contains whitespace so GNU Make
    /// never splits `-C`, `ROOT=`, `BUILD=`, or `SHELL=` across spaces. Paths without whitespace
    /// are returned unchanged.
    package static func noSpaceAlias(
        for path: String,
        fileManager fm: FileManager = .default
    ) -> String {
        guard !path.isEmpty,
              path.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else {
            return path
        }
        let rawTmp = NSTemporaryDirectory().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let baseTmp: String
        if rawTmp.isEmpty || rawTmp.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            baseTmp = "/tmp"
        } else {
            baseTmp = "/" + rawTmp
        }
        let aliasDir = baseTmp + "/nx2a-nospace"
        let digest = SHA256.hash(data: Data(path.utf8))
        let hash12 = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        let linkPath = aliasDir + "/" + hash12

        if let existing = try? fm.destinationOfSymbolicLink(atPath: linkPath), existing == path {
            return linkPath
        }
        do {
            try fm.createDirectory(atPath: aliasDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: linkPath) || (try? fm.attributesOfItem(atPath: linkPath)) != nil {
                try fm.removeItem(atPath: linkPath)
            }
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: path)
            return linkPath
        } catch {
            return path
        }
    }

    /// Compiles or reuses cached `s2arm-host`, `libs2a_vaguard.dylib`, and optional `S2ArmNS2Connection`.
    package static func ensureHostBinaries(
        s2armTree: String,
        upstreamsRoot: URL,
        home: String = NSHomeDirectory(),
        runner: ProcessRunner = SystemProcessRunner(),
        fileManager fm: FileManager = .default,
        onLine: (@Sendable (String) -> Void)? = nil
    ) -> Result<HostBinaries, PackError> {
        let key = hostCacheKey(s2armTree: s2armTree, fileManager: fm)
        let cacheDir = upstreamsRoot
            .appendingPathComponent("s2arm-host-cache", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
        let cachedHost = cacheDir.appendingPathComponent("s2arm-host")
        let cachedDylib = cacheDir.appendingPathComponent("libs2a_vaguard.dylib")
        let cachedHelper = cacheDir.appendingPathComponent("S2ArmNS2Connection")

        if fm.isExecutableFile(atPath: cachedHost.path), fm.fileExists(atPath: cachedDylib.path) {
            return .success(HostBinaries(
                hostExecutable: cachedHost,
                vaGuardDylib: cachedDylib,
                ns2Helper: fm.isExecutableFile(atPath: cachedHelper.path) ? cachedHelper : nil,
                cacheDirectory: cacheDir
            ))
        }

        do {
            try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        } catch {
            return .failure(.hostBuildFailed(error.localizedDescription))
        }

        let devDir = Toolchain.developerDir(runner: runner) ?? "/Applications/Xcode.app/Contents/Developer"
        let treeAlias = noSpaceAlias(for: s2armTree, fileManager: fm)
        let buildAlias = noSpaceAlias(for: cacheDir.path, fileManager: fm)
        let devDirAlias = noSpaceAlias(for: devDir, fileManager: fm)
        let treePrefix = treeAlias.hasSuffix("/") ? treeAlias : treeAlias + "/"

        let modernBash = S2ArmBootstrap.findModernBash(
            home: home,
            runner: runner,
            exists: { fm.isExecutableFile(atPath: $0) }
        )
        let bashAlias = modernBash.map { noSpaceAlias(for: $0, fileManager: fm) }

        var extraBins: [String] = []
        if let bashAlias, let shimDir = S2ArmBootstrap.linkBashShim(modernBash: bashAlias, in: treeAlias, fileManager: fm) {
            extraBins.append(shimDir)
        }
        let localVenvBin = treePrefix + ".venv/bin"
        if fm.fileExists(atPath: localVenvBin) {
            extraBins.append(localVenvBin)
        }
        let runtimePrefix = S2ArmBootstrap.runtimeToolsPrefix(in: treeAlias)
        let runtimeReady = S2ArmBootstrap.isRuntimeToolsPrefixReady(runtimePrefix, fileManager: fm)
        if runtimeReady {
            extraBins.append(runtimePrefix + "/bin")
        }
        if fm.fileExists(atPath: Toolchain.venvDir + "/bin") {
            let managedVenvAlias = noSpaceAlias(for: Toolchain.venvDir, fileManager: fm)
            extraBins.append(managedVenvAlias + "/bin")
        }
        var makeArgs = [
            "-C", treeAlias,
            "ROOT=\(treeAlias)",
            "host",
            "S2A_CS=1",
            "S2A_MAC_FRONTEND=1",
            "BUILD=\(buildAlias)",
            "DEVELOPER_DIR=\(devDirAlias)",
        ]
        var baseEnv = ProcessInfo.processInfo.environment
        baseEnv["DEVELOPER_DIR"] = devDirAlias
        baseEnv["HOME"] = home
        for envKey in cacheEnvKeys {
            if let val = baseEnv[envKey], !val.isEmpty {
                baseEnv[envKey] = noSpaceAlias(for: val, fileManager: fm)
            }
        }
        if runtimeReady {
            baseEnv["S2A_ZSTD_LIB"] = runtimePrefix + "/lib/libzstd.1.dylib"
        }
        if let bashAlias {
            makeArgs.append("SHELL=\(bashAlias)")
            baseEnv["SHELL"] = bashAlias
        }
        let dnRes = S2ArmBuilder.findDotnet(S2ArmBuilder.dotnetCandidates(home: home), tree: s2armTree, runner: runner)
        let env = ProxyEnvironment.merged(into: S2ArmBuilder.environmentWithToolPaths(
            base: baseEnv,
            dotnetPath: dnRes.ok ? dnRes.path : nil,
            extraBinDirs: extraBins,
            home: home,
            runner: runner
        ))

        let makeOK: Bool
        if let onLine {
            makeOK = runner.stream(ProcessLaunch(executable: "/usr/bin/make", arguments: makeArgs, environment: env, directory: treeAlias), line: onLine)
        } else {
            makeOK = runner.capture(ProcessLaunch(executable: "/usr/bin/make", arguments: makeArgs, environment: env, directory: treeAlias)).ok
        }
        guard makeOK else {
            return .failure(.hostBuildFailed("make host exited with non-zero status"))
        }

        guard let foundHost = findArtifact(named: "s2arm-host", in: cacheDir, fileManager: fm) else {
            return .failure(.missingHostArtifact("s2arm-host"))
        }
        guard let foundDylib = findArtifact(named: "libs2a_vaguard.dylib", in: cacheDir, fileManager: fm) else {
            return .failure(.missingHostArtifact("libs2a_vaguard.dylib"))
        }
        let foundHelper = findArtifact(named: "S2ArmNS2Connection", in: cacheDir, fileManager: fm)

        if foundHost.standardizedFileURL != cachedHost.standardizedFileURL {
            try? fm.removeItem(at: cachedHost)
            try? fm.copyItem(at: foundHost, to: cachedHost)
        }
        if foundDylib.standardizedFileURL != cachedDylib.standardizedFileURL {
            try? fm.removeItem(at: cachedDylib)
            try? fm.copyItem(at: foundDylib, to: cachedDylib)
        }
        if let foundHelper, foundHelper.standardizedFileURL != cachedHelper.standardizedFileURL {
            try? fm.removeItem(at: cachedHelper)
            try? fm.copyItem(at: foundHelper, to: cachedHelper)
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cachedHost.path)
        if fm.fileExists(atPath: cachedHelper.path) {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cachedHelper.path)
        }
        return .success(HostBinaries(
            hostExecutable: cachedHost,
            vaGuardDylib: cachedDylib,
            ns2Helper: fm.isExecutableFile(atPath: cachedHelper.path) ? cachedHelper : nil,
            cacheDirectory: cacheDir
        ))
    }

    /// Minimal native arm64 Mach-O launcher that reads `../Resources/s2arm-launch.json`,
    /// creates persistent data subdirectories, sets S2Arm env vars, and execs `s2arm-host`.
    package static let launcherCSource = #"""
    #include <errno.h>
    #include <limits.h>
    #include <mach-o/dyld.h>
    #include <stdbool.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/stat.h>
    #include <unistd.h>

    static int mkdir_p(const char *path) {
        char tmp[PATH_MAX];
        size_t len = strlen(path);
        if (len == 0 || len >= sizeof(tmp)) return -1;
        memcpy(tmp, path, len + 1);
        for (char *p = tmp + 1; *p; p++) {
            if (*p == '/') {
                *p = '\0';
                if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
                *p = '/';
            }
        }
        if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
        return 0;
    }

    static bool json_get_string(const char *json, const char *key, char *out, size_t out_cap) {
        char needle[128];
        int n = snprintf(needle, sizeof(needle), "\"%s\"", key);
        if (n <= 0 || (size_t)n >= sizeof(needle)) return false;
        const char *p = strstr(json, needle);
        if (!p) return false;
        p += n;
        while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
        if (*p != ':') return false;
        p++;
        while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
        if (*p != '"') return false;
        p++;
        size_t idx = 0;
        while (*p && *p != '"') {
            if (*p == '\\' && p[1]) {
                p++;
                char c = *p;
                if (c == 'n') c = '\n';
                else if (c == 'r') c = '\r';
                else if (c == 't') c = '\t';
                else if (c == 'u' && p[1] && p[2] && p[3] && p[4]) {
                    char hex[5] = {p[1], p[2], p[3], p[4], 0};
                    unsigned int cp = (unsigned int)strtoul(hex, NULL, 16);
                    p += 4;
                    if (cp < 0x80) {
                        if (idx + 1 < out_cap) out[idx++] = (char)cp;
                    } else if (cp < 0x800) {
                        if (idx + 2 < out_cap) {
                            out[idx++] = (char)(0xC0 | (cp >> 6));
                            out[idx++] = (char)(0x80 | (cp & 0x3F));
                        }
                    } else {
                        if (idx + 3 < out_cap) {
                            out[idx++] = (char)(0xE0 | (cp >> 12));
                            out[idx++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                            out[idx++] = (char)(0x80 | (cp & 0x3F));
                        }
                    }
                    p++;
                    continue;
                }
                if (idx + 1 < out_cap) out[idx++] = c;
                p++;
            } else {
                if (idx + 1 < out_cap) out[idx++] = *p;
                p++;
            }
        }
        out[idx] = '\0';
        return idx > 0;
    }

    int main(int argc, char **argv) {
        (void)argc;
        char raw_exe[PATH_MAX];
        uint32_t sz = sizeof(raw_exe);
        if (_NSGetExecutablePath(raw_exe, &sz) != 0) {
            if (!argv || !argv[0]) return 1;
            strncpy(raw_exe, argv[0], sizeof(raw_exe) - 1);
            raw_exe[sizeof(raw_exe) - 1] = '\0';
        }
        char resolved[PATH_MAX];
        if (!realpath(raw_exe, resolved)) {
            strncpy(resolved, raw_exe, sizeof(resolved) - 1);
            resolved[sizeof(resolved) - 1] = '\0';
        }
        char *slash = strrchr(resolved, '/');
        if (!slash) return 1;
        *slash = '\0';

        char cfg_path[PATH_MAX];
        snprintf(cfg_path, sizeof(cfg_path), "%s/../Resources/s2arm-launch.json", resolved);
        FILE *f = fopen(cfg_path, "rb");
        if (!f) {
            fprintf(stderr, "s2arm-launch: cannot open %s\n", cfg_path);
            return 1;
        }
        char buf[16384];
        size_t rd = fread(buf, 1, sizeof(buf) - 1, f);
        fclose(f);
        buf[rd] = '\0';

        char mac_root[PATH_MAX] = {0};
        char title_id[64] = {0};
        char game_name[512] = {0};
        if (!json_get_string(buf, "macRootPath", mac_root, sizeof(mac_root))) {
            fprintf(stderr, "s2arm-launch: missing macRootPath\n");
            return 1;
        }
        if (!json_get_string(buf, "titleID", title_id, sizeof(title_id))) {
            strncpy(title_id, "0000000000000000", sizeof(title_id) - 1);
        }
        if (!json_get_string(buf, "gameName", game_name, sizeof(game_name))) {
            strncpy(game_name, title_id, sizeof(game_name) - 1);
        }

        const char *home = getenv("HOME");
        if (!home || !home[0]) home = "/tmp";
        char data_root[PATH_MAX];
        snprintf(data_root, sizeof(data_root), "%s/Library/Application Support/NX2Apple/s2arm-data/%s", home, title_id);

        char saves_dir[PATH_MAX], save_data_dir[PATH_MAX], shader_dir[PATH_MAX];
        char docs_dir[PATH_MAX], ryu_dir[PATH_MAX], pso_dir[PATH_MAX], macro_dir[PATH_MAX], playtime_path[PATH_MAX];
        char snapshot_dir[PATH_MAX], cheats_dir[PATH_MAX], mods_dir[PATH_MAX];
        snprintf(saves_dir, sizeof(saves_dir), "%s/saves", data_root);
        snprintf(save_data_dir, sizeof(save_data_dir), "%s/SaveData", data_root);
        snprintf(shader_dir, sizeof(shader_dir), "%s/shader-cache", data_root);
        snprintf(docs_dir, sizeof(docs_dir), "%s/docs", data_root);
        snprintf(ryu_dir, sizeof(ryu_dir), "%s/ryu-data", data_root);
        snprintf(pso_dir, sizeof(pso_dir), "%s/pso-dev", data_root);
        snprintf(macro_dir, sizeof(macro_dir), "%s/macro-dump", data_root);
        snprintf(playtime_path, sizeof(playtime_path), "%s/playtime.json", data_root);
        snprintf(snapshot_dir, sizeof(snapshot_dir), "%s/snapshot", data_root);
        snprintf(cheats_dir, sizeof(cheats_dir), "%s/cheats", data_root);
        snprintf(mods_dir, sizeof(mods_dir), "%s/mods", data_root);

        mkdir_p(saves_dir);
        mkdir_p(save_data_dir);
        mkdir_p(shader_dir);
        mkdir_p(docs_dir);
        mkdir_p(ryu_dir);
        mkdir_p(pso_dir);
        mkdir_p(macro_dir);
        mkdir_p(snapshot_dir);
        mkdir_p(cheats_dir);
        mkdir_p(mods_dir);

        setenv("S2A_IPHONE_VA", "0", 1);
        setenv("S2A_GAME_DATA", mac_root, 1);
        setenv("S2A_RYU_DATA", ryu_dir, 1);
        setenv("S2A_SAVE_FOLDER", save_data_dir, 1);
        setenv("S2A_DOCS", docs_dir, 1);
        setenv("S2A_PLAYTIME", playtime_path, 1);
        setenv("NXGAL_SHADER_CACHE_DIR", shader_dir, 1);
        setenv("NXGAL_PSO_DEV_DIR", pso_dir, 1);
        setenv("S2A_MACRO_DUMP", macro_dir, 1);
        setenv("S2A_SNAPSHOT_DIR", snapshot_dir, 1);
        setenv("S2A_CHEATS_DIR", cheats_dir, 1);
        setenv("S2A_MODS_DIR", mods_dir, 1);
        setenv("S2A_DOCKED", "1", 1);
        setenv("S2A_AUTOPLAY", "0", 1);
        setenv("S2A_GAME_NAME", game_name, 1);
        setenv("S2A_GAME_ID", title_id, 1);

        (void)chdir(docs_dir);

        char host_path[PATH_MAX];
        snprintf(host_path, sizeof(host_path), "%s/s2arm-host", resolved);
        char *child_argv[] = {host_path, mac_root, NULL};
        execv(host_path, child_argv);
        fprintf(stderr, "s2arm-launch: execv(%s) failed: %s\n", host_path, strerror(errno));
        return 127;
    }
    """#

    package static func infoPlist(titleID: String, gameName: String, hasIcon: Bool) -> [String: Any] {
        let tidUpper = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let tidLower = tidUpper.lowercased()
        let name = gameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tidUpper : gameName
        var plist: [String: Any] = [
            "CFBundleIdentifier": "org.s2arm.game.\(tidLower)",
            "DMUpstream": "s2arm",
            "S2ATitleID": tidUpper,
            "DMTitleID": tidUpper,
            "CFBundleDisplayName": name,
            "CFBundleName": name,
            "CFBundleExecutable": "s2arm-launch",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "15.0",
            "NSHighResolutionCapable": true,
            "LSSupportsGameMode": false,
            "LSApplicationCategoryType": "public.app-category.games",
            "NSBluetoothAlwaysUsageDescription": "Connect game controllers over Bluetooth.",
        ]
        if hasIcon {
            plist["CFBundleIconFile"] = "AppIcon"
        }
        return plist
    }

    private static func findIconImage(in macRootPath: String, fileManager fm: FileManager) -> URL? {
        let root = URL(fileURLWithPath: macRootPath, isDirectory: true)
        for rel in ["icon.jpg", "icon.png", "icon.jpeg", "control/icon.jpg", "control/icon.png"] {
            let cand = root.appendingPathComponent(rel)
            if fm.fileExists(atPath: cand.path) {
                return cand
            }
        }
        return nil
    }

    private static func generateICNS(
        from imageURL: URL,
        to icnsURL: URL,
        runner: ProcessRunner,
        fileManager fm: FileManager
    ) -> Bool {
        let iconset = icnsURL.deletingLastPathComponent().appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try? fm.removeItem(at: iconset)
        defer { try? fm.removeItem(at: iconset) }
        do {
            try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let sizes: [(Int, String)] = [
            (16, "icon_16x16.png"),
            (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"),
            (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"),
            (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png"),
        ]
        for (px, filename) in sizes {
            let out = iconset.appendingPathComponent(filename)
            let res = runner.capture(ProcessLaunch(
                executable: "/usr/bin/sips",
                arguments: ["-z", "\(px)", "\(px)", "-s", "format", "png", imageURL.path, "--out", out.path]
            ))
            guard res.ok else { return false }
        }
        let utilRes = runner.capture(ProcessLaunch(
            executable: "/usr/bin/iconutil",
            arguments: ["-c", "icns", iconset.path, "-o", icnsURL.path]
        ))
        return utilRes.ok && fm.fileExists(atPath: icnsURL.path)
    }

    /// Packages an S2Arm macRootPath + compiled host into a signed `.app` bundle at `destinationAppURL`.
    package static func packApp(
        s2armTree: String,
        macRootPath: String,
        titleID: String,
        gameName: String,
        destinationAppURL: URL,
        upstreamsRoot: URL,
        home: String = NSHomeDirectory(),
        runner: ProcessRunner = SystemProcessRunner(),
        fileManager fm: FileManager = .default,
        onLine: (@Sendable (String) -> Void)? = nil
    ) -> Result<URL, PackError> {
        let hostResult = ensureHostBinaries(
            s2armTree: s2armTree,
            upstreamsRoot: upstreamsRoot,
            home: home,
            runner: runner,
            fileManager: fm,
            onLine: onLine
        )
        let binaries: HostBinaries
        switch hostResult {
        case .success(let b): binaries = b
        case .failure(let err): return .failure(err)
        }

        let stagingRoot = destinationAppURL.deletingLastPathComponent()
            .appendingPathComponent(".s2arm-pack-" + UUID().uuidString, isDirectory: true)
        let stagedApp = stagingRoot.appendingPathComponent("Game.app", isDirectory: true)
        let contentsDir = stagedApp.appendingPathComponent("Contents", isDirectory: true)
        let macOSDir = contentsDir.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesDir = contentsDir.appendingPathComponent("Resources", isDirectory: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        do {
            try fm.createDirectory(at: macOSDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

            let destHost = macOSDir.appendingPathComponent("s2arm-host")
            let destDylib = macOSDir.appendingPathComponent("libs2a_vaguard.dylib")
            try fm.copyItem(at: binaries.hostExecutable, to: destHost)
            try fm.copyItem(at: binaries.vaGuardDylib, to: destDylib)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destHost.path)

            var toSign = [destDylib, destHost]
            if let helper = binaries.ns2Helper {
                let destHelper = macOSDir.appendingPathComponent("S2ArmNS2Connection")
                try fm.copyItem(at: helper, to: destHelper)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destHelper.path)
                toSign.append(destHelper)
            }

            // Compile native Mach-O launcher `s2arm-launch`
            let srcC = stagingRoot.appendingPathComponent("s2arm-launch.c")
            let outLaunch = macOSDir.appendingPathComponent("s2arm-launch")
            try Data(launcherCSource.utf8).write(to: srcC)
            let devDir = Toolchain.developerDir(runner: runner)
            var clangEnv = ProcessInfo.processInfo.environment
            if let devDir { clangEnv["DEVELOPER_DIR"] = devDir }
            let clangRes = runner.capture(ProcessLaunch(
                executable: "/usr/bin/xcrun",
                arguments: ["clang", "-O2", "-arch", "arm64", "-o", outLaunch.path, srcC.path],
                environment: clangEnv
            ))
            guard clangRes.ok, fm.fileExists(atPath: outLaunch.path) else {
                let detail = (clangRes.err + "\n" + clangRes.out).trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(.launcherCompileFailed(detail.isEmpty ? "exit \(clangRes.status)" : detail))
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outLaunch.path)

            // Write s2arm-launch.json
            let tidUpper = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let cleanName = gameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tidUpper : gameName
            let cfg: [String: String] = [
                "gameName": cleanName,
                "macRootPath": macRootPath,
                "titleID": tidUpper,
            ]
            let cfgData = try JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys])
            try cfgData.write(to: resourcesDir.appendingPathComponent("s2arm-launch.json"))

            // Optional icon from macRootPath
            var hasIcon = false
            if let iconImg = findIconImage(in: macRootPath, fileManager: fm) {
                hasIcon = generateICNS(
                    from: iconImg,
                    to: resourcesDir.appendingPathComponent("AppIcon.icns"),
                    runner: runner,
                    fileManager: fm
                )
            }

            // Write Info.plist
            let plistObj = infoPlist(titleID: tidUpper, gameName: cleanName, hasIcon: hasIcon)
            let plistData = try PropertyListSerialization.data(fromPropertyList: plistObj, format: .xml, options: 0)
            try plistData.write(to: contentsDir.appendingPathComponent("Info.plist"))

            // Ad-hoc sign dylib, helpers, and outer bundle
            for bin in toSign {
                let signRes = runner.capture(ProcessLaunch(
                    executable: "/usr/bin/codesign",
                    arguments: ["--force", "--sign", "-", bin.path]
                ))
                guard signRes.ok else {
                    return .failure(.codesignFailed("\(bin.lastPathComponent): \(signRes.err)"))
                }
            }
            let appSignRes = runner.capture(ProcessLaunch(
                executable: "/usr/bin/codesign",
                arguments: ["--force", "--sign", "-", stagedApp.path]
            ))
            guard appSignRes.ok else {
                return .failure(.codesignFailed(appSignRes.err.isEmpty ? "exit \(appSignRes.status)" : appSignRes.err))
            }

            // Atomically place into destinationAppURL
            try fm.createDirectory(at: destinationAppURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let backup = destinationAppURL.deletingLastPathComponent()
                .appendingPathComponent(".old-s2app-" + UUID().uuidString + ".app", isDirectory: true)
            let hadDest = fm.fileExists(atPath: destinationAppURL.path)
            if hadDest {
                try? fm.moveItem(at: destinationAppURL, to: backup)
            }
            do {
                try fm.moveItem(at: stagedApp, to: destinationAppURL)
            } catch {
                try? fm.removeItem(at: destinationAppURL)
                if hadDest && fm.fileExists(atPath: backup.path) {
                    try? fm.moveItem(at: backup, to: destinationAppURL)
                }
                return .failure(.bundleWriteFailed(error.localizedDescription))
            }
            if fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: backup)
            }
            return .success(destinationAppURL)
        } catch {
            return .failure(.bundleWriteFailed(error.localizedDescription))
        }
    }
}
