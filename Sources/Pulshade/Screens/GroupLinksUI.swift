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
                model.requestedConversation = p.group
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
            Card(title: "Join links", footer: "Anyone with a link can see the group's name, picture, description and size, and ask to join.") {
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
        .sheet(item: $showing) { LinkCodeSheet(link: $0) }
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
            Button("Decline") { model.declineJoin(held.id, in: id) }
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
            Button {
                copyToClipboard(link.code.link)
                withAnimation(.snappy) { copied = link.id }
            } label: {
                Image(systemName: copied == link.id ? "checkmark" : "doc.on.doc").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(theme.accent)
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
                TextField("Name (only admins see it)", text: $label)
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
    @Environment(\.theme) private var theme
    let link: JoinLink
    @State private var copied = false

    var body: some View {
        SheetBody(width: 380) {
            VStack(spacing: 16) {
                SheetHeader(symbol: "qrcode", title: link.label.isEmpty ? "Join link" : link.label)
                QRCode(text: link.code.link, size: 220)
                Button {
                    copyToClipboard(link.code.link)
                    withAnimation(.snappy) { copied = true }
                } label: {
                    Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "link").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
            }
        }
    }
}
