import SwiftUI

/// A thin strip along the top of the app while PULSHADE can't talk to its server: while it first reaches it
/// after unlocking (over Tor when Tor is on), and whenever it can't get through after that. The chats stay
/// open either way, anything sent waits in the outbox, and the strip goes once the server answers.
struct ConnectionStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if model.relayUnreachable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                Text(branded: "Can't reach the server · Retrying…")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.dim)
                Button { Task { await model.retryRelay() } } label: {
                    if model.retryingRelay { ProgressView().controlSize(.mini) } else { Text("Retry") }
                }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
                .disabled(model.retryingRelay)
            } else {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(status)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.dim)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        guard model.overTor else { return "Connecting…" }
        let progress = Tor.progress
        if progress < 0 { return "Tor couldn't start" }
        if progress < 100 { return "Connecting to Tor… \(progress)%" }
        return "Reaching the server over Tor…"
    }
}
