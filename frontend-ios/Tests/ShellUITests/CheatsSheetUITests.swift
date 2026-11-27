import Foundation
import SwiftUI
import Testing
@testable import ShellUI

@MainActor @Suite struct CheatsSheetUITests {
    @Test func shellActionsReportsCheatsSupportWhenLoadCallbackIsWired() {
        #expect(!ShellActions().supportsCheats)
        let actions = ShellActions(
            onLoadCheats: { id in GameCheatsSnapshot(gameID: id, gameTitle: "Demo") },
            onMergeOnlineCheats: { _, _ in .failed("") },
            onReplaceOnlineCheats: { _, _ in .failed("") }
        )
        #expect(actions.supportsCheats)
        #expect(actions.onMergeOnlineCheats != nil)
        #expect(actions.onReplaceOnlineCheats != nil)
    }

    @Test func snapshotCountsCapabilitiesAndGatesCodeNeedsBakeSwitches() {
        let receipt = GameCheatFetchReceipt(
            titleID: "0100000000010000",
            buildID: "CD57B23FA4BBAD65",
            status: "found",
            sources: ["HamletDuFromage/switch-cheats-db"],
            entryCount: 5,
            fetchedAt: 1_795_770_000,
            fileName: "CD57B23FA4BBAD65.txt",
            fileSHA256: "abc",
            origin: "fetched"
        )
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
                GameCheatEntry(name: "Max Rupees", key: "Max Rupees", section: "Stats", capability: .fixedHeapWarning, hasFixedAddress: true),
                GameCheatEntry(name: "Unsafe Patch", key: "Unsafe Patch", section: "Movement", capability: .codeNeedsBake, unsafeCodeReason: "dataflow_bypass: x24"),
                GameCheatEntry(name: "Broken Master", key: "Broken Master", isMaster: true, isBroken: true),
                GameCheatEntry(name: "Truncated", key: "Truncated", isBroken: true),
            ],
            fuseAlert: GameCheatFuseAlert(disabledItems: ["2x Speed"], disabledMaster: false),
            exportFileURL: URL(fileURLWithPath: "/tmp/CD57B23FA4BBAD65.txt"),
            fetchReceipt: receipt
        )

        #expect(snapshot.visibleEntries.count == 7)
        #expect(snapshot.dataReadyCount == 1)
        #expect(snapshot.codeBakedCount == 1)
        #expect(snapshot.codeNeedsBakeCount == 1)
        #expect(snapshot.unsafeCodeCount == 1)
        #expect(snapshot.fixedHeapWarningCount == 1)
        #expect(snapshot.fixedAddressCount == 1)
        #expect(snapshot.readyOnIOSCount == 3)
        #expect(snapshot.totalActiveCount == 5)
        #expect(snapshot.visibleEntries[0].switchableOnIOS)
        #expect(snapshot.visibleEntries[1].switchableOnIOS)
        #expect(snapshot.visibleEntries[1].triggerCombo == "B + ZR")
        #expect(!snapshot.visibleEntries[2].switchableOnIOS)
        #expect(snapshot.visibleEntries[3].switchableOnIOS)
        #expect(!snapshot.visibleEntries[4].switchableOnIOS)
        #expect(!snapshot.visibleEntries[5].switchableOnIOS)
        #expect(!snapshot.visibleEntries[6].switchableOnIOS)

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
        #expect(FocusLayer.isLive("cht.fetch", under: .cheats))
        #expect(FocusLayer.isLive("cht.delete", under: .cheats))
        #expect(!FocusLayer.isLive("set.cheats", under: .cheats))
    }

    @Test func onlinePreviewSheetAndFetchCardHandleFetchedAndPreservedStates() {
        let preview = GameCheatOnlinePreview(
            titleID: "0100000000010000",
            buildID: "CD57B23FA4BBAD65",
            sources: ["HamletDuFromage/switch-cheats-db"],
            onlineText: "[Infinite Health]\n04000000 00180020 000003E7\n\n[New Speed]\n04000000 00000800 1E202800\n",
            localCount: 1,
            onlineCount: 2,
            addedCount: 1,
            sameNameCount: 1,
            localOnlyCount: 0,
            entries: [
                GameCheatOnlineEntry(
                    id: "Infinite Health",
                    name: "Infinite Health",
                    isAdded: false,
                    rawLines: ["04000000 00180020 000003E7"],
                    capability: .dataReady
                ),
                GameCheatOnlineEntry(
                    id: "New Speed",
                    name: "New Speed",
                    isAdded: true,
                    rawLines: ["04000000 00000800 1E202800"],
                    capability: .codeNeedsBake
                ),
            ]
        )
        let previewSheet = CheatsOnlinePreviewSheet(
            preview: preview,
            onKeep: {},
            onMerge: {},
            onReplace: {}
        )
        _ = previewSheet.body

        let macFetchedReceipt = GameCheatFetchReceipt(
            titleID: "0100000000010000",
            buildID: "CD57B23FA4BBAD65",
            status: "fetched",
            sources: ["switch-cheats-db"],
            entryCount: 2,
            fetchedAt: 1_795_770_000,
            fileName: "CD57B23FA4BBAD65.txt",
            origin: "fetched"
        )
        #expect(macFetchedReceipt.isFoundStatus)
        let fetchedCard = CheatsFetchStatusCard(receipt: macFetchedReceipt)
        _ = fetchedCard.body

        let preservedReceipt = GameCheatFetchReceipt(
            titleID: "0100000000010000",
            buildID: "CD57B23FA4BBAD65",
            status: "preserved_user",
            sources: ["HamletDuFromage/switch-cheats-db"],
            entryCount: 2,
            fetchedAt: 1_795_770_000,
            fileName: "CD57B23FA4BBAD65.txt",
            origin: "user"
        )
        let preservedCard = CheatsFetchStatusCard(receipt: preservedReceipt, onReviewOnlineResult: {})
        _ = preservedCard.body
    }
}
