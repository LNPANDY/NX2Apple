import SwiftUI
import NXCore
import NXLauncher
import NXModel

// The Builds page: the cards in the order a build goes, from the files to the progress. It only arranges them (CardPages.swift
// scrolls them). Each card observes the stores it shows (NXLauncher, and `FilesCard` here), so a change in one store redraws that
// card and no other.

struct BuildPage: View {
    let build: BuildStore
    let repo: RepoStore
    let dependencies: DependencyStore
    let devices: DeviceStore
    @Binding var extrasOpen: Bool   // the optional input rows of the files card
    @Binding var logOpen: Bool   // the log card's disclosure
    var onViewGame: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    @EnvironmentObject var loc: Localizer

    var body: some View {
        CardPageHeading(loc.t("build.heading"), note: loc.t("build.intro"))
        SetupHintCard(repo: repo, dependencies: dependencies, onOpenSettings: onOpenSettings)
        FilesCard(build: build, extrasOpen: $extrasOpen)
        OfflineBuildCard(build: build)
        TargetCard(build: build)
        InstallCard(devices: devices, build: build)
        LogCard(log: build.log, devices: devices, isOpen: $logOpen,
                showRequests: BuildNotifier.shared.$showLog.eraseToAnyPublisher(),   // a clicked notification of a failed build
                didShow: { BuildNotifier.shared.showLog = false })
        ActionCard(build: build, dependencies: dependencies, repo: repo)
        Group {   // a ViewBuilder holds ten views at most
            ShellCopyCard(devices: devices)
            BuildFailureCard(m: build)
            OutcomeCard(build: build, devices: devices, onViewGame: onViewGame)
            ProgressCard(build: build)
        }
    }
}
