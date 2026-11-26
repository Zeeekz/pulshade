import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

private extension ProfileLink {
    var displayTitle: String { kind == .custom ? (label ?? "Link") : kind.title }
}

/// A profile's links and wallets as small chips under the bio, each with its logo and name, wrapping onto more lines
/// as needed. Tap a link to open it (after asking), tap a wallet to see the address with a copy button and a QR code.
struct ProfileLinkChips: View {
    @Environment(\.theme) private var theme
    var links: [ProfileLink]
    /// When this person's wallet last changed, if it did, and whether the profile is your own.
    var walletChangedAt: Date? = nil
    var isMine = false
    @State private var asking: ProfileLink?
    @State private var showing: ProfileLink?

    var body: some View {
        // Checked again on the way in, so nothing odd gets a chip even if it got this far.
        let shown = ProfileLink.cleaned(links)
        if !shown.isEmpty {
            CenteredFlow(spacing: 6, lineSpacing: 6) {
                ForEach(shown) { link in
                    Button {
                        if link.url != nil { asking = link } else { showing = link }
                    } label: {
                        HStack(spacing: 6) {
                            BrandTile(kind: link.kind, size: 20)
                            Text(link.displayTitle)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Ink.text)
                                .lineLimit(1)
                        }
                        .padding(.leading, 5).padding(.trailing, 10).frame(height: 30)
                        .background(Ink.raised, in: .capsule)
                        .overlay(Capsule().strokeBorder(Ink.line))
                        .contentShape(.capsule)
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel(link.kind.isWallet ? "\(link.displayTitle) address" : "\(link.displayTitle), \(link.subtitle)")
                    .accessibilityHint(link.url != nil ? "Opens in your browser after asking" : "Shows the address")
                }
            }
            .frame(maxWidth: .infinity)
            .confirmationDialog("Leave Pulshade?", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                                presenting: asking) { link in
                Button("Open \(link.domain ?? "link")") { if let url = link.url { Platform.open(url) } }
                Button("Cancel", role: .cancel) {}
            } message: { link in
                Text("This goes to \(link.domain ?? "a website"). Pulshade can't protect you there.\n\(String(link.value.prefix(120)))")
            }
            .sheet(item: $showing) { link in
                WalletSheet(link: link, changedAt: link.kind.isWallet ? walletChangedAt : nil, isMine: isMine)
            }
        }
    }
}

