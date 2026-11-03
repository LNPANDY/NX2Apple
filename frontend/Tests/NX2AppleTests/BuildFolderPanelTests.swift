import AppKit
import XCTest
@testable import NX2Apple

/// The Build tab's Save to dialog must offer "New Folder": the folder for the IPA often does not exist yet (#477).
@MainActor final class BuildFolderPanelTests: IsolatedDefaultsTestCase {
    func testTheSaveToPanelCanCreateFolders() {
        let panel = LauncherStores.buildFolderPanel()
        XCTAssertTrue(panel.canCreateDirectories)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
    }
}
