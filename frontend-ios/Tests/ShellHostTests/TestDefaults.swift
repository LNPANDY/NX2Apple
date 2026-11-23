import Foundation

/// An isolated in-memory `UserDefaults` for `frontend-ios` tests, kept completely out of `~/Library/Preferences` and `cfprefsd`.
///
/// Swift Testing runs suites concurrently across all cores. Creating thousands of path-backed `UserDefaults(suiteName:)` instances
/// in parallel saturates `cfprefsd` on virtualized CI runners (hitting the 15 s XPC timeout on `removeObject`), while plain suite
/// names leave permanent `.plist` files in `~/Library/Preferences`. An in-memory `UserDefaults` subclass avoids both `cfprefsd`
/// IPC and filesystem writes on macOS and iOS Simulator alike.
///
/// The same file is in ShellHostTests and ShellUITests so neither target needs an extra shared module. `TestDefaultsTests` checks
/// that the copies match and that no test makes a suite another way.
enum TestDefaults {
    /// A new, empty isolated `UserDefaults` instance.
    static func make(_ label: String) -> UserDefaults {
        _ = label
        return InMemoryDefaults()
    }

    /// A per-test provider whose `UserDefaults` instances are keyed by identifier (for example a title ID) and cached per key.
    static func keyed(_ label: String) -> @Sendable (String) -> UserDefaults {
        _ = label
        let box = KeyedDefaultsBox()
        return { box.defaults(for: $0) }
    }
}

private final class KeyedDefaultsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [String: InMemoryDefaults] = [:]

    func defaults(for id: String) -> UserDefaults {
        lock.lock()
        defer { lock.unlock() }
        if let existing = byID[id] { return existing }
        let created = InMemoryDefaults()
        byID[id] = created
        return created
    }
}

private final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return storage[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock()
        if let value {
            storage[defaultName] = value
        } else {
            storage.removeValue(forKey: defaultName)
        }
        lock.unlock()
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }

    override func set(_ value: Int, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    override func set(_ value: Float, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    override func set(_ value: Double, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    override func set(_ value: Bool, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    override func set(_ url: URL?, forKey defaultName: String) { set(url as Any?, forKey: defaultName) }

    override func url(forKey defaultName: String) -> URL? {
        let raw = object(forKey: defaultName)
        if let url = raw as? URL { return url }
        if let data = raw as? Data { return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data) as URL? }
        if let path = raw as? String { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return nil
    }

    override func removeObject(forKey defaultName: String) {
        set(nil as Any?, forKey: defaultName)
    }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    override func synchronize() -> Bool { true }
}
