import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// What you've pinned to your profile (links, wallets, notes), one tap from sending in the chat you're in: a quick
/// way to hand someone your address or a note without typing it out. Each goes as an ordinary message.
struct QuickSendSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation.ID

    private var links: [ProfileLink] { ProfileLink.cleaned(model.activeProfile.links ?? []) }
    private var notes: [ProfileNote] { ProfileNote.cleaned(model.activeProfile.notes ?? []) }

    /// The words a pinned item is sent as.
    static func text(for link: ProfileLink) -> String {
        let name = link.kind == .custom ? (link.label ?? link.kind.title) : link.kind.title
        return link.kind.isWallet ? "My \(name) address:\n\(link.value)" : "\(name): \(link.value)"
    }

    static func text(for note: ProfileNote) -> String? {
        guard !note.isLocked, let words = note.text, !words.isEmpty else { return nil }
        return "\(note.title)\n\n\(words)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Send from your profile").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 26))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Rectangle().fill(Ink.line).frame(height: 1)
            ScrollView {
                VStack(spacing: 18) {
                    if links.isEmpty && notes.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "pin").font(.system(size: 26)).foregroundStyle(Ink.faint)
                            Text("Nothing pinned yet").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text)
                            Text("Pin links, wallets and notes to your profile in Settings, and they'll be here to send in one tap.")
                                .font(.system(size: 13)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 40).padding(.horizontal, 24)
                    }
                    section("Links", links.filter { !$0.kind.isWallet }.map { link in
                        Item(id: "l" + link.id, symbol: link.kind.symbol, title: link.kind == .custom ? (link.label ?? "Link") : link.kind.title,
                             detail: link.value, text: Self.text(for: link))
                    })
                    section("Wallets", links.filter(\.kind.isWallet).map { link in
                        Item(id: "w" + link.id, symbol: link.kind.symbol, title: link.kind.title, detail: link.value, text: Self.text(for: link))
                    })
                    section("Notes", notes.map { note in
                        Item(id: "n" + note.id, symbol: note.isLocked ? "lock.fill" : "doc.text", title: note.title,
                             detail: note.isLocked ? "Locked: only on your profile" : (note.text ?? ""), text: Self.text(for: note))
                    })
                }
                .padding(20)
            }
            .scrollIndicators(.never)
        }
        .frame(width: Platform.isPhone ? nil : 420, height: Platform.isPhone ? nil : 520)
        .background(Ink.base)
        .preferredColorScheme(Ink.scheme)
    }

    private struct Item: Identifiable {
        var id: String
        var symbol: String
        var title: String
        var detail: String
        /// Nil when it can't be sent as words (a locked note).
        var text: String?
    }

    @ViewBuilder private func section(_ title: String, _ items: [Item]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.faint).padding(.leading, 4)
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider().overlay(Ink.line).padding(.leading, 52) }
                        row(item)
                    }
                }
                .background(Ink.surface, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.line))
            }
        }
    }

    private func row(_ item: Item) -> some View {
        Button {
            guard let text = item.text else { return }
            model.send(text, in: conversation)
            model.playSendSound()
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.symbol)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
                    .frame(width: 30, height: 30)
                    .background(theme.accent.opacity(0.14), in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                    Text(item.detail).font(.system(size: 12)).foregroundStyle(Ink.dim).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if item.text != nil {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)).foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(item.text == nil)
        .opacity(item.text == nil ? 0.55 : 1)
        .accessibilityLabel(item.text == nil ? "\(item.title), locked, can't be sent" : "Send \(item.title)")
    }
}
