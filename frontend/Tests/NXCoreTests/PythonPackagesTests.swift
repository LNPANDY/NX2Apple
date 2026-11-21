import XCTest
@testable import NXCore

/// nsz installs into a folder the launcher owns, because Homebrew's Python is externally managed (LNPANDY/NX2Apple#1500).
final class PythonPackagesTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("pypkgs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func fakePython(version: String = "3.14") -> FakeProcessRunner {
        let fake = FakeProcessRunner()
        fake.answer = { launch in
            launch.arguments.contains { $0.contains("sys.version_info") } ? ProcessResult(out: version + "\n") : ProcessResult()
        }
        return fake
    }

    func testTheFolderIsKeyedByThePythonVersion() {
        XCTAssertEqual(PythonPackages.directory(version: "3.14", home: "/h"), "/h/Library/Application Support/NX2Apple/python-packages/3.14")
        XCTAssertEqual(PythonPackages.versionName(python: "/opt/homebrew/bin/python3.13", runner: fakePython(version: "3.13")), "3.13")
        let none = FakeProcessRunner()
        none.answer = { _ in .failedToStart("no such file") }
        XCTAssertEqual(PythonPackages.versionName(python: "/x", runner: none), "unknown")
    }

    func testTheBuildEnvironmentCarriesTheFolderOnPythonPath() {
        let fake = fakePython()
        let dir = PythonPackages.directory(version: "3.14", home: home.path)
        let env = PythonPackages.environment(python: "/opt/homebrew/bin/python3.14", env: ["PATH": "/usr/bin"], home: home.path, runner: fake)
        XCTAssertEqual(env["PYTHONPATH"], dir)
        XCTAssertEqual(env["PATH"], "/usr/bin")
        let more = PythonPackages.environment(python: "/opt/homebrew/bin/python3.14", env: ["PYTHONPATH": "/else"], home: home.path, runner: fake)
        XCTAssertEqual(more["PYTHONPATH"], dir + ":/else")
    }

    func testNszInstallsIntoTheLauncherFolderNotIntoAnExternallyManagedPython() {
        // A plain `pip install` is what Homebrew's Python refuses. A target install is not touched by PEP 668.
        let fake = fakePython()
        let py = "/opt/homebrew/bin/python3.14"
        let dir = PythonPackages.directory(version: "3.14", home: home.path)
        let env = PythonPackages.environment(python: py, env: ["PATH": "/usr/bin"], home: home.path, runner: fake)
        let ok = PythonPackages.installNsz(python: py, env: env, home: home.path, runner: fake) { _ in }
        XCTAssertTrue(ok)
        let pip = fake.launches.first { $0.arguments.contains("pip") }
        XCTAssertEqual(pip?.executable, py)
        XCTAssertEqual(pip?.arguments, ["-m", "pip", "install", "--target", dir, "nsz"])
        XCTAssertFalse(pip?.arguments.contains("--break-system-packages") ?? true)
        XCTAssertEqual(pip?.environment?["PYTHONPATH"], dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir))
    }

    func testAFailedInstallIsReported() {
        let fake = fakePython()
        fake.streamOK = false
        let env = PythonPackages.environment(python: "/p", env: [:], home: home.path, runner: fake)
        XCTAssertFalse(PythonPackages.installNsz(python: "/p", env: env, home: home.path, runner: fake) { _ in })
    }
}
