import SwiftUI

/// What the relay and the network can learn about you right now: the address the relay sees, the Tor circuits
/// each lane uses, and the settings that matter for staying anonymous. Everything here is read on this device,
/// except one request, on a lane of its own, asking the relay which address it sees.
struct AnonymityReport: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var seen: String?
    @State private var checking = false
    @State private var checked = false

    /// Where requests actually go, not the relay as saved: Pulshade's own relay is saved by its onion address, but
    /// with Tor off it's reached by its direct one.
    private var relay: URL? { model.reachable(nil).flatMap { URL(string: $0) } }
    private var onion: Bool { relay.map(Tor.isOnion) ?? false }
    private var local: Bool { relay?.host().map { Invite.isLocal($0.lowercased()) } ?? false }
    /// Going over Tor, and able to: Tor can't reach a relay on your own network.
    private var tor: Bool { onion || model.data.security.tor && !local }
    /// Tor is switched on but the relay is local, so nothing connects at all.
    private var stuck: Bool { model.data.security.tor && local }
    private var hidden: Bool { tor && Tor.progress >= 0 }

    var body: some View {
        SettingsScreen(title: "Anonymity Report") {
            SettingsGroup {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: hidden ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(hidden ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Color.orange))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(branded: hidden ? "Your IP address is hidden from the relay"
                             : stuck ? "PULSHADE can't connect" : "The relay can see your IP address")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text)
                        Text(summary).font(.system(size: 13)).foregroundStyle(Ink.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }

            SettingsGroup("What the relay sees", footer: seenFooter) {
                SettingRow("Address") {
                    if checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(seen ?? (checked ? "No answer" : "Not checked"))
                            .font(.system(size: 13, design: .monospaced)).foregroundStyle(Ink.dim)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                RowDivider()
                SettingRow("Connection") {
                    Text(onion ? "Onion service" : tor ? "Tor, through an exit" : stuck ? "None" : "Direct")
                        .font(.system(size: 14)).foregroundStyle(Ink.dim)
                }
                RowDivider()
                ActionRow(title: checking ? "Checking…" : "Check again") { Task { await check() } }
                    .disabled(checking)
            }

            if tor {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    let circuits = Tor.circuits().filter { !$0.lane.hasPrefix("report|") }
                        .sorted { label($0.lane) < label($1.lane) }
                    SettingsGroup("Tor circuits", footer: circuitsFooter) {
                        if circuits.isEmpty {
                            SettingRow("None yet") {
                                Text(Tor.progress < 0 ? "Tor couldn't start" : "Connecting…")
                                    .font(.system(size: 14)).foregroundStyle(Ink.dim)
                            }
                        }
                        ForEach(Array(circuits.enumerated()), id: \.element.lane) { n, circuit in
                            if n > 0 { RowDivider() }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(label(circuit.lane)).font(.system(size: 15)).foregroundStyle(Ink.text)
                                Text(path(circuit.hops))
                                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 11)
                        }
                    }
                }
            }

            SettingsGroup("Checks") {
                ForEach(Array(checks.enumerated()), id: \.offset) { n, item in
                    if n > 0 { RowDivider(inset: 46) }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(item.ok ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.orange))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(branded: item.title).font(.system(size: 15)).foregroundStyle(Ink.text)
                            Text(branded: item.detail).font(.system(size: 12)).foregroundStyle(Ink.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                }
            }
        }
        .task { await check() }
    }

    private var summary: String {
        if onion { return "Your relay is an onion service: everything goes over Tor, and no Tor exit sees your traffic either." }
        if tor { return "Everything goes over Tor. The relay sees a Tor exit's address instead of yours." }
        if stuck { return "Tor is on, but your relay is on your own network, which Tor can't reach. Use the relay's onion address, or turn Tor off." }
        if local { return "Your relay is on your own network, which Tor can't reach, so the connection is direct." }
        return "Turn on Tor in Settings → Network to hide it."
    }

    private var seenFooter: String {
        guard let seen else { return "Asked on a connection of its own, so it isn't tied to your messages." }
        if seen.hasPrefix("fd") && seen.contains(":") {
            return "Onion connections have no IP address. The relay makes one up for each circuit, only to count requests."
        }
        if tor { return "This is a Tor exit's address, shared with many other Tor users. Yours isn't sent." }
        if local { return "This is your device's address on your own network." }
        return "This is your public IP address, or your VPN's if you use one."
    }

    private var circuitsFooter: String {
        let ends = onion
            ? "the last one is a meeting point that sees neither you nor the relay, which joins it through Tor relays of "
                + "its own, not shown here."
            : "the last one only sees where you're going."
        return "Each persona, inbox and call has its own circuit. The first relay on each (the guard) sees your IP "
            + "address but not where you're going; " + ends + " Only kept in memory."
    }

    private func path(_ hops: [String]) -> String {
        (["You"] + hops.map { $0 == "onion" ? "relay (onion)" : $0.isEmpty ? "?" : $0 }).joined(separator: " → ")
    }

    /// A lane's name for people: whose it is and what it's for.
    private func label(_ lane: String) -> String {
        let name = String(lane.split(separator: "|").first ?? "")
        func persona(_ id: String) -> String {
            if id == "main" { return model.data.profile.displayName }
            return model.data.personas.first { $0.id.uuidString == id }?.profile.displayName ?? "Persona"
        }
        switch name {
        case "main": return persona("main")
        case "send": return "Sending"
        case "link": return "Linking devices"
        case "reports": return "Reports"
        case "call": return "Call"
        case "preview": return "Link previews"
        default:
            if name.hasPrefix("public-") { return "Public inbox · " + persona(String(name.dropFirst(7))) }
            return persona(name)
        }
    }

    private struct Check { var ok: Bool; var title: String; var detail: String }

    private var checks: [Check] {
        let security = model.data.security
        return [
            Check(ok: tor, title: tor ? "Tor is on" : "Tor is off",
                  detail: tor ? "The relay never learns your IP address." : "The relay sees your IP address on every request."),
            Check(ok: onion || relay?.scheme == "https" || local,
                  title: onion ? "Onion relay" : relay?.scheme == "https" ? "Relay over HTTPS" : "Relay on your own network",
                  detail: onion ? "Encrypted end to end by Tor, and nobody learns where the relay is."
                      : "Messages are end-to-end encrypted either way; this only protects the connection."),
            Check(ok: tor, title: "Separate connections per persona",
                  detail: tor ? "Each persona, public inbox and call has its own Tor circuit, so they can't be linked by address."
                      : "Personas use separate connections, but all from the same IP address."),
            Check(ok: true, title: "Random timing",
                  detail: "Fetches, receipts and call joins wait random moments, so the relay can't line them up."),
            Check(ok: !security.linkPreviews || tor, title: security.linkPreviews ? "Link previews are on" : "Link previews are off",
                  detail: !security.linkPreviews ? "Links you send don't make your device visit the website."
                      : tor ? "Previews are fetched over a Tor circuit of their own, so the website never sees your IP address."
                      : "With Tor off, building a preview visits the website directly."),
            Check(ok: security.notificationContent == .hidden || !security.notifications,
                  title: "Notification text",
                  detail: security.notificationContent == .hidden || !security.notifications
                      ? "Notifications only say \"New message\"."
                      : "Names or text appear in notifications, which the system stores outside PULSHADE's encryption."),
            Check(ok: security.blockCapture, title: "Screen protection",
                  detail: security.blockCapture ? "Screenshots and recordings of PULSHADE come out blank or covered."
                      : "PULSHADE can be captured in screenshots and recordings."),
        ]
    }

    private func check() async {
        checking = true
        defer { checking = false; checked = true }
        seen = await model.client(nil, lane: "report")?.seen()
    }
}
