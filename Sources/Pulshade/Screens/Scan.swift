import SwiftUI

/// The camera on the chat list. It reads a new device's code to link it, or a friend's invite to add them.
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
                if model.pendingLink != nil || model.linkConfirmation != nil {
                    LinkApproval()
                } else if let pending {
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
                    Text("Point it at the code on a new device you're logging in to, or at a friend's invite.")
                        .font(.system(size: 12)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                    if !scanning {
                        Button("Try again") { start() }.buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
            .animation(.snappy, value: model.pendingLink?.request.deviceID)
            .onDisappear { model.linkConfirmation = nil }
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
    /// point Pulshade at a relay, behind your back. Device codes only work from the camera.
    private func use(_ text: String) {
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
        if preview.kind == .device {
            if initial != nil {
                problem = "Codes for linking a device only work from the camera, pointed at your own new device."
            } else {
                carryOut(text)
            }
            return
        }
        pending = (text, preview)
    }

    private func carryOut(_ text: String) {
        pending = nil
        switch model.useScannedCode(text, fromLink: initial != nil) {
        case .device: break
        case let .contact(contact): added = contact
        case let .chat(id):
            model.requestedConversation = id
            dismiss()
        case .expired: problem = "This chat link has run out, or has already been used."
        case .unknown: problem = "That isn't a PULSHADE code."
        case .outdated: problem = Invite.outdatedNotice
        case .refused: problem = "Codes for linking a device only work from the camera, pointed at your own new device."
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
        case .device: ("iphone.gen3", "", "")
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

/// "Link this device?", for a new device that scanned your code or whose code you scanned.
struct LinkApproval: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let digits = model.linkConfirmation, model.pendingLink == nil {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 40, weight: .light)).foregroundStyle(theme.accent)
                Text("Check the new device")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.text)
                Text(digits)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced)).foregroundStyle(Ink.text)
                Text("The new device now shows digits. If they are not exactly these, tap Cancel on the new device: someone else answered first. If it shows none, update PULSHADE on it.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange).multilineTextAlignment(.center)
                Button {
                    model.linkConfirmation = nil
                    dismiss()
                } label: {
                    Text("Done").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 16)
                }
                .buttonStyle(GlowButtonStyle(size: 34))
            }
            .transition(.opacity)
        } else if let pending = model.pendingLink {
            VStack(spacing: 14) {
                Image(systemName: Platform.isPhone ? "laptopcomputer.and.iphone" : "iphone.gen3")
                    .font(.system(size: 40, weight: .light)).foregroundStyle(theme.accent)
                Text("Link “\(pending.request.name)”?")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.text)
                Text("It gets your account, contacts, groups and personas. Only link devices you own.")
                    .font(.system(size: 12)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                VStack(spacing: 4) {
                    Text(pending.request.checkCode)
                        .font(.system(size: 24, weight: .semibold, design: .monospaced)).foregroundStyle(Ink.text)
                    Text("Link only if your new device shows these same digits.")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                .padding(.vertical, 4)
                HStack(spacing: 10) {
                    Button("Cancel") {
                        model.cancelLink()
                        model.linkConfirmation = nil
                        dismiss()
                    }
                    .buttonStyle(.plain).foregroundStyle(Ink.dim)
                    Button {
                        model.approveLink()
                    } label: {
                        Text("Link").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 16)
                    }
                    .buttonStyle(GlowButtonStyle(size: 34))
                }
            }
            .transition(.opacity)
        }
    }
}
