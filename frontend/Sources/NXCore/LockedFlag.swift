import Foundation

/// A flag two threads share (the cancel button on the main thread, the install's wait loop on a background one).
package final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    package init() {}

    package func set(_ value: Bool) { lock.lock(); flag = value; lock.unlock() }
    package var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
