import AppKit
import SwiftUI
import NXLauncher

/// The check scene of the card interaction (DSCardArt): one card in each state side by side, the hover and the press forced
/// through `dsCardPreview` because no pointer is there in a capture. A row below shows a list row at rest and under the pointer.
struct GalleryCardStates: View {
    private static let art: NSImage = {
        let size = NSSize(width: 480, height: 267)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [DS.Color.nsStatusErrorFill, DS.Color.nsSurfaceRaised])?   // stand-in art from the tokens
            .draw(in: NSRect(origin: .zero, size: size), angle: -30)
        image.unlockFocus()
        return image
    }()

    private let states: [(title: String, preview: DSCardPreview?, selected: Bool, attention: Bool)] = [
        ("Rest", nil, false, false), ("Hover", .hover, false, false), ("Pressed", .pressed, false, false),
        ("Selected", nil, true, false), ("Focused", .focus, false, false), ("Chip", nil, false, true),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            Text("Card states").font(DS.Font.title)
            HStack(alignment: .top, spacing: LibraryCardLayout.gridSpacing) {
                ForEach(states, id: \.title) { state in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        LibraryGameCard(title: "Hades", image: Self.art, focus: .center,
                                        state: LibraryArtworkState(mac: !state.attention, ios: false, attention: state.attention ? .missingData : .none),
                                        width: 170, selected: state.selected, select: {})
                            .environment(\.dsCardPreview, state.preview)
                        Text(state.title).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).padding(.leading, LibraryCardLayout.inset)
                    }
                }
            }
            .padding(DSCardRoom.around(width: 170))
            Text("Row states").font(DS.Font.headline)
            HStack(spacing: DS.Space.m) {
                ForEach([("Rest", false), ("Hover", true)], id: \.0) { title, hovered in
                    DSCard {
                        DSRow(title, detail: "A row answers the pointer with the raised surface") { EmptyView() }
                            .dsRowHover()
                            .environment(\.dsCardPreview, hovered ? .hover : nil)
                    }
                    .frame(width: 420)
                }
            }
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
