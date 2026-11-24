import Darwin
import Foundation
import Security
import Testing
import ShellUI
@testable import ShellHost

#if os(macOS)
private struct FakeCertPicker: SideloadCertificatePicker {
    var outcome: CertificatePickOutcome
    @MainActor func pickCertificateOutcome() async -> CertificatePickOutcome { outcome }
}

@MainActor private final class CapturingLauncher: GameLauncher {
    private(set) var launched: [LaunchableGame] = []
    func launch(_ game: LaunchableGame) async throws {
        launched.append(game)
    }
}

@MainActor private final class FailOnceThenSucceedLauncher: GameLauncher {
    enum TestLaunchError: LocalizedError {
        case refusedSignature
        var errorDescription: String? { "iOS refused the code signature of this game's framework." }
    }
    private(set) var attempts = 0
    private(set) var succeededGames: [LaunchableGame] = []
    func launch(_ game: LaunchableGame) async throws {
        attempts += 1
        if attempts == 1 {
            throw TestLaunchError.refusedSignature
        }
        succeededGames.append(game)
    }
}

@Suite(.serialized) struct MachOLocalSignerTests {
    private struct CommandOutput {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandOutput(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    private static func generateP12(in dir: URL, name: String, keyKind: String,
                                    commonName: String, teamID: String, password: String) throws -> Data {
        let keyURL = dir.appendingPathComponent("\(name).key")
        let csrURL = dir.appendingPathComponent("\(name).csr")
        let crtURL = dir.appendingPathComponent("\(name).crt")
        let extURL = dir.appendingPathComponent("\(name).ext")
        let p12URL = dir.appendingPathComponent("\(name).p12")
        let subject = "/CN=\(commonName)/OU=\(teamID)/O=NX2Apple Test/C=US"

        let extConfig = """
        [v3_codesign]
        basicConstraints=CA:FALSE
        keyUsage=critical,digitalSignature
        extendedKeyUsage=critical,codeSigning
        """
        try Data(extConfig.utf8).write(to: extURL)

        if keyKind == "ec" {
            let gen = try run("/usr/bin/openssl", ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", keyURL.path])
            #expect(gen.status == 0, "openssl ecparam failed: \(gen.stderr)")
        } else {
            let gen = try run("/usr/bin/openssl", ["genrsa", "-out", keyURL.path, "2048"])
            #expect(gen.status == 0, "openssl genrsa failed: \(gen.stderr)")
        }

        let csr = try run("/usr/bin/openssl", ["req", "-new", "-key", keyURL.path, "-out", csrURL.path, "-subj", subject])
        #expect(csr.status == 0, "openssl req csr failed: \(csr.stderr)")

        let x509 = try run("/usr/bin/openssl", [
            "x509", "-req", "-sha256", "-in", csrURL.path, "-signkey", keyURL.path,
            "-out", crtURL.path, "-days", "365", "-extfile", extURL.path, "-extensions", "v3_codesign",
        ])
        #expect(x509.status == 0, "openssl x509 sign failed: \(x509.stderr)")

        let exp = try run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", keyURL.path, "-in", crtURL.path,
                                               "-out", p12URL.path, "-passout", "pass:\(password)"])
        #expect(exp.status == 0, "openssl pkcs12 failed: \(exp.stderr)")
        return try Data(contentsOf: p12URL)
    }

    private static func buildMinimalFramework(in hotRoot: URL, titleID: String = "0100000000010000",
                                              stripSignature: Bool = true) throws -> (frameworkURL: URL, executableURL: URL) {
        let fm = FileManager.default
        let fwName = "DmGame\(titleID)"
        let fwURL = hotRoot.appendingPathComponent("\(fwName).framework", isDirectory: true)
        try fm.createDirectory(at: fwURL, withIntermediateDirectories: true)

        let srcURL = hotRoot.appendingPathComponent("\(fwName)_src.c")
        try Data("int dm_fixture_entry(void) { return 0x2a; }\n".utf8).write(to: srcURL)
        defer { try? fm.removeItem(at: srcURL) }

        let exeURL = fwURL.appendingPathComponent(fwName)
        let clang = try run("/usr/bin/clang", [
            "-arch", "arm64", "-dynamiclib",
            "-install_name", "@rpath/\(fwName).framework/\(fwName)",
            "-o", exeURL.path, srcURL.path,
        ])
        #expect(clang.status == 0, "clang failed: \(clang.stderr)")

        let infoPlist: [String: Any] = [
            "CFBundleExecutable": fwName,
            "CFBundleIdentifier": "org.nxnative.game.\(titleID)",
            "CFBundleName": fwName,
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: fwURL.appendingPathComponent("Info.plist"))

        let manifestJSON = """
        {
          "schema": 1,
          "title_id": "\(titleID)",
          "name": "Local Sign Fixture",
          "display_version": "1.0.0",
          "package_version": "65536",
          "modules": ["main", "sdk"],
          "nro_count": 0,
          "chain": "b-3f9a2c",
          "loader": "FR",
          "framework": "\(fwName).framework",
          "framework_executable": "\(fwName)",
          "image_marker": "dm_fixture_entry",
          "profile": "profile.tsv",
          "shader_map": "dm/shader_map.tsv",
          "launcher": "dm/launcher.json",
          "romfs_marker": "fixture.marker",
          "romfs_identity": "DMROMFSID1 fixture",
          "min_os": "26.0"
        }
        """
        try Data(manifestJSON.utf8).write(to: fwURL.appendingPathComponent("game.manifest.json"))
        try Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0xff, 0xd9])
            .write(to: fwURL.appendingPathComponent("banner.jpg"))
        try Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
            .write(to: fwURL.appendingPathComponent("icon.png"))

