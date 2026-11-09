import SwiftUI

struct NewConversationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    var opened: (Conversation.ID) -> Void

    @State private var kind: ConversationKind?
    @State private var burner = false
    @State private var title = ""
    @State private var avatar: Data?
    @State private var picked: Set<String> = []
    @State private var seed = UUID().uuidString

    var body: some View {
        SheetBody(width: 480) {
            VStack(spacing: 20) {
                SheetHeader(symbol: burner ? "link" : kind?.symbol ?? "plus", title: burner ? "One-time chat link" : kind?.label ?? "New")
                if burner {
                    ChatLinkForm(back: { burner = false }, opened: { id in opened(id); dismiss() })
                        .transition(.push(from: .trailing))
                } else if let kind {
                    form(kind).transition(.push(from: .trailing))
                } else {
                    chooser.transition(.push(from: .leading))
                }
            }
            .animation(.smooth(duration: 0.4), value: kind)
            .animation(.smooth(duration: 0.4), value: burner)
        }
    }

    private var chooser: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(ConversationKind.allCases) { k in
                    KindTile(symbol: k.symbol, label: k.label) { kind = k }
                }
            }
            KindTile(symbol: "link", label: "One-time chat link", hot: true) { burner = true }
        }
    }

    @ViewBuilder private func form(_ kind: ConversationKind) -> some View {
        VStack(spacing: 18) {
            if kind != .direct {
                AvatarPicker(image: $avatar, seed: seed, size: 90)
                TextField("Name", text: $title)
                    .textFieldStyle(PulseFieldStyle())
                    .multilineTextAlignment(.center)
            }
            if kind != .channel {
                ContactPicker(single: kind == .direct, picked: $picked)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "person.wave.2.fill")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(theme.gradient.opacity(0.7))
                    Text("Followers join with the channel's invite link.")
                        .font(.system(size: 12)).foregroundStyle(Ink.faint)
                }
            }
            HStack(spacing: 12) {
                Button { self.kind = nil; picked = [] } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(IconButtonStyle(size: 46))
                    .accessibilityLabel("Back")
                Button { create(kind) } label: { Image(systemName: "checkmark") }
                    .buttonStyle(GlowButtonStyle(size: 46))
                    .disabled(!valid(kind))
                    .accessibilityLabel("Create")
            }
        }
    }

    private func valid(_ kind: ConversationKind) -> Bool {
        switch kind {
        case .direct: picked.count == 1
        case .group, .broadcast:
            !picked.isEmpty && picked.count <= Conversation.maxMembers && !title.trimmingCharacters(in: .whitespaces).isEmpty
        case .channel: !title.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func create(_ kind: ConversationKind) {
        guard valid(kind) else { return }
        let convo = model.startConversation(kind: kind, title: title.trimmingCharacters(in: .whitespaces),
                                            members: Array(picked).sorted(), avatar: avatar)
        opened(convo.id)
        dismiss()
    }
}

private struct KindTile: View {
    @Environment(\.theme) private var theme
    var symbol: String
    var label: String
    var hot = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(hot ? AnyShapeStyle(Burn.gradient) : AnyShapeStyle(theme.gradient))
                    .symbolEffect(.bounce, value: hover)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.dim)
            }
            .frame(maxWidth: .infinity).frame(height: hot ? 84 : 110)
            .glass(14)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.gradient.opacity(hover ? 0.7 : 0), lineWidth: 1.5))
            .scaleEffect(hover ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.3)) { hover = h } }
    }
}

