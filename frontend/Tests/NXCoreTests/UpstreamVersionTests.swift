import Foundation
import XCTest
@testable import NXCore

final class UpstreamVersionTests: XCTestCase {
    private var temporary: URL!
    private var storeRoot: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("upstream-ver-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        storeRoot = temporary.appendingPathComponent("upstreams", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    /// Creates a real ZIP archive with an optional EOCD comment (matching GitHub codeload format).
    private func makeZip(of folder: URL, name: String, comment: String? = nil) throws -> URL {
        let out = temporary.appendingPathComponent(name)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = """
        import os, sys, zipfile
        src, dst = sys.argv[1], sys.argv[2]
        comment = sys.argv[3] if len(sys.argv) > 3 else ""
        root_name = os.path.basename(os.path.normpath(src))
        with zipfile.ZipFile(dst, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            for base, _, files in os.walk(src):
                for fn in files:
                    full = os.path.join(base, fn)
                    rel = os.path.join(root_name, os.path.relpath(full, src))
                    zf.write(full, rel)
            if comment:
                zf.comment = comment.encode("utf-8")
        """
        var args = ["-c", script, folder.path, out.path]
        if let comment { args.append(comment) }
        proc.arguments = args
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
        return out
    }

    private func makeS2ArmFolder(name: String, complete: Bool = true) throws -> URL {
        let dir = temporary.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("pack/jobs"), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8).write(to: dir.appendingPathComponent("pack/jobs/main.py"))
        if complete {
            try fm.createDirectory(at: dir.appendingPathComponent("runtime/rewriter"), withIntermediateDirectories: true)
            try Data("/* rewriter */\n".utf8).write(to: dir.appendingPathComponent("runtime/rewriter/rewriter.c"))
            try fm.createDirectory(at: dir.appendingPathComponent("pack/oneclick"), withIntermediateDirectories: true)
            try Data("#!/bin/bash\n".utf8).write(to: dir.appendingPathComponent("pack/oneclick/oneclick.sh"))
        }
        return dir
    }

