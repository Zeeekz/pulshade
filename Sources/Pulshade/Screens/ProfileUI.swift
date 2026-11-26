import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

// MARK: - The profile card

/// The top of every profile, the same wherever it's opened: the picture in the middle, the name, one line under it,
/// the @handle and bio, the links and wallets they've pinned, then the buttons for this person. Everything else goes
/// below it, in `ProfileTabs`. No colour is picked per person: the soft wash at the top follows the app's theme.
struct ProfileHero<Actions: View>: View {
    @Environment(\.theme) private var theme
    var avatar: Data?
    var seed: String
    var name: String
    /// A line under the name: what they call themselves when you've given them a nickname, their role in a group,
    /// or "This is you".
    var subtitle: String?
    var handle: String?
    var bio: String?
    var verified = false
    /// Links and wallets they've pinned, shown as small tappable chips under the bio.
    var links: [ProfileLink] = []
    var walletChangedAt: Date? = nil
    var isMine = false
    /// A few numbers in a strip under the bio, such as how long you've been friends and how many groups you share.
    var facts: [ProfileFact] = []
    @ViewBuilder var actions: Actions
    @State private var copiedHandle = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(spacing: 0) {
            ProfileCover()
                .frame(height: 92)
            Avatar(image: avatar, seed: seed, size: 96, showsStory: false)
                .padding(4)
                .background(Ink.surface, in: .circle)
                .overlay(alignment: .bottomTrailing) {
                    if verified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(theme.accent)
                            .background(Circle().fill(Ink.surface).padding(1))
                            .offset(x: -4, y: -4)
                            .accessibilityLabel("Verified in person")
                    }
                }
                .padding(.top, -52)
            VStack(spacing: 0) {
                Text(name)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Ink.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.7)
                    .padding(.top, 10)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Ink.faint).multilineTextAlignment(.center).padding(.top, 2)
                }
                if let handle { handleLine(handle).padding(.top, 8) }
                if let bio, !bio.isEmpty {
                    Text(LinkPreviews.linked(bio))
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.text)
                        .tint(theme.accent)
                        .lineSpacing(2)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
                ProfileLinkChips(links: links, walletChangedAt: walletChangedAt, isMine: isMine)
                    .padding(.top, 14)
                if !facts.isEmpty {
                    ProfileFactStrip(facts: facts).padding(.top, 16)
                }
                actions
                    .padding(.top, 16)
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(Ink.surface)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Ink.line, lineWidth: 1))
    }

    private func handleLine(_ handle: String) -> some View {
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
                HStack(spacing: 5) {
                    Text(copiedHandle ? "Copied" : "@\(handle)")
                        .font(.system(size: 14, weight: .semibold))
                    Image(systemName: copiedHandle ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(0.7)
                }
                .foregroundStyle(copiedHandle ? theme.accent : Ink.dim)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Ink.raised, in: .capsule)
                .overlay(Capsule().strokeBorder(Ink.line))
                .contentShape(.capsule)
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
                    .help("This username can only belong to PULSHADE's creator")
            }
        }
    }
}

/// One number on a profile card's strip: "2 yrs" over "Friends", "3" over "Groups".
struct ProfileFact: Hashable {
    var value: String
    var label: String
}

