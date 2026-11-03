import SwiftUI
import NXModel

/// The build log as a scrolling text. It is the only view that observes `BuildLog`, so a log line redraws this and not the
/// launcher around it (LNPANDY/NX2Apple#387).
package struct BuildLogView: View {
    @ObservedObject var log: BuildLog
    let placeholder: String

    package init(log: BuildLog, placeholder: String) {
        self.log = log
        self.placeholder = placeholder
    }

    package var body: some View {
        ScrollViewReader { sp in
            ScrollView {
                Text(log.text.isEmpty ? placeholder : log.text)
                    .font(.mono(11))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .id("end")
            }
            .frame(height: 220)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: log.text) { _ in sp.scrollTo("end", anchor: .bottom) }
            .onAppear { sp.scrollTo("end", anchor: .bottom) }
        }
    }
}
