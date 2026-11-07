import Foundation
import Testing
@testable import ShellUI

@Suite struct TouchLayoutGestureTests {
    @Test func draggingRequiresASelectedControlAndKeepsFaceKeysGrouped() {
        #expect(!TouchLayoutEditorView.canDrag(.a, selected: nil, together: true))
        #expect(!TouchLayoutEditorView.canDrag(.stick, selected: .a, together: true))
        #expect(TouchLayoutEditorView.canDrag(.b, selected: .a, together: true))
        #expect(!TouchLayoutEditorView.canDrag(.b, selected: .a, together: false))
        #expect(TouchLayoutEditorView.canDrag(.b, selected: .b, together: false))
    }

}
