import Testing
@testable import ShellUI

@Suite struct RecentRowTests {
    @Test func hairlineHasSpaceAndRowKeepsItsHeight() {
        #expect(RecentRow.separatorGap == 10)
        #expect(RecentRow.minHeight == 60)
    }
}
