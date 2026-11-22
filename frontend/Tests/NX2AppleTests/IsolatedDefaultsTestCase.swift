import Darwin
import IOKit.pwr_mgt
import XCTest
@testable import NXLauncher

/// The base of every test in this target. A test process shares one UserDefaults domain (`com.apple.dt.xctest.tool`), and the domain
/// outlives the run: a key one test wrote, or a killed run left behind, was read by the next test and the next run (a stale
/// `exportIPA` or a `repoPath` in a deleted folder failed the shell install tests).
///
/// - `testDefaults` is a suite of its own for the test, from `TestDefaults`, so no file of it stays in `~/Library/Preferences`.
///   A test hands it to `LauncherStores(defaults:)` and to every store or helper that takes a `defaults`, so nothing reads or
///   writes the shared domain.
/// - The shared domain is emptied once per process, so a leftover of an earlier run is gone before the first test.
/// - After each test the shared domain must be as it was before: a test that leaves a key there fails, and the key is put back.
///   Only a change this process made counts. Every `swift test` on the Mac shares the domain, and a second run at the same time
///   (another checkout, a pre-push) writes into it too: its keys showed up here as this test's leak (a `libraryFilter` failed
///   ShellExportTests in full runs, a slow test that passes alone, as ShellHotInstallTests did). UserDefaults posts didChangeNotification
///   only for this process's own writes, so a test that saw none leaves the domain alone.
class IsolatedDefaultsTestCase: XCTestCase {
    /// The suite of this test, created on first use.
    var testDefaults: UserDefaults {
        if let suite = isolatedSuite { return suite }
        let defaults = TestDefaults.make("nx2apple-test")
        isolatedSuite = defaults
        return defaults
    }
    private var isolatedSuite: UserDefaults?

    /// The domain the process reads and writes through `UserDefaults.standard`.
    static var sharedDomain: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    private static let testProcessActivity: NSObjectProtocol = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleDisplaySleepDisabled],
        reason: "NX2AppleTests offscreen rendering and RunLoop timers"
    )
    private static var lastDisplayWake: CFAbsoluteTime = 0

    private static func keepDisplayAndRunLoopAwake() {
        _ = testProcessActivity
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDisplayWake > 60 else { return }
        lastDisplayWake = now
        var assertionID = IOPMAssertionID(0)
        IOPMAssertionDeclareUserActivity("NX2AppleTests" as CFString, kIOPMUserActiveLocal, &assertionID)
    }

    private static let sharedDomainCleared: Void = {
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        UserDefaults.standard.removePersistentDomain(forName: sharedDomain)
    }()

    static func sharedKeys() -> [String: Any] { UserDefaults.standard.persistentDomain(forName: sharedDomain) ?? [:] }

    /// Counts this process's writes to `UserDefaults.standard` while a test runs (another process's writes post nothing here).
    final class WriteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// The longest one test may run (the slowest on CI, GalleryCatalogTests, takes about 3 minutes). A test that runs longer is
    /// stuck: the watchdog names it, samples the process and ends the run, so CI fails on that test instead of being cancelled at
    /// the job's 30 minutes with a log that stops wherever the output was last flushed (#1474).
    static let stuckAfter: TimeInterval = 600

    /// Ends the run when `name` is still running after `stuckAfter`: its name and a `sample` of every thread go to stderr first.
    private static func watchdog(_ name: String) -> DispatchWorkItem {
        let item = DispatchWorkItem {
            FileHandle.standardError.write(Data("\nWATCHDOG: \(name) has run for \(Int(stuckAfter)) s, sampling the process and ending the run\n".utf8))
            let sample = Process()
            sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sample.arguments = [String(getpid()), "3"]
            sample.standardOutput = FileHandle.standardError
            sample.standardError = FileHandle.standardError
            try? sample.run()
            sample.waitUntilExit()
            exit(3)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + stuckAfter, execute: item)
        return item
    }

    override func invokeTest() {
        _ = Self.sharedDomainCleared
        // The output goes to a pipe on CI, block-buffered: flushed per test, the log shows which test runs (setvbuf above comes
        // after XCTest's first lines, so it does not take effect)
        fflush(stdout)
        let watchdog = Self.watchdog(name)
        defer { watchdog.cancel(); fflush(stdout) }
        Self.keepDisplayAndRunLoopAwake()
        let before = Self.sharedKeys()
        let writes = WriteCounter()
        let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard,
                                                              queue: nil) { _ in writes.add() }
        isolatedSuite = nil
        super.invokeTest()
        isolatedSuite = nil
        NotificationCenter.default.removeObserver(observer)
        let after = Self.sharedKeys()
        let changed = Self.leaked(before: before, after: after, ownWrites: writes.value)
        if !changed.isEmpty {
            XCTFail("\(name) left \(changed.joined(separator: ", ")) in the shared test defaults (\(Self.sharedDomain)). "
                    + "Give the store or helper `testDefaults`, or restore the key.")
            for key in changed { UserDefaults.standard.set(before[key], forKey: key) }   // the next test starts clean
        }
    }

    /// The keys a test left in the shared domain: none when this process wrote nothing there, whatever another process did.
    static func leaked(before: [String: Any], after: [String: Any], ownWrites: Int) -> [String] {
        guard ownWrites > 0 else { return [] }
        return Set(before.keys).union(after.keys).filter { !same(before[$0], after[$0]) }.sorted()
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return (a as AnyObject).isEqual(b)
        default: return false
        }
    }
}

/// The guard's own tests: the suite is separate from the shared domain, and the shared domain starts empty.
final class SharedDefaultsGuardTests: IsolatedDefaultsTestCase {
    func testTheTestSuiteIsNotTheSharedDomain() {
        let before = Self.sharedKeys()
        testDefaults.set("somewhere", forKey: "repoPath")
        testDefaults.set(true, forKey: "exportIPA")
        XCTAssertEqual(testDefaults.string(forKey: "repoPath"), "somewhere")
        XCTAssertEqual(NSDictionary(dictionary: Self.sharedKeys()), NSDictionary(dictionary: before))
    }

    /// A second `swift test` writing into the shared domain at the same time is not this test's leak: another process's write
    /// is visible here but posts no didChangeNotification, so the guard leaves it alone.
    func testAnotherProcesssWriteIsNotThisTestsLeak() throws {
        XCTAssertEqual(Self.leaked(before: [:], after: ["libraryFilter": "ios"], ownWrites: 0), [])
        XCTAssertEqual(Self.leaked(before: [:], after: ["libraryFilter": "ios"], ownWrites: 1), ["libraryFilter"])
        XCTAssertEqual(Self.leaked(before: ["librarySort": "name"], after: ["librarySort": "name"], ownWrites: 2), [])

        let posts = WriteCounter()
        let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard,
                                                              queue: nil) { _ in posts.add() }
        defer { NotificationCenter.default.removeObserver(observer) }
        func runDefaults(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
        }
        try runDefaults(["write", Self.sharedDomain, "isolatedDefaultsProbe", "other"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(Self.sharedKeys()["isolatedDefaultsProbe"] as? String, "other", "the other process's write is visible here")
        XCTAssertEqual(posts.value, 0, "and posts nothing in this process")
        try runDefaults(["delete", Self.sharedDomain, "isolatedDefaultsProbe"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    func testTheSharedDomainIsEmptyBeforeTheTest() {
        XCTAssertTrue(Self.sharedKeys().isEmpty, "left over: \(Self.sharedKeys().keys.sorted())")
    }
}
