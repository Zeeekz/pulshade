import SwiftUI

/// Someone in a chat, picked to show their profile.
struct MemberRef: Identifiable, Equatable {
    var fingerprint: String
    var id: String { fingerprint }
}

/// Someone's profile as seen from a chat you share: their picture, name and what you know of them, and a way to become
/// friends if you aren't.
struct MemberProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let fingerprint: String
    let conversation: Conversation.ID
    @State private var note = ""

    var body: some View {
        SheetBody(width: 380) {
            if let convo = model.conversation(conversation), let person = model.contact(fingerprint, in: convo.persona) {
                let role: String? = model.role(of: fingerprint, in: convo).map { "\($0) in \(convo.title)" }
                    ?? (convo.kind == .group ? "In \(convo.title)" : nil)
                VStack(spacing: 16) {
                    SheetHeader(symbol: "person.crop.circle", title: "Profile")
                    ProfileHero(avatar: person.avatar, seed: fingerprint,
                                name: person.displayName, subtitle: role, badge: person.badge, handle: person.handle,
                                bio: person.hidden ? nil : person.bio, verified: person.verified) {
                        VStack(spacing: 10) { action(person, convo) }
                    }
                    if !person.hidden {
                        ProfileTabs(links: person.links ?? [], collectibles: person.collectibles ?? [], notes: person.notes ?? [],
                                    messages: convo.messages.filter { $0.sender == fingerprint },
                                    walletChangedAt: person.walletChangedAt, isMine: person.isSelf)
                    }
                }
            } else {
                Text("They're no longer in this chat.").font(.system(size: 13)).foregroundStyle(Ink.dim).padding(30)
            }
        }
    }

    @ViewBuilder
    private func action(_ person: Contact, _ convo: Conversation) -> some View {
        switch model.friendState(of: fingerprint, in: convo) {
        case .friend:
            Button("Message") {
                if let chat = model.data.conversations.first(where: { $0.kind == .direct && $0.members == [fingerprint] && $0.persona == convo.persona }) {
                    model.requestedConversation = chat.id
                } else {
                    model.requestedConversation = model.startConversation(kind: .direct, title: person.displayName, members: [fingerprint],
                                                                          persona: .some(convo.persona)).id
                }
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
        case .asked:
            Label("Asked to be friends", systemImage: "clock").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim)
        case .canAsk:
            TextField("Add a note (optional)", text: $note, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Ink.raised, in: .rect(cornerRadius: 8))
                .onChange(of: note) { _, new in if new.count > 200 { note = String(new.prefix(200)) } }
            Button {
                model.addFriend(fingerprint, in: convo.id, note: note)
            } label: {
                Label("Add friend", systemImage: "person.badge.plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            Text("They'll get a request to connect with \(model.profile(for: convo.persona).displayName).")
                .font(.system(size: 11)).foregroundStyle(Ink.faint).multilineTextAlignment(.center)
        case .me, .unknown:
            EmptyView()
        }
    }
}

/// Invites to be friends from people you share a group with, in Contacts beside the other requests.
struct GroupFriendInvitesSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FROM YOUR GROUPS")
                .font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Ink.faint).padding(.leading, 4)
            ForEach(model.groupFriendInvites) { invite in
                HStack(alignment: .top, spacing: 14) {
                    Avatar(image: invite.avatar, seed: invite.from, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(invite.name).font(.system(size: 14, weight: .bold)).foregroundStyle(Ink.text)
                            Spacer()
                            Text(invite.at.chatStamp).font(.system(size: 11)).foregroundStyle(Ink.faint)
                        }
                        Text("Wants to be friends · from \(invite.groupTitle)").font(.system(size: 12)).foregroundStyle(Ink.dim)
                        if let note = invite.note, !note.isEmpty {
                            Text(note)
                                .font(.system(size: 13)).foregroundStyle(Ink.dim)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Ink.raised.opacity(0.7), in: .rect(cornerRadius: 12))
                        }
                        HStack(spacing: 8) {
                            Button { model.acceptFriendInvite(invite.id) } label: {
                                Label("Accept", systemImage: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Ink.onAccent.opacity(0.85))
                                    .padding(.horizontal, 14).frame(height: 30)
                                    .background(theme.gradient, in: .capsule)
                            }
                            .buttonStyle(.plain)
                            Button { model.declineFriendInvite(invite.id) } label: { Image(systemName: "xmark") }
                                .buttonStyle(IconButtonStyle(size: 30))
                                .accessibilityLabel("Decline")
                        }
                    }
                }
                .padding(12)
                .background(Ink.surface, in: .rect(cornerRadius: 12))
            }
        }
    }
}
