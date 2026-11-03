import Foundation
import NXCore

/// A `GitCheckout` that runs nothing: each call is recorded and answered from the fields.
final class FakeGitCheckout: GitCheckout, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var binary: String? = "/fake/git"
    var behindCount: Int? = 0
    var pullResult = ProcessResult()
    var autoPullResult: ProcessResult?
    var adoptResult: (ok: Bool, log: String) = (true, "")
    var cloneOK = true
    /// What a clone makes in its destination (a test makes it look like a checkout). nil: nothing.
    var cloneMakes: ((String) -> Void)?

    var calls: [String] { lock.withLock { recorded } }
    private func record(_ call: String) { lock.withLock { recorded.append(call) } }

    func run(_ dir: String, _ args: [String]) -> ProcessResult { record("run \(dir) \(args.joined(separator: " "))"); return ProcessResult() }
    func clone(url: String, into dest: String, line: @escaping (String) -> Void) -> Bool {
        record("clone \(url) \(dest)"); line("Cloning"); cloneMakes?(dest); return cloneOK
    }
    func behind(_ dir: String) -> Int? { record("behind \(dir)"); return behindCount }
    func pull(_ dir: String) -> ProcessResult { record("pull \(dir)"); return pullResult }
    func autoPull(_ dir: String) -> ProcessResult? { record("autoPull \(dir)"); return autoPullResult }
    func adopt(_ dir: String, remote: String, branch: String) -> (ok: Bool, log: String) {
        record("adopt \(dir) \(remote) \(branch)")
        if adoptResult.ok { try? FileManager.default.createDirectory(atPath: dir + "/.git", withIntermediateDirectories: true) }
        return adoptResult
    }
}
