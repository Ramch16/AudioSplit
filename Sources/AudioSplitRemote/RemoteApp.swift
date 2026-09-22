import AudioSplitShared
import SwiftUI

@main
struct AudioSplitRemoteApp: App {
    @State private var model = RemoteModel()

    var body: some Scene {
        WindowGroup {
            RemoteRootView(model: model)
        }
    }
}
