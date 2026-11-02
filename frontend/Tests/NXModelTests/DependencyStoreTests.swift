import XCTest
@testable import NXModel
@testable import NXCore

/// `DependencyStore` without SwiftUI: the detection is a closure that answers from the test, a fake `ProcessRunner` stands in for
/// brew and xcodebuild, and the defaults are a suite of their own. Nothing probes this Mac and nothing is installed. The Python row's
/// venv install is not run here: `Toolchain.makeVenv` reads and writes the real venv folder.
@MainActor final class DependencyStoreTests: XCTestCase {
    private final class FakeRepo: RepoLocation {
        var path = "/repo"
        var isRepo = true
        var isGit = true
    }

    /// What the detection was asked, and what it answers.
    private final class Scanner: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [(repo: String, needsIOS: Bool)] = []
        private var written: [[Dep]] = []
        var result = DependencyCheck.Result(deps: [], python: "", dotnet: "")
        var questions: [(repo: String, needsIOS: Bool)] { lock.lock(); defer { lock.unlock() }; return asked }
        var reports: [[Dep]] { lock.lock(); defer { lock.unlock() }; return written }
        func scan(_ repo: String, _ needsIOS: Bool) -> DependencyCheck.Result {
            lock.lock(); asked.append((repo, needsIOS)); lock.unlock()
            return result
        }
        func report(_ deps: [Dep]) { lock.lock(); written.append(deps); lock.unlock() }
    }

    private var suite: String!
    private var defaults: UserDefaults!
    private let runner = FakeProcessRunner()
    private let localizer = Localizer(.en)
    private let repo = FakeRepo()
    private let scanner = Scanner()
    private var log: [String] = []
    private var notes: [String] = []
    private var appStoreOpened = 0
    private var iOS = true

    override func setUpWithError() throws {
        suite = "nxmodel-dependency-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeStore() -> DependencyStore {
        let scanner = self.scanner
        return DependencyStore(localizer: localizer, runner: runner, repo: repo, defaults: defaults,
                               needsIOS: { [unowned self] in iOS },
                               scan: { scanner.scan($0, $1) }, report: { scanner.report($0) },
                               openAppStore: { [unowned self] in appStoreOpened += 1 },
                               log: { [unowned self] in log.append($0) }, installFailed: { [unowned self] in notes.append($0) })
    }

    private func dep(_ id: String, present: Bool, cmd: [String] = ["brew", "install", "x"], warning: Bool = false) -> Dep {
        Dep(id: id, name: "dep." + id, hint: "dep." + id + ".hint", present: present, warning: warning, installCmd: cmd)
    }

    // ---- The check ----

    func testTheCheckPublishesTheRowsAndThePathsAfterTheSpinner() async {
        scanner.result = DependencyCheck.Result(deps: [dep("xcode", present: true), dep("dotnet", present: true)],
                                                python: "/opt/py/bin/python3", dotnet: "/opt/dotnet/dotnet")
        let store = makeStore()
        XCTAssertFalse(store.checked)
        let task = store.check()
        XCTAssertFalse(store.checked, "the panel shows its spinner until the rows are in")
        await task.value
        XCTAssertTrue(store.checked)
        XCTAssertEqual(store.deps.map(\.id), ["xcode", "dotnet"])
        XCTAssertEqual(store.pythonPath, "/opt/py/bin/python3")
        XCTAssertEqual(store.dotnetPath, "/opt/dotnet/dotnet")
    }

    func testTheCheckReadsTheRepositoryAndThePlatformChoiceAndWritesTheReport() async {
        repo.path = "/somewhere/checkout"
        iOS = false
        scanner.result = DependencyCheck.Result(deps: [dep("xcode", present: false)], python: "", dotnet: "")
        let store = makeStore()
        await store.check().value
        XCTAssertEqual(scanner.questions.map(\.repo), ["/somewhere/checkout"])
        XCTAssertEqual(scanner.questions.map(\.needsIOS), [false])
        XCTAssertEqual(scanner.reports.map { $0.map(\.id) }, [["xcode"]])
        iOS = true
        await store.check().value
        XCTAssertEqual(scanner.questions.map(\.needsIOS), [false, true], "asked again at every check")
    }

    func testEverythingIsPresentOnlyAfterACheckWithNoMissingRow() async {
        let store = makeStore()
        XCTAssertFalse(store.allPresent, "before the first check")
        scanner.result = DependencyCheck.Result(deps: [dep("xcode", present: true), dep("metal", present: false)], python: "", dotnet: "")
        await store.check().value
        XCTAssertFalse(store.allPresent)
        scanner.result = DependencyCheck.Result(deps: [dep("xcode", present: true), dep("metal", present: true, warning: true)], python: "", dotnet: "")
        await store.check().value
        XCTAssertTrue(store.allPresent, "a warning row is present")
        _ = store.check()
        XCTAssertFalse(store.allPresent, "not while a check runs")
    }

    func testTheBuildReadsTheStoreThroughDependencyStatus() async {
        scanner.result = DependencyCheck.Result(deps: [dep("xcode", present: true)], python: "/py", dotnet: "/dn")
        let store = makeStore()
        await store.check().value
        let status: DependencyStatus = store
        XCTAssertTrue(status.checked)
        XCTAssertTrue(status.allPresent)
        XCTAssertEqual(status.pythonPath, "/py")
        XCTAssertEqual(status.dotnetPath, "/dn")
        XCTAssertEqual(status.deps.map(\.id), ["xcode"])
        let python: PythonLocation = store
        XCTAssertEqual(python.pythonPath, "/py", "the engine sync reads the interpreter through the narrow protocol")
    }

    // ---- The list's state ----

    func testTheListIsOpenWhileSomethingIsMissingAndFoldsWhenAllIsGreen() async {
        let store = makeStore()
        XCTAssertTrue(store.open, "not checked yet")
        scanner.result = DependencyCheck.Result(deps: [dep("xcode", present: false)], python: "", dotnet: "")
        await store.check().value
        XCTAssertTrue(store.open)
        scanner.result = DependencyCheck.Result(deps: [dep("xcode", present: true)], python: "", dotnet: "")
        await store.check().value
        XCTAssertFalse(store.open, "a set-up machine never needs the rows again")
    }

    func testAToggleOverridesAndIsRemembered() async {
        scanner.result = DependencyCheck.Result(deps: [dep("xcode", present: true)], python: "", dotnet: "")
        let store = makeStore()
        await store.check().value
        XCTAssertNil(store.expanded)
        store.toggle()
        XCTAssertEqual(store.expanded, true)
        XCTAssertTrue(store.open)
        XCTAssertEqual(defaults.object(forKey: DependencyStore.expandedKey) as? Bool, true)
        let again = makeStore()
        XCTAssertEqual(again.expanded, true, "the choice comes back with the next launch")
        again.toggle()
        XCTAssertEqual(again.expanded, false)
        XCTAssertFalse(again.open)
    }

    func testARowsDetailIsAPathAKeyWithArgumentsOrTheHint() {
        let store = makeStore()
        var d = dep("dotnet", present: true)
        XCTAssertEqual(store.detail(of: d), localizer.t("dep.dotnet.hint"), "no detail: the hint")
        d.detail = "/opt/dotnet/dotnet"
        XCTAssertEqual(store.detail(of: d), "/opt/dotnet/dotnet")
        d.detail = "dep.metal.other:32023.1:32023.2"
        XCTAssertTrue(store.detail(of: d).contains("32023.1"))
        XCTAssertTrue(store.detail(of: d).contains("32023.2"))
        d.detail = "dep.dotnet.missing"
        XCTAssertEqual(store.detail(of: d), localizer.t("dep.dotnet.missing"))
        d.detail = "3.9.6 is too old"
        XCTAssertEqual(store.detail(of: d), "3.9.6 is too old", "free text stays as it is")
    }

    // ---- The installs ----

    private func storeWithRows(_ rows: [Dep]) async -> DependencyStore {
        scanner.result = DependencyCheck.Result(deps: rows, python: "", dotnet: "")
        let store = makeStore()
        await store.check().value
        return store
    }

    func testAnInstallRunsTheRowsCommandThroughBashAndChecksAgain() async throws {
        let store = await storeWithRows([dep("zstd", present: false, cmd: ["/opt/homebrew/bin/brew", "install", "zstd"])])
        runner.streamAnswer = { _ in (["==> Installing zstd"], true) }
        scanner.result = DependencyCheck.Result(deps: [dep("zstd", present: true)], python: "", dotnet: "")
        let task = store.install(store.deps[0])
        XCTAssertTrue(store.isInstalling("zstd"), "the row says so from the call on")
        await task.value
        XCTAssertFalse(store.isInstalling("zstd"))
        XCTAssertTrue(store.allPresent, "the check after the install found it")
        let launch = try XCTUnwrap(runner.launches.first)
        XCTAssertEqual(launch.executable, "/bin/bash")
        XCTAssertEqual(launch.arguments, ["-c", "/opt/homebrew/bin/brew install zstd"])
        XCTAssertEqual(launch.environment?["NONINTERACTIVE"], "1")
        XCTAssertTrue(launch.environment?["PATH"]?.hasPrefix("/opt/homebrew/bin:") ?? false)
        try await Task.sleep(nanoseconds: 50_000_000)   // the lines reach the log through the main queue
        XCTAssertTrue(log.contains("==> Installing zstd\n"))
        XCTAssertTrue(notes.isEmpty)
    }

    func testAWordWithASpaceIsQuotedForBash() async {
        let store = await storeWithRows([dep("x", present: false, cmd: ["/bin/echo", "two words"])])
        await store.install(store.deps[0]).value
        XCTAssertEqual(runner.launches.first?.arguments, ["-c", "/bin/echo 'two words'"])
    }

    func testAFailedInstallKeepsTheToolsErrorLineOnTheRowAndSaysSo() async {
        let store = await storeWithRows([dep("zstd", present: false)])
        runner.streamAnswer = { _ in (["==> Fetching zstd", "Error: zstd: no bottle available"], false) }
        scanner.result = DependencyCheck.Result(deps: [dep("zstd", present: false)], python: "", dotnet: "")
        let rows = store.deps
        await store.install(rows[0]).value
        XCTAssertEqual(notes, [String(format: localizer.t("dep.install.fail"), localizer.t("dep.zstd"))])
        XCTAssertFalse(store.isInstalling("zstd"))
        XCTAssertTrue(store.checked, "the check ran again")
    }

    func testTheErrorLineAndTheFixSitOnTheRowUntilTheNextCheck() async {
        let store = await storeWithRows([dep("zstd", present: false)])
        runner.streamAnswer = { _ in (["Error: zstd: no bottle available"], false) }
        // The check at the end of the install replaces the rows, so look at the row while it still runs the install.
        let task = store.install(store.deps[0])
        scanner.result = DependencyCheck.Result(deps: [dep("zstd", present: false)], python: "", dotnet: "")
        XCTAssertTrue(store.isInstalling("zstd"))
        await task.value
        XCTAssertEqual(notes.count, 1)
    }

    func testARowWithoutACommandOpensTheAppStoreAndInstallsNothing() async {
        let store = await storeWithRows([dep("xcode", present: false, cmd: [])])
        await store.install(store.deps[0]).value
        XCTAssertEqual(appStoreOpened, 1)
        XCTAssertTrue(runner.launches.isEmpty)
        XCTAssertFalse(store.isInstalling("xcode"))
    }

    func testARowTheListDoesNotHoldIsNotInstalled() async {
        let store = await storeWithRows([dep("xcode", present: true)])
        await store.install(dep("zstd", present: false)).value
        XCTAssertTrue(runner.launches.isEmpty)
        XCTAssertTrue(notes.isEmpty)
    }
}
