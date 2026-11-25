import SwiftUI

/// The camera on the chat list. It reads a friend's invite to add them, or a one-time chat link.
/// Also opens with a code the system Camera handed over through a pulshade:// link.
struct ScanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    var initial: String?

    @State private var scanner = QRScanner()
    @State private var scanning = false
    @State private var added: Contact?
    @State private var problem: String?
    /// A code read and waiting for a yes.
    @State private var pending: (text: String, preview: AppModel.CodePreview)?

    var body: some View {
        SheetBody(width: 420) {
            VStack(spacing: 16) {
                SheetHeader(symbol: "qrcode.viewfinder", title: "Scan a code")
                if let pending {
                    confirmation(pending.preview)
                } else if let added {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 40, weight: .light)).foregroundStyle(theme.accent)
                        Text("\(added.displayName) added")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.text)
                        Text("They'll appear in your contacts once their device says hello.")
                            .font(.system(size: 12)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                        Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
                    }
                    .transition(.opacity)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16).fill(Ink.raised)
                        if scanning {
                            CameraPreview(session: scanner.session).clipShape(.rect(cornerRadius: 16))
                        } else {
                            Image(systemName: "camera").font(.system(size: 40, weight: .light)).foregroundStyle(Ink.faint)
                        }
                    }
                    .frame(width: 260, height: 260)
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.accent.opacity(scanning ? 0.6 : 0.2), lineWidth: 1.5))
                    if let problem {
                        ProblemText(problem)
                            .multilineTextAlignment(.center)
                    }
                    Text("Point it at your friend's invite code.")
                        .font(.system(size: 12)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                    if !scanning {
                        Button("Try again") { start() }.buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
            .animation(.snappy, value: added?.fingerprint)
            .animation(.snappy, value: pending?.text)
        }
        .onAppear {
            if let initial { use(initial) } else { start() }
        }
        .onChange(of: scanner.found) { _, text in
            guard let text else { return }
            scanning = false
            use(text)
        }
        .onDisappear { scanner.stop() }
    }

    private func start() {
        problem = nil
        Task {
            scanning = await scanner.start()
            if !scanning { problem = "PULSHADE can't use the camera. Allow it in Settings, then try again." }
        }
    }

    /// Nothing happens until you say yes, so a link on a web page or a code on a poster can't add anyone, or
    /// point Pulshade at a relay, behind your back.
    private func use(_ text: String) {
        // A Pulshade web link (a name, or a code after "#"): opened as the pulshade:// link it stands for.
        if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let target = WebLinks.parse(url) {
            switch target {
            case let .name(handle, check):
                model.openedKeyCheck = check
                model.openedHandle = handle
                dismiss()
                return
            case let .group(code):
                model.openedGroupLink = OpenedGroupLink(code: code)
                dismiss()
                return
            case let .invite(code):
                // Carries on below as the code itself, which waits for a yes.
                return use(code)
            case let .chat(link):
                return use(link.link)
            case let .short(code):
                model.openedShort = code
                dismiss()
                return
            }
        }
        // A profile link (a website's Pulshade button, as a QR code): its profile, with the request button, in Contacts.
        if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let link = DirectoryProfile.handle(fromLink: url) {
            model.openedKeyCheck = link.keyCheck
            model.openedHandle = link.handle
            dismiss()
            return
        }
        // A group's join link: its preview, with Join.
        if let code = GroupLinkCode(text) {
            model.openedGroupLink = OpenedGroupLink(code: code)
            dismiss()
            return
        }
        guard let preview = model.inspectCode(text) else {
            problem = Invite.isOutdated(text) ? Invite.outdatedNotice : "That isn't a PULSHADE code."
            return
        }
        pending = (text, preview)
    }

    private func carryOut(_ text: String) {
        pending = nil
        switch model.useScannedCode(text) {
        case let .contact(contact): added = contact
        case let .chat(id):
            model.requestedConversation = id
            dismiss()
        case .expired: problem = "This chat link has run out, or has already been used."
        case .unknown: problem = "That isn't a PULSHADE code."
        case .outdated: problem = Invite.outdatedNotice
        }
    }

    private func confirmation(_ preview: AppModel.CodePreview) -> some View {
        let persona = model.activeProfile.displayName
        let (symbol, title, detail): (String, String, String) = switch preview.kind {
        case .contact: ("person.crop.circle.badge.plus", "Add this person?",
                        "They'll see your name and picture as \(persona).")
        case .channel: ("megaphone", "Follow this channel?", "Its staff will see your name and picture as \(persona).")
        case let .chat(endsAt): ("timer", "Join this one-time chat?",
                                 "You'll join as a throwaway identity, wiped \(endsAt.formatted(.relative(presentation: .named))).")
        }
        return VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(theme.accent)
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.text)
            Text(detail).font(.system(size: 12)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
            if let relay = preview.relay {
                Text(branded: "This uses another relay, \(URL(string: relay)?.host() ?? relay). Whoever runs it will see your connection whenever PULSHADE checks for messages.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                Button("Cancel") {
                    pending = nil
                    if initial != nil { dismiss() } else { start() }
                }
                .buttonStyle(.plain).foregroundStyle(Ink.dim)
                Button {
                    if let text = pending?.text { carryOut(text) }
                } label: {
                    Text(preview.kind == .channel ? "Follow" : preview.kind == .contact ? "Add" : "Join")
                        .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 16)
                }
                .buttonStyle(GlowButtonStyle(size: 34))
            }
        }
        .transition(.opacity)
    }
}
