import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)

            Text("Replies")
                .font(.system(size: 34, weight: .semibold))

            Text("How you actually text — reply speed, reply ratio,\nwho you answer first and who you leave on read.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Divider().frame(width: 320)

            Text(statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusLine: String {
        switch state.phase {
        case .idle:              return "Reading your messages is wired up next."
        case .needsAccess:       return "Needs Full Disk Access."
        case .loading(let p):    return "Loading… \(Int(p * 100))%"
        case .ready:             return "\(state.messageCount) messages read."
        case .failed(let why):   return why
        }
    }
}
