import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// A profile's identity card: one bordered card with the picture on the left and the name and @handle beside it, then the
/// bio and the buttons. Everything else goes below it, in `ProfileTabs`.
/// No colour is picked per person: it follows the app's own theme.
struct ProfileHero<Actions: View>: View {
    @Environment(\.theme) private var theme
    var avatar: Data?
    var seed: String
    var name: String
    /// A line under the name, such as what they call themselves when you've given them a nickname.
    var subtitle: String?
    var badge: Collectible?
    var handle: String?
    var bio: String?
    var verified = false
    /// Your own profile swaps in the picker, so the card you edit is the card people see.
    var avatarEditor: AnyView? = nil
    @ViewBuilder var actions: Actions
    @State private var copiedHandle = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    Group {
                        if let avatarEditor { avatarEditor } else { Avatar(image: avatar, seed: seed, size: 84, showsStory: false) }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(name)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(Ink.text)
                                .lineLimit(2).minimumScaleFactor(0.7)
                            BadgeMark(badge: badge, size: 22)
                            if verified {
                                Image(systemName: "checkmark.seal.fill").font(.system(size: 15)).foregroundStyle(theme.accent)
                                    .accessibilityLabel("Verified in person")
                            }
                        }
                        if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(Ink.faint) }
                        if let handle {
                            HStack(spacing: 8) {
                                Button {
                                    copyToClipboard("@\(handle)")
                                    Haptics.tick()
                                    withAnimation(.snappy) { copiedHandle = true }
                                    Task {
                                        try? await Task.sleep(for: .seconds(1.5))
                                        withAnimation(.snappy) { copiedHandle = false }
                                    }
                                } label: {
                                    Text(copiedHandle ? "Copied" : "@\(handle)")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(copiedHandle ? theme.accent : Ink.dim)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("@\(handle)")
                                .accessibilityHint("Copies the username")
                                if DirectoryProfile.isReserved(handle) {
                                    Label("Creator", systemImage: "checkmark.seal.fill")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(theme.accent)
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(theme.accent.opacity(0.14), in: .capsule)
                                        .overlay(Capsule().strokeBorder(theme.accent.opacity(0.35)))
                                        .help("This handle can only belong to PULSHADE's creator")
                                }
                            }
                        }
                        if badge.isModerator { ModeratorTag() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let bio, !bio.isEmpty {
                    Text(LinkPreviews.linked(bio))
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.text)
                        .tint(theme.accent)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                actions
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(Ink.surface, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Ink.line, lineWidth: 1))
    }
}

/// One of the buttons under a profile's bio: an icon with its name beneath, in a bordered tile. They share the width.
struct ProfileActionTile: View {
    @Environment(\.theme) private var theme
    var title: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.accent)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.dim)
            }
            .frame(maxWidth: .infinity).frame(height: 58)
            .background(Ink.raised, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.line))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// A line of facts on a profile: an icon, a small label and the value. Tap to copy it, or to open what it names.
struct ProfileInfoRow: Identifiable {
    var symbol: String
    var label: String
    var value: String
    var copyable = false
    var action: (() -> Void)? = nil
    var id: String { label }
}

/// A group both of you are in, listed on a profile.
struct ProfileGroupRef: Identifiable {
    var id: UUID
    var title: String
    var avatar: Data?
    var count: Int
}

private struct ProfileInfoCard: View {
    @Environment(\.theme) private var theme
    var rows: [ProfileInfoRow]
    @State private var copied: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                if i > 0 { Divider().overlay(Ink.line).padding(.leading, 52) }
                if row.copyable || row.action != nil {
                    Button { tap(row) } label: { content(row) }.buttonStyle(.plain)
                } else {
                    content(row)
                }
            }
        }
        .background(Ink.surface, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
    }

    private func content(_ row: ProfileInfoRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).font(.system(size: 12)).foregroundStyle(Ink.faint)
                Text(copied == row.id ? "Copied" : row.value).font(.system(size: 15)).foregroundStyle(Ink.text).lineLimit(2)
            }
            Spacer(minLength: 8)
            if row.action != nil {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.faint)
            } else if row.copyable {
                Image(systemName: "doc.on.doc").font(.system(size: 13)).foregroundStyle(Ink.faint)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private func tap(_ row: ProfileInfoRow) {
        if let action = row.action { action(); return }
        copyToClipboard(row.value)
        Haptics.tick()
        withAnimation(.snappy) { copied = row.id }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.snappy) { if copied == row.id { copied = nil } }
        }
    }
}