/// Lays its children out in rows, each row centred, starting a new row when one is full.
struct CenteredFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let fitted = CGSize(width: min(size.width, width), height: size.height)
            if x > 0 && x + fitted.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((i, fitted))
            x += fitted.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = rows(subviews, width: width)
        let height = lines.reduce(0) { $0 + ($1.map(\.1.height).max() ?? 0) } + lineSpacing * CGFloat(max(lines.count - 1, 0))
        let widest = lines.map { $0.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max($0.count - 1, 0)) }.max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in rows(subviews, width: bounds.width) {
            let lineWidth = line.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(line.count - 1, 0))
            let lineHeight = line.map(\.1.height).max() ?? 0
            var x = bounds.minX + (bounds.width - lineWidth) / 2
            for (i, size) in line {
                subviews[i].place(at: CGPoint(x: x, y: y + (lineHeight - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += lineHeight + lineSpacing
        }
    }
}

/// A wallet address, big enough to read, with a copy button and a QR code.
private struct WalletSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    var link: ProfileLink
    var changedAt: Date?
    var isMine: Bool

    /// Four characters at a time, so the whole address is easy to compare and not just its ends.
    private var grouped: String {
        stride(from: 0, to: link.value.count, by: 4).map { String(link.value.dropFirst($0).prefix(4)) }.joined(separator: " ")
    }

    var body: some View {
        VStack(spacing: 16) {
            BrandTile(kind: link.kind, size: 56)
            Text(link.kind.title + " address").font(.system(size: 18, weight: .semibold)).foregroundStyle(Ink.text)
            if let changedAt, !isMine, changedAt > Date().addingTimeInterval(-30 * 86400) {
                Label("This address changed on \(changedAt.formatted(date: .abbreviated, time: .omitted)). Confirm it with them another way before you send anything.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            QRCode(text: link.value, size: 180)
            Text(grouped)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Ink.text)
                .multilineTextAlignment(.center)
            Text(isMine ? "This is the address people see on your profile."
                        : "Pulshade checked this is a real address, not whose it is. Compare all of it and confirm with them another way.")
                .font(.system(size: 12))
                .foregroundStyle(Ink.faint)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button { copyToClipboard(link.value) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(ProfileActionStyle())
                Button("Done") { dismiss() }
                    .buttonStyle(ProfileActionStyle())
            }
        }
        .padding(24)
        .frame(maxWidth: 380)
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Editing your own

/// What the add-a-link sheet is opened for: a link or a wallet, maybe one already saved.
struct LinkDraft: Identifiable {
    var wallets: Bool
    var kind: ProfileLinkKind?
    var existing: ProfileLink?
    var id: String { (wallets ? "w" : "l") + (kind?.rawValue ?? "pick") + (existing?.id ?? "new") }
}

/// Pick a logo, then type one value. Says right away if it isn't valid, and saves only a valid one.
struct AddLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    var draft: LinkDraft
    var choices: [ProfileLinkKind]
    var save: (ProfileLink) -> Void
    @State private var kind: ProfileLinkKind?
    @State private var text = ""
    @State private var label = ""

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var result: ProfileLink? { kind.flatMap { ProfileLink.make($0, from: trimmed, label: label) } }
    private var problem: String? {
        guard let kind else { return nil }
        if kind == .custom, !label.isEmpty, ProfileLinkKind.cleanLabel(label) == nil { return "That name has characters that can't be shown." }
        guard !trimmed.isEmpty, ProfileLink.make(kind, from: trimmed, label: kind == .custom ? "x" : nil) == nil else { return nil }
        switch kind {
        case .website, .custom: return "Use a full web address that starts with https://"
        case .nostr: return "That isn't a valid npub key."
        case _ where kind.isWallet: return "That isn't a valid \(kind.title) address. Check it and try again."
        default: return "That isn't a valid \(kind.title) username or link."
        }
    }

    var body: some View {
        Group {
            if let kind { entry(kind) } else { picker }
        }
        .padding(24)
        .frame(minWidth: 340, maxWidth: 460)
        .presentationDetents([.medium, .large])
        .animation(.snappy, value: kind)
        .onAppear {
            kind = draft.kind
            if let old = draft.existing { text = old.value; label = old.label ?? "" }
            else if choices.count == 1 { kind = choices.first }
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(draft.wallets ? "Add a wallet" : "Add a link").font(.system(size: 20, weight: .semibold)).foregroundStyle(Ink.text)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(Ink.dim)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 14)], spacing: 18) {
                    ForEach(choices, id: \.self) { choice in
                        Button { kind = choice } label: {
                            VStack(spacing: 8) {
                                BrandTile(kind: choice, size: 56)
                                Text(choice == .custom ? "Other link" : choice.title)
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.dim).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func entry(_ kind: ProfileLinkKind) -> some View {
        VStack(spacing: 18) {
            HStack {
                if draft.existing == nil && choices.count > 1 {
                    Button { self.kind = nil; text = ""; label = "" } label: { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(.plain).foregroundStyle(Ink.dim)
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(Ink.dim)
            }
            BrandTile(kind: kind, size: 72)
            Text(kind == .custom ? "Other link" : kind.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Ink.text)
            VStack(spacing: 0) {
                if kind == .custom {
                    field("Name shown on your profile", $label)
                    Divider().overlay(Ink.line)
                }
                field(kind.prompt, $text)
            }
            .background(Ink.surface, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
            Group {
                if let problem {
                    Text(problem).foregroundStyle(.orange)
                } else if kind.isWallet {
                    Text("Public: anyone who opens your profile can read this.").foregroundStyle(Ink.faint)
                } else {
                    Text(" ")
                }
            }
            .font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center)
            Button {
                if let result { save(result); dismiss() }
            } label: {
                Text("Save").font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(theme.gradient, in: .capsule)
                    .opacity(result == nil ? 0.35 : 1)
            }
            .buttonStyle(.plain)
            .disabled(result == nil)
            .keyboardShortcut(.defaultAction)
            Spacer(minLength: 0)
        }
    }

    private func field(_ prompt: String, _ binding: Binding<String>) -> some View {
        TextField("", text: binding, prompt: Text(prompt).foregroundStyle(Ink.faint))
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .foregroundStyle(Ink.text)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
    }
}

/// Shrinks a little under the finger.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}
