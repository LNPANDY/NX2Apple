import Testing
@testable import ShellUI

@Suite struct NativeChoiceControlTests {
    @Test func controllerSelectionAdvancesWrapsAndHandlesMissingValues() {
        let options = [SettingOption("over", "Over"), SettingOption("below", "Below")]
        #expect(NativeChoiceControl.nextValue(options, after: "over") == "below")
        #expect(NativeChoiceControl.nextValue(options, after: "below") == "over")
        #expect(NativeChoiceControl.nextValue(options, after: "unknown") == "over")
        #expect(NativeChoiceControl.nextValue([], after: "unknown") == nil)
    }
}