/// What's on a profile under its card, in tabs: About (the facts and links), Collectibles, Notes, and the groups you
/// share. Only the tabs that have something in them.
struct ProfileTabs: View {
    @Environment(\.theme) private var theme
    var info: [ProfileInfoRow] = []
    var links: [ProfileLink] = []
    var collectibles: [Collectible] = []
    var notes: [ProfileNote] = []
    var groups: [ProfileGroupRef] = []
    /// What this person sent in the chat you share, for the Media, Files and Links tabs.
    var messages: [Message] = []
    var walletChangedAt: Date? = nil
    var isMine = false
    @State private var picked: Kind?

    enum Kind: String, Identifiable {
        case about = "About", media = "Media", files = "Files", links = "Links", collectibles = "Collectibles", notes = "Notes",
             groups = "In common"
        var id: String { rawValue }
    }

    /// Photos and videos, newest first. A photo still on its way (only a tiny preview so far) waits until it's here.
    private var media: [Message] {
        messages.filter { m in
            guard !m.isSystem, m.voice == nil, m.attachment?.kind != .file else { return false }
            return m.isVideo || (m.image != nil && m.awaiting == nil)
        }.sorted { $0.date > $1.date }
    }
    private var files: [Message] { messages.filter { $0.attachment?.kind == .file }.sorted { $0.date > $1.date } }
    private var linkMessages: [Message] { messages.filter { $0.preview != nil }.sorted { $0.date > $1.date } }

    private var available: [Kind] {
        var out: [Kind] = []
        if !info.isEmpty || !ProfileLink.cleaned(links).isEmpty { out.append(.about) }
        if !media.isEmpty { out.append(.media) }
        if !files.isEmpty { out.append(.files) }
        if !linkMessages.isEmpty { out.append(.links) }
        if !collectibles.filter({ $0.kind != nil }).isEmpty { out.append(.collectibles) }
        if !ProfileNote.cleaned(notes).isEmpty { out.append(.notes) }
        if !groups.isEmpty { out.append(.groups) }
        return out
    }

