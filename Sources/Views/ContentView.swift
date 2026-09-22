import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch state.phase {
            case .needsAccess(let status):
                PermissionView(
                    status: status,
                    onRecheck: { Task { await state.refresh() } },
                    onUseSample: { Task { await state.useSample() } })
            case .loading(let p):
                loading(p)
            case .failed(let why):
                failure(why)
            case .idle, .ready:
                summary
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await state.refresh() }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from System Settings, re-check without a relaunch.
            if phase == .active, case .needsAccess = state.phase {
                Task { await state.refresh() }
            }
        }
    }

    private func loading(_ p: Double) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: p)
                .frame(width: 260)
            Text("Reading your messages…")
                .foregroundStyle(.secondary)
        }
    }

    private func failure(_ why: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.orange)
            Text(why)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Try again") { Task { await state.refresh() } }
        }
    }

    // The dashboard replaces this in the third milestone.
    private var summary: some View {
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text("Replies")
                .font(.system(size: 34, weight: .semibold))
            Text("\(state.messageCount) messages across \(state.store.conversations.count) conversations")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(state.source.label)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(48)
    }
}