struct ContactPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var single: Bool
    @Binding var picked: Set<String>

    var body: some View {
        if model.visibleContacts.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(theme.gradient)
                Text("Add someone from Invite first")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.faint)
            }
            .frame(height: 140)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 10)], spacing: 14) {
                    ForEach(model.visibleContacts) { c in
                        let on = picked.contains(c.fingerprint)
                        Button {
                            withAnimation(.snappy(duration: 0.3)) {
                                if single { picked = [c.fingerprint] }
                                else if on { picked.remove(c.fingerprint) } else { picked.insert(c.fingerprint) }
                            }
                        } label: {
                            VStack(spacing: 6) {
                                ZStack(alignment: .bottomTrailing) {
                                    Avatar(image: c.avatar, seed: c.fingerprint, size: 56, showsStory: false)
                                        .overlay(Circle().strokeBorder(theme.gradient, lineWidth: on ? 3 : 0))
                                        .scaleEffect(on ? 1.06 : 1)
                                    if on { SymbolBadge(symbol: "checkmark", size: 20).transition(.scale) }
                                }
                                Text(c.displayName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(on ? Ink.text : Ink.dim)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 220)
        }
    }
}

/// Burner colours: always fire, whatever the theme.
enum Burn {
    static let gradient = LinearGradient(colors: [.hex(0xFFB547), .hex(0xFF5A36), .hex(0xD42A6B)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
    static let lifetimes: [(label: String, seconds: TimeInterval)] = [("10m", 600), ("1h", 3600), ("1d", 86_400), ("1w", 604_800)]
}

/// Makes a one-time chat link, or opens someone else's. Whoever opens it first gets a private chat with
/// you; both sides are anonymous, and the chat is wiped from both when the time runs out.
private struct ChatLinkForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var back: () -> Void
    var opened: (Conversation.ID) -> Void

    @State private var lifetime: TimeInterval = 3600
    @State private var link: ChatLink?
    @State private var code: ChatCode?
    @State private var codeFailed = false
    @State private var joining = false
    @State private var theirLink = ""
    @State private var copied = false
    @State private var problem: String?
    @State private var shake = 0

    var body: some View {
        VStack(spacing: 18) {
            if let link {
                QRCode(text: link.link, size: 170)
                    .transition(.scale.combined(with: .opacity))
                VStack(spacing: 4) {
                    if let code {
                        Text("Or have them type this code")
                            .font(.system(size: 12)).foregroundStyle(Ink.faint)
                        Text(code.display)
                            .font(.system(size: 24, weight: .semibold, design: .monospaced)).foregroundStyle(Ink.text)
                            .textSelection(.enabled)
                    } else if codeFailed {
                        Text("Couldn't reach the relay to make a code. The QR code and link still work.")
                            .font(.system(size: 12)).foregroundStyle(Ink.faint).multilineTextAlignment(.center)
                        Button("Try again") { makeCode(for: link) }
                            .font(.system(size: 13, weight: .semibold)).buttonStyle(.plain).foregroundStyle(theme.accent)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Making a code…").font(.system(size: 12)).foregroundStyle(Ink.faint)
                        }
                    }
                }
                .frame(minHeight: 50)
                Text("Works once. The chat is deleted for both of you \(link.endsAt.formatted(.relative(presentation: .named))).")
                    .font(.system(size: 12)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button {
                        copyToClipboard(link.link)
                        withAnimation(.snappy) { copied = true }
                    } label: {
                        Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    ShareLink(item: link.link) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(PrimaryButtonStyle())
                }
            } else {
                Text("Anyone with the link can chat with you until it runs out. The chat is deleted for both of you at the end.")
                    .font(.system(size: 12)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ForEach(Burn.lifetimes, id: \.seconds) { option in
                        let on = lifetime == option.seconds
                        Button { withAnimation(.snappy) { lifetime = option.seconds } } label: {
                            Text(option.label)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(on ? AnyShapeStyle(Ink.onAccent.opacity(0.85)) : AnyShapeStyle(Ink.dim))
                                .frame(width: 54, height: 32)
                                .background(on ? AnyShapeStyle(Burn.gradient) : AnyShapeStyle(Ink.raised.opacity(0.7)), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Create link") {
                    let made = model.makeChatLink(lasting: lifetime)
                    withAnimation(.snappy) { link = made }
                    makeCode(for: made)
                }
                    .buttonStyle(PrimaryButtonStyle())

                HStack(spacing: 8) {
                    TextField("", text: $theirLink, prompt: Text("Have a link or code? Enter it here").foregroundStyle(Ink.faint))
                        .textFieldStyle(PulseFieldStyle())
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit(join)
                        .modifier(Shake(trigger: shake))
                    Button(action: join) {
                        if joining { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.right") }
                    }
                        .buttonStyle(IconButtonStyle(size: 44))
                        .accessibilityLabel("Open the chat")
                        .disabled(theirLink.isEmpty || joining)
                }
                if let problem {
                    ProblemText(problem)
                }
            }

            Button(action: back) { Image(systemName: "chevron.left") }
                .buttonStyle(IconButtonStyle(size: 40))
        }
        .animation(.snappy, value: link)
    }

    private func join() {
        if let code = ChatCode(theirLink) {
            joining = true
            problem = nil
            Task {
                let result = await model.joinChatCode(code)
                joining = false
                switch result {
                case let .success(id): opened(id)
                case .failure(.unreachable): fail("Can't reach the relay. Try again in a moment.")
                case .failure(.expired): fail("This chat has run out.")
                case .failure(.unknown): fail("No chat has that code, or someone already used it.")
                }
            }
            return
        }
        guard let parsed = ChatLink(theirLink) else {
            problem = "That isn't a one-time chat link or code."
            withAnimation(.default) { shake += 1 }
            return
        }
        guard let id = model.joinChatLink(parsed) else {
            problem = "This chat link has run out, or has already been used."
            withAnimation(.default) { shake += 1 }
            return
        }
        opened(id)
    }

    private func makeCode(for link: ChatLink) {
        withAnimation(.snappy) { codeFailed = false }
        Task {
            let made = await model.makeChatCode(for: link)
            withAnimation(.snappy) { code = made; codeFailed = made == nil }
        }
    }

    private func fail(_ message: String) {
        problem = message
        withAnimation(.default) { shake += 1 }
    }
}
