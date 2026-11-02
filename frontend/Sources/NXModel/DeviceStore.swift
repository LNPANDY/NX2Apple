import Foundation
import Combine
import NXCore

/// The devices (LNPANDY/NX2Apple#387, step 7): the iPhones and iPads paired with this Mac, the teams it can sign for, the device and
/// the team the player chose to install on, and the copy flow of the shared app (the question before the game data goes over, and
/// the wait for a cable). It follows `AppUpdateStore` (`frontend/ARCHITECTURE.md`, "Stores").
///
/// - What it works with comes through `init`: a `ProcessRunner` for devicectl and the keychain, the path of `xcrun` (a test points it
///   at a stand-in), the defaults the choices are saved in. The two listings are closures with the real ones as default, so a test
///   gives it devices and teams without a Mac that has them.
/// - The listings block (devicectl takes a few seconds), so they run off the main actor. `refresh()` returns the `Task`.
/// - The copy question is asked by the install, which runs on a background queue and waits for the answer: `askCopy` blocks that
///   queue, `answerCopy` (the card's buttons) lets it go on. `setWaiting` and `waitCancelled` are the same bridge for the cable wait.
/// - Not here, because they belong to the build run: the device the last build went to (`installedOn`, `installedAppPath`), whether
///   this build installs directly (it reads the build target), the retry of the game data, and the install itself (`installShell`),
///   the reinstall and the re-sign. They go with the build store.
@MainActor package final class DeviceStore: ObservableObject {
    nonisolated package static let deviceKey = "installDevice"
    nonisolated package static let teamKey = "signingTeam"

    @Published package var devices: [AppleDevice] = []
    @Published package var teams: [SigningTeam] = []
    /// The listing ran at least once, so the picker shows its spinner until then and "no devices" after.
    @Published package var checked = false
    /// The UDID of the device a build is installed on. Empty: the build stays an IPA. Saved when it changes.
    @Published package var installDevice: String {
        didSet { defaults.set(installDevice, forKey: Self.deviceKey) }
    }
    /// The team ID the build is signed for. Saved when it changes.
    @Published package var signingTeam: String {
        didSet { defaults.set(signingTeam, forKey: Self.teamKey) }
    }
    /// The shared app's copy question: the size and the connection (nil: none is up).
    @Published package private(set) var shellCopy: ShellCopyPlan?
    /// Waiting for a cable before the game data goes over.
    @Published package private(set) var shellWaiting = false

    /// The `xcrun` the device tools and the install run through.
    package let xcrun: String
    /// The teams the Mac knows, read by the refresh and again when a signing step fails.
    package var readTeams: @Sendable () -> [SigningTeam]

    private let defaults: UserDefaults
    private let listDevices: @Sendable (_ xcrun: String) -> [AppleDevice]
    private var copyAnswer: ((ShellCopyDecision) -> Void)?
    private let waitCancel = LockedFlag()

    /// - Parameters:
    ///   - listDevices: the paired devices for an `xcrun` path. Runs off the main actor.
    ///   - readTeams: the signing teams. Runs off the main actor.
    package init(runner: ProcessRunner, xcrun: String = "/usr/bin/xcrun", defaults: UserDefaults = .standard,
                 listDevices: (@Sendable (String) -> [AppleDevice])? = nil,
                 readTeams: (@Sendable () -> [SigningTeam])? = nil) {
        self.xcrun = xcrun
        self.defaults = defaults
        self.listDevices = listDevices ?? { DeviceTools.devices(xcrun: $0, runner: runner) }
        self.readTeams = readTeams ?? { DeviceTools.teams(runner: runner) }
        self.installDevice = defaults.string(forKey: Self.deviceKey) ?? ""
        self.signingTeam = defaults.string(forKey: Self.teamKey) ?? ""
    }

    /// A device's name for a message, "iPhone" when this Mac has not listed it.
    package func deviceName(_ udid: String) -> String { devices.first { $0.id == udid }?.name ?? "iPhone" }

    /// The paired devices and the signing teams, read in the background (devicectl can take a few seconds). A team that is no longer
    /// known is replaced by the first one.
    @discardableResult package func refresh() -> Task<Void, Never> {
        let xcrun = xcrun, list = listDevices, teamsOf = readTeams
        return Task { @MainActor in
            let (devices, teams) = await Task.detached(priority: .userInitiated) { (list(xcrun), teamsOf()) }.value
            self.devices = devices; self.teams = teams; self.checked = true
            if !teams.contains(where: { $0.id == self.signingTeam }) { self.signingTeam = teams.first?.id ?? "" }
        }
    }

    // MARK: The copy flow

    /// Asks the player whether the game data goes over now (the card shows the plan with Continue, "Wait for a cable" and "Not now")
    /// and blocks the calling queue until they answer. Called by the install on its background queue, never on the main thread.
    nonisolated package func askCopy(_ plan: ShellCopyPlan) -> ShellCopyDecision {
        let answered = DispatchSemaphore(value: 0)
        let box = Answer()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.waitCancel.set(false)
                self.copyAnswer = { box.set($0); answered.signal() }
                self.shellCopy = plan
            }
        }
        answered.wait()
        return box.value
    }

    /// What the player picked on the copy card (Continue, wait for a cable, not now), handed to the install waiting for it.
    package func answerCopy(_ decision: ShellCopyDecision) {
        guard let answer = copyAnswer else { return }
        copyAnswer = nil
        shellCopy = nil
        answer(decision)
    }

    /// The install tells that the cable wait starts or ends. Called from its background queue.
    nonisolated package func setWaiting(_ on: Bool) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.shellWaiting = on } }
    }

    /// "Stop waiting" while the install waits for a cable: the poll ends at its next look and the game data stays for later.
    package func cancelWait() { waitCancel.set(true) }

    /// The install asks between two polls whether the player cancelled.
    nonisolated package var waitCancelled: Bool { waitCancel.value }

    /// The install ended: no question and no wait stay on the screen.
    package func copyEnded() {
        shellCopy = nil; shellWaiting = false
    }

    /// The answer the blocked queue reads after the semaphore.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var decision = ShellCopyDecision.skip
        func set(_ new: ShellCopyDecision) { lock.lock(); decision = new; lock.unlock() }
        var value: ShellCopyDecision { lock.lock(); defer { lock.unlock() }; return decision }
    }
}
