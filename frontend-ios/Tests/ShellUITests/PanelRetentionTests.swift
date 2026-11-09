import Testing
@testable import ShellUI

/// #664: the panel that closes last stays drawn while the sheet slides out, and never takes input while it does.
@Suite struct PanelRetentionTests {
    @Test func theLastPanelStaysDrawnUntilTheSheetIsGone() {
        var retention = PanelRetention()
        #expect(!retention.draws(.controllers, open: false))
        retention.closed(.controllers, sheetStaysOpen: false)
        #expect(retention.draws(.controllers, open: false), "drawn while the sheet slides out")
        #expect(retention.isLeaving(.controllers, open: false), "and hidden from touch, VoiceOver and the controller")
        #expect(!retention.draws(.shellSettings, open: false))
        retention.reset()
        #expect(!retention.draws(.controllers, open: false))
    }

    @Test func aPanelClosedOverGameSettingsIsNotRetained() {
        var retention = PanelRetention()
        retention.closed(.controllers, sheetStaysOpen: true)
        #expect(!retention.draws(.controllers, open: false), "it must not cover the settings that stay")
    }

    @Test func anOpenPanelIsDrawnAndNeverLeaving() {
        var retention = PanelRetention()
        retention.closed(.shellSettings, sheetStaysOpen: false)
        #expect(retention.draws(.shellSettings, open: true))
        #expect(!retention.isLeaving(.shellSettings, open: true), "reopened before the sheet went")
    }
}
