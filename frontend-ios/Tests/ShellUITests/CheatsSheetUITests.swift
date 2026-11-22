import Foundation
import SwiftUI
import Testing
@testable import ShellUI

@MainActor @Suite struct CheatsSheetUITests {
    @Test func shellActionsReportsCheatsSupportWhenLoadCallbackIsWired() {
        #expect(!ShellActions().supportsCheats)
        let actions = ShellActions(onLoadCheats: { id in GameCheatsSnapshot(gameID: id, gameTitle: "Demo") })
        #expect(actions.supportsCheats)
    }

    @Test func snapshotCountsCapabilitiesAndGatesCodeNeedsBakeSwitches() {
        let snapshot = GameCheatsSnapshot(
            gameID: "0100000000010000",
            gameTitle: "Orbit Fixture",
            buildID: "CD57B23FA4BBAD65",
            hasCurrentFile: true,
            masterOn: true,
            entries: [
                GameCheatEntry(name: "Stats", key: "Stats", section: "Stats", isLabel: true, isSectionMarker: true),
                GameCheatEntry(name: "Infinite Health", key: "Infinite Health", section: "Stats", capability: .dataReady, enabled: true),
                GameCheatEntry(name: "Moon Jump", key: "Moon Jump", section: "Movement", capability: .codeBaked, triggerKeys: ["B", "ZR"], enabled: true),
                GameCheatEntry(name: "2x Speed", key: "2x Speed", section: "Movement", capability: .codeNeedsBake),
                GameCheatEntry(name: "Max Rupees", key: "Max Rupees", section: "Stats", capability: .fixedHeapWarning),
            ],
            fuseAlert: GameCheatFuseAlert(disabledItems: ["2x Speed"], disabledMaster: false),
            exportFileURL: URL(fileURLWithPath: "/tmp/CD57B23FA4BBAD65.txt")
        )

        #expect(snapshot.visibleEntries.count == 4)
        #expect(snapshot.dataReadyCount == 1)
        #expect(snapshot.codeBakedCount == 1)
        #expect(snapshot.codeNeedsBakeCount == 1)
        #expect(snapshot.fixedHeapWarningCount == 1)
        #expect(snapshot.readyOnIOSCount == 3)
        #expect(snapshot.totalActiveCount == 4)
        #expect(snapshot.visibleEntries[0].switchableOnIOS)
        #expect(snapshot.visibleEntries[1].switchableOnIOS)
        #expect(snapshot.visibleEntries[1].triggerCombo == "B + ZR")
        #expect(!snapshot.visibleEntries[2].switchableOnIOS)
        #expect(snapshot.visibleEntries[3].switchableOnIOS)

        let view = CheatsSheetView(snapshot: snapshot, actions: ShellActions(), onClose: {})
        _ = view.body
    }

    @Test func gameDetailViewBuildsWithCheatsEntryAndFocusLayerIncludesCheats() {
        let detail = GameDetail(
            game: GameTile(id: "0100000000010000", title: "Orbit Fixture"),
            cheatsSummary: GameCheatsSummary(buildID: "CD57B23FA4BBAD65", totalCount: 4, enabledCount: 2, needsBakeCount: 1, masterOn: true, fuseTripped: false)
        )
        let actions = ShellActions(onLoadCheats: { id in GameCheatsSnapshot(gameID: id, gameTitle: "Orbit Fixture") })
        let detailView = GameDetailView(detail: detail, actions: actions)
        _ = detailView.body

        #expect(FocusLayer.cheats.prefix == "cht.")
        #expect(FocusLayer.isLive("cht.import", under: .cheats))
        #expect(!FocusLayer.isLive("set.cheats", under: .cheats))
    }
}