    private func makeMNGFolder(name: String) throws -> URL {
        let dir = temporary.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("games/totk"), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8).write(to: dir.appendingPathComponent("build_app.py"))
        return dir
    }

    func testExtractGitCommitFromRealZipEOCDAndReceiptWriteOnInstall() throws {
        let sha = "21459d5a1234567890abcdef1234567890abcdef"
        let folder = try makeS2ArmFolder(name: "S2Arm-main")
        let zip = try makeZip(of: folder, name: "s2arm-eocd.zip", comment: sha.uppercased())
        XCTAssertEqual(UpstreamVersion.extractGitCommitFromZip(zip), sha)

        let noCommentZip = try makeZip(of: folder, name: "s2arm-plain.zip")
        XCTAssertNil(UpstreamVersion.extractGitCommitFromZip(noCommentZip))

        let badCommentZip = try makeZip(of: folder, name: "s2arm-bad-comment.zip", comment: "not-a-sha")
        XCTAssertNil(UpstreamVersion.extractGitCommitFromZip(badCommentZip))

        let store = UpstreamEngineStore(root: storeRoot)
        let remote = UpstreamRemoteInfo(kind: .s2arm, commit: sha, version: "v0.5.8", date: "2026.11.19")
        let installed = try store.install(zip: zip, kind: .s2arm, remoteInfo: remote)
        let receipt = try XCTUnwrap(UpstreamVersion.localReceipt(for: .s2arm, directory: installed.path))
        XCTAssertEqual(receipt.commit, sha)
        XCTAssertEqual(receipt.version, "v0.5.8")
        XCTAssertFalse(receipt.installedAt.isEmpty)
        XCTAssertFalse(UpstreamVersion.hasUpdate(local: receipt, remote: remote))
    }

    func testLegacyInstallFallbackUsesEntryMtimeAndFlagsUpdate() throws {
        let dir = try makeMNGFolder(name: "legacy-mng")
        let script = dir.appendingPathComponent("build_app.py")
        let fixedDate = Date(timeIntervalSince1970: 1_763_424_000) // 2025-11-18 00:00:00 UTC
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: script.path)

        let receipt = try XCTUnwrap(UpstreamVersion.localReceipt(for: .macNativeGames, directory: dir.path))
        XCTAssertNil(receipt.commit)
        XCTAssertEqual(receipt.version, "2025.11.18")

        let remote = UpstreamRemoteInfo(
            kind: .macNativeGames,
            commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            version: "2025.11.18",
            date: "2025.11.18"
        )
        XCTAssertTrue(UpstreamVersion.hasUpdate(local: receipt, remote: remote))
    }

    func testFailedUpdatePreservesExistingTreeAndOldReceipt() throws {
        let oldSHA = "1111111111111111111111111111111111111111"
        let store = UpstreamEngineStore(root: storeRoot)
        let goodZip = try makeZip(of: try makeS2ArmFolder(name: "S2Arm-v1"), name: "good.zip", comment: oldSHA)
        let installed = try store.install(
            zip: goodZip,
            kind: .s2arm,
            remoteInfo: UpstreamRemoteInfo(kind: .s2arm, commit: oldSHA, version: "v0.5.7", date: "2026.11.10")
        )

        let badZip = try makeZip(of: try makeS2ArmFolder(name: "S2Arm-bad", complete: false), name: "bad.zip")
        XCTAssertThrowsError(try store.install(zip: badZip, kind: .s2arm))

        let preserved = try XCTUnwrap(UpstreamVersion.localReceipt(for: .s2arm, directory: installed.path))
        XCTAssertEqual(preserved.commit, oldSHA)
        XCTAssertEqual(preserved.version, "v0.5.7")
    }

    func testParseInfoRefsForS2ArmAndMacNativeGames() throws {
        let shaMain = "64ba1861cedebd244256c4bf8fa41340e8aa4a28"
        let shaTagObj = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let shaTagCommit = "70f3dbe16699127e0cc53c4992e3ac2500d8bbaa"

        // Real pkt-line format with NUL capabilities, flush 0000, annotated tag ^{}, and impactor-* noise.
        let s2AheadLines = [
            "001e# service=git-upload-pack",
            "00000159\(shaMain) HEAD\0multi_ack symref=HEAD:refs/heads/main",
            "003d\(shaMain) refs/heads/main",
            "0040\(shaMain) refs/tags/impactor-2.0",
            "003e\(shaTagObj) refs/tags/v0.5.7",
            "003e\(shaTagObj) refs/tags/v0.5.8",
            "0041\(shaTagCommit) refs/tags/v0.5.8^{}",
            "0000",
        ]
        let s2AheadPayload = Data(s2AheadLines.joined(separator: "\n").utf8)
        let ahead = try XCTUnwrap(UpstreamVersion.parseInfoRefs(kind: .s2arm, data: s2AheadPayload))
        XCTAssertEqual(ahead.commit, shaMain)
        XCTAssertEqual(ahead.version, "v0.5.8+")

        // Annotated tag dereference (^{}) matches main -> exact semver without "+".
        let s2ExactLines = [
            "001e# service=git-upload-pack",
            "0000003d\(shaMain) refs/heads/main",
            "003e\(shaTagObj) refs/tags/v0.5.8",
            "0041\(shaMain) refs/tags/v0.5.8^{}",
            "003e\(shaTagCommit) refs/tags/v0.5.7",
        ]
        let s2ExactPayload = Data(s2ExactLines.joined(separator: "\n").utf8)
        let exact = try XCTUnwrap(UpstreamVersion.parseInfoRefs(kind: .s2arm, data: s2ExactPayload))
        XCTAssertEqual(exact.version, "v0.5.8")

        // Numeric semver comparison: v0.5.10 > v0.5.9
        let s2NumericLines = [
            "003d\(shaMain) refs/heads/main",
            "003e\(shaTagCommit) refs/tags/v0.5.9",
            "003f\(shaMain) refs/tags/v0.5.10",
        ]
        let s2NumericPayload = Data(s2NumericLines.joined(separator: "\n").utf8)
        let numeric = try XCTUnwrap(UpstreamVersion.parseInfoRefs(kind: .s2arm, data: s2NumericPayload))
        XCTAssertEqual(numeric.version, "v0.5.10")

        // No semver tags -> fallback to 7-char short SHA
        let s2NoTags = Data("003d\(shaMain) refs/heads/main\n".utf8)
        let fallback = try XCTUnwrap(UpstreamVersion.parseInfoRefs(kind: .s2arm, data: s2NoTags))
        XCTAssertEqual(fallback.version, "64ba186")

        // MacNativeGames: source-YYYYMMDD-<sha> exact match vs ahead (+) + same-day different SHA update check
        let mngMain = "778ab5f9ac1ca79a204a32b62400539bb58c7cfb"
        let mngSnap = "7a158084c306e8ea348a95c5cefe029b9bb03690"
        let mngAheadLines = [
            "001e# service=git-upload-pack",
            "0000003d\(mngMain) refs/heads/main",
            "0047\(shaTagCommit) refs/tags/launcher-v1.0.9",
            "0050\(mngSnap) refs/tags/source-20261118-7a158084",
        ]
        let mngAheadPayload = Data(mngAheadLines.joined(separator: "\n").utf8)
        let mngAhead = try XCTUnwrap(UpstreamVersion.parseInfoRefs(kind: .macNativeGames, data: mngAheadPayload))
        XCTAssertEqual(mngAhead.commit, mngMain)
        XCTAssertEqual(mngAhead.version, "2026.11.18+")

        let mngExactLines = [
            "003d\(mngSnap) refs/heads/main",
            "0050\(mngSnap) refs/tags/source-20261118-7a158084",
        ]
        let mngExactPayload = Data(mngExactLines.joined(separator: "\n").utf8)
        let mngExact = try XCTUnwrap(UpstreamVersion.parseInfoRefs(kind: .macNativeGames, data: mngExactPayload))
        XCTAssertEqual(mngExact.version, "2026.11.18")

        // Same day, different 40-char SHA must still detect an update.
        let localSameDay = UpstreamVersionReceipt(commit: mngSnap, version: "2026.11.18", installedAt: "2026.11.18")
        XCTAssertTrue(UpstreamVersion.hasUpdate(local: localSameDay, remote: mngAhead))
        let localSameSHA = UpstreamVersionReceipt(commit: mngMain, version: "2026.11.18+", installedAt: "2026.11.18")
        XCTAssertFalse(UpstreamVersion.hasUpdate(local: localSameSHA, remote: mngAhead))
    }

    func testFirstTimeDownloadAutoFetchesInfoRefsForSemanticVersionReceipt() throws {
        final class InfoRefsTransport: EngineTransport, @unchecked Sendable {
            let zipURL: URL
            let refsData: Data
            init(zipURL: URL, refsData: Data) { self.zipURL = zipURL; self.refsData = refsData }
            func data(from url: URL) -> EngineFetch<Data> { .ok(refsData) }
            func download(from url: URL, to destination: URL) -> Bool {
                guard let payload = try? Data(contentsOf: zipURL) else { return false }
                return (try? payload.write(to: destination)) != nil
            }
        }

        let mainSHA = "64ba1861cedebd244256c4bf8fa41340e8aa4a28"
        let tagSHA = "70f3dbe16699127e0cc53c4992e3ac2500d8bbaa"
        let zip = try makeZip(of: try makeS2ArmFolder(name: "S2Arm-first"), name: "first.zip", comment: mainSHA)
        let refs = Data("003d\(mainSHA) refs/heads/main\n003e\(tagSHA) refs/tags/v0.5.8\n".utf8)
        let transport = InfoRefsTransport(zipURL: zip, refsData: refs)
        let store = UpstreamEngineStore(root: storeRoot)

        let res = store.downloadAndInstall(kind: .s2arm, transport: transport, remoteInfo: nil)
        switch res {
        case .success(let dir):
            let receipt = try XCTUnwrap(UpstreamVersion.localReceipt(for: .s2arm, directory: dir.path))
            XCTAssertEqual(receipt.commit, mainSHA)
            XCTAssertEqual(receipt.version, "v0.5.8+")
        case .failure(let err):
            XCTFail("Expected success, got \(err)")
        }
    }

    func testBuiltInReceiptAndCompactBadgeFormatting() throws {
        let repo = temporary.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("0b5fd6020093abcdef1234567890abcdef123456\n".utf8).write(to: repo.appendingPathComponent(".upstream-ref"))

        let builtIn = try XCTUnwrap(UpstreamVersion.builtInReceipt(repoPath: repo.path, bundleResources: nil))
        XCTAssertEqual(builtIn.version, "0b5fd60")
        XCTAssertEqual(
            UpstreamVersion.compactBadgeText(kind: .nxnative, local: builtIn, hasUpdate: false, builtInFallback: "Built-in", installedFallback: "Installed"),
            "0b5fd60"
        )
        XCTAssertEqual(
            UpstreamVersion.compactBadgeText(kind: .nxnative, local: nil, hasUpdate: false, builtInFallback: "Built-in", installedFallback: "Installed"),
            "Built-in"
        )
        let localS2 = UpstreamVersionReceipt(commit: "1111111111111111111111111111111111111111", version: "v0.5.7", installedAt: "2026.11.18")
        XCTAssertEqual(
            UpstreamVersion.compactBadgeText(kind: .s2arm, local: localS2, hasUpdate: true, builtInFallback: "Built-in", installedFallback: "Installed"),
            "v0.5.7 ↑"
        )
        XCTAssertEqual(
            UpstreamVersion.compactBadgeText(kind: .s2arm, local: localS2, hasUpdate: false, builtInFallback: "Built-in", installedFallback: "Installed"),
            "v0.5.7"
        )
    }

    func testS2ArmResolveSourceDirectoryForSingleAndSharedNupFolders() throws {
        let soloDir = temporary.appendingPathComponent("solo", isDirectory: true)
        try FileManager.default.createDirectory(at: soloDir, withIntermediateDirectories: true)
        let soloNup = soloDir.appendingPathComponent("Game.nup")
        try Data("nup".utf8).write(to: soloNup)

        let workDir = temporary.appendingPathComponent("work", isDirectory: true).path
        let soloResolved = S2ArmBuilder.resolveSourceDirectory(soloNup.path, workDir: workDir)
        XCTAssertFalse(soloResolved.stagingFailed)
        XCTAssertNil(soloResolved.stagedDirectory)
        XCTAssertEqual(soloResolved.directory, soloDir.path)

        let sharedDir = temporary.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        let targetNup = sharedDir.appendingPathComponent("GameA.nup")
        let otherPkg = sharedDir.appendingPathComponent("GameB.nsp")
        try Data("nup-a".utf8).write(to: targetNup)
        try Data("nsp-b".utf8).write(to: otherPkg)

        let sharedResolved = S2ArmBuilder.resolveSourceDirectory(targetNup.path, workDir: workDir)
        XCTAssertFalse(sharedResolved.stagingFailed)
        let staged = try XCTUnwrap(sharedResolved.stagedDirectory)
        XCTAssertEqual(sharedResolved.directory, staged)
        let stagedItems = try FileManager.default.contentsOfDirectory(atPath: staged)
        XCTAssertEqual(stagedItems, ["GameA.nup"])
    }

    func testProxyEnvironmentMergesExplicitVarsAndBridgesSystemProxySettings() {
        // 1. Explicit process env pairs lower/upper keys and wins over systemSettings.
        let explicit = ProxyEnvironment.merged(
            into: ["PATH": "/usr/bin"],
            processEnv: ["https_proxy": "http://127.0.0.1:7890", "NO_PROXY": "localhost,127.0.0.1"],
            systemSettings: [
                "HTTPEnable": 1, "HTTPProxy": "10.0.0.1", "HTTPPort": 8080,
            ]
        )
        XCTAssertEqual(explicit["https_proxy"], "http://127.0.0.1:7890")
        XCTAssertEqual(explicit["HTTPS_PROXY"], "http://127.0.0.1:7890")
        XCTAssertEqual(explicit["no_proxy"], "localhost,127.0.0.1")
        XCTAssertEqual(explicit["NO_PROXY"], "localhost,127.0.0.1")
        XCTAssertNil(explicit["http_proxy"])
        XCTAssertEqual(explicit["GIT_CONFIG_COUNT"], "2")
        XCTAssertEqual(explicit["GIT_CONFIG_KEY_0"], "http.version")
        XCTAssertEqual(explicit["GIT_CONFIG_VALUE_0"], "HTTP/1.1")
        XCTAssertEqual(explicit["GIT_CONFIG_KEY_1"], "http.postBuffer")
        XCTAssertEqual(explicit["GIT_CONFIG_VALUE_1"], "524288000")

        // 1b. Preserves caller/process GIT_CONFIG_COUNT and skips git overrides when no proxy is active.
        let customGit = ProxyEnvironment.merged(
            into: ["GIT_CONFIG_COUNT": "1"],
            processEnv: ["https_proxy": "http://127.0.0.1:7890"],
            systemSettings: [:]
        )
        XCTAssertEqual(customGit["GIT_CONFIG_COUNT"], "1")
        XCTAssertNil(customGit["GIT_CONFIG_KEY_0"])
        let customGitProc = ProxyEnvironment.merged(
            into: [:],
            processEnv: ["https_proxy": "http://127.0.0.1:7890", "GIT_CONFIG_COUNT": "1"],
            systemSettings: [:]
        )
        XCTAssertNil(customGitProc["GIT_CONFIG_KEY_0"])
        let noProxy = ProxyEnvironment.merged(into: [:], processEnv: [:], systemSettings: [:])
        XCTAssertNil(noProxy["GIT_CONFIG_COUNT"])

        // 2. Falls back to macOS system HTTP/HTTPS settings when processEnv has no proxy.
        let bridgedHTTP = ProxyEnvironment.merged(
            into: [:],
            processEnv: [:],
            systemSettings: [
                "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
                "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890,
                "ExceptionsList": ["*.local", "169.254/16"],
            ]
        )
        XCTAssertEqual(bridgedHTTP["GIT_CONFIG_COUNT"], "2")
        XCTAssertEqual(bridgedHTTP["http_proxy"], "http://127.0.0.1:7890")
        XCTAssertEqual(bridgedHTTP["HTTP_PROXY"], "http://127.0.0.1:7890")
        XCTAssertEqual(bridgedHTTP["https_proxy"], "http://127.0.0.1:7890")
        XCTAssertEqual(bridgedHTTP["HTTPS_PROXY"], "http://127.0.0.1:7890")
        XCTAssertEqual(bridgedHTTP["no_proxy"], "*.local,169.254/16")

        // 3. Falls back to SOCKS5 when only SOCKS is enabled.
        let bridgedSOCKS = ProxyEnvironment.merged(
            into: [:],
            processEnv: [:],
            systemSettings: [
                "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 1080,
            ]
        )
        XCTAssertEqual(bridgedSOCKS["all_proxy"], "socks5h://127.0.0.1:1080")
        XCTAssertEqual(bridgedSOCKS["ALL_PROXY"], "socks5h://127.0.0.1:1080")

        // 4. URLSession proxy dictionary built from explicit env vars.
        let dict = ProxyEnvironment.urlSessionProxyDictionary(
            processEnv: ["HTTPS_PROXY": "http://127.0.0.1:7890", "http_proxy": "http://127.0.0.1:7891"]
        )
        XCTAssertEqual(dict?["HTTPSEnable"] as? Int, 1)
        XCTAssertEqual(dict?["HTTPSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(dict?["HTTPSPort"] as? Int, 7890)
        XCTAssertEqual(dict?["HTTPEnable"] as? Int, 1)
        XCTAssertEqual(dict?["HTTPPort"] as? Int, 7891)
        XCTAssertNil(ProxyEnvironment.urlSessionProxyDictionary(processEnv: [:]))
    }
}
