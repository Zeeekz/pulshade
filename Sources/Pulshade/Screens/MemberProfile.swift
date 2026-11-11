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
                VStack(spacing: 14) {
                    SheetHeader(symbol: "person.crop.circle", title: "Profile")
                    Avatar(image: person.avatar, seed: fingerprint, size: 84)
                    VStack(spacing: 4) {
                        Text(person.displayName).font(.system(size: 18, weight: .bold)).foregroundStyle(Ink.text)
                        if let handle = person.handle { Text("@" + handle).font(.system(size: 13)).foregroundStyle(Ink.dim) }
                        if let role = model.role(of: fingerprint, in: convo) {
                            Text("\(role) in \(convo.title)").font(.system(size: 12)).foregroundStyle(Ink.faint)
                        } else if convo.kind == .group {
                            Text("In \(convo.title)").font(.system(size: 12)).foregroundStyle(Ink.faint)
                        }
                    }
                    if let bio = person.bio, !bio.isEmpty, !person.hidden {
                        Text(bio).font(.system(size: 13)).foregroundStyle(Ink.text).multilineTextAlignment(.center)
                    }
                    action(person, convo)
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
