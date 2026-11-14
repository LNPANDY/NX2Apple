import Foundation
import Testing
import ShellUI
@testable import ShellHost

@MainActor @Suite struct ShellHostSettingsRefreshTests {
    private func orbitDetail(_ model: ShellHostModel) throws -> GameDetail {
        try #require(model.details.first { $0.id == Fixtures.orbit })
    }

    private func rowValue(_ detail: GameDetail, _ id: String) -> String? {
        detail.sections.flatMap(\.rows).first { $0.id == id }?.value
    }

    @Test func changingAndResettingSettingsUpdateRowsInMemoryWithoutRescanningDisk() throws {
        let box = try Sandbox()
        let appDir = try box.giveAppData(Fixtures.orbit)
        let model = ShellHostModel(config: box.config())

        let initial = try orbitDetail(model)
        #expect(initial.dlc == "No additional content")
        #expect(rowValue(initial, "DM_UPSCALER") == "off")
        #expect(rowValue(initial, "DM_UPSCALER_SHARPNESS") == nil)
        #expect(!initial.hasModifiedSettings)

        // Write a new DLC folder on disk after initial load: change() and resetDefaults() must not re-scan disk I/O.
        try box.write("dlc", to: appDir.appendingPathComponent("aoc/pack1/content.dat"))

        model.change(Fixtures.orbit, setting: "DM_UPSCALER", value: "fsr")
        let afterChange = try orbitDetail(model)
        #expect(afterChange.dlc == "No additional content")
        #expect(rowValue(afterChange, "DM_UPSCALER") == "fsr")
        #expect(rowValue(afterChange, "DM_UPSCALER_SHARPNESS") != nil)
        #expect(afterChange.sections.flatMap(\.rows).first { $0.id == "DM_UPSCALER" }?.changed == true)
        #expect(afterChange.hasModifiedSettings)

        model.change(Fixtures.orbit, setting: "pad.A", value: "Y")
        let afterPad = try orbitDetail(model)
        #expect(afterPad.dlc == "No additional content")
        #expect(rowValue(afterPad, "pad.A") == "Y")

        model.resetDefaults(Fixtures.orbit)
        let afterReset = try orbitDetail(model)
        #expect(afterReset.dlc == "No additional content")
        #expect(rowValue(afterReset, "DM_UPSCALER") == "off")
        #expect(rowValue(afterReset, "DM_UPSCALER_SHARPNESS") == nil)
        #expect(rowValue(afterReset, "pad.A") == "follow")
        #expect(!afterReset.hasModifiedSettings)

        model.reload()
        let afterReload = try orbitDetail(model)
        #expect(afterReload.dlc == "1 additional content pack")
    }

    @Test func refreshAndReloadInvalidateCachedProfileWhenGameDataChanges() throws {
        let box = try Sandbox()
        let model = ShellHostModel(config: box.config())
        let initial = try orbitDetail(model)
        #expect(rowValue(initial, "DM_LANG") == nil)

        let appDir = try box.giveAppData(Fixtures.orbit)
        try box.write("JPja USen CNzh TWzh\n0111\n", to: appDir.appendingPathComponent("romfs/System/RegionLangMask.txt"))
        model.useAppData(Fixtures.orbit)

        let updated = try orbitDetail(model)
        let langRow = try #require(updated.sections.flatMap(\.rows).first { $0.id == "DM_LANG" })
        if case .choice(let options) = langRow.kind {
            #expect(options.map(\.id) == ["en-US", "ja", "zh-Hant", "zh-Hans"])
        } else {
            Issue.record("Expected DM_LANG to be a choice row")
        }

        // Subsequent in-memory change uses the newly cached RomFS profile cleanly.
        model.change(Fixtures.orbit, setting: "DM_LANG", value: "zh-Hans")
        let afterLangChange = try orbitDetail(model)
        #expect(rowValue(afterLangChange, "DM_LANG") == "zh-Hans")
        #expect(afterLangChange.hasModifiedSettings)
    }
}
