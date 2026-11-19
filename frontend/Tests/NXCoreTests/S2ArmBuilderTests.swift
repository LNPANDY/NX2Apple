import XCTest
@testable import NXCore

final class S2ArmBuilderTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeFakeS2ArmTree(name: String = "s2arm", hasScript: Bool = true) throws -> String {
        let root = temporary.appendingPathComponent(name)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("pack/jobs"), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8).write(to: root.appendingPathComponent("pack/jobs/main.py"))
        try fm.createDirectory(at: root.appendingPathComponent("runtime/rewriter"), withIntermediateDirectories: true)
        try Data("/* rewriter */\n".utf8).write(to: root.appendingPathComponent("runtime/rewriter/rewriter.c"))
        if hasScript {
            try fm.createDirectory(at: root.appendingPathComponent("pack/oneclick"), withIntermediateDirectories: true)
            try Data("#!/bin/bash\n".utf8).write(to: root.appendingPathComponent("pack/oneclick/oneclick.sh"))
        }
        return root.path
    }

    func testIsUsableTree() throws {
        XCTAssertFalse(S2ArmBuilder.isUsableTree(""))
        let validTree = try makeFakeS2ArmTree(name: "s2arm-valid", hasScript: true)
        XCTAssertTrue(S2ArmBuilder.isUsableTree(validTree))

        let incompleteTree = try makeFakeS2ArmTree(name: "s2arm-incomplete", hasScript: false)
        XCTAssertFalse(S2ArmBuilder.isUsableTree(incompleteTree))
    }

    func testArguments() {
        let encryptedArgs = S2ArmBuilder.arguments(
            tree: "/opt/s2arm",
            sourceInput: "/games/zelda",
            keysPath: "/keys/prod.keys",
            isUnencryptedInput: false,
            workDir: "/work",
            isMacTarget: false,
            titleID: "0100F2C0115B6000",
            deviceUDID: "udid-123",
            eventsFile: "/work/s2a-events.jsonl"
        )
        let expectedEncrypted = [
            "/opt/s2arm/pack/oneclick/oneclick.sh",
            "/games/zelda",
            "--keys", "/keys/prod.keys",
            "--out", "/work",
            "--target", "ios",
            "--title-id", "0100F2C0115B6000",
            "--device", "udid-123",
            "--events", "/work/s2a-events.jsonl"
        ]
        XCTAssertEqual(encryptedArgs, expectedEncrypted)

        let macUnencryptedArgs = S2ArmBuilder.arguments(
            tree: "/opt/s2arm",
            sourceInput: "/games/zelda.nup",
            keysPath: "/keys/prod.keys",
            isUnencryptedInput: true,
            workDir: "/work",
            isMacTarget: true,
            titleID: nil,
            deviceUDID: "udid-123",
            eventsFile: ""
        )
        XCTAssertEqual(macUnencryptedArgs[0], "/opt/s2arm/pack/oneclick/oneclick.sh")
        XCTAssertEqual(macUnencryptedArgs[1], "/games/zelda.nup")
        XCTAssertFalse(macUnencryptedArgs.contains("--keys"))
        XCTAssertFalse(macUnencryptedArgs.contains("--title-id"))
        XCTAssertFalse(macUnencryptedArgs.contains("--device"))
        XCTAssertFalse(macUnencryptedArgs.contains("--events"))
        XCTAssertTrue(macUnencryptedArgs.contains("--target"))
        XCTAssertTrue(macUnencryptedArgs.contains("mac"))
    }

    func testEnvironment() {
        let encryptedEnv = S2ArmBuilder.environment(pythonPath: "/usr/bin/python3", keysPath: "/keys/prod.keys", isUnencryptedInput: false)
        XCTAssertEqual(encryptedEnv["S2A_PYTHON"], "/usr/bin/python3")
        XCTAssertEqual(encryptedEnv["PYTHONUNBUFFERED"], "1")
        XCTAssertEqual(encryptedEnv["S2A_KEYS"], "/keys/prod.keys")

        let unencryptedEnv = S2ArmBuilder.environment(pythonPath: "/usr/bin/python3", keysPath: "/keys/prod.keys", isUnencryptedInput: true)
        XCTAssertEqual(unencryptedEnv["S2A_PYTHON"], "/usr/bin/python3")
        XCTAssertEqual(unencryptedEnv["PYTHONUNBUFFERED"], "1")
        XCTAssertNil(unencryptedEnv["S2A_KEYS"])
    }

    func testParseEvents() {
        XCTAssertNil(S2ArmBuilder.parseEvents(""))
        XCTAssertNil(S2ArmBuilder.parseEvents("not a json\n"))
        XCTAssertNil(S2ArmBuilder.parseEvents("{\"ev\": \"stage\", \"name\": \"extract\"}\n"))

        let successJSONL = """
        {"ev": "stage", "name": "extract"}
        {"ev": "result", "ok": true, "ipa": "/out/app.ipa", "pack": "/out/pack.romfs"}
        {"ev": "say", "msg": "done"}
        """
        let summary = S2ArmBuilder.parseEvents(successJSONL)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.ok == true)
        XCTAssertEqual(summary?.ipaPath, "/out/app.ipa")
        XCTAssertEqual(summary?.packPath, "/out/pack.romfs")
        XCTAssertNil(summary?.macRootPath)

        let macSuccessJSONL = """
        {"ev": "result", "ok": true, "root": "/out/AppRoot"}
        """
        let macSummary = S2ArmBuilder.parseEvents(macSuccessJSONL)
        XCTAssertNotNil(macSummary)
        XCTAssertTrue(macSummary?.ok == true)
        XCTAssertEqual(macSummary?.macRootPath, "/out/AppRoot")

        let failJSONL = """
        {"ev": "result", "ok": false, "msg": "Packaging failed due to missing keys"}
        """
        let failSummary = S2ArmBuilder.parseEvents(failJSONL)
        XCTAssertNotNil(failSummary)
        XCTAssertFalse(failSummary?.ok == true)
        XCTAssertEqual(failSummary?.message, "Packaging failed due to missing keys")
    }

    func testLastError() {
        let eventsFail = "{\"ev\": \"result\", \"ok\": false, \"msg\": \"Decryption error from events\"}\n"
        let logText = "stage 1\n🔴 fatal shader failure\ncleaning up\n"
        XCTAssertEqual(
            S2ArmBuilder.lastError(in: logText, eventsText: eventsFail),
            "Decryption error from events",
            "Error from events should take priority"
        )

        XCTAssertEqual(
            S2ArmBuilder.lastError(in: logText, eventsText: nil),
            "🔴 fatal shader failure"
        )

        let redChineseLog = "stage 1\n【红】 代码重写失败\ncleaning up\n"
        XCTAssertEqual(
            S2ArmBuilder.lastError(in: redChineseLog, eventsText: nil),
            "【红】 代码重写失败"
        )

        let errorPrefixLog = "stage 1\nERROR: out of memory\ncleaning up\n"
        XCTAssertEqual(
            S2ArmBuilder.lastError(in: errorPrefixLog, eventsText: nil),
            "ERROR: out of memory"
        )

        let normalLog = "stage 1\nfinished step 2\n"
        XCTAssertEqual(
            S2ArmBuilder.lastError(in: normalLog, eventsText: nil),
            "finished step 2"
        )
    }

    func testSdkRequirementReadsGlobalJsonAndFallsBack() throws {
        let fallback = S2ArmBuilder.sdkRequirement(in: "")
        XCTAssertEqual(fallback.version, "10.0.403")
        XCTAssertEqual(fallback.rollForward, "latestFeature")

        let tree = try makeFakeS2ArmTree(name: "s2arm-global-json")
        let missingGlobal = S2ArmBuilder.sdkRequirement(in: tree)
        XCTAssertEqual(missingGlobal.version, "10.0.403")
        XCTAssertEqual(missingGlobal.rollForward, "latestFeature")

        let compatDir = URL(fileURLWithPath: tree).appendingPathComponent("compat/tree")
        try FileManager.default.createDirectory(at: compatDir, withIntermediateDirectories: true)
        let json = """
        {
          "sdk": {
            "version": "10.0.405",
            "rollForward": "latestFeature"
          }
        }
        """
        try Data(json.utf8).write(to: compatDir.appendingPathComponent("global.json"))
        let custom = S2ArmBuilder.sdkRequirement(in: tree)
        XCTAssertEqual(custom.version, "10.0.405")
        XCTAssertEqual(custom.rollForward, "latestFeature")
    }

    func testSdkSatisfiesAndFindDotnetRejects10_0_402AndAccepts10_0_403() throws {
        XCTAssertFalse(S2ArmBuilder.sdkSatisfies("10.0.402", required: "10.0.403", rollForward: "latestFeature"))
        XCTAssertFalse(S2ArmBuilder.sdkSatisfies("9.0.405", required: "10.0.403", rollForward: "latestFeature"))
        XCTAssertTrue(S2ArmBuilder.sdkSatisfies("10.0.403", required: "10.0.403", rollForward: "latestFeature"))
        XCTAssertTrue(S2ArmBuilder.sdkSatisfies("10.0.404", required: "10.0.403", rollForward: "latestFeature"))
        XCTAssertTrue(S2ArmBuilder.sdkSatisfies("10.0.500", required: "10.0.403", rollForward: "latestFeature"))

        let tree = try makeFakeS2ArmTree(name: "s2arm-dotnet-check")
        let runner = FakeProcessRunner()
        runner.answer = { launch in
            if launch.executable == "/fake/dotnet-old" {
                return ProcessResult(status: 0, out: "8.0.404 [/fake/sdk]\n10.0.402 [/fake/sdk]\n")
            }
            if launch.executable == "/fake/dotnet-new" {
                return ProcessResult(status: 0, out: "10.0.403 [/fake/sdk]\n")
            }
            return ProcessResult(status: 1, out: "")
        }

        let rejected = S2ArmBuilder.findDotnet(
            ["/fake/dotnet-old"],
            tree: tree,
            runner: runner,
            exists: { _ in true }
        )
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.requiredVersion, "10.0.403")
        XCTAssertEqual(rejected.foundOldVersion, "10.0.402")

        let accepted = S2ArmBuilder.findDotnet(
            ["/fake/dotnet-old", "/fake/dotnet-new"],
            tree: tree,
            runner: runner,
            exists: { _ in true }
        )
        XCTAssertTrue(accepted.ok)
        XCTAssertEqual(accepted.path, "/fake/dotnet-new")
        XCTAssertNil(accepted.foundOldVersion)
    }

    func testMissingPythonPackagesReportsAbsentImports() {
        let runner = FakeProcessRunner()
        runner.answer = { _ in ProcessResult(status: 0, out: "Pillow,skia-pathops\n") }
        let missing = S2ArmBuilder.missingPythonPackages(python: "/fake/python3", runner: runner)
        XCTAssertEqual(missing, ["Pillow", "skia-pathops"])

        runner.answer = { _ in ProcessResult(status: 0, out: "\n") }
        XCTAssertEqual(S2ArmBuilder.missingPythonPackages(python: "/fake/python3", runner: runner), [])
    }
}
