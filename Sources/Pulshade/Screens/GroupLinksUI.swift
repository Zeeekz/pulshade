import SwiftUI

/// A group's join link, opened: its preview, then Join (or Ask to join), then what happened.
struct JoinGroupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    var code: GroupLinkCode

    @State private var preview: GroupPreview?
    @State private var loading = true
    @State private var note = ""

    private var ask: JoinAsk? {
        guard let preview else { return nil }
        return model.data.joinAsks.first { $0.group == preview.group && $0.persona == model.activePersona }
    }

    var body: some View {
        SheetBody(width: 420) {
            VStack(spacing: 16) {
                SheetHeader(symbol: "person.3", title: "Join a group")
                if loading {
                    ProgressView().padding(30)
                } else if let preview {
                    details(preview)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "link.badge.plus").font(.system(size: 34, weight: .light)).foregroundStyle(Ink.faint)
                        Text("This link doesn't work. It may have been reset or deleted, or it ran out.")
                            .font(.system(size: 13)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 20)
                }
            }
        }
        .task {
            preview = await model.previewGroup(code)
            loading = false
        }
    }

    @ViewBuilder
    private func details(_ p: GroupPreview) -> some View {
        VStack(spacing: 10) {
            Avatar(image: p.avatar, seed: p.group.uuidString, size: 72)
            Text(p.title).font(.system(size: 18, weight: .bold)).foregroundStyle(Ink.text).multilineTextAlignment(.center)
            Text(p.members == 1 ? "1 member" : "\(p.members) members").font(.system(size: 12)).foregroundStyle(Ink.dim)
            if let about = p.about, !about.isEmpty {
                Text(about).font(.system(size: 13)).foregroundStyle(Ink.text).multilineTextAlignment(.center)
            }
        }
        if model.isInGroup(p, persona: model.activePersona) {
            Text("You're in this group.").font(.system(size: 13)).foregroundStyle(Ink.dim)
            Button("Open") {
                model.requestedConversation = model.conversationID(forGroup: p.group, persona: model.activePersona)
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
        } else if let ask {
            VStack(spacing: 8) {
                if ask.declined {
                    Text("Your request was turned down.").font(.system(size: 13)).foregroundStyle(Ink.dim)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(ask.approval ? "Asked. An admin needs to say yes." : "Asked. You'll be in as soon as an admin's phone sees it.")
                            .font(.system(size: 12)).foregroundStyle(Ink.dim)
                    }
                }
                Button(ask.declined ? "Done" : "Cancel request") {
                    model.cancelJoinAsk(ask.id)
                    if ask.declined { dismiss() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accent)
            }
        } else {
            if p.approval {
                TextField("A note for the admins (optional)", text: $note, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Ink.raised, in: .rect(cornerRadius: 8))
                    .onChange(of: note) { _, new in if new.count > 200 { note = String(new.prefix(200)) } }
            }
            Text("The group sees the name and picture of \(model.profile(for: model.activePersona).displayName), under a key used only in this group.")
                .font(.system(size: 11)).foregroundStyle(Ink.faint).multilineTextAlignment(.center)
            Button(p.approval ? "Ask to join" : "Join group") {
                model.askToJoin(p, note: note, persona: model.activePersona)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}

/// For admins of a group that shares one mailbox: its join links, requests waiting for a yes, and who is banned.
struct GroupLinksSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let id: Conversation.ID

    @State private var making = false
    @State private var showing: JoinLink?
    @State private var copied: UUID?
    @State private var confirm: (title: String, action: () -> Void)?

    var body: some View {
        let links = model.joinLinks(id)
        let held = model.heldJoins(id)
        VStack(spacing: 18) {
            if !held.isEmpty {
                Card(title: "Requests to join · \(held.count)") {
                    ForEach(held) { request(model: $0) }
                }
            }
            Card(title: "Join links", footer: "Anyone with a link can see the group's name, picture, description and size, and ask to join. Members can see the links; only admins can read who asked.") {
                ForEach(links?.links ?? []) { linkRow($0) }
                if (links?.links.count ?? 0) < GroupLinks.maxLinks {
                    Button { making = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "link.badge.plus").font(.system(size: 12, weight: .semibold))
                                .frame(width: 28, height: 28).background(theme.wash, in: .circle)
                                .foregroundStyle(theme.accent)
                            Text("New link").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.accent)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let bans = links?.bans, !bans.isEmpty {
                Card(title: "Banned · \(bans.count)") {
                    ForEach(bans, id: \.self) { key in
                        HStack {
                            Text(model.bannedName(key, in: id)).font(.system(size: 13)).foregroundStyle(Ink.text).lineLimit(1)
                            Spacer()
                            Button("Unban") { model.unban(key, in: id) }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accent)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $making) { NewJoinLinkSheet(id: id) }
        .sheet(item: $showing) { LinkCodeSheet(link: $0, target: model.linkCode($0, in: id)?.text ?? "") }
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            Button("Continue", role: .destructive) { confirm?.action(); confirm = nil }
        }
    }

    private func request(model held: HeldJoin) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(image: held.request.card.avatar, seed: held.request.card.fingerprint, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(held.request.card.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.text).lineLimit(1)
                if let note = held.request.note {
                    Text(note).font(.system(size: 12)).foregroundStyle(Ink.dim).lineLimit(3)
                }
            }
            Spacer()
            Menu {
                Button("Decline") { model.declineJoin(held.id, in: id) }
                Button("Decline and ban", role: .destructive) { model.declineAndBan(held.id, in: id) }
            } label: {
                Text("Decline").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.dim)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.dim)
            Button("Add") { model.approveJoin(held.id, in: id) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accent)
        }
    }

    private func linkRow(_ link: JoinLink) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "link").font(.system(size: 12)).foregroundStyle(Ink.dim).frame(width: 28, height: 28)
                .background(Ink.raised, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.label.isEmpty ? "Link" : link.label).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.text).lineLimit(1)
                Text(summary(link)).font(.system(size: 11)).foregroundStyle(link.isOpen() ? Ink.dim : Ink.faint)
            }
            Spacer()
            let target = model.linkCode(link, in: id)?.text ?? ""
            CopyLinkButton(target: target) { withAnimation(.snappy) { copied = link.id } } label: {
                Image(systemName: copied == link.id ? "checkmark" : "doc.on.doc").font(.system(size: 12))
            }
            .foregroundStyle(theme.accent)
            .accessibilityLabel("Copy link")
            Menu {
                Button("Show QR code") { showing = link }
                Button("Reset link") {
                    confirm = ("Reset this link? Everyone who has it now won't be able to use it.", { model.resetJoinLink(link.id, in: id) })
                }
                Button("Delete link", role: .destructive) {
                    confirm = ("Delete this link?", { model.deleteJoinLink(link.id, in: id) })
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Ink.faint).frame(width: 30, height: 30).contentShape(.rect)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More for this link")
        }
    }

    private func summary(_ link: JoinLink) -> String {
        var parts: [String] = []
        if link.approval { parts.append("Admins approve") }
        if let limit = link.limit { parts.append("\(link.used) of \(limit) used") } else if link.used > 0 { parts.append("\(link.used) joined") }
        if let expires = link.expires {
            parts.append(expires > .now ? "Until \(expires.formatted(date: .abbreviated, time: .omitted))" : "Expired")
        }
        return parts.isEmpty ? "Anyone with it can join" : parts.joined(separator: " · ")
    }
}

