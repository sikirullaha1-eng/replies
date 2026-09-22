import SwiftUI

/// Replies — reads your own iMessage history and tells you how you reply.
/// Everything happens on this Mac. The app has no network code at all.
@main
struct RepliesApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
                .frame(minWidth: 1100, minHeight: 760)
        }
        .defaultSize(width: 1240, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
