import XCTest
@testable import NSPortBuilder

/// The release app carries its build tools and a Python (BundledTools.swift): the dependency check prefers them to Homebrew's and to
/// a system Python, and the build's PATH starts with them. A fake bundle stands in for Contents/Resources.
final class BundledToolsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// An executable file `relative` under the fake Resources folder; `script` is what it prints when it runs.
    @discardableResult
    private func install(_ relative: String, script: String = "#!/bin/sh\nexit 0\n") throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
    private func installAllTools() throws {
        for (_, binary, _) in BuildModel.brewDeps { try install("tools/bin/" + binary) }
    }
    private func row(_ rows: [BuildModel.Dep], _ pkg: String) -> BuildModel.Dep? { rows.first { $0.id == "brew:" + pkg } }

    // ---- what the bundle holds ----

    func testNoBundleAnswersNil() {
        XCTAssertNil(BundledTools.binDirectory(in: nil))
        XCTAssertNil(BundledTools.tool("zstd", in: nil))
        XCTAssertNil(BundledTools.python(in: nil))
        XCTAssertNil(BundledTools.binDirectory(in: root), "a folder with no tools/bin")
        XCTAssertNil(BundledTools.tool("zstd", in: root))
    }

    func testSwiftRunHasNoResources() {
        // `swift test` and `swift run` execute outside a .app, so the launcher sees no bundle there
        XCTAssertNil(BundledTools.resources)
    }

    func testToolAndPythonPaths() throws {
        let zstd = try install("tools/bin/zstd")
        let py = try install("python/bin/python3")
        XCTAssertEqual(BundledTools.tool("zstd", in: root), zstd)
        XCTAssertNil(BundledTools.tool("xcodegen", in: root))
        XCTAssertEqual(BundledTools.python(in: root), py)
        XCTAssertEqual(BundledTools.binDirectory(in: root), root.appendingPathComponent("tools/bin").path)
    }

    func testAFileWithoutTheExecuteBitIsNotATool() throws {
        let url = root.appendingPathComponent("tools/bin/zstd")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(BundledTools.tool("zstd", in: root))
    }

    // ---- PATH ----

    func testPathWithoutBundleIsTheBaseUnchanged() {
        XCTAssertEqual(BundledTools.path("/usr/bin:/bin", python: nil, in: nil), "/usr/bin:/bin")
        XCTAssertEqual(BundledTools.path("/usr/bin:/bin", python: nil, in: root), "/usr/bin:/bin")
    }

    func testPathPutsTheBundledToolsFirstThenItsPython() throws {
        try install("tools/bin/zstd")
        let py = try install("python/bin/python3")
        XCTAssertEqual(BundledTools.path("/opt/homebrew/bin:/usr/bin", python: py, in: root),
                       root.path + "/tools/bin:" + root.path + "/python/bin:/opt/homebrew/bin:/usr/bin")
    }

    func testPathKeepsARejectedOrOtherPythonOff() throws {
        // review of #154: the bundled interpreter that findPython rejected must not lead the PATH, nor must it when another was chosen
        try install("tools/bin/zstd")
        try install("python/bin/python3")
        let expected = root.path + "/tools/bin:/usr/bin"
        XCTAssertEqual(BundledTools.path("/usr/bin", python: "/opt/homebrew/bin/python3", in: root), expected)
        XCTAssertEqual(BundledTools.path("/usr/bin", python: nil, in: root), expected)
    }

    func testOnlyTheBundledPythonGetsTheIsolatedEnvironment() throws {
        let py = try install("python/bin/python3")
        let env = BundledTools.environment(for: py, in: root)
        XCTAssertEqual(env["PYTHONNOUSERSITE"], "1")
        XCTAssertEqual(env["PYTHONDONTWRITEBYTECODE"], "1")
        XCTAssertTrue(BundledTools.environment(for: "/opt/homebrew/bin/python3", in: root).isEmpty)
        XCTAssertTrue(BundledTools.environment(for: py, in: nil).isEmpty)
    }

    func testPathWithToolsButNoPython() throws {
        try install("tools/bin/zstd")
        XCTAssertEqual(BundledTools.path("/usr/bin", python: nil, in: root), root.path + "/tools/bin:/usr/bin")
    }

    func testBuildToolPathKeepsTheHomebrewBaseWithoutABundle() {
        // under `swift test` there is no bundle: the helper is the old string
        XCTAssertEqual(BuildModel.toolPath(), "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        XCTAssertEqual(BuildModel.toolPath("/usr/bin:/bin"), "/usr/bin:/bin")
    }

    // ---- the dependency rows ----

    func testWithoutABundleTheRowsAreHomebrews() {
        let rows = BuildModel.toolDeps(resources: nil, installed: { "/opt/homebrew/bin/" + $0 }, brew: "/opt/homebrew/bin/brew")
        XCTAssertEqual(rows.map { $0.id }, ["brew"] + BuildModel.brewDeps.map { "brew:" + $0.formula })
        XCTAssertTrue(rows.allSatisfy { $0.present })
        XCTAssertEqual(row(rows, "zstd")?.detail, "/opt/homebrew/bin/zstd")
        XCTAssertEqual(row(rows, "glslang")?.detail, "/opt/homebrew/bin/glslangValidator")
    }

    func testWithoutABundleOrHomebrewTheRowsAreMissing() {
        let rows = BuildModel.toolDeps(resources: nil, installed: { _ in nil }, brew: nil)
        XCTAssertFalse(rows.first { $0.id == "brew" }!.present)
        XCTAssertTrue(BuildModel.brewDeps.allSatisfy { row(rows, $0.formula)?.present == false })
    }

    func testBundledToolsArePresentAndNeedNoHomebrew() throws {
        try installAllTools()
        let rows = BuildModel.toolDeps(resources: root, installed: { _ in nil }, brew: nil)
        XCTAssertNil(rows.first { $0.id == "brew" }, "nothing needs Homebrew")
        XCTAssertEqual(rows.count, BuildModel.brewDeps.count)
        XCTAssertTrue(rows.allSatisfy { $0.present && $0.detail == "dep.bundled" })
        XCTAssertEqual(rows.map { $0.name }, BuildModel.brewDeps.map { "dep.tool." + $0.binary }, "named by the tool, not \"brew: …\"")
        for (_, binary, _) in BuildModel.brewDeps {
            for lang in [Lang.en, .zh] { XCTAssertEqual(L10n.string("dep.tool." + binary, lang), binary) }
        }
    }

    func testBundledWinsOverHomebrews() throws {
        try installAllTools()
        let rows = BuildModel.toolDeps(resources: root, installed: { "/opt/homebrew/bin/" + $0 }, brew: "/opt/homebrew/bin/brew")
        XCTAssertTrue(rows.allSatisfy { $0.detail == "dep.bundled" })
        XCTAssertNil(rows.first { $0.id == "brew" })
    }

    func testOneMissingToolBringsBackTheHomebrewRowForThatTool() throws {
        try installAllTools()
        try FileManager.default.removeItem(at: root.appendingPathComponent("tools/bin/spirv-cross"))
        let rows = BuildModel.toolDeps(resources: root, installed: { _ in nil }, brew: nil)
        XCTAssertEqual(rows.first?.id, "brew")
        XCTAssertFalse(rows.first!.present)
        XCTAssertEqual(row(rows, "spirv-cross")?.present, false)
        XCTAssertEqual(row(rows, "zstd")?.detail, "dep.bundled")
        XCTAssertEqual(row(rows, "zstd")?.name, "dep.tool.zstd")
        XCTAssertEqual(row(rows, "spirv-cross")?.name, "dep.spirv", "missing: the Homebrew row keeps its label")
    }

    func testAMissingBundledToolFallsBackToHomebrewsCopy() throws {
        try installAllTools()
        try FileManager.default.removeItem(at: root.appendingPathComponent("tools/bin/xcodegen"))
        let rows = BuildModel.toolDeps(resources: root, installed: { $0 == "xcodegen" ? "/opt/homebrew/bin/xcodegen" : nil },
                                       brew: "/opt/homebrew/bin/brew")
        XCTAssertEqual(row(rows, "xcodegen")?.detail, "/opt/homebrew/bin/xcodegen")
        XCTAssertEqual(row(rows, "xcodegen")?.present, true)
        XCTAssertEqual(row(rows, "xcodegen")?.name, "dep.xcodegen", "a Homebrew copy keeps the Homebrew label")
        XCTAssertNil(rows.first { $0.id == "brew" }, "every tool is bundled or installed")
    }

    func testBundledRowDetailIsLocalized() {
        XCTAssertEqual(L10n.string("dep.bundled", .en), "bundled")
        XCTAssertNotEqual(L10n.string("dep.bundled", .zh), "dep.bundled")
    }

    // ---- the Python ----

    func testFindPythonUsesTheBundledOneThatRunsAndImports() throws {
        // a stand-in interpreter that answers the version probe and accepts the import probe
        let py = try install("python/bin/python3", script: """
            #!/bin/sh
            case "$2" in *sys.version_info*) echo 3.13;; esac
            exit 0

            """)
        let found = BuildModel.findPython(resources: root)
        XCTAssertEqual(found.path, py)
        XCTAssertTrue(found.ok)
    }

    func testFindPythonSkipsABundledOneThatDoesNotRun() throws {
        let py = try install("python/bin/python3", script: "#!/bin/sh\nexit 1\n")
        XCTAssertNotEqual(BuildModel.findPython(resources: root).path, py)
    }

    func testFindPythonSkipsABundledOneThatIsTooOld() throws {
        let py = try install("python/bin/python3", script: "#!/bin/sh\ncase \"$2\" in *sys.version_info*) echo 3.9;; esac\nexit 0\n")
        XCTAssertNotEqual(BuildModel.findPython(resources: root).path, py)
    }

    // ---- the pinned packages ----

    func testBundledPackagePinsCoverThePipPackages() throws {
        // frontend/Tests/NSPortBuilderTests/BundledToolsTests.swift -> frontend/tools
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let text = try String(contentsOf: url.appendingPathComponent("tools/bundled-python-requirements.txt"), encoding: .utf8)
        let pins = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        let names = Set(pins.map { String($0.split(separator: "=", maxSplits: 1)[0]).lowercased() })
        for pkg in BuildModel.pipPackages((3, 13)) {
            XCTAssertTrue(names.contains(pkg.lowercased()), "\(pkg) is installed by the launcher's venv but not pinned for the bundle")
        }
        XCTAssertTrue(pins.allSatisfy { $0.contains("==") }, "every bundled package has an exact version")
    }
}
