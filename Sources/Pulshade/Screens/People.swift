import SwiftUI

/// Add a friend: share your invite as a QR code or link, add someone from theirs (a contact or a channel), or
/// find them by @username. The one place for all three, so nobody needs a username to be reached.
struct PeopleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var openChat: (Conversation.ID) -> Void
    /// Off only for rendering the page to an image, which can't draw a scroll view.
    var scrolls = true
    /// Opened from the Account tab on iPhone: a page with a back button, not a tab of its own.
    var inSettings = false
    /// Opened as a sheet from the chat list, Contacts or the New menu.
    var inSheet = false
    @Environment(\.dismiss) private var dismiss

    @State private var invite = ""
    @State private var theirCode = ""
    @State private var nickname = ""
    @State private var shake = 0
    @State private var added: Contact?
    @State private var copied = false
    @State private var scanning = false
    @State private var username = ""

    private var parsed: Invite? { Invite(code: theirCode) }

    var body: some View {
        Group {
            if inSettings { SettingsScreen(title: "Add a friend") { VStack(spacing: 20) { mine; theirs } } }
            else if inSheet {
                SheetBody(width: 440) {
                    VStack(spacing: 20) {
                        SheetHeader(symbol: "person.badge.plus", title: "Add a friend")
                        mine
                        theirs
                    }
                }
            }
            else if scrolls { ScrollView { content }.scrollIndicators(.never) } else { content }
        }
            .onAppear { if invite.isEmpty { invite = model.makeInviteCode() } }
            .sheet(isPresented: $scanning) { ScanSheet() }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 20) {
                Heading(title: "Add a friend")
                    .padding(.top, 12)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        mine.frame(width: 360)
                        theirs.frame(width: 360)
                    }
                    VStack(spacing: 20) {
                        mine
                        theirs
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: .infinity)
    }

    // MARK: Your invite

    private var mine: some View {
        panel {
            VStack(spacing: 18) {
                // The QR code carries the whole link: a camera reads it at any length, and it puts nothing on the relay.
                QRCode(text: WebLinks.long(invite), size: 188)
                    .overlay {
                        Avatar(image: model.activeProfile.avatar, seed: model.fingerprint, size: 40)
                            .overlay(Circle().strokeBorder(Ink.text, lineWidth: 3))
                    }
                    .id(invite)
                    .transition(.opacity)
                VStack(spacing: 4) {
                    Text(model.activeProfile.displayName)
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.text)
                    Text(model.activeProfile.handle.map { "@\($0)" } ?? "No username: this code is how people add you")
                        .font(.system(size: 13)).foregroundStyle(model.activeProfile.handle == nil ? Ink.faint : theme.accent)
                }
                HStack(spacing: 10) {
                    SharedLinkButtons(target: invite, onCopied: {
                        withAnimation(.snappy) { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
                    }, copyLabel: {
                        Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }, shareLabel: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }, copyStyle: AnyButtonStyle(PanelButtonStyle()), shareStyle: AnyButtonStyle(PanelButtonStyle()))
                    Button { withAnimation(.snappy) { invite = model.makeInviteCode() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(PanelButtonStyle(square: true))
                    .help("New code")
                    .accessibilityLabel("New code")
                }
            }
            .frame(maxWidth: .infinity)
        } footer: {
            model.activeProfile.handle == nil
                ? "Show this code to a friend, or send them the link in any app. Each code works for one person; tap the arrows for a new one."
                : "Show this code, send the link, or just tell them your @username. Each code works for one person."
        }
    }

    // MARK: Add someone

    private var theirs: some View {
        panel {
            VStack(alignment: .leading, spacing: 14) {
                Text("Add someone")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.text)
                Button { scanning = true } label: { Label("Scan their code", systemImage: "qrcode.viewfinder") }
                    .buttonStyle(PrimaryButtonStyle())
                HStack(spacing: 10) {
                    Rectangle().fill(Ink.line).frame(height: 1)
                    Text("or paste it").font(.system(size: 12)).foregroundStyle(Ink.faint).fixedSize()
                    Rectangle().fill(Ink.line).frame(height: 1)
                }
                HStack(spacing: 10) {
                    if let parsed {
                        Avatar(seed: parsed.fingerprint, size: 30, symbol: parsed.kind == .channel ? "megaphone.fill" : nil)
                            .transition(.scale.combined(with: .opacity))
                    }
                    TextField("", text: $theirCode, prompt: Text("Invite link or code").foregroundStyle(Ink.faint))
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.text)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .onSubmit(add)
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Ink.raised, in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(parsed != nil ? theme.accent.opacity(0.6) : Ink.line))
                .modifier(Shake(trigger: shake))
                .animation(.snappy, value: parsed?.fingerprint)

                if parsed == nil, Invite.isOutdated(theirCode) || Invite.isFromNewer(theirCode) {
                    Text(Invite.problem(with: theirCode)).font(.system(size: 12)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if parsed != nil {
                    if parsed?.kind != .channel {
                        TextField("", text: $nickname, prompt: Text("Nickname (optional)").foregroundStyle(Ink.faint))
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .foregroundStyle(Ink.text)
                            .padding(.horizontal, 14)
                            .frame(height: 46)
                            .background(Ink.raised, in: .rect(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line))
                            .onSubmit(add)
                            .transition(.opacity)
                    }
                    Button(action: add) { Text(parsed?.kind == .channel ? "Follow channel" : "Add contact") }
                        .buttonStyle(SecondaryButtonStyle())
                        .transition(.opacity)
                }

                if let added { addedRow(added).transition(.opacity) }

                HStack(spacing: 10) {
                    Rectangle().fill(Ink.line).frame(height: 1)
                    Text("or find their username").font(.system(size: 12)).foregroundStyle(Ink.faint).fixedSize()
                    Rectangle().fill(Ink.line).frame(height: 1)
                }
                HStack(spacing: 6) {
                    Text("@").font(.system(size: 14)).foregroundStyle(Ink.faint)
                    TextField("", text: $username, prompt: Text("username").foregroundStyle(Ink.faint))
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.text)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .onSubmit(find)
                    Button("Find", action: find)
                        .font(.system(size: 14, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(DirectoryProfile.validHandle(username) == nil ? Ink.faint : theme.accent)
                        .disabled(DirectoryProfile.validHandle(username) == nil)
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Ink.raised, in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line))
            }
            .animation(.snappy, value: parsed != nil)
            .animation(.snappy, value: added?.fingerprint)
        } footer: {
            "Someone added by code appears in your contacts once their device answers. Someone found by username gets a request to accept."
        }
    }

    private func addedRow(_ contact: Contact) -> some View {
        let current = model.contact(contact.fingerprint) ?? contact
        return HStack(spacing: 12) {
            Avatar(image: current.avatar, seed: current.fingerprint, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(current.name.isEmpty ? "Waiting for them…" : current.displayName)
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.text)
                Text(current.hidden ? "Following" : "Added").font(.system(size: 12)).foregroundStyle(Ink.dim)
            }
            Spacer()
            if !current.hidden {
                Button("Message") {
                    openChat(model.startConversation(kind: .direct, title: current.displayName, members: [current.fingerprint]).id)
                }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
            }
        }
        .padding(12)
        .background(Ink.raised, in: .rect(cornerRadius: 12))
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content, footer: () -> String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(Ink.surface, in: .rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.line))
            Text(footer())
                .font(.system(size: 12)).foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
        }
    }

    /// Opens their profile in Contacts, where the request is sent from.
    private func find() {
        guard let handle = DirectoryProfile.validHandle(username) else { return }
        username = ""
        model.openedHandle = handle
        if inSheet || inSettings { dismiss() }
    }

    private func add() {
        guard let contact = model.addContact(code: theirCode, nickname: nickname.trimmingCharacters(in: .whitespaces)) else {
            withAnimation(.default) { shake += 1 }
            return
        }
        theirCode = ""
        nickname = ""
        withAnimation(.snappy) { added = contact }
    }
}

/// A compact button for actions inside a panel: a label, or a square icon.
private struct PanelButtonStyle: ButtonStyle {
    var square = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Ink.text)
            .padding(.horizontal, square ? 0 : 14)
            .frame(width: square ? 40 : nil, height: 40)
            .frame(maxWidth: square ? nil : .infinity)
            .background(configuration.isPressed ? Ink.hover : Ink.raised, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line))
            .contentShape(.rect)
    }
}
