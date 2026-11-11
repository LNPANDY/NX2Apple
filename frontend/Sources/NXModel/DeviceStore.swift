import Foundation
import Combine
import NXCore

/// The two places step 3 of the export sends the game data to.
package enum SendWhere {
    package static let device = "device"
    package static let drive = "drive"
}

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
    nonisolated package static let exportKey = "exportIPA"
    nonisolated package static let oneGameKey = "exportOneGame"
    nonisolated package static let sendWhereKey = "sendWhere"
    nonisolated package static let driveFolderKey = "driveFolder"

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
    /// The build makes the shared app as an unsigned IPA instead of installing it (#416). Needs no device and no team. Saved when it changes.
    @Published package var exportIPA: Bool {
        didSet { defaults.set(exportIPA, forKey: Self.exportKey) }
    }
    /// The export makes one game's own IPA with its game data inside, instead of the shared app (#540). Off unless the player picks it.
    @Published package var exportOneGame: Bool {
        didSet { defaults.set(exportOneGame, forKey: Self.oneGameKey) }
    }
    /// Where step 3 of the export sends the game data: `SendWhere.device` or `.drive`. Saved when it changes.
    @Published package var sendWhere: String {
        didSet { defaults.set(sendWhere, forKey: Self.sendWhereKey) }
    }
    /// The folder (a drive) the game data is copied to. Saved when it changes.
    @Published package var driveFolder: String {
        didSet { defaults.set(driveFolder, forKey: Self.driveFolderKey) }
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
    private var refreshGeneration = 0

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
        self.exportIPA = defaults.bool(forKey: Self.exportKey)
        self.exportOneGame = defaults.bool(forKey: Self.oneGameKey)
        self.sendWhere = defaults.string(forKey: Self.sendWhereKey) ?? SendWhere.device
        self.driveFolder = defaults.string(forKey: Self.driveFolderKey) ?? ""
    }

    /// A device's name for a message, "iPhone" when this Mac has not listed it.
    package func deviceName(_ udid: String) -> String { devices.first { $0.id == udid }?.name ?? "iPhone" }

    /// The paired devices and the signing teams, read in the background (devicectl can take a few seconds). A team that is no longer
    /// known is replaced by the first one, while a transient empty team list preserves a valid saved team ID.
    @discardableResult package func refresh() -> Task<Void, Never> {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let xcrun = xcrun, list = listDevices, teamsOf = readTeams
        let lookup = Task.detached(priority: .userInitiated) { (list(xcrun), teamsOf()) }
        return Task { @MainActor in
            let (devices, teams) = await lookup.value
            guard self.refreshGeneration == generation else { return }
            self.devices = devices
            self.teams = teams
            self.checked = true
            if teams.isEmpty {
                if !self.signingTeam.isEmpty && !Self.isValidTeamID(self.signingTeam) {
                    self.signingTeam = ""
                }
            } else if !teams.contains(where: { $0.id == self.signingTeam }) {
                self.signingTeam = teams[0].id
            }
        }
    }

    nonisolated private static func isValidTeamID(_ id: String) -> Bool {
        id.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil
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

    /// Cancels an active copy prompt or cable wait when the build is stopped.
    package func cancelCopy() {
        cancelWait()
        shellWaiting = false
        answerCopy(.skip)
    }

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