    var body: some View {
        let tabs = available
        if !tabs.isEmpty {
            let current = tabs.first(where: { $0 == picked }) ?? tabs[0]
            VStack(spacing: 14) {
                if tabs.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 24) {
                            ForEach(tabs) { tab in
                                let on = tab == current
                                Button {
                                    withAnimation(.snappy(duration: 0.25)) { picked = tab }
                                } label: {
                                    VStack(spacing: 8) {
                                        Text(tab.rawValue)
                                            .font(.system(size: 13, weight: .semibold))
                                            .lineLimit(1)
                                            .foregroundStyle(on ? Ink.text : Ink.faint)
                                        Rectangle().fill(on ? theme.accent : .clear).frame(height: 2)
                                    }
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, 18).padding(.top, 12)
                    }
                    .scrollIndicators(.never)
                    .background(Ink.surface, in: .rect(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
                }
                switch current {
                case .about:
                    VStack(spacing: 12) {
                        if !info.isEmpty { ProfileInfoCard(rows: info) }
                        ProfileLinkList(links: links, tint: theme.accent, walletChangedAt: walletChangedAt, isMine: isMine)
                    }
                case .media: ProfileMediaGrid(messages: media)
                case .files:
                    VStack(spacing: 8) {
                        ForEach(files) { FileBubble(message: $0, mine: $0.isMine) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .links: ProfileSharedLinks(messages: linkMessages)
                case .collectibles: ContactCollectibles(items: collectibles, tint: theme.accent)
                case .notes: ProfileNoteList(notes: notes, tint: theme.accent)
                case .groups:
                    VStack(spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { i, group in
                            if i > 0 { Divider().overlay(Ink.line).padding(.leading, 60) }
                            HStack(spacing: 12) {
                                Avatar(image: group.avatar, seed: group.id.uuidString, size: 36, symbol: "person.2.fill", showsStory: false)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.text).lineLimit(1)
                                    Text("\(group.count) members").font(.system(size: 12)).foregroundStyle(Ink.faint)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                    }
                    .background(Ink.surface, in: .rect(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
                }
            }
            .frame(maxWidth: .infinity)
            .id(current)
            .transition(.opacity)
        }
    }
}

/// Photos and videos from a chat, three to a row. A tap opens a photo full size or plays a video.
private struct ProfileMediaGrid: View {
    var messages: [Message]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
            ForEach(messages) { MediaTile(message: $0) }
        }
        .padding(6)
        .background(Ink.surface, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
    }
}

private struct MediaTile: View {
    var message: Message
    @State private var open = false

    private var ready: Bool { message.video?.isEmpty == false }

    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    if let data = message.image, let img = DecodedImages.image(data, fit: 400) {
                        Image(platformImage: img).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Ink.raised)
                    }
                    if message.isVideo {
                        if ready {
                            Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(.white)
                                .frame(width: 34, height: 34).background(.black.opacity(0.5), in: .circle)
                        } else {
                            ProgressView().tint(.white)
                        }
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if message.isVideo, ready, let seconds = message.clipSeconds { VideoBadge(seconds: seconds).padding(4) }
            }
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
            .onTapGesture { if !message.isVideo || ready { open = true } }
            .modifier(MediaOpener(message: message, open: $open))
            .accessibilityLabel(message.isVideo ? "Video" : "Photo")
            .accessibilityAddTraits(.isButton)
    }
}

private struct MediaOpener: ViewModifier {
    var message: Message
    @Binding var open: Bool

    func body(content: Content) -> some View {
        if message.isVideo {
            content.modifier(VideoPlayerCover(isPresented: $open, clip: message.video ?? Data()))
        } else {
            content.modifier(ImageViewerCover(isPresented: $open, data: message.image ?? Data(), date: message.date,
                                              caption: message.text.isEmpty ? nil : message.text))
        }
    }
}

/// Links that were shared in the chat, each with its title and site. A tap asks before it leaves the app.
private struct ProfileSharedLinks: View {
    var messages: [Message]
    @State private var asking: LinkPreview?

    private func domain(_ p: LinkPreview) -> String { URL(string: p.url)?.host() ?? p.url }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                if let p = m.preview {
                    if i > 0 { Divider().overlay(Ink.line).padding(.leading, 66) }
                    Button { asking = p } label: {
                        HStack(spacing: 12) {
                            Group {
                                if let data = p.image, let img = DecodedImages.image(data, fit: 120) {
                                    Image(platformImage: img).resizable().scaledToFill()
                                } else {
                                    Image(systemName: "link").font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.faint)
                                }
                            }
                            .frame(width: 44, height: 44)
                            .background(Ink.raised)
                            .clipShape(.rect(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title ?? domain(p)).font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.text).lineLimit(2)
                                Text(p.site ?? domain(p)).font(.system(size: 12)).foregroundStyle(Ink.faint).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(m.date.chatStamp).font(.system(size: 11)).foregroundStyle(Ink.faint)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Ink.surface, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
        .confirmationDialog("Leave Pulshade?", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            presenting: asking) { p in
            Button("Open \(domain(p))") { if let url = URL(string: p.url) { Platform.open(url) } }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text("This goes to \(domain(p)). Pulshade can't protect you there.")
        }
    }
}

/// Someone found by @handle: their whole profile, with one button to add them. A note is optional and tucked away.
struct FoundProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var profile: DirectoryProfile
    var openChat: (Conversation.ID) -> Void

    @State private var addingNote = false
    @State private var note = ""
    @State private var justSent = false
    @State private var reporting: ReportSubject?

    private var tint: Color { theme.accent }
    private var known: Contact? { model.visibleContacts.first { $0.fingerprint == profile.fingerprint } }
    private var requested: Bool { justSent || model.sentRequests.contains { $0.fingerprint == profile.fingerprint } }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 16) {
                ProfileHero(avatar: profile.avatar, seed: profile.fingerprint,
                            name: profile.name.isEmpty ? "Anonymous" : profile.name,
                            subtitle: model.isMine(profile.fingerprint) ? "This is you" : nil, badge: profile.badge,
                            handle: profile.handle, bio: profile.bio) { actions }
                if let earlier = model.earlierOwner(of: profile) {
                    Label("@\(profile.handle) used to be \(earlier.displayName). This is a different account.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ProfileTabs(links: profile.links ?? [], notes: profile.notes ?? [])
                if !model.isMine(profile.fingerprint) {
                    Button("Report @\(profile.handle)") {
                        reporting = ReportSubject(key: profile.signingKey, handle: profile.handle, name: profile.name)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Ink.faint)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: 360)
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .sheet(item: $reporting) { ReportSheet(subject: $0) }
        .animation(.snappy, value: requested)
        .animation(.snappy, value: addingNote)
    }

    @ViewBuilder private var actions: some View {
        if model.isMine(profile.fingerprint) {
            EmptyView()
        } else if let known {
            wideButton("Message", "bubble.left.fill") {
                let convo = model.startConversation(kind: .direct, title: known.displayName, members: [known.fingerprint])
                openChat(convo.id)
            }
        } else if requested {
            VStack(spacing: 10) {
                Label("Request sent", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(tint.opacity(0.12), in: .capsule)
                    .overlay(Capsule().strokeBorder(tint.opacity(0.3)))
                Text("Once they accept, you're connected and your chat opens. Nothing else to do.")
                    .font(.system(size: 12.5)).foregroundStyle(Ink.faint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 18) {
                    // A request can go missing (a relay restart): sending again gets it there.
                    if !justSent { Button("Send again", action: add) }
                    Button("Cancel request") {
                        model.cancelRequest(to: profile.fingerprint)
                        justSent = false
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ink.dim)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
            VStack(spacing: 10) {
                wideButton("Add friend", "person.crop.circle.badge.plus", action: add)
                if addingNote {
                    TextField("", text: $note, prompt: Text("A note with your request").foregroundStyle(Ink.faint), axis: .vertical)
                        .textFieldStyle(LargeFieldStyle())
                        .lineLimit(1...3)
                        .onSubmit(add)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Button("Add a note") { addingNote = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Ink.dim)
                }
            }
        }
    }

    private func wideButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Ink.onAccent)
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(tint.gradient, in: .capsule)
                .shadow(color: tint.opacity(0.35), radius: 12, y: 4)
                .contentShape(.capsule)
        }
        .buttonStyle(PressScale())
    }

    private func add() {
        guard model.sendRequest(to: profile, note: note) != nil else { return }
        Haptics.tick()
        note = ""
        addingNote = false
        justSent = true
    }
}

/// Opens a found profile on its own page, from the chat list's search.
struct FoundProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// How tall the profile is, so the sheet opens only that tall instead of leaving a black void under it.
    @State private var contentHeight: CGFloat = 0
    var profile: DirectoryProfile
    var openChat: (Conversation.ID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Profile").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 26))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Rectangle().fill(Ink.line).frame(height: 1)
            ScrollView {
                FoundProfileView(profile: profile) { id in
                    dismiss()
                    openChat(id)
                }
                .padding(.top, 16)
                .padding(.bottom, 28)
                .background(GeometryReader { Color.clear.preference(key: SheetHeightKey.self, value: $0.size.height) })
            }
            .scrollIndicators(.never)
            .onPreferenceChange(SheetHeightKey.self) { contentHeight = $0 }
        }
        .background(Ink.base)
        #if os(macOS)
        .frame(width: 440, height: 640)
        #else
        .presentationDetents([.height(max(320, contentHeight + 56)), .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}

private struct SheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension DirectoryProfile: Identifiable {
    var id: String { handle }
}
