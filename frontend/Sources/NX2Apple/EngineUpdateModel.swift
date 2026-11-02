import Foundation
import NXCore
import NXModel
import NXLauncher

// The release app's engine in the model: which tree the build reads, the launch check, the channel switch and what
// Settings says. The rules (what is verified, where a tree comes from) are in EngineUpdater.swift. A launcher built
// from the repository has no engine in its bundle (`engineBundle` is nil), and everything here leaves it alone.
extension BuildModel {
    /// At launch: build from the selected engine in the store, copy the app's own engine there on the first start,
    /// then ask the selected channel for a newer one. On the stable channel a new app brings its own engine, which
    /// then replaces the one an older app left selected, without the network.
    func prepareEngine() {
        guard let bundled = engineBundle, !engineBusy, let id = EngineStore.identity(of: bundled) else { return }
        let selected = engineSelection.engineID
        let appMovedOn = engineSelection.channel == .stable && selected != id && engineSelection.version != AppUpdateStore.appVersion
        if !appMovedOn, engineStore.isUsable(selected), let dir = engineStore.directory(for: selected) {
            repoPath = dir.path
            checkEngineUpdate(automatic: true)
            return
        }
        engineBusy = true
        engineStatus = t("engine.preparing")
        let store = engineStore
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try EngineInstaller.seed(from: bundled, engineID: id, store: store) }
            DispatchQueue.main.async {
                self.engineBusy = false
                switch result {
                case .success:
                    // The app's engine is the stable one of this release. A player on experimental gets theirs from the check.
                    let engine = EngineUpdate.Engine(id: id, version: AppUpdateStore.appVersion)
                    if self.running {   // a build started from the old folder while the copy ran
                        self.pendingEngine = (engine, self.engineSelection.channel)
                        self.engineStatus = ""
                    } else {
                        self.switchEngine(to: engine, channel: self.engineSelection.channel, announce: false)
                        self.checkEngineUpdate(automatic: true)
                    }
                case .failure:
                    self.engineStatus = self.t("engine.seedFail")
                }
            }
        }
    }

    /// Ask the selected channel for its engine. `automatic` is the launch check: it installs only with automatic
    /// updates on, and it says nothing when the engine is current or the network is down.
    func checkEngineUpdate(automatic: Bool = false) {
        runEngineUpdate(channel: engineSelection.channel, install: automatic ? MainActor.assumeIsolated { repo.autoUpdate } : true, quiet: automatic)
    }

    /// Install the engine the launch check found (automatic updates off).
    func installAvailableEngine() {
        runEngineUpdate(channel: engineSelection.channel, install: true, quiet: false)
    }

    /// The channel picker: a different channel is confirmed first, because the switch can change the shader chain.
    func requestEngineChannel(_ channel: EngineChannel) {
        guard engineSelection.channel.switchWarningKey(to: channel) != nil, !engineBusy, !running else { return }
        confirmingChannel = channel
    }

    /// The alert's button passes the channel it showed, so the order of the alert's own dismissal does not matter.
    func confirmEngineChannel(_ channel: EngineChannel) {
        confirmingChannel = nil
        runEngineUpdate(channel: channel, install: true, quiet: false)
    }

    func cancelEngineChannel() { confirmingChannel = nil }

    /// The selected channel is only changed once its engine is in place, so Settings never names a channel whose
    /// engine the build does not use.
    private func runEngineUpdate(channel: EngineChannel, install: Bool, quiet: Bool) {
        guard usesEngineStore, !engineBusy else { return }
        guard !running else {
            if !quiet { engineStatus = t("engine.waitForBuild") }
            return
        }
        engineBusy = true
        if !quiet { engineStatus = t(channel == engineSelection.channel ? "engine.checking" : "engine.switching") }
        let store = engineStore, bundled = engineBundle, current = engineSelection.engineID, transport = engineTransport
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = EngineUpdate.run(channel: channel, appVersion: AppUpdateStore.appVersion, current: current, store: store,
                                           bundled: bundled, install: install, transport: transport)
            DispatchQueue.main.async {
                self.engineBusy = false
                self.applyEngineOutcome(outcome, channel: channel, quiet: quiet)
            }
        }
    }

    func applyEngineOutcome(_ outcome: EngineUpdate.Outcome, channel: EngineChannel, quiet: Bool) {
        switch outcome {
        case .current(let engine):
            engineAvailable = nil
            if engineSelection.channel != channel || engineSelection.version != engine.version {
                engineSelection.channel = channel
                engineSelection.version = engine.version
                engineSelection.save()
            }
            if !quiet { engineStatus = String(format: t("engine.upToDate"), engine.version) }
        case .available(let engine):
            engineAvailable = engine
            engineStatus = String(format: t("engine.available"), engine.version)
        case .installed(let engine, _):
            engineAvailable = nil
            if running {
                pendingEngine = (engine, channel)
                engineStatus = String(format: t("engine.waitsForBuild"), engine.version)
            } else {
                switchEngine(to: engine, channel: channel)
            }
        case .failed(let failure):
            if quiet, failure == .network || failure == .noManifest { return }
            let key = EngineUpdate.key(failure)
            engineStatus = failure == .noManifest ? String(format: t(key), t(channel.labelKey)) : t(key)
        }
    }

    /// Point the build at an installed tree, keep the one before it, and say whether the shader chain changed.
    /// `announce` off (the app's own engine at launch): only a changed shader chain is worth a line.
    func switchEngine(to engine: EngineUpdate.Engine, channel: EngineChannel, announce: Bool = true) {
        guard let dir = engineStore.directory(for: engine.id) else { return }
        let old = repoPath
        engineSelection.channel = channel
        engineSelection.switched(to: engine.id, version: engine.version)
        engineSelection.save()
        repoPath = dir.path
        engineStore.prune(keeping: engineSelection.kept)
        if let change = EngineUpdate.chainChange(from: old, to: dir.path) {
            engineStatus = String(format: t("engine.chainChanged"), engine.version, change.old, change.new)
        } else {
            engineStatus = announce ? String(format: t("engine.installed"), engine.version) : ""
        }
    }

    /// The build that held an installed engine back has ended (LauncherView watches `running`).
    func applyPendingEngine() {
        guard !running, let pending = pendingEngine else { return }
        pendingEngine = nil
        switchEngine(to: pending.engine, channel: pending.channel)
    }

    /// What Settings shows for the engine: its version and the pin it was built from.
    var engineDetail: String {
        let s = engineSelection
        guard !s.engineID.isEmpty else { return t("engine.none") }
        return String(format: t("engine.detail"), s.version.isEmpty ? "?" : s.version, String(s.engineID.prefix(8)))
    }
}
