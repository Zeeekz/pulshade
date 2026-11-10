import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// What the chat list shows while something is typed in its search, as in Telegram: matching chats, then contacts,
/// then a lookup of everyone on Pulshade by @handle, then messages that contain the words.
///
/// The directory only answers exact handles, and each lookup costs the phone a little proof of work, so the global
/// lookup runs when the row is tapped or Return is pressed, not on every key.
struct ChatSearchResults: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var query: String
    /// Bumped when Return is pressed in the search field: looks the handle up.
    var submitted: Int
    var open: (Conversation.ID) -> Void

    @State private var looking = false
    @State private var found: DirectoryProfile?
    @State private var lookedUp: String?
    @State private var problem: String?

    private var text: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Without a leading @, so "@nova" still finds a contact called Nova.
    private var bare: String { text.trimmingCharacters(in: CharacterSet(charactersIn: "@")) }
    private var handle: String? { DirectoryProfile.validHandle(text) }

    private var chats: [Conversation] {
        model.sortedConversations.filter { c in
            c.title.localizedCaseInsensitiveContains(bare)
                || (c.kind == .direct && c.members.first.flatMap({ model.contact($0) }).map(matches) == true)
        }
    }

    /// Contacts that match and have no chat in the list above, so nobody shows twice.
    private var contacts: [Contact] {
        let inChats = Set(chats.filter { $0.kind == .direct }.compactMap(\.members.first))
        return model.visibleContacts
            .filter { matches($0) && !inChats.contains($0.fingerprint) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// The newest messages that contain what's typed, across every chat in view.
    private var messages: [(chat: Conversation, message: Message)] {
        guard bare.count >= 2 else { return [] }
        var hits: [(chat: Conversation, message: Message)] = []
        for c in model.sortedConversations {
            for m in c.messages.reversed() where !m.isSystem && m.text.localizedCaseInsensitiveContains(bare) {
                hits.append((c, m))
            }
        }
        return Array(hits.sorted { $0.message.date > $1.message.date }.prefix(50))
    }

    private func matches(_ c: Contact) -> Bool {
        c.displayName.localizedCaseInsensitiveContains(bare) || c.name.localizedCaseInsensitiveContains(bare)
            || (c.handle?.localizedCaseInsensitiveContains(bare) ?? false)
    }

    var body: some View {
        let chats = chats, contacts = contacts, messages = messages
        LazyVStack(alignment: .leading, spacing: 1) {
            if !chats.isEmpty {
                header("Chats")
                ForEach(chats) { c in
                    Button { model.markRead(c.id); open(c.id) } label: { ChatRow(conversation: c, selected: false) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c.title)
                }
            }
            if !contacts.isEmpty {
                header("Contacts")
                ForEach(contacts) { c in
                    Button { message(c) } label: {
                        PersonRow(avatar: c.avatar, seed: c.fingerprint, name: c.displayName, badge: c.badge,
                                  detail: c.handle.map { "@\($0)" })
                    }
                    .buttonStyle(.plain)
                }
            }
            if let handle {
                header("Global search")
                global(handle)
            }
            if !messages.isEmpty {
                header("Messages")
                ForEach(messages, id: \.message.id) { hit in
                    Button { model.markRead(hit.chat.id); open(hit.chat.id) } label: { MessageHit(chat: hit.chat, message: hit.message) }
                        .buttonStyle(.plain)
                }
            }
            if chats.isEmpty && contacts.isEmpty && messages.isEmpty && handle == nil {
                Constellation(symbol: "magnifyingglass", text: "No results")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
        .onChange(of: query) { found = nil; lookedUp = nil; problem = nil }
        .onChange(of: submitted) { if let handle { lookUp(handle) } }
    }

    // MARK: Global

    @ViewBuilder private func global(_ handle: String) -> some View {
        if let found, lookedUp == handle {
            Button { openProfile(found) } label: {
                PersonRow(avatar: found.avatar, seed: found.fingerprint,
                          name: found.name.isEmpty ? "Anonymous" : found.name, badge: found.badge,
                          detail: model.isMine(found.fingerprint) ? "@\(found.handle) · you" : "@\(found.handle)")
            }
            .buttonStyle(.plain)
        } else if lookedUp == handle {
            note(problem ?? "No one has @\(handle). Handles are exact, so check the spelling.")
        } else {
            Button { lookUp(handle) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "at")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Ink.onAccent)
                        .frame(width: rowAvatar, height: rowAvatar)
                        .background(theme.accent.opacity(0.85), in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Find @\(handle)").font(.system(size: rowTitle, weight: .semibold)).foregroundStyle(Ink.text)
                        Text("Everyone on PULSHADE, by exact handle").font(.system(size: rowLine)).foregroundStyle(Ink.faint)
                    }
                    Spacer()
                    if looking { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 10)
                .frame(minHeight: rowAvatar + 16)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(looking)
        }
    }

    private func lookUp(_ handle: String) {
        guard !looking else { return }
        if DirectoryProfile.reportHandles.contains(handle) {
            // Pulshade Safety lives in Contacts, which knows what to show for it.
            model.openedHandle = handle
            return
        }
        looking = true
        Task {
            do {
                found = try await model.findProfile(handle)
                problem = nil
            } catch AppModel.DirectoryError.unreachable {
                found = nil; problem = "Can't reach the relay"
            } catch {
                found = nil; problem = "That profile didn't check out"
            }
            lookedUp = handle
            looking = false
        }
    }

    /// A contact's chat opens; anyone else's profile opens in Contacts, where a request can be sent.
    private func openProfile(_ profile: DirectoryProfile) {
        if let known = model.visibleContacts.first(where: { $0.fingerprint == profile.fingerprint }) {
            message(known)
        } else {
            model.openedHandle = profile.handle
        }
    }

    private func message(_ contact: Contact) {
        let convo = model.startConversation(kind: .direct, title: contact.displayName, members: [contact.fingerprint])
        open(convo.id)
    }

    // MARK: Pieces

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Ink.faint)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Ink.dim)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }
}

