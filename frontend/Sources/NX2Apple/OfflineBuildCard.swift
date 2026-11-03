import SwiftUI
import NXCore
import NXModel

struct OfflineBuildCard: View {
    @ObservedObject var build: BuildStore
    var body: some View {
        if build.target == BuildTarget.mac {
            OfflineDataView(t: build.t, saveFolder: $build.offlineSaveFolder, cacheFolder: $build.offlineCacheFolder)
                .disabled(build.running)
        }
    }
}
