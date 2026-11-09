import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// What you've pinned to your profile (links, wallets, notes) and your collectibles, one tap from sending in the chat
/// you're in. Links and wallets go as ordinary messages. A note goes as a card with no words in it: they open it from
/// your profile, behind its password or the access you gave. A collectible goes as a card with its picture.
struct QuickSendSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation.ID

    private var links: [ProfileLink] { ProfileLink.cleaned(model.activeProfile.links ?? []) }
    private var notes: [ProfileNote] { ProfileNote.cleaned(model.activeProfile.notes ?? []) }
    private var collectibles: [Collectible] { (model.activeProfile.collectibles ?? []).filter { $0.kind != nil } }
    /// A note for chosen contacts, about to be sent to someone who can't read it yet: asks first.
    @State private var sharing: (note: ProfileNote, fingerprint: String, name: String)?

    /// The words a pinned item is sent as.
    static func text(for link: ProfileLink) -> String {
        let name = link.kind == .custom ? (link.label ?? link.kind.title) : link.kind.title
        return link.kind.isWallet ? "My \(name) address:\n\(link.value)" : "\(name): \(link.value)"
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
                    if links.isEmpty && notes.isEmpty && collectibles.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "pin").font(.system(size: 26)).foregroundStyle(Ink.faint)
                            Text("Nothing pinned yet").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text)
                            Text("Pin links, wallets, notes or collectibles to send them in one tap.")
                                .font(.system(size: 13)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 40).padding(.horizontal, 24)
                    }
                    section("Links", links.filter { !$0.kind.isWallet }.map { link in
                        Item(id: "l" + link.id, symbol: link.kind.symbol, title: link.kind == .custom ? (link.label ?? "Link") : link.kind.title,
                             detail: link.value, send: { sendText(Self.text(for: link)) })
                    })
                    section("Wallets", links.filter(\.kind.isWallet).map { link in
                        Item(id: "w" + link.id, symbol: link.kind.symbol, title: link.kind.title, detail: link.value, send: { sendText(Self.text(for: link)) })
                    })
                    section("Notes", notes.map { note in
                        Item(id: "n" + note.id, symbol: note.isLocked ? "lock.fill" : note.isRestricted ? "person.fill.checkmark" : "doc.text",
                             title: note.title, detail: note.subtitle, send: { sendNote(note) })
                    })
                    section("Collectibles", collectibles.compactMap { c in
                        c.kind.map { kind in
                            Item(id: "c" + c.id, symbol: "", kind: kind, title: kind.name, detail: "#\(c.serial)", send: { sendCollectible(c, kind) })
                        }
                    })
                }
                .padding(20)
            }
            .scrollIndicators(.never)
        }
        .frame(width: Platform.isPhone ? nil : 420, height: Platform.isPhone ? nil : 520)
        .background(Ink.base)
        .preferredColorScheme(Ink.scheme)
        .confirmationDialog(sharing.map { "Let \($0.name) read “\($0.note.title)”?" } ?? "", isPresented: Binding(get: { sharing != nil },
                                                                                                     set: { if !$0 { sharing = nil } }),
                            titleVisibility: .visible, presenting: sharing) { ask in
            Button("Share it and send") { share(ask.note, with: ask.fingerprint) }
            Button("Cancel", role: .cancel) {}
        } message: { ask in
            Text("“\(ask.note.title)” is only for the contacts you chose. \(ask.name) isn't one of them yet.")
        }
    }

    private struct Item: Identifiable {
        var id: String
        var symbol: String
        /// A collectible's drawing, shown instead of the symbol.
        var kind: Collectible.Kind?
        var title: String
        var detail: String
        var send: () -> Void
    }

    private func finish() {
        model.playSendSound()
        dismiss()
    }

    private func sendText(_ text: String) {
        model.send(text, in: conversation)
        finish()
    }

    private func sendCollectible(_ collectible: Collectible, _ kind: Collectible.Kind) {
        model.send("\(kind.name) #\(collectible.serial)", collectible: collectible, in: conversation)
        finish()
    }

    /// A note goes as a card. One made for chosen contacts goes only in a chat with one of them, or with your say-so.
    private func sendNote(_ note: ProfileNote) {
        let card = NoteCard(note)
        guard let chosen = note.sharedWith else {
            model.send(card.fallbackText, note: card, in: conversation)
            finish()
            return
        }
        guard let chat = model.conversation(conversation), chat.kind == .direct, let partner = chat.members.first else { return }
        if chosen.contains(partner) {
            model.send(card.fallbackText, note: card, in: conversation)
            finish()
        } else {
            sharing = (note, partner, model.contact(partner, in: chat.persona)?.displayName ?? "They")
        }
    }

    /// Adds them to who may read the note (their phone gets it with your profile), then sends the card.
    private func share(_ note: ProfileNote, with fingerprint: String) {
        model.updateProfile { profile in
            guard var all = profile.notes, let i = all.firstIndex(where: { $0.id == note.id }) else { return }
            var chosen = all[i].sharedWith ?? []
            if !chosen.contains(fingerprint) { chosen.append(fingerprint) }
            all[i].sharedWith = chosen
            profile.notes = all
        }
        let card = NoteCard(note)
        model.send(card.fallbackText, note: card, in: conversation)
        finish()
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
            item.send()
        } label: {
            HStack(spacing: 12) {
                if let kind = item.kind {
                    CollectibleIcon(item: kind, size: 34).frame(width: 34, height: 34)
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
                        .frame(width: 30, height: 30)
                        .background(theme.accent.opacity(0.14), in: .rect(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                    Text(item.detail).font(.system(size: 12)).foregroundStyle(Ink.dim).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)).foregroundStyle(theme.accent)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send \(item.title)")
    }
}