        if stripSignature {
            let strip = try run("/usr/bin/codesign", ["--remove-signature", exeURL.path])
            #expect(strip.status == 0, "codesign --remove-signature failed: \(strip.stderr)")
            let info = try #require(FrameworkSignature.inspect(executable: exeURL))
            #expect(!info.hasCodeSignature)
        }
        return (fwURL, exeURL)
    }

    private static func inode(of url: URL) throws -> UInt64 {
        var st = stat()
        let rc = Darwin.lstat(url.path, &st)
        #expect(rc == 0)
        return UInt64(st.st_ino)
    }

    private static func extractCMSSignedAttributes(fromSignedMachO binary: Data) throws -> [Data] {
        // Locate CSSLOT_CMS_SIGNATURE (0x00010000) inside SuperBlob (0xfade0cc0) via FrameworkSignature.inspect offset.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cms-inspect-\(UUID().uuidString)")
        try binary.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let info = try #require(FrameworkSignature.inspect(executable: tmp))
        #expect(info.hasCodeSignature)
        let sbStart = Int(info.signatureOffset)
        let sbEnd = sbStart + Int(info.signatureSize)
        let superBlob = binary.subdata(in: sbStart..<sbEnd)
        func u32BE(_ d: Data, _ off: Int) -> UInt32 {
            (UInt32(d[d.startIndex + off]) << 24) | (UInt32(d[d.startIndex + off + 1]) << 16)
                | (UInt32(d[d.startIndex + off + 2]) << 8) | UInt32(d[d.startIndex + off + 3])
        }
        let slotCount = Int(u32BE(superBlob, 8))
        var cmsDER = Data()
        for i in 0..<slotCount {
            let slotType = u32BE(superBlob, 12 + i * 8)
            let slotOff = Int(u32BE(superBlob, 12 + i * 8 + 4))
            if slotType == 0x0001_0000 {
                let blobLen = Int(u32BE(superBlob, slotOff + 4))
                cmsDER = superBlob.subdata(in: (slotOff + 8)..<(slotOff + blobLen))
                break
            }
        }
        let contentInfo = try #require(ASN1DER.readElement(in: cmsDER, at: cmsDER.startIndex))
        let ciChildren = try #require(ASN1DER.children(of: contentInfo, in: cmsDER))
        let explicit0 = ciChildren[1]
        let signedData = try #require(ASN1DER.children(of: explicit0, in: cmsDER)?.first)
        let sdChildren = try #require(ASN1DER.children(of: signedData, in: cmsDER))
        let signerInfosSet = try #require(sdChildren.last)
        let signerInfo = try #require(ASN1DER.children(of: signerInfosSet, in: cmsDER)?.first)
        let siChildren = try #require(ASN1DER.children(of: signerInfo, in: cmsDER))
        let signedAttrs = try #require(siChildren.first { $0.tag == 0xA0 })
        let attrEls = try #require(ASN1DER.children(of: signedAttrs, in: cmsDER))
        return attrEls.map { $0.fullData(in: cmsDER) }
    }

    @Test func signsUnsignedFrameworkWithRSA2048AndPassesAppleCodesignStrictVerify() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signer-rsa-\(UUID().uuidString)", isDirectory: true)
        let hotRoot = root.appendingPathComponent("Documents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: hotRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let (fwURL, exeURL) = try Self.buildMinimalFramework(in: hotRoot, stripSignature: true)
        let p12 = try Self.generateP12(in: root, name: "rsa_dev", keyKind: "rsa",
                                       commonName: "Apple Development: Test User", teamID: "TESTTEAM99", password: "p12-pass")

        let backing = InMemoryCertBacking()
        let store = SideloadCertificateStore(backing: backing)
        let summary = try store.importPKCS12(data: p12, password: "p12-pass")
        #expect(summary.commonName == "Apple Development: Test User")
        #expect(summary.teamID == "TESTTEAM99")
        #expect(!summary.isExpired)
        #expect(summary.fingerprintHex.count == 64)

        let inodeBefore = try Self.inode(of: exeURL)
        let hostID = "com.sidestore.nx2apple.USER123"
        let didSign = try MachOLocalSigner.ensureSignedIfNeeded(frameworkURL: fwURL, allowedRoot: hotRoot, hostBundleID: hostID, store: store)
        #expect(didSign)

        let inodeAfter = try Self.inode(of: exeURL)
        #expect(inodeAfter != inodeBefore, "atomic replacement must allocate a fresh inode for XNU cs_blobs")

        // Gold standard verification via Apple's official `/usr/bin/codesign --verify --deep --strict --verbose=4`.
        let verify = try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=4", fwURL.path])
        #expect(verify.status == 0, "codesign strict verify failed:\nstdout:\(verify.stdout)\nstderr:\(verify.stderr)")

        let dump = try Self.run("/usr/bin/codesign", ["-dvvv", fwURL.path])
        #expect(dump.status == 0, "codesign -dvvv failed: \(dump.stderr)")
        let combined = dump.stdout + "\n" + dump.stderr
        #expect(combined.contains("Identifier=\(hostID)"), "missing expected host bundle identifier:\n\(combined)")
        #expect(combined.contains("TeamIdentifier=TESTTEAM99"), "missing expected TeamIdentifier:\n\(combined)")

        // Preflight check must now recognize the new team signature cleanly.
        let appBundle = root.appendingPathComponent("DmShell.app", isDirectory: true)
        #expect(FrameworkSignature.preflightExternal(executable: exeURL, appBundleURL: appBundle, hostTeamID: "TESTTEAM99") == nil)

        // Verify strict X.690 DER ascending order of CMS `signedAttrs` (required by iOS AMFI even when macOS codesign is lenient).
        let signedBytes = try Data(contentsOf: exeURL)
        let cmsAttrs = try Self.extractCMSSignedAttributes(fromSignedMachO: signedBytes)
        #expect(cmsAttrs.count == 5)
        #expect(cmsAttrs == cmsAttrs.sorted { $0.lexicographicallyPrecedes($1) }, "CMS signedAttrs must be sorted in ascending DER byte order for iOS AMFI")

        // Second call hits the `.nx-local-sign.json` receipt and skips re-signing without changing the inode.
        let didSignAgain = try MachOLocalSigner.ensureSignedIfNeeded(frameworkURL: fwURL, allowedRoot: hotRoot, hostBundleID: hostID, store: store)
        #expect(!didSignAgain)
        #expect(try Self.inode(of: exeURL) == inodeAfter)

        // Negative check: tampering with a sealed resource must fail strict verification.
        try Data([0x00, 0x01, 0x02]).write(to: fwURL.appendingPathComponent("banner.jpg"))
        let tamperedVerify = try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fwURL.path])
        #expect(tamperedVerify.status != 0, "tampered sealed resource must fail codesign --verify --strict")
    }

    @Test func reSignsPreviouslySignedFrameworkWithECDSAP256AndInvalidatesReceiptOnCertChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signer-ec-\(UUID().uuidString)", isDirectory: true)
        let hotRoot = root.appendingPathComponent("Documents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: hotRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Keep initial ad-hoc signature and also sign the whole bundle with a different identifier first.
        let (fwURL, exeURL) = try Self.buildMinimalFramework(in: hotRoot, stripSignature: false)
        let preSign = try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "com.old.other.app", fwURL.path])
        #expect(preSign.status == 0, "initial ad-hoc sign failed: \(preSign.stderr)")

        let ecP12 = try Self.generateP12(in: root, name: "ec_dev", keyKind: "ec",
                                         commonName: "Apple Development: EC User", teamID: "ECTEAM8888", password: "ec-password")
        let store = SideloadCertificateStore(backing: InMemoryCertBacking())
        let ecSummary = try store.importPKCS12(data: ecP12, password: "ec-password")
        #expect(ecSummary.teamID == "ECTEAM8888")

        let hostID = "com.altstore.nx2apple.ECUSER"
        #expect(try MachOLocalSigner.ensureSignedIfNeeded(frameworkURL: fwURL, allowedRoot: hotRoot, hostBundleID: hostID, store: store))

        let verifyEC = try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=4", fwURL.path])
        #expect(verifyEC.status == 0, "ECDSA codesign strict verify failed:\n\(verifyEC.stderr)")
        let dumpEC = try Self.run("/usr/bin/codesign", ["-dvvv", fwURL.path])
        let outEC = dumpEC.stdout + "\n" + dumpEC.stderr
        #expect(outEC.contains("Identifier=\(hostID)"))
        #expect(outEC.contains("TeamIdentifier=ECTEAM8888"))

        let inodeAfterEC = try Self.inode(of: exeURL)

        // Replace stored certificate with a different RSA certificate -> receipt invalidates and framework re-signs cleanly.
        let rsaP12 = try Self.generateP12(in: root, name: "rsa_new", keyKind: "rsa",
                                          commonName: "Apple Development: Rotated", teamID: "NEWTEAM777", password: "pw2")
        _ = try store.importPKCS12(data: rsaP12, password: "pw2")

        #expect(try MachOLocalSigner.ensureSignedIfNeeded(frameworkURL: fwURL, allowedRoot: hotRoot, hostBundleID: hostID, store: store))
        #expect(try Self.inode(of: exeURL) != inodeAfterEC)

        let verifyRotated = try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=4", fwURL.path])
        #expect(verifyRotated.status == 0, "rotated RSA verify failed:\n\(verifyRotated.stderr)")
        let dumpRotated = try Self.run("/usr/bin/codesign", ["-dvvv", fwURL.path])
        #expect((dumpRotated.stdout + "\n" + dumpRotated.stderr).contains("TeamIdentifier=NEWTEAM777"))
    }

    @Test func completesWWDRAndRootCertificateChainsByExactIssuerSubjectDER() throws {
        let bundled = AppleCertificateAuthorities.allDER
        #expect(bundled.count >= 5)

        // Built-in WWDR G3 and G6 must each chain up to their exact Apple Root CA.
        let parsed = bundled.compactMap { der -> (Data, X509CertificateInfo)? in
            guard let info = X509CertificateParser.parse(der: der) else { return nil }
            return (der, info)
        }
        #expect(parsed.count == bundled.count)

        let wwdrG3 = try #require(parsed.first { $0.1.commonName.contains("Worldwide Developer Relations") && $0.1.teamID == "G3" })
        let chainG3 = AppleCertificateAuthorities.completeChain(leafDER: wwdrG3.0, providedChainDER: [])
        #expect(chainG3.count == 2)
        #expect(X509CertificateParser.parse(der: chainG3[1])?.commonName == "Apple Root CA")

        let wwdrG6 = try #require(parsed.first { $0.1.commonName.contains("Worldwide Developer Relations") && $0.1.teamID == "G6" })
        let chainG6 = AppleCertificateAuthorities.completeChain(leafDER: wwdrG6.0, providedChainDER: [])
        #expect(chainG6.count == 2)
        #expect(X509CertificateParser.parse(der: chainG6[1])?.commonName == "Apple Root CA - G3")

        // Unordered + unrelated extra certs in `providedChainDER` must still walk strictly leaf -> intermediate -> root.
        let rootG1 = try #require(parsed.first { $0.1.commonName == "Apple Root CA" })
        let rootG3 = try #require(parsed.first { $0.1.commonName == "Apple Root CA - G3" })
        let orderedFromShuffled = AppleCertificateAuthorities.completeChain(
            leafDER: wwdrG3.0,
            providedChainDER: [rootG3.0, rootG1.0],
            extraCandidatesDER: []
        )
        #expect(orderedFromShuffled == [wwdrG3.0, rootG1.0])
    }

    @Test func rejectsWrongPasswordDamagedMachOAndOutsideAllowedRootSafely() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signer-err-\(UUID().uuidString)", isDirectory: true)
        let hotRoot = root.appendingPathComponent("Documents/Frameworks", isDirectory: true)
        let bundledRoot = root.appendingPathComponent("DmShell.app/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: hotRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundledRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let p12 = try Self.generateP12(in: root, name: "good", keyKind: "rsa",
                                       commonName: "Apple Development: Guard", teamID: "GUARD12345", password: "correct")
        let store = SideloadCertificateStore(backing: InMemoryCertBacking())

        // Wrong password must throw .wrongPassword and leave backing empty.
        #expect(throws: SideloadCertificateError.wrongPassword) {
            try store.importPKCS12(data: p12, password: "wrong")
        }
        #expect(!store.hasCertificate)
        #expect(throws: SideloadCertificateError.emptyFile) {
            try store.importPKCS12(data: Data(), password: "")
        }

        _ = try store.importPKCS12(data: p12, password: "correct")
        let identity = try store.loadIdentity()

        // Truncated/damaged Mach-O must throw .invalidMachO without modifying or corrupting the original file.
        let damagedFW = hotRoot.appendingPathComponent("DmGame0100000000090000.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: damagedFW, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "DmGame0100000000090000"], format: .xml, options: 0)
        try plist.write(to: damagedFW.appendingPathComponent("Info.plist"))
        let truncatedBytes = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01, 0x00, 0x00])
        let damagedExe = damagedFW.appendingPathComponent("DmGame0100000000090000")
        try truncatedBytes.write(to: damagedExe)

        do {
            _ = try MachOLocalSigner.signFramework(at: damagedFW, allowedRoot: hotRoot, identity: identity, hostBundleID: "com.test.app")
            Issue.record("Expected invalidMachO for truncated Mach-O binary")
        } catch MachOLocalSignerError.invalidMachO {
            // Expected.
        }
        #expect(try Data(contentsOf: damagedExe) == truncatedBytes, "failed signing must leave original file intact")
        #expect(!FileManager.default.fileExists(atPath: damagedFW.appendingPathComponent("_CodeSignature").path))

        // Fat / Universal Mach-O header (0xCAFEBABE) must be rejected cleanly without corrupting the file.
        let fatBytes = Data([0xca, 0xfe, 0xba, 0xbe, 0x00, 0x00, 0x00, 0x01]) + Data(repeating: 0, count: 64)
        try fatBytes.write(to: damagedExe)
        do {
            _ = try MachOLocalSigner.signFramework(at: damagedFW, allowedRoot: hotRoot, identity: identity, hostBundleID: "com.test.app")
            Issue.record("Expected invalidMachO for Fat/Universal Mach-O binary")
        } catch MachOLocalSignerError.invalidMachO {
            // Expected.
        }
        #expect(try Data(contentsOf: damagedExe) == fatBytes, "Fat binary rejection must leave file untouched")
        #expect(!FileManager.default.fileExists(atPath: damagedFW.appendingPathComponent("_CodeSignature").path))

        // Insufficient header pad space (non-zero bytes right after load commands) must throw `.insufficientHeaderSpace`.
        let (tightFW, tightExe) = try Self.buildMinimalFramework(in: hotRoot, titleID: "0100000000090001", stripSignature: true)
        var tightData = try Data(contentsOf: tightExe)
        let sizeofcmds = Int(UInt32(tightData[20]) | (UInt32(tightData[21]) << 8)
                             | (UInt32(tightData[22]) << 16) | (UInt32(tightData[23]) << 24))
        let insertOff = 32 + sizeofcmds
        #expect(insertOff + 16 <= tightData.count)
        tightData[insertOff] = 0xAA // poison the header pad slot so inserting LC_CODE_SIGNATURE would overwrite non-zero bytes
        try tightData.write(to: tightExe)
        #expect(throws: MachOLocalSignerError.insufficientHeaderSpace) {
            try MachOLocalSigner.signFramework(at: tightFW, allowedRoot: hotRoot, identity: identity, hostBundleID: "com.test.app")
        }
        #expect(try Data(contentsOf: tightExe) == tightData, "insufficientHeaderSpace must leave original binary untouched")
        #expect(!FileManager.default.fileExists(atPath: tightFW.appendingPathComponent("_CodeSignature").path))

        // Refuses to touch read-only bundled framework outside `hotFrameworksRoot`.
        let (bundledFW, _) = try Self.buildMinimalFramework(in: bundledRoot, stripSignature: true)
        #expect(throws: MachOLocalSignerError.outsideAllowedRoot) {
            try MachOLocalSigner.signFramework(at: bundledFW, allowedRoot: hotRoot, identity: identity, hostBundleID: "com.test.app")
        }
    }

    @MainActor @Test func cachedReceiptLaunchFailureTriggersForceResignAndRetry() async throws {
        let box = try Sandbox()
        let hotRoot = box.root.appendingPathComponent("Documents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: hotRoot, withIntermediateDirectories: true)

        let (fwURL, exeURL) = try Self.buildMinimalFramework(in: hotRoot, titleID: Fixtures.orbit, stripSignature: true)
        let fixtureDir = box.games.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        try FileManager.default.copyItem(at: fixtureDir.appendingPathComponent("launcher.json"),
                                         to: fwURL.appendingPathComponent("launcher.json"))
        try FileManager.default.copyItem(at: fixtureDir.appendingPathComponent("DmGame.framework/msl"),
                                         to: fwURL.appendingPathComponent("msl"))
        try FileManager.default.removeItem(at: fixtureDir)
        try box.giveAppData(Fixtures.orbit)

        let p12 = try Self.generateP12(in: box.root, name: "heal_dev", keyKind: "rsa",
                                       commonName: "Apple Development: Heal User", teamID: "HEAL123456", password: "pw")
        let backing = InMemoryCertBacking()
        let store = SideloadCertificateStore(backing: backing)
        _ = try store.importPKCS12(data: p12, password: "pw")

        // Pre-sign once so a valid `.nx-local-sign.json` receipt exists.
        let hostID = "com.sidestore.nx2apple.HEAL"
        #expect(try MachOLocalSigner.ensureSignedIfNeeded(frameworkURL: fwURL, allowedRoot: hotRoot, hostBundleID: hostID, store: store))
        // Modify a sealed resource (banner.jpg) while leaving the executable's inode/size/mtime intact so the receipt still hits.
        try Data([0xff, 0xd8, 0xff, 0xfe, 0x00, 0x02, 0xff, 0xd9]).write(to: fwURL.appendingPathComponent("banner.jpg"))
        let inodeBeforeHeal = try Self.inode(of: exeURL)

        var cfg = box.config()
        cfg.hotFrameworksRoot = hotRoot
        cfg.sideloadCertBacking = backing
        cfg.hostBundleID = { hostID }
        let launcher = FailOnceThenSucceedLauncher()
        let model = ShellHostModel(config: cfg, launcher: launcher)
        await model.waitForStartupTasks()

        // Launch hits cached receipt -> first launch fails -> model clears receipt, force re-signs (fresh inode + updated CodeResources), retries and succeeds.
        await model.playNow(Fixtures.orbit)
        #expect(model.notice == nil)
        #expect(launcher.attempts == 2)
        #expect(launcher.succeededGames.count == 1)
        #expect(try Self.inode(of: exeURL) != inodeBeforeHeal, "self-healing force re-sign must allocate a fresh inode")

        let verify = try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=4", fwURL.path])
        #expect(verify.status == 0, "self-healed framework failed strict codesign verify:\n\(verify.stderr)")
    }

    @MainActor @Test func shellHostModelImportsCertificateAndSignsHotFrameworkOnLaunch() async throws {
        let box = try Sandbox()
        let hotRoot = box.root.appendingPathComponent("Documents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: hotRoot, withIntermediateDirectories: true)

        let (fwURL, exeURL) = try Self.buildMinimalFramework(in: hotRoot, titleID: Fixtures.orbit, stripSignature: true)
        // Copy launcher.json and msl/ from fixture, then remove the read-only bundled copy so the hot framework owns this title.
        let fixtureDir = box.games.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        try FileManager.default.copyItem(at: fixtureDir.appendingPathComponent("launcher.json"),
                                         to: fwURL.appendingPathComponent("launcher.json"))
        try FileManager.default.copyItem(at: fixtureDir.appendingPathComponent("DmGame.framework/msl"),
                                         to: fwURL.appendingPathComponent("msl"))
        try FileManager.default.removeItem(at: fixtureDir)
        try box.giveAppData(Fixtures.orbit)

        let p12 = try Self.generateP12(in: box.root, name: "model_dev", keyKind: "rsa",
                                       commonName: "Apple Development: Model User", teamID: "MODEL12345", password: "pw")

        var cfg = box.config()
        cfg.hotFrameworksRoot = hotRoot
        cfg.hostBundleID = { "com.sidestore.nx2apple.MODEL" }
        let launcher = CapturingLauncher()
        let model = ShellHostModel(
            config: cfg,
            launcher: launcher,
            certificatePicker: FakeCertPicker(outcome: .picked(data: p12, fileName: "sidestore.p12"))
        )
        await model.waitForStartupTasks()
        #expect(model.sideloadCertificate == nil)

        // 1. Pick file, try wrong password -> error returned, certificate remains unconfigured.
        let picked = await model.pickSideloadCertificateFileNow()
        #expect(picked == .picked(fileName: "sidestore.p12"))
        let wrongErr = await model.confirmSideloadCertificatePasswordNow("bad-password")
        #expect(wrongErr != nil)
        #expect(model.sideloadCertificate == nil)

        // 2. Pick file again and confirm with correct password -> summary published.
        #expect(await model.pickSideloadCertificateFileNow() == .picked(fileName: "sidestore.p12"))
        let okErr = await model.confirmSideloadCertificatePasswordNow("pw")
        #expect(okErr == nil)
        #expect(model.sideloadCertificate?.commonName == "Apple Development: Model User")
        #expect(model.sideloadCertificate?.teamID == "MODEL12345")

        // 3. Play triggers automatic on-demand signing of the unsigned hot framework before handing off to launcher.
        let inodeBeforePlay = try Self.inode(of: exeURL)
        await model.playNow(Fixtures.orbit)
        #expect(model.notice == nil)
        #expect(launcher.launched.count == 1)
        let inodeAfterPlay = try Self.inode(of: exeURL)
        #expect(inodeAfterPlay != inodeBeforePlay)

        let verify = try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=4", fwURL.path])
        #expect(verify.status == 0, "auto-signed framework failed strict codesign verify:\n\(verify.stderr)")

        // 4. Playing again hits receipt without re-signing.
        await model.playNow(Fixtures.orbit)
        #expect(launcher.launched.count == 2)
        #expect(try Self.inode(of: exeURL) == inodeAfterPlay)

        // 5. Removing certificate clears summary and backing.
        await model.removeSideloadCertificateNow()
        #expect(model.sideloadCertificate == nil)
    }

    @MainActor @Test func shellHostModelBlocksExternalHotFrameworkLaunchWhenProfileDisallowsHotLoading() async throws {
        let box = try Sandbox()
        let hotRoot = box.root.appendingPathComponent("Documents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: hotRoot, withIntermediateDirectories: true)

        let (fwURL, _) = try Self.buildMinimalFramework(in: hotRoot, titleID: Fixtures.orbit, stripSignature: true)
        let fixtureDir = box.games.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        try FileManager.default.copyItem(at: fixtureDir.appendingPathComponent("launcher.json"),
                                         to: fwURL.appendingPathComponent("launcher.json"))
        try FileManager.default.copyItem(at: fixtureDir.appendingPathComponent("DmGame.framework/msl"),
                                         to: fwURL.appendingPathComponent("msl"))
        try FileManager.default.removeItem(at: fixtureDir)
        try box.giveAppData(Fixtures.orbit)

        var cfg = box.config()
        cfg.hotFrameworksRoot = hotRoot
        cfg.supportsHotFrameworkLoading = { false }
        let launcher = CapturingLauncher()
        let model = ShellHostModel(config: cfg, launcher: launcher)
        await model.waitForStartupTasks()

        await model.playNow(Fixtures.orbit)
        #expect(launcher.launched.isEmpty, "disallowed external framework must be blocked before dlopen")
        #expect(model.notice == hostText("This app signature does not support loading games from Documents/Frameworks. Reinstall the app from NX2Apple on your computer."))
    }

    @Test func frameworkSignatureExtractsCMSSigningCertificateSHA1AndDetectsMismatch() throws {
        let box = try Sandbox()
        let hotRoot = box.root.appendingPathComponent("Documents/Frameworks", isDirectory: true)
        let appBundle = box.root.appendingPathComponent("DmShell.app", isDirectory: true)
        try FileManager.default.createDirectory(at: hotRoot, withIntermediateDirectories: true)

        let (fwURL, exeURL) = try Self.buildMinimalFramework(in: hotRoot, titleID: Fixtures.orbit, stripSignature: true)
        let p12 = try Self.generateP12(in: box.root, name: "cms_sha1", keyKind: "rsa",
                                       commonName: "Apple Development: Shell Match", teamID: "SAME123456", password: "pw")
        let backing = InMemoryCertBacking()
        let store = SideloadCertificateStore(backing: backing)
        _ = try store.importPKCS12(data: p12, password: "pw")
        let identity = try store.loadIdentity()
        _ = try MachOLocalSigner.signFramework(at: fwURL, allowedRoot: hotRoot, identity: identity, hostBundleID: "org.nxnative.shell")

        // Compute the expected uppercase SHA-1 of the leaf certificate DER using `openssl x509`.
        let pemURL = box.root.appendingPathComponent("cms_sha1.crt")
        let fp = try Self.run("/usr/bin/openssl", ["x509", "-in", pemURL.path, "-noout", "-fingerprint", "-sha1"])
        #expect(fp.status == 0)
        let expectedSHA1 = fp.stdout
            .components(separatedBy: "=").last?
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        #expect(expectedSHA1.count == 40)

        let info = try #require(FrameworkSignature.inspect(executable: exeURL))
        #expect(info.certSHA1 == expectedSHA1)
        #expect(FrameworkSignature.preflightExternal(executable: exeURL, appBundleURL: appBundle,
                                                   hostTeamID: "SAME123456", hostCertSHA1: expectedSHA1) == nil)

        let otherSHA1 = String(repeating: "F", count: 40)
        let mismatch = FrameworkSignature.preflightExternal(executable: exeURL, appBundleURL: appBundle,
                                                            hostTeamID: "SAME123456", hostCertSHA1: otherSHA1)
        #expect(mismatch == hostText("Could not load the game framework because the signing certificate does not match this app. Reinstall the app from your computer."))
    }

    @Test func arm64SignatureUses16KiBCodePagesValidDesignatedRequirementsSortedCMSCertsAndUpgradesV1Receipt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signer-16k-\(UUID().uuidString)", isDirectory: true)
        let hotRoot = root.appendingPathComponent("Documents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: hotRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Build a multi-page (> 64 KiB) arm64 framework executable so 16 KiB vs 4 KiB page hashing produces distinct slot counts.
        let (fwURL, exeURL) = try Self.buildMinimalFramework(in: hotRoot, titleID: "0100159000016384", stripSignature: true)
        let largeSrcURL = root.appendingPathComponent("large_arm64.c")
        let largeC = """
        const unsigned char dm_large_rodata[70000] = { 1, 2, 3, 4, 5, 6, 7, 8 };
        int dm_fixture_entry(void) { return dm_large_rodata[0] + 41; }
        """
        try Data(largeC.utf8).write(to: largeSrcURL)
        let clang = try Self.run("/usr/bin/clang", [
            "-arch", "arm64", "-dynamiclib",
            "-install_name", "@rpath/DmGame0100159000016384.framework/DmGame0100159000016384",
            "-o", exeURL.path, largeSrcURL.path,
        ])
        #expect(clang.status == 0)
        #expect(try Self.run("/usr/bin/codesign", ["--remove-signature", exeURL.path]).status == 0)

        // Generate a CA + leaf chain so SignedData.certificates contains multiple DER certificates to test X.690 DER sorting.
        let caKey = root.appendingPathComponent("ca.key")
        let caCrt = root.appendingPathComponent("ca.crt")
        let leafKey = root.appendingPathComponent("leaf.key")
        let leafCsr = root.appendingPathComponent("leaf.csr")
        let leafCrt = root.appendingPathComponent("leaf.crt")
        let extFile = root.appendingPathComponent("ext.cnf")
        let p12URL = root.appendingPathComponent("chain.p12")
        try Data("[v3_cs]\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n".utf8)
            .write(to: extFile)
        #expect(try Self.run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", caKey.path, "-out", caCrt.path, "-days", "365",
            "-subj", "/CN=ZZZ Test Intermediate CA/O=NX2Apple Test/C=US",
        ]).status == 0)
        #expect(try Self.run("/usr/bin/openssl", ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", leafKey.path]).status == 0)
        #expect(try Self.run("/usr/bin/openssl", [
            "req", "-new", "-key", leafKey.path, "-out", leafCsr.path,
            "-subj", "/CN=Apple Development: 16K Signer/OU=TXM16KTEAM/O=NX2Apple Test/C=US",
        ]).status == 0)
        #expect(try Self.run("/usr/bin/openssl", [
            "x509", "-req", "-sha256", "-in", leafCsr.path, "-CA", caCrt.path, "-CAkey", caKey.path,
            "-CAcreateserial", "-out", leafCrt.path, "-days", "365", "-extfile", extFile.path, "-extensions", "v3_cs",
        ]).status == 0)
        #expect(try Self.run("/usr/bin/openssl", [
            "pkcs12", "-export", "-inkey", leafKey.path, "-in", leafCrt.path, "-certfile", caCrt.path,
            "-out", p12URL.path, "-passout", "pass:txm-pw",
        ]).status == 0)

        let store = SideloadCertificateStore(backing: InMemoryCertBacking())
        _ = try store.importPKCS12(data: Data(contentsOf: p12URL), password: "txm-pw")
        let hostID = "com.sidestore.nx2apple.TXM"
        #expect(try MachOLocalSigner.ensureSignedIfNeeded(frameworkURL: fwURL, allowedRoot: hotRoot, hostBundleID: hostID, store: store))

        // 1. Verify 16 KiB (2^14 = 16384) CodeDirectory page size required by iOS arm64 TXM / SPTM.
        let csDetail = try Self.run("/usr/bin/codesign", ["-dvvvvv", exeURL.path])
        #expect(csDetail.status == 0)
        #expect(csDetail.stderr.contains("Page size=16384"), "arm64 CodeDirectory must use 16384-byte pages:\n\(csDetail.stderr)")

        let strictVerify = try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=4", fwURL.path])
        #expect(strictVerify.status == 0, "strict codesign verify failed:\n\(strictVerify.stderr)")

        // 2. Verify embedded Designated Requirement and Apple-anchored DR bytecode via `/usr/bin/csreq`.
        let drOut = try Self.run("/usr/bin/codesign", ["-d", "-r-", exeURL.path])
        #expect(drOut.status == 0)
        let combinedDR = drOut.stdout + "\n" + drOut.stderr
        #expect(combinedDR.contains("designated => identifier \"\(hostID)\""))

        let identity = try store.loadIdentity()
        let appleReqSuper = MachOLocalSigner.buildDesignatedRequirementsBlob(
            identifier: hostID,
            teamID: "TXM16KTEAM",
            leafDER: identity.leafCertificateDER,
            isAppleAnchored: true
        )
        // Single requirement starts at offset 20 inside CS_RequirementsBlob (count = 1).
        let singleAppleReq = appleReqSuper.subdata(in: 20..<appleReqSuper.count)
        let reqFile = root.appendingPathComponent("apple_dr.req")
        try singleAppleReq.write(to: reqFile)
        let csreqOut = try Self.run("/usr/bin/csreq", ["-r", reqFile.path, "-t"])
        #expect(csreqOut.status == 0, "csreq rejected Apple-anchored DR: \(csreqOut.stderr)")
        #expect(csreqOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            == "identifier \"\(hostID)\" and anchor apple generic and certificate leaf[subject.OU] = TXM16KTEAM")

        // 3. Verify CMS SignedData.certificates (`[0] IMPLICIT CertificateSet`) is sorted in ascending X.690 DER order,
        //    and verify detached RFC 5652 CMS signature integrity over the 16 KiB CodeDirectory via public Security CMSDecoder
        //    and OpenSSL CMS verification (never private dlopen/dlsym symbols).
        let signedBytes = try Data(contentsOf: exeURL)
        let sigInfo = try #require(FrameworkSignature.inspect(executable: exeURL))
        let sb = signedBytes.subdata(in: Int(sigInfo.signatureOffset)..<(Int(sigInfo.signatureOffset) + Int(sigInfo.signatureSize)))
        func u32BE(_ d: Data, _ off: Int) -> UInt32 {
            (UInt32(d[d.startIndex + off]) << 24) | (UInt32(d[d.startIndex + off + 1]) << 16)
                | (UInt32(d[d.startIndex + off + 2]) << 8) | UInt32(d[d.startIndex + off + 3])
        }
        let slotCount = Int(u32BE(sb, 8))
        var cdSlice = Data()
        var cmsDER = Data()
        for i in 0..<slotCount {
            let sType = u32BE(sb, 12 + i * 8)
            let sOff = Int(u32BE(sb, 12 + i * 8 + 4))
            let sLen = Int(u32BE(sb, sOff + 4))
            if sType == 0 {
                cdSlice = sb.subdata(in: sOff..<(sOff + sLen))
            } else if sType == 0x0001_0000 {
                cmsDER = sb.subdata(in: (sOff + 8)..<(sOff + sLen))
            }
        }
        #expect(cdSlice[cdSlice.startIndex + 39] == 14, "CodeDirectory pageSizeShift byte must be 14 (16 KiB)")

        let ci = try #require(ASN1DER.readElement(in: cmsDER, at: cmsDER.startIndex))
        let ciFields = try #require(ASN1DER.children(of: ci, in: cmsDER))
        let sd = try #require(ASN1DER.children(of: ciFields[1], in: cmsDER)?.first)
        let sdFields = try #require(ASN1DER.children(of: sd, in: cmsDER))
        let certsImplicit = try #require(sdFields.first { $0.tag == 0xA0 })
        let certElements = try #require(ASN1DER.children(of: certsImplicit, in: cmsDER)).map { $0.fullData(in: cmsDER) }
        #expect(certElements.count == 2)
        let sortedCerts = certElements.sorted { $0.lexicographicallyPrecedes($1) }
        #expect(certElements == sortedCerts, "CMS SignedData.certificates must be sorted in X.690 DER order")

        var cmsDecoderOpt: CMSDecoder?
        #expect(CMSDecoderCreate(&cmsDecoderOpt) == errSecSuccess)
        let cmsDecoder = try #require(cmsDecoderOpt)
        let cmsUpdateStatus = cmsDER.withUnsafeBytes { rawBuf -> OSStatus in
            guard let base = rawBuf.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(cmsDecoder, base, rawBuf.count)
        }
        #expect(cmsUpdateStatus == errSecSuccess)
        #expect(CMSDecoderSetDetachedContent(cmsDecoder, cdSlice as CFData) == errSecSuccess)
        #expect(CMSDecoderFinalizeMessage(cmsDecoder) == errSecSuccess)
        var numSigners = 0
        #expect(CMSDecoderGetNumSigners(cmsDecoder, &numSigners) == errSecSuccess)
        #expect(numSigners == 1)
        var signerCertOpt: SecCertificate?
        #expect(CMSDecoderCopySignerCert(cmsDecoder, 0, &signerCertOpt) == errSecSuccess)
        let signerCert = try #require(signerCertOpt)
        #expect((SecCertificateCopyData(signerCert) as Data) == identity.leafCertificateDER)

        let cmsFile = root.appendingPathComponent("cms.der")
        let cdFile = root.appendingPathComponent("cd.bin")
        try cmsDER.write(to: cmsFile)
        try cdSlice.write(to: cdFile)
        let cmsVerify = try Self.run("/usr/bin/openssl", [
            "cms", "-verify", "-binary", "-inform", "DER",
            "-in", cmsFile.path, "-content", cdFile.path, "-noverify", "-out", "/dev/null",
        ])
        #expect(cmsVerify.status == 0, "openssl cms -verify failed: \(cmsVerify.stderr)")

        // 4. Legacy schema=1 `.nx-local-sign.json` receipt (from pre-fix 4 KiB builds) must invalidate and force re-signing.
        let receiptURL = MachOLocalSigner.receiptURL(for: fwURL)
        var oldReceipt = try JSONDecoder().decode(LocalSignReceipt.self, from: Data(contentsOf: receiptURL))
        #expect(oldReceipt.schema == LocalSignReceipt.currentSchema)
        oldReceipt.schema = 1
        try JSONEncoder().encode(oldReceipt).write(to: receiptURL, options: .atomic)
        #expect(!MachOLocalSigner.isReceiptValid(frameworkURL: fwURL, certFingerprint: identity.summary.fingerprintHex, hostBundleID: hostID))

        let inodeBeforeUpgrade = try Self.inode(of: exeURL)
        #expect(try MachOLocalSigner.ensureSignedIfNeeded(frameworkURL: fwURL, allowedRoot: hotRoot, hostBundleID: hostID, store: store))
        #expect(try Self.inode(of: exeURL) != inodeBeforeUpgrade)
        let upgradedReceipt = try JSONDecoder().decode(LocalSignReceipt.self, from: Data(contentsOf: receiptURL))
        #expect(upgradedReceipt.schema == LocalSignReceipt.currentSchema)
    }

    @Test func importsPasswordlessSideStoreRC240AndPBES2PKCS12VariantsAndRejectsWrongPasswords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signer-p12-variants-\(UUID().uuidString)", isDirectory: true)
        let hotRoot = root.appendingPathComponent("Documents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: hotRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Fixture generator commands: `/usr/bin/openssl` real PKCS#12 exports covering:
        // 1) SideStore passwordless export (`-keypbe NONE -certpbe NONE -nomac -passout pass:`) for both RSA-2048 and EC P-256
        // 2) Apple `SecItemExport` empty-password layout (`-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-RC2-40 -passout pass:`)
        // 3) OpenSSL 3 modern PBES2 (`-keypbe AES-256-CBC -certpbe AES-256-CBC -macalg sha256`) with empty & non-empty passwords
        //    plus an unrelated extra certificate to verify public-key leaf pairing.
        let rsaKey = root.appendingPathComponent("rsa.key")
        let rsaCrt = root.appendingPathComponent("rsa.crt")
        let ecKey = root.appendingPathComponent("ec.key")
        let ecCrt = root.appendingPathComponent("ec.crt")
        let extraKey = root.appendingPathComponent("extra.key")
        let extraCrt = root.appendingPathComponent("extra.crt")
        let extURL = root.appendingPathComponent("cs.ext")
        try Data("[v3_cs]\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n".utf8)
            .write(to: extURL)

        #expect(try Self.run("/usr/bin/openssl", ["genrsa", "-out", rsaKey.path, "2048"]).status == 0)
        let rsaCsr = root.appendingPathComponent("rsa.csr")
        #expect(try Self.run("/usr/bin/openssl", ["req", "-new", "-key", rsaKey.path, "-out", rsaCsr.path,
                                                  "-subj", "/CN=Apple Development: SideStore RSA/OU=SSRSA12345/O=Test/C=US"]).status == 0)
        #expect(try Self.run("/usr/bin/openssl", ["x509", "-req", "-sha256", "-in", rsaCsr.path, "-signkey", rsaKey.path,
                                                  "-out", rsaCrt.path, "-days", "365", "-extfile", extURL.path, "-extensions", "v3_cs"]).status == 0)

        #expect(try Self.run("/usr/bin/openssl", ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", ecKey.path]).status == 0)
        let ecCsr = root.appendingPathComponent("ec.csr")
        #expect(try Self.run("/usr/bin/openssl", ["req", "-new", "-key", ecKey.path, "-out", ecCsr.path,
                                                  "-subj", "/CN=Apple Development: SideStore EC/OU=SSEC678901/O=Test/C=US"]).status == 0)
        #expect(try Self.run("/usr/bin/openssl", ["x509", "-req", "-sha256", "-in", ecCsr.path, "-signkey", ecKey.path,
                                                  "-out", ecCrt.path, "-days", "365", "-extfile", extURL.path, "-extensions", "v3_cs"]).status == 0)

        #expect(try Self.run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", extraKey.path, "-out", extraCrt.path, "-days", "365",
            "-subj", "/CN=Unrelated Extra Certificate/OU=WRONGTEAM0/O=Test/C=US",
        ]).status == 0)

        // Variant 1A & 1B: SideStore passwordless MAC-less `keyBag` (rejected by SecPKCS12Import with errSecDecode -26275).
        let sideStoreRSAURL = root.appendingPathComponent("sidestore_rsa.p12")
        #expect(try Self.run("/usr/bin/openssl", [
            "pkcs12", "-export", "-inkey", rsaKey.path, "-in", rsaCrt.path, "-certfile", extraCrt.path,
            "-keypbe", "NONE", "-certpbe", "NONE", "-nomac", "-out", sideStoreRSAURL.path, "-passout", "pass:",
        ]).status == 0)
        let sideStoreRSAData = try Data(contentsOf: sideStoreRSAURL)

        let sideStoreECURL = root.appendingPathComponent("sidestore_ec.p12")
        #expect(try Self.run("/usr/bin/openssl", [
            "pkcs12", "-export", "-inkey", ecKey.path, "-in", ecCrt.path,
            "-keypbe", "NONE", "-certpbe", "NONE", "-nomac", "-out", sideStoreECURL.path, "-passout", "pass:",
        ]).status == 0)
        let sideStoreECData = try Data(contentsOf: sideStoreECURL)

        #expect(throws: SideloadCertificateError.wrongPassword) {
            try SideloadCertificateStore.parseIdentity(p12Data: sideStoreRSAData, password: "unexpected-password")
        }

        let storeRSA = SideloadCertificateStore(backing: InMemoryCertBacking())
        let summaryRSA = try storeRSA.importPKCS12(data: sideStoreRSAData, password: "")
        #expect(summaryRSA.commonName == "Apple Development: SideStore RSA")
        #expect(summaryRSA.teamID == "SSRSA12345")

        let (fw1, _) = try Self.buildMinimalFramework(in: hotRoot, titleID: "0100159000000001", stripSignature: true)
        #expect(try MachOLocalSigner.ensureSignedIfNeeded(frameworkURL: fw1, allowedRoot: hotRoot,
                                                          hostBundleID: "com.sidestore.nx2apple.A", store: storeRSA))
        #expect(try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fw1.path]).status == 0)

        let storeEC = SideloadCertificateStore(backing: InMemoryCertBacking())
        let summaryEC = try storeEC.importPKCS12(data: sideStoreECData, password: "")
        #expect(summaryEC.commonName == "Apple Development: SideStore EC")
        #expect(summaryEC.teamID == "SSEC678901")

        let (fw2, _) = try Self.buildMinimalFramework(in: hotRoot, titleID: "0100159000000002", stripSignature: true)
        #expect(try MachOLocalSigner.ensureSignedIfNeeded(frameworkURL: fw2, allowedRoot: hotRoot,
                                                          hostBundleID: "com.sidestore.nx2apple.B", store: storeEC))
        #expect(try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fw2.path]).status == 0)

        // Variant 2: 40-bit RC2 certBag + 3-Key 3DES keyBag with empty password (matching `SecItemExport` empty-passphrase output).
        let rc2URL = root.appendingPathComponent("rc2_empty.p12")
        #expect(try Self.run("/usr/bin/openssl", [
            "pkcs12", "-export", "-inkey", rsaKey.path, "-in", rsaCrt.path,
            "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-RC2-40",
            "-out", rc2URL.path, "-passout", "pass:",
        ]).status == 0)
        let rc2Data = try Data(contentsOf: rc2URL)
        let fallbackRC2 = try PKCS12FallbackParser.parseIdentity(p12Data: rc2Data, password: "", now: Date())
        #expect(fallbackRC2.summary.teamID == "SSRSA12345")
        #expect(throws: SideloadCertificateError.wrongPassword) {
            try PKCS12FallbackParser.parseIdentity(p12Data: rc2Data, password: "wrong", now: Date())
        }
        let storeRC2 = SideloadCertificateStore(backing: InMemoryCertBacking())
        #expect(try storeRC2.importPKCS12(data: rc2Data, password: "").teamID == "SSRSA12345")

        // Variant 3: PBES2 (`PBKDF2-HMAC-SHA256` + `AES-256-CBC` + `SHA-256` MAC) with empty and non-empty passwords.
        let pbes2EmptyURL = root.appendingPathComponent("pbes2_empty.p12")
        #expect(try Self.run("/usr/bin/openssl", [
            "pkcs12", "-export", "-inkey", ecKey.path, "-in", ecCrt.path, "-certfile", extraCrt.path,
            "-keypbe", "AES-256-CBC", "-certpbe", "AES-256-CBC", "-macalg", "sha256",
            "-out", pbes2EmptyURL.path, "-passout", "pass:",
        ]).status == 0)
        let pbes2EmptyData = try Data(contentsOf: pbes2EmptyURL)
        let parsedPBES2Empty = try SideloadCertificateStore.parseIdentity(p12Data: pbes2EmptyData, password: "")
        #expect(parsedPBES2Empty.summary.teamID == "SSEC678901")
        #expect(throws: SideloadCertificateError.wrongPassword) {
            try SideloadCertificateStore.parseIdentity(p12Data: pbes2EmptyData, password: "bad")
        }

        let pbes2PassURL = root.appendingPathComponent("pbes2_pw.p12")
        #expect(try Self.run("/usr/bin/openssl", [
            "pkcs12", "-export", "-inkey", rsaKey.path, "-in", rsaCrt.path,
            "-keypbe", "AES-256-CBC", "-certpbe", "AES-256-CBC", "-macalg", "sha256",
            "-out", pbes2PassURL.path, "-passout", "pass:pbes2-pw",
        ]).status == 0)
        let pbes2PassData = try Data(contentsOf: pbes2PassURL)
        let fallbackPBES2Pass = try PKCS12FallbackParser.parseIdentity(p12Data: pbes2PassData, password: "pbes2-pw", now: Date())
        #expect(fallbackPBES2Pass.summary.teamID == "SSRSA12345")
        #expect(throws: SideloadCertificateError.wrongPassword) {
            try PKCS12FallbackParser.parseIdentity(p12Data: pbes2PassData, password: "", now: Date())
        }
    }
}
#endif