/// A new join link: a name, whether admins approve each request, how long it works and for how many.
private struct NewJoinLinkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: Conversation.ID

    @State private var label = ""
    @State private var approval = false
    @State private var days = 0
    @State private var limit = 0

    var body: some View {
        SheetBody(width: 400) {
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(symbol: "link.badge.plus", title: "New link")
                TextField("Name (members can see it)", text: $label)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Ink.raised, in: .rect(cornerRadius: 8))
                    .onChange(of: label) { _, new in if new.count > 40 { label = String(new.prefix(40)) } }
                Card {
                    Toggle("Admins approve each request", isOn: $approval).font(.system(size: 13))
                    Divider().overlay(Ink.line)
                    Field(label: "Works for") {
                        Picker("", selection: $days) {
                            Text("Always").tag(0)
                            Text("1 day").tag(1)
                            Text("1 week").tag(7)
                            Text("1 month").tag(30)
                        }
                        .labelsHidden().fixedSize()
                    }
                    Divider().overlay(Ink.line)
                    Field(label: "People who can join") {
                        Picker("", selection: $limit) {
                            Text("No limit").tag(0)
                            Text("1").tag(1)
                            Text("10").tag(10)
                            Text("50").tag(50)
                            Text("100").tag(100)
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                Button("Make link") {
                    model.makeJoinLink(in: id, label: label.trimmingCharacters(in: .whitespacesAndNewlines), approval: approval,
                                       expires: days == 0 ? nil : Date().addingTimeInterval(TimeInterval(days) * 86_400),
                                       limit: limit == 0 ? nil : limit)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// A link as a QR code, to be scanned from another phone.
private struct LinkCodeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let link: JoinLink
    /// The link's code (it names the group's owner).
    let target: String
    @State private var copied = false


    var body: some View {
        SheetBody(width: 380) {
            VStack(spacing: 16) {
                SheetHeader(symbol: "qrcode", title: link.label.isEmpty ? "Join link" : link.label)
                QRCode(text: WebLinks.long(target), size: 220)
                CopyLinkButton(target: target) { withAnimation(.snappy) { copied = true } } label: {
                    Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "link").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(theme.accent)
            }
        }
    }
}

/// A group's or channel's public name: claimed here by a group's owner or a channel's admin, from the same pool of
/// names as @usernames. Anyone can look it up or open its link.
struct PublicNameSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let id: Conversation.ID
    let kind: ConversationKind

    @State private var editing = false
    @State private var text = ""
    @State private var approval = true
    @State private var busy = false
    @State private var problem: String?
    @State private var copied = false
    @State private var confirmRemove = false

    private var noun: String { kind == .channel ? "channel" : "group" }

    var body: some View {
        let name = model.publicName(id)
        Card(title: "Public name", footer: footer(name)) {
            if let name, !editing {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("@" + name.handle).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.text)
                        if let link = WebLinks.name(name.handle) {
                            Text(link.replacingOccurrences(of: "https://", with: "")).font(.system(size: 11)).foregroundStyle(Ink.dim)
                        }
                    }
                    Spacer()
                    if let link = WebLinks.name(name.handle) {
                        Button {
                            copyToClipboard(link)
                            withAnimation(.snappy) { copied = true }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12))
                        }
                        .buttonStyle(.plain).foregroundStyle(theme.accent)
                        .accessibilityLabel("Copy link")
                    }
                    Menu {
                        Button("Change name") { text = name.handle; editing = true }
                        Button("Remove name", role: .destructive) { confirmRemove = true }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Ink.faint).frame(width: 30, height: 30).contentShape(.rect)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("More for the public name")
                }
            } else if editing {
                HStack(spacing: 6) {
                    Text("@").font(.system(size: 14)).foregroundStyle(Ink.faint)
                    TextField("name", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .onSubmit(claim)
                        .onChange(of: text) { _, new in if new.count > 24 { text = String(new.prefix(24)) } }
                }
                .padding(10)
                .background(Ink.raised, in: .rect(cornerRadius: 8))
                if kind == .group && name == nil {
                    Toggle("Admins approve each request", isOn: $approval).font(.system(size: 13))
                }
                if let problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(.red)
                }
                HStack {
                    Button("Cancel") { editing = false; problem = nil }
                        .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button(name == nil ? "Claim" : "Save", action: claim)
                        .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accent)
                        .disabled(busy || DirectoryProfile.validHandle(text) == nil)
                }
            } else {
                Button { text = ""; editing = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "at").font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28).background(theme.wash, in: .circle)
                            .foregroundStyle(theme.accent)
                        Text("Give this \(noun) a public name").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.accent)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .confirmationDialog("Remove the public name? Its link stops working, and the name is held for you for three months.",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await model.removePublicName(for: id) } }
        }
    }

    private func footer(_ name: PublicName?) -> String {
        kind == .channel
            ? "Anyone can find the channel by its name and follow it, and can see it's run from your account, as its invite link already shows. Names come from the same pool as @usernames."
            : "Anyone can find the group by its name, see its name, picture, description and size, and ask to join. Resetting its link doesn't stop that: remove the name. Names come from the same pool as @usernames."
    }

    private func claim() {
        guard !busy, DirectoryProfile.validHandle(text) != nil else { return }
        busy = true
        problem = nil
        Task {
            do {
                try await model.setPublicName(text, for: id, approval: approval)
                editing = false
            } catch AppModel.PublicNameError.taken {
                problem = "That name is taken"
            } catch AppModel.PublicNameError.reserved {
                problem = "That name can't be used"
            } catch AppModel.PublicNameError.held {
                problem = "That name was let go of lately and is still held for its last owner"
            } catch AppModel.PublicNameError.invalidHandle {
                problem = "Names are letters, numbers or _"
            } catch AppModel.PublicNameError.unreachable {
                problem = "Can't reach the relay"
            } catch AppModel.PublicNameError.notAllowed {
                problem = kind == .channel ? "Only the channel's admins can name it" : "Only the group's owner can name it"
            } catch {
                problem = "That didn't work. Try again."
            }
            busy = false
        }
    }
}