/// The strip of numbers on a profile card, split by thin lines.
struct ProfileFactStrip: View {
    var facts: [ProfileFact]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.offset) { i, fact in
                if i > 0 { Rectangle().fill(Ink.line).frame(width: 1, height: 28) }
                VStack(spacing: 2) {
                    Text(fact.value)
                        .font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Ink.text)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(fact.label).font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.faint).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 10)
        .background(Ink.raised.opacity(0.6), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// The band at the top of a profile card: the theme's accent fading down, with a faint heartbeat line across it.
struct ProfileCover: View {
    @Environment(\.theme) private var theme

    var body: some View {
        let light = theme.scheme == .light
        ZStack {
            LinearGradient(colors: [theme.accent.opacity(light ? 0.30 : 0.38), theme.accent.opacity(light ? 0.08 : 0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            ProfilePulseLine()
                .stroke(theme.accent.opacity(light ? 0.35 : 0.45), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .padding(.vertical, 18)
            LinearGradient(colors: [.clear, Ink.surface.opacity(0.9)], startPoint: .center, endPoint: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// A flat line with heartbeat spikes, repeated across the width.
private struct ProfilePulseLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let mid = rect.midY
        let h = rect.height / 2
        let beat: CGFloat = 120
        var x = rect.minX - 30
        p.move(to: CGPoint(x: x, y: mid))
        while x < rect.maxX {
            p.addLine(to: CGPoint(x: x + beat * 0.40, y: mid))
            p.addLine(to: CGPoint(x: x + beat * 0.47, y: mid - h * 0.35))
            p.addLine(to: CGPoint(x: x + beat * 0.53, y: mid + h * 0.9))
            p.addLine(to: CGPoint(x: x + beat * 0.60, y: mid - h))
            p.addLine(to: CGPoint(x: x + beat * 0.66, y: mid + h * 0.25))
            p.addLine(to: CGPoint(x: x + beat * 0.72, y: mid))
            x += beat
            p.addLine(to: CGPoint(x: x, y: mid))
        }
        return p
    }
}

/// The buttons under a profile card, side by side: an icon with its name beneath, in a bordered tile.
struct ProfileActionTile: View {
    @Environment(\.theme) private var theme
    var title: String
    var symbol: String
    /// The main action of the row (Message, Edit profile): filled with the accent.
    var prominent = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(prominent ? Ink.onAccent : theme.accent)
                Text(title).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(prominent ? Ink.onAccent : Ink.dim).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: 58)
            .background(prominent ? AnyShapeStyle(theme.accent.gradient) : AnyShapeStyle(Ink.raised),
                        in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(prominent ? Color.clear : Ink.line))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// The one main button on a profile that isn't a friend's yet, such as Add friend: full width, in the accent.
struct ProfilePrimaryButton: View {
    @Environment(\.theme) private var theme
    var title: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Ink.onAccent)
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(theme.gradient, in: .rect(cornerRadius: 14, style: .continuous))
                .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(PressScale())
    }
}

/// A quiet status in place of the main button, such as "Request sent".
struct ProfileStatusPill: View {
    @Environment(\.theme) private var theme
    var title: String
    var symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(theme.accent)
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(theme.accent.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.accent.opacity(0.3)))
    }
}

// MARK: - Facts about a friend

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

/// A small bordered card, the one shape every block under a profile card uses.
struct ProfileCard<Content: View>: View {
    var padded = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(padded ? 12 : 0)
            .frame(maxWidth: .infinity)
            .background(Ink.surface, in: .rect(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Ink.line))
    }
}

/// A small heading over a block under a profile card.
struct ProfileSectionTitle: View {
    var title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .tracking(0.4)
            .foregroundStyle(Ink.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
    }
}

struct ProfileInfoCard: View {
    @Environment(\.theme) private var theme
    var rows: [ProfileInfoRow]
    @State private var copied: String?

    var body: some View {
        ProfileCard {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                if i > 0 { Divider().overlay(Ink.line).padding(.leading, 52) }
                if row.copyable || row.action != nil {
                    Button { tap(row) } label: { content(row) }.buttonStyle(.plain)
                } else {
                    content(row)
                }
            }
        }
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

// MARK: - Tabs

/// What's on a profile under its card, in tabs that come in the same order everywhere: Notes, Collectibles, Shared
/// (photos, files and links from your chat) and In common. Only the tabs with something in them show, except on your
/// own profile, where Notes and Collectibles are always there with a way to add some.
struct ProfileTabs: View {
    @Environment(\.theme) private var theme
    var notes: [ProfileNote] = []
    /// The collectibles this profile shows (already checked as genuine).
    var collectibles: [Collectible] = []
    var groups: [ProfileGroupRef] = []
    /// What was sent in the chat you share, for the Shared tab.
    var messages: [Message] = []
    var isMine = false
    /// Whether the collectibles list has arrived (needed to draw any of them).
    var hasCollectibleList = false
    /// Your own profile: opens the editor from an empty tab.
    var edit: (() -> Void)? = nil
    @State private var picked: Kind?
    @State private var pickedShared: SharedKind?

    enum Kind: String, Identifiable, CaseIterable {
        case notes = "Notes", collectibles = "Collectibles", shared = "Shared", groups = "In common"
        var id: String { rawValue }
    }

    enum SharedKind: String, Identifiable, CaseIterable {
        case media = "Media", files = "Files", links = "Links"
        var id: String { rawValue }
    }

    /// Photos and videos, newest first. A photo still on its way (only a tiny preview so far) waits until it's here.
    private var media: [Message] {
        messages.filter { m in
            guard !m.isSystem, m.voice == nil, m.attachment?.kind != .file else { return false }
            return m.isVideo || ((m.image != nil || m.imageFile != nil) && m.awaiting == nil)
        }.sorted { $0.date > $1.date }
    }
    private var files: [Message] { messages.filter { $0.attachment?.kind == .file }.sorted { $0.date > $1.date } }
    private var linkMessages: [Message] { messages.filter { $0.preview != nil }.sorted { $0.date > $1.date } }
    private var cleanNotes: [ProfileNote] { ProfileNote.cleaned(notes) }

    private func count(_ kind: SharedKind) -> Int {
        switch kind {
        case .media: media.count
        case .files: files.count
        case .links: linkMessages.count
        }
    }

    private var available: [Kind] {
        var out: [Kind] = []
        if !cleanNotes.isEmpty || isMine { out.append(.notes) }
        if (!collectibles.isEmpty || isMine) && hasCollectibleList { out.append(.collectibles) }
        if SharedKind.allCases.contains(where: { count($0) > 0 }) { out.append(.shared) }
        if !groups.isEmpty { out.append(.groups) }
        return out
    }

    var body: some View {
        let tabs = available
        if !tabs.isEmpty {
            let current = tabs.first(where: { $0 == picked }) ?? tabs[0]
            VStack(spacing: 12) {
                if tabs.count > 1 { tabBar(tabs, current: current) }
                Group {
                    switch current {
                    case .notes: notesTab
                    case .collectibles: collectiblesTab
                    case .shared: sharedTab
                    case .groups: groupsTab
                    }
                }
                .id(current)
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func tabCount(_ tab: Kind) -> Int? {
        switch tab {
        case .notes: cleanNotes.count
        case .collectibles: collectibles.count
        case .shared: SharedKind.allCases.reduce(0) { $0 + count($1) }
        case .groups: groups.count
        }
    }

    private func tabBar(_ tabs: [Kind], current: Kind) -> some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                let on = tab == current
                Button {
                    withAnimation(.snappy(duration: 0.25)) { picked = tab }
                } label: {
                    HStack(spacing: 5) {
                        Text(tab.rawValue).lineLimit(1).minimumScaleFactor(0.8)
                        if let n = tabCount(tab), n > 0 {
                            Text("\(n)")
                                .font(.system(size: 11, weight: .bold).monospacedDigit())
                                .foregroundStyle(on ? theme.accent : Ink.faint)
                        }
                    }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(on ? Ink.text : Ink.faint)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.raised)
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.line))
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Ink.surface, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
    }

    @ViewBuilder private var notesTab: some View {
        if cleanNotes.isEmpty {
            emptyCard(symbol: "doc.text", title: "No notes yet",
                      text: "Pin a note to your profile: public, locked with a password, or for friends you choose.",
                      button: "New note")
        } else {
            ProfileNoteList(notes: notes, tint: theme.accent)
        }
    }

    @ViewBuilder private var collectiblesTab: some View {
        VStack(spacing: 10) {
            if collectibles.isEmpty {
                emptyCard(symbol: "sparkles", title: "Nothing on show",
                          text: "Pick up to \(AppModel.showcaseLimit) of your collectibles for friends to see here.",
                          button: "Choose collectibles")
            } else {
                CollectibleShowcase(copies: collectibles, isMine: isMine)
                if isMine, let edit {
                    Button("Change what's shown", action: edit)
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
        }
    }

    @ViewBuilder private var sharedTab: some View {
        let kinds = SharedKind.allCases.filter { count($0) > 0 }
        let current = kinds.first(where: { $0 == pickedShared }) ?? kinds.first ?? .media
        VStack(spacing: 10) {
            if kinds.count > 1 {
                HStack(spacing: 8) {
                    ForEach(kinds) { kind in
                        let on = kind == current
                        Button { withAnimation(.snappy(duration: 0.2)) { pickedShared = kind } } label: {
                            HStack(spacing: 5) {
                                Text(kind.rawValue)
                                Text("\(count(kind))").foregroundStyle(on ? theme.accent.opacity(0.8) : Ink.faint)
                            }
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(on ? theme.accent : Ink.dim)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(on ? theme.accent.opacity(0.14) : Ink.surface, in: .capsule)
                            .overlay(Capsule().strokeBorder(on ? theme.accent.opacity(0.4) : Ink.line))
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                    Spacer(minLength: 0)
                }
            }
            switch current {
            case .media: ProfileMediaGrid(messages: media)
            case .files:
                VStack(spacing: 8) {
                    ForEach(files) { FileBubble(message: $0, mine: $0.isMine) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .links: ProfileSharedLinks(messages: linkMessages)
            }
        }
    }

    private var groupsTab: some View {
        ProfileCard {
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
    }

    /// Only on your own profile: an empty tab says what goes there and opens the editor.
    private func emptyCard(symbol: String, title: String, text: String, button: String) -> some View {
        ProfileCard(padded: true) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(theme.accent)
                    .frame(width: 46, height: 46)
                    .background(theme.accent.opacity(0.12), in: .circle)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text)
                Text(text).font(.system(size: 13)).foregroundStyle(Ink.faint).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let edit {
                    Button(button, action: edit)
                        .buttonStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Ink.onAccent)
                        .padding(.horizontal, 16).frame(height: 36)
                        .background(theme.gradient, in: .capsule)
                        .padding(.top, 4)
                }
            }
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Your own, as others see it

/// Your profile exactly as people see it, with Edit profile and Share where a friend's has Message and Call.
/// Opened from the card at the top of Me, and from Preview on the edit page.
struct MyProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    /// Shown from the edit page: its Edit button just goes back.
    var fromEditor = false
    @Environment(\.dismiss) private var dismiss
    @State private var copiedLink = false
    @Environment(\.openSettingsPage) private var openSettingsPage

    private var profile: Profile { model.activeProfile }

    /// Friends, groups and notes on this profile.
    private var facts: [ProfileFact] {
        let persona = model.activePersona
        let friends = model.visibleContacts.filter { !$0.isSelf && $0.departing == nil }.count
        let groups = model.data.conversations.filter { $0.kind == .group && $0.persona == persona }.count
        let notes = ProfileNote.cleaned(profile.notes ?? []).count
        return [ProfileFact(value: "\(friends)", label: friends == 1 ? "Friend" : "Friends"),
                ProfileFact(value: "\(groups)", label: groups == 1 ? "Group" : "Groups"),
                ProfileFact(value: "\(notes)", label: notes == 1 ? "Note" : "Notes")]
    }

    var body: some View {
        SettingsScreen(title: "Your profile", back: fromEditor ? "Edit" : "Me") {
            VStack(spacing: 14) {
                ProfileHero(avatar: profile.avatar, seed: model.fingerprint,
                            name: profile.displayName,
                            subtitle: model.activePersona == nil ? nil : "Persona",
                            handle: profile.handle, bio: profile.bio,
                            links: profile.links ?? [], isMine: true, facts: facts) {
                    HStack(spacing: 8) {
                        ProfileActionTile(title: "Edit profile", symbol: "pencil", prominent: true) { edit() }
                        if let handle = profile.handle, let me = model.me(model.activePersona) {
                            ProfileActionTile(title: copiedLink ? "Link copied" : "Copy link", symbol: copiedLink ? "checkmark" : "link") {
                                copyToClipboard(WebLinks.profile(handle, key: me.card.signing))
                                Haptics.tick()
                                withAnimation(.snappy) { copiedLink = true }
                                Task {
                                    try? await Task.sleep(for: .seconds(1.5))
                                    withAnimation(.snappy) { copiedLink = false }
                                }
                            }
                        } else {
                            NavigationLink(value: SettingsPage.invite) {
                                VStack(spacing: 5) {
                                    Image(systemName: "person.badge.plus").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.accent)
                                    Text("Add a friend").font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.dim)
                                }
                                .frame(maxWidth: .infinity).frame(height: 58)
                                .background(Ink.raised, in: .rect(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.line))
                                .contentShape(.rect(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                ProfileTabs(notes: profile.notes ?? [], collectibles: model.showcase(for: model.activePersona),
                            isMine: true, hasCollectibleList: model.collectibleList != nil, edit: edit)
                Text(profile.handle == nil
                     ? "Friends see this. Claim a username to let others find it too."
                     : "Friends see all of this. Anyone who finds @\(profile.handle!) sees your card, links and notes, except notes for chosen friends.")
                    .font(.system(size: 12)).foregroundStyle(Ink.faint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
        }
    }

    private func edit() {
        if fromEditor { dismiss() } else { openSettingsPage?(.profile) }
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
    @Environment(AppModel.self) private var model
    var message: Message
    @State private var open = false

    private var ready: Bool { model.videoData(for: message)?.isEmpty == false }

    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    if let data = model.imageData(for: message), let img = DecodedImages.image(data, fit: 400) {
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
    @Environment(AppModel.self) private var model
    var message: Message
    @Binding var open: Bool

    func body(content: Content) -> some View {
        if message.isVideo {
            content.modifier(VideoPlayerCover(isPresented: $open, clip: model.videoData(for: message) ?? Data()))
        } else {
            content.modifier(ImageViewerCover(isPresented: $open, data: model.imageData(for: message) ?? Data(),
                                              date: message.date,
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
            Button("Open \(domain(p))") {
                // A preview's URL comes from the other side: only web links may leave the app, exactly as in a chat.
                if let url = LinkPreviews.openable(URL(string: p.url)) { Platform.open(url) }
            }
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

    private var known: Contact? { model.visibleContacts.first { $0.fingerprint == profile.fingerprint } }
    private var requested: Bool { justSent || model.sentRequests.contains { $0.fingerprint == profile.fingerprint } }

    var body: some View {
        VStack(spacing: 14) {
            ProfileHero(avatar: profile.avatar, seed: profile.fingerprint,
                        name: profile.name.isEmpty ? "Anonymous" : profile.name,
                        subtitle: model.isMine(profile.fingerprint) ? "This is you" : nil,
                        handle: profile.handle, bio: profile.bio,
                        links: profile.links ?? [], isMine: model.isMine(profile.fingerprint)) { actions }
            if let earlier = model.earlierOwner(of: profile) {
                Label("@\(profile.handle) used to be \(earlier.displayName). This is a different account.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProfileTabs(notes: profile.notes ?? [])
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
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .sheet(item: $reporting) { ReportSheet(subject: $0) }
        .animation(.snappy, value: requested)
        .animation(.snappy, value: addingNote)
    }

    @ViewBuilder private var actions: some View {
        if model.isMine(profile.fingerprint) {
            EmptyView()
        } else if let known {
            ProfilePrimaryButton(title: "Message", symbol: "bubble.left.fill") {
                let convo = model.startConversation(kind: .direct, title: known.displayName, members: [known.fingerprint])
                openChat(convo.id)
            }
        } else if requested {
            VStack(spacing: 10) {
                ProfileStatusPill(title: "Request sent", symbol: "checkmark.circle.fill")
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
                ProfilePrimaryButton(title: "Add friend", symbol: "person.crop.circle.badge.plus", action: add)
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
        .presentationDetents([.height(max(320, contentHeight + 56)), .large])
        .presentationDragIndicator(.visible)
    }
}

private struct SheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension DirectoryProfile: Identifiable {
    var id: String { handle }
}
