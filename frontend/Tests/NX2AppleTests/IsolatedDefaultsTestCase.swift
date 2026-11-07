import XCTest

/// The base of every test in this target. A test process shares one UserDefaults domain (`com.apple.dt.xctest.tool`), and the domain
/// outlives the run: a key one test wrote, or a killed run left behind, was read by the next test and the next run (a stale
/// `exportIPA` or a `repoPath` in a deleted folder failed the shell install tests).
///
/// - `testDefaults` is a suite of its own for the test, from `TestDefaults`, so no file of it stays in `~/Library/Preferences`.
///   A test hands it to `LauncherStores(defaults:)` and to every store or helper that takes a `defaults`, so nothing reads or
///   writes the shared domain.
/// - The shared domain is emptied once per process, so a leftover of an earlier run is gone before the first test.
/// - After each test the shared domain must be as it was before: a test that leaves a key there fails, and the key is put back.
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

    private static let sharedDomainCleared: Void = {
        UserDefaults.standard.removePersistentDomain(forName: sharedDomain)
    }()

    static func sharedKeys() -> [String: Any] { UserDefaults.standard.persistentDomain(forName: sharedDomain) ?? [:] }

    override func invokeTest() {
        _ = Self.sharedDomainCleared
        let before = Self.sharedKeys()
        isolatedSuite = nil
        super.invokeTest()
        isolatedSuite = nil
        let after = Self.sharedKeys()
        let changed = Set(before.keys).union(after.keys).filter { !Self.same(before[$0], after[$0]) }.sorted()
        if !changed.isEmpty {
            XCTFail("\(name) left \(changed.joined(separator: ", ")) in the shared test defaults (\(Self.sharedDomain)). "
                    + "Give the store or helper `testDefaults`, or restore the key.")
            for key in changed { UserDefaults.standard.set(before[key], forKey: key) }   // the next test starts clean
        }
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

    func testTheSharedDomainIsEmptyBeforeTheTest() {
        XCTAssertTrue(Self.sharedKeys().isEmpty, "left over: \(Self.sharedKeys().keys.sorted())")
    }
}
