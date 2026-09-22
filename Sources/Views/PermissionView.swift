import SwiftUI

/// The first-run screen. macOS will not let Replies read the messages until
/// the app itself is added to Full Disk Access — nobody can do that for him.
struct PermissionView: View {
    @Environment(AppState.self) private var state
    var status: Permission.Status
    var onRecheck: () -> Void
    var onUseSample: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 20) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.tint)

                Text(status == .noDatabase
                     ? "No messages on this Mac"
                     : "Replies needs permission to read your messages")
                    .font(.system(size: 26, weight: .semibold))
                    .multilineTextAlignment(.center)

                Text(explanation)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .fixedSize(horizontal: false, vertical: true)

                if status == .denied {
                    steps
                }

                HStack(spacing: 12) {
                    if status == .denied {
                        Button("Open Full Disk Access") { Permission.openSettings() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        Button("Show Replies in Finder") { Permission.revealApp() }
                            .controlSize(.large)
                    }
                    Button("Check again", action: onRecheck)
                        .controlSize(.large)
                }
                .padding(.top, 4)

                if Permission.sampleURL != nil {
                    Button("Look around with sample data instead", action: onUseSample)
                        .buttonStyle(.link)
                        .padding(.top, 2)
                }
            }
            .padding(44)

            Spacer(minLength: 0)

            Text("Replies reads the database on this Mac and never writes to it. There is no network code in this app — nothing is uploaded anywhere.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var explanation: String {
        switch status {
        case .noDatabase:
            return "There is no iMessage database at ~/Library/Messages/chat.db, which usually means Messages has never been signed in on this Mac."
        case .denied:
            return "macOS keeps your messages behind Full Disk Access. You have to grant it to Replies yourself — it takes about twenty seconds."
        case .granted:
            return "Access granted."
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(1, "Open Full Disk Access below — it opens System Settings on the right page.")
            step(2, "Press the + button, or drag Replies in from Finder.")
            step(3, "Turn the switch on for Replies, then come back and press Check again.")
        }
        .padding(18)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 19, height: 19)
                .background(Circle().fill(.tint))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
