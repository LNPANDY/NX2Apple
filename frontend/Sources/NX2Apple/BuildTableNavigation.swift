import SwiftUI

/// SwiftUI Table owns selection and keyboard input. Controllers also need to reveal rows not yet materialized on macOS 13.
final class BuildTableNavigation: ObservableObject {
    weak var table: NSTableView?
    func reveal(row: Int) {
        guard let table, row >= 0, row < table.numberOfRows else { return }
        table.scrollRowToVisible(row)
    }
}

struct BuildTableProbe: NSViewRepresentable {
    let navigation: BuildTableNavigation
    final class Probe: NSView {
        weak var navigation: BuildTableNavigation?
        func attach() {
            var ancestor: NSView? = self
            while let view = ancestor {
                if let table = view as? NSTableView { navigation?.table = table; return }
                ancestor = view.superview
            }
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
    }
    func makeNSView(context: Context) -> Probe { let view = Probe();view.navigation = navigation;return view }
    func updateNSView(_ view: Probe, context: Context) {
        view.navigation = navigation
        guard navigation.table == nil else { return }   // every row has a probe: one that found the table is enough
        DispatchQueue.main.async { [weak view] in view?.attach() }
    }
}