private var rowAvatar: CGFloat { Platform.isPhone ? 48 : 40 }
private var rowTitle: CGFloat { Platform.isPhone ? 16 : 14 }
private var rowLine: CGFloat { Platform.isPhone ? 14 : 12.5 }

/// One person in the results: picture, name and a short line under it.
private struct PersonRow: View {
    var avatar: Data?
    var seed: String
    var name: String
    var badge: Collectible?
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Avatar(image: avatar, seed: seed, size: rowAvatar, showsStory: false)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(name).font(.system(size: rowTitle, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                    BadgeMark(badge: badge, size: 14)
                }
                if let detail {
                    Text(detail).font(.system(size: rowLine)).foregroundStyle(Ink.faint).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: rowAvatar + 16)
        .contentShape(.rect)
    }
}

/// A message that matched: the chat it's in, when, and the text.
private struct MessageHit: View {
    @Environment(AppModel.self) private var model
    var chat: Conversation
    var message: Message

    var body: some View {
        let direct = chat.kind == .direct
        HStack(spacing: 12) {
            Avatar(image: chat.avatar ?? (direct ? model.contact(chat.members.first ?? "")?.avatar : nil),
                   seed: direct ? (chat.members.first ?? chat.id.uuidString) : chat.id.uuidString,
                   size: rowAvatar, symbol: direct ? nil : chat.kind.symbol, showsStory: false)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(chat.title).font(.system(size: rowTitle, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(message.date.chatStamp).font(.system(size: 11.5)).foregroundStyle(Ink.faint)
                }
                Text((message.isMine ? "You: " : "") + message.text)
                    .font(.system(size: rowLine))
                    .foregroundStyle(Ink.dim)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: rowAvatar + 16)
        .contentShape(.rect)
    }
}
