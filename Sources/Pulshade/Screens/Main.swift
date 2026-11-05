import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

enum Section: String, CaseIterable, Identifiable {
    case chats, contacts, collectibles, burn, people, settings
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right.fill"
        case .contacts: "person.2.fill"
        case .collectibles: "crown.fill"
        case .burn: "flame.fill"
        case .people: "qrcode"
        case .settings: "gearshape.fill"
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            #if os(iOS)
            PhoneMainView()
            #else
            DesktopMainView()
            #endif
        }
        .sheet(isPresented: Binding(get: { model.openedCode != nil }, set: { if !$0 { model.openedCode = nil } })) {
            ScanSheet(initial: model.openedCode)
        }
        // The backup code now covers something new: save it, or know it's covered.
        .sheet(item: Binding(get: { model.codeAlert }, set: { model.codeAlert = $0 })) { BackupCodeSheet(alert: $0) }
        .overlay { CallView() }
        .animation(.smooth(duration: 0.3), value: model.call == nil)
    }
}

#if os(iOS)
/// iPhone: tabs along the bottom, chats pushed onto a navigation stack.
private struct PhoneMainView: View {
    @Environment(AppModel.self) private var model
    @State private var section: Section = .chats
    @State private var selection: Conversation.ID?
    @State private var switchingPersona = false

    var body: some View {
        TabView(selection: $section) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: Section.chats) {
                NavigationStack {
                    ChatList(selection: $selection, section: $section)
                        .background(Ink.base)
                        .toolbar(.hidden, for: .navigationBar)
                        .navigationDestination(item: $selection) { id in
                            ConversationView(id: id).toolbar(.hidden, for: .navigationBar)
                        }
                }
            }
            .badge(model.unreadTotal)
            Tab("Contacts", systemImage: "person.2", value: Section.contacts) {
                ContactsView(openChat: open).background(Ink.base)
            }
            .badge(model.requests.count)
            Tab("Burn", systemImage: "flame", value: Section.burn) {
                LeaveView().background(Ink.base)
            }
            Tab("Invite", systemImage: "qrcode", value: Section.people) {
                PeopleView(openChat: open).background(Ink.base)
            }
            // Your account: its picture is the tab. A tap opens settings; holding it switches or adds a persona.
            Tab(value: Section.settings) {
                SettingsView().background(Ink.base)
            } label: {
                Label { Text("Account") } icon: { accountIcon }
            }
        }
        .tint(model.theme.accent)
        .background(TabHold(tab: 4) { switchingPersona = true })
        .sheet(isPresented: $switchingPersona) {
            PersonaSwitcher(done: { switchingPersona = false })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #if DEBUG
        .onAppear {
            // Screenshots: PULSHADE_DEMO_SCREEN=contacts|burn|people|settings|chat opens that screen.
            guard AppModel.demoRequested, let name = ProcessInfo.processInfo.environment["PULSHADE_DEMO_SCREEN"] else { return }
            if name == "chat", let first = model.data.conversations.first { open(first.id) }
            else if let s = Section(rawValue: name) { section = s }
        }
        #endif
        .onChange(of: model.requestedConversation, initial: true) { _, id in
            guard let id, model.conversation(id) != nil else { return }
            open(id)
            model.requestedConversation = nil
        }
        .onChange(of: model.openedHandle, initial: true) { _, handle in
            if handle != nil { section = .contacts }
        }
        // The open chat was deleted (by them, another of your devices, a burn or a block): go back to the list
        // rather than leave an empty screen.
        .onChange(of: selection.map { model.conversation($0) == nil } ?? false) { _, gone in
            if gone { selection = nil }
        }
    }

    private func open(_ id: Conversation.ID) {
        section = .chats
        selection = id
        model.markRead(id)
    }

    /// The active persona's picture as a round image for the tab bar, which only takes images, and turns any image
    /// into a one-colour shape unless it's marked to keep its own colours.
    private var accountIcon: Image {
        let size = CGSize(width: 28, height: 28)
        let picture: UIImage? = model.activeProfile.avatar.flatMap(UIImage.init(data:)) ?? {
            let renderer = ImageRenderer(content: PulseArt(tint: Signature.tint(for: model.fingerprint, model: model), size: 28)
                .frame(width: 28, height: 28))
            renderer.scale = 3
            return renderer.uiImage
        }()
        guard let picture else { return Image(systemName: "person.crop.circle") }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let round = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).addClip()
            // Fill the circle, cropping the longer side, as a profile picture does.
            let scale = max(size.width / picture.size.width, size.height / picture.size.height)
            let drawn = CGSize(width: picture.size.width * scale, height: picture.size.height * scale)
            picture.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                                    width: drawn.width, height: drawn.height))
        }
        return Image(uiImage: round.withRenderingMode(.alwaysOriginal)).renderingMode(.original)
    }
}

/// Holding one tab of the tab bar, which SwiftUI has no gesture for. iOS draws the tab buttons in a floating layer of
/// its own and keeps their touches to themselves, so the long press goes on that tab's button itself, found by its
/// place along the bar, and is put back whenever iOS rebuilds the buttons.
private struct TabHold: UIViewRepresentable {
    /// Which tab, counting from the first.
    var tab: Int
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.coordinator = context.coordinator
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        context.coordinator.tab = tab
        context.coordinator.action = action
        probe.attachSoon()
    }

    final class Probe: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachSoon()
        }

        /// The buttons appear a moment after the tab view, and are redrawn when a tab's picture changes.
        func attachSoon() {
            for delay in [0.0, 0.5, 1.5, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, let window = self.window else { return }
                    self.coordinator?.attach(in: window)
                }
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var tab = 0
        var action: () -> Void = {}
        static let name = "pulshade.tabhold"

        /// Gives the tab's button (and the copy iOS draws for the selection) the long press, once each.
        func attach(in window: UIWindow) {
            var buttons: [(view: UIView, frame: CGRect)] = []
            func collect(_ view: UIView) {
                if String(describing: type(of: view)).contains("TabButton"), view.bounds.width > 0 {
                    buttons.append((view, view.convert(view.bounds, to: window).integral))
                }
                view.subviews.forEach(collect)
            }
            collect(window)
            var places: [CGRect] = []
            for b in buttons where !places.contains(b.frame) { places.append(b.frame) }
            guard places.count > tab else { return }
            let xs = places.map(\.midX), ys = places.map(\.midY)
            let across = (xs.max()! - xs.min()!) >= (ys.max()! - ys.min()!)
            let target = places.sorted { across ? $0.minX < $1.minX : $0.minY < $1.minY }[tab]
            for b in buttons where b.frame == target && !(b.view.gestureRecognizers ?? []).contains(where: { $0.name == Self.name }) {
                let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
                press.name = Self.name
                press.minimumPressDuration = 0.4
                press.delegate = self
                b.view.addGestureRecognizer(press)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func pressed(_ press: UILongPressGestureRecognizer) {
            guard press.state == .began else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        }
    }
}
#endif

/// Mac: a slim rail, the chat list and the open chat side by side.
private struct DesktopMainView: View {
    @Environment(AppModel.self) private var model
    @State private var section: Section = .chats
    @State private var selection: Conversation.ID?

    var body: some View {
        HStack(spacing: 0) {
            Rail(section: $section)
            Rectangle().fill(Ink.line).frame(width: 1)
            Group {
                switch section {
                case .chats:
                    HStack(spacing: 0) {
                        ChatList(selection: $selection, section: $section)
                            .frame(width: 330)
                        Rectangle().fill(Ink.line).frame(width: 1)
                        if let id = selection, model.conversation(id) != nil {
                            ConversationView(id: id)
                                .id(id)
                                .transition(.opacity.combined(with: .move(edge: .trailing)))
                        } else {
                            EmptyChat().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .background {
                        // Esc closes the open chat, back to the empty view.
                        Button("") { withAnimation(.smooth(duration: 0.3)) { selection = nil } }
                            .keyboardShortcut(.cancelAction)
                            .disabled(selection == nil)
                            .hidden()
                    }
                case .contacts: ContactsView(openChat: { id in
                    selection = id
                    withAnimation(.smooth) { section = .chats }
                })
                case .collectibles: CollectiblesView()
                case .burn: LeaveView()
                case .people: PeopleView(openChat: { id in
                    selection = id
                    withAnimation(.smooth) { section = .chats }
                })
                case .settings: SettingsView()
                }
            }
            .transition(.blurReplace)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Ink.base.opacity(0.85))
        .animation(.smooth(duration: 0.3), value: section)
        .animation(.smooth(duration: 0.3), value: selection)
        .onChange(of: model.requestedConversation, initial: true) { _, id in
            guard let id, model.conversation(id) != nil else { return }
            withAnimation(.smooth) {
                section = .chats
                selection = id
            }
            model.markRead(id)
            model.requestedConversation = nil
        }
        .onChange(of: model.openedHandle, initial: true) { _, handle in
            if handle != nil { withAnimation(.smooth) { section = .contacts } }
        }
    }
}

private struct Rail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Binding var section: Section
    @Namespace private var glow
    @State private var switching = false

    /// Unread messages waiting under personas you're not currently using.
    private var otherUnread: Int {
        model.data.conversations.filter { $0.persona != model.activePersona && !model.isBurner($0.persona) && !$0.muted }
            .reduce(0) { $0 + $1.unread }
    }

    var body: some View {
        VStack(spacing: 6) {
            PulseMark(size: 30).padding(.top, 36).padding(.bottom, 16)
            ForEach([Section.chats, .contacts, .collectibles, .burn, .people], id: \.self) { s in item(s) }
            Spacer()
            item(.settings)
            Button { model.lock() } label: { Image(systemName: "lock") }
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Ink.faint)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
                .help("Lock  ⇧⌘L")
                .accessibilityLabel("Lock")
            Button { switching.toggle() } label: {
                Avatar(image: model.activeProfile.avatar, seed: model.fingerprint, size: 32)
                    .overlay(Circle().strokeBorder(model.signature("me"), lineWidth: 1.5).padding(-3))
                    .overlay(alignment: .topTrailing) {
                        if otherUnread > 0 { Circle().fill(theme.accent).frame(width: 10, height: 10).offset(x: 3, y: -3) }
                    }
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .padding(.bottom, 18)
            .accessibilityLabel("Switch persona")
            .popover(isPresented: $switching, arrowEdge: .trailing) { PersonaSwitcher(done: { switching = false }) }
        }
        .frame(width: 66)
        .background(Ink.void)
    }

    private func item(_ s: Section) -> some View {
        Button { withAnimation(.snappy(duration: 0.4)) { section = s } } label: {
            ZStack {
                if section == s {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Ink.raised)
                        .matchedGeometryEffect(id: "glow", in: glow)
                }
                Image(systemName: s.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(section == s ? theme.accent : Ink.faint)
                if s == .contacts, !model.requests.isEmpty {
                    Text("\(model.requests.count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Ink.onAccent)
                        .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                        .background(theme.accent, in: .capsule)
                        .offset(x: 11, y: -11)
                        .transition(.scale)
                }
                #if os(macOS)
                if s == .settings, Updater.shared.ready {
                    Circle().fill(theme.accent).frame(width: 8, height: 8).offset(x: 10, y: -10).transition(.scale)
                }
                #endif
            }
            .frame(width: 40, height: 40)
            .overlay(alignment: .leading) {
                if section == s {
                    Capsule().fill(theme.accent).frame(width: 3, height: 16).offset(x: -13)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(s.rawValue.capitalized)
    }
}

// MARK: - Chat list

private struct ChatList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Binding var selection: Conversation.ID?
    @Binding var section: Section
    @State private var filter: ConversationKind?
    @State private var search = ""
    @State private var composing = false
    /// The story camera and viewer are shown from here, not from the story strip: it sits in a lazy list whose rows
    /// SwiftUI throws away and rebuilds, and whatever they were showing went with them.
    @State private var composingStory = false
    @State private var viewingStory: StoryReel?
    @State private var confirmDelete: Conversation?
    @State private var confirmClear = false
    @State private var scanningCode = false
    /// How tall the search bar and stories are together, so the list can snap past them.
    @State private var storiesHeight: CGFloat = 0

    private var items: [Conversation] {
        model.sortedConversations.filter { c in
            (filter == nil || c.kind == filter) &&
                (search.isEmpty || c.title.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Heading(title: "Chats")
                Menu {
                    Button("Clear all chats…", role: .destructive) { confirmClear = true }
                        .disabled(model.clearableChats.isEmpty)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.dim)
                        .frame(width: 30, height: 30)
                        .background(Ink.raised, in: .rect(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Ink.line))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
                Button { scanningCode = true } label: { Image(systemName: "qrcode.viewfinder") }
                    .buttonStyle(IconButtonStyle(size: 30))
                    .help("Scan a code")
                    .accessibilityLabel("Scan a code")
                Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(IconButtonStyle(size: 30))
                    .keyboardShortcut("n")
                    .help("New  ⌘N")
                    .accessibilityLabel("New chat")
            }
            .padding(.horizontal, 16)
            .padding(.top, Platform.isPhone ? 12 : 38)
            .padding(.bottom, 12)

            // Search and stories scroll away with the chats, as in Telegram, so the list gets the whole screen;
            // the filters stay pinned under the heading.
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    VStack(spacing: 0) {
                        searchField
                        StoryStrip(composing: $composingStory, viewing: $viewingStory)
                            .padding(.vertical, 12)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { storiesHeight = $0 }
                    SwiftUI.Section {
                        rows
                    } header: {
                        FilterChips(filter: $filter)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                            .background(Ink.base)
                    }
                }
            }
            .scrollIndicators(.never)
            .scrollDismissesKeyboard(.immediately)
            .scrollTargetBehavior(StoriesSnap(height: storiesHeight))
        }
        .confirmationDialog(confirmDelete?.deleteWarning.title ?? "",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmDelete) { c in
            Button("Delete", role: .destructive) {
                if selection == c.id { selection = nil }
                model.delete(c.id)
            }
        } message: { c in
            Text(c.deleteWarning.detail)
        }
        .confirmationDialog("Clear all \(model.clearableChats.count) chats?", isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("Clear all chats", role: .destructive) {
                selection = nil
                withAnimation(.smooth(duration: 0.35)) { model.clearAllChats() }
            }
        } message: {
            Text("Every one-to-one chat is deleted for both sides. Groups, channels and lists stay.")
        }
        .sheet(isPresented: $composing) {
            NewConversationSheet { id in selection = id }
        }
        .sheet(isPresented: $scanningCode) { ScanSheet() }
        // Each cover on an anchor of its own: two full-screen covers on one view cancel each other out.
        .background { Color.clear.storyCamera(isPresented: $composingStory) }
        .background {
            Color.clear.viewerCover(item: $viewingStory) { reel in
                StoryViewer(stories: reel.stories, start: reel.start, following: reel.following)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Ink.faint)
            TextField("", text: $search, prompt: Text("Search").foregroundStyle(Ink.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Ink.raised, in: .rect(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var rows: some View {
        if items.isEmpty {
            Constellation(symbol: filter?.symbol ?? "bubble.left.and.bubble.right",
                          text: search.isEmpty ? "No conversations" : "No results")
                .padding(.top, 80)
        } else {
            LazyVStack(spacing: 1) {
                ForEach(items) { c in row(c) }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private func row(_ c: Conversation) -> some View {
        Button {
            selection = c.id
            model.markRead(c.id)
        } label: {
            ChatRow(conversation: c, selected: selection == c.id)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(c.title)
        .contextMenu { rowMenu(c) }
        .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .opacity))
    }

    @ViewBuilder private func rowMenu(_ c: Conversation) -> some View {
        Button(c.pinned ? "Unpin" : "Pin") { model.togglePin(c.id) }
        Button(c.muted ? "Unmute" : "Mute") { model.toggleMute(c.id) }
        Divider()
        Button("Delete…", role: .destructive) { confirmDelete = c }
    }
}

/// Like Telegram: the search bar and stories never stop half shown. A scroll that would end part way through them
/// carries on to show them in full or hide them completely, whichever way it was going; past them, the chats
/// scroll freely.
private struct StoriesSnap: ScrollTargetBehavior {
    var height: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let y = target.rect.minY
        guard height > 0, y > 0, y < height else { return }
        let hide: Bool
        if context.velocity.dy > 0.1 { hide = true }
        else if context.velocity.dy < -0.1 { hide = false }
        else { hide = y > height / 2 }
        target.rect.origin.y = hide ? height : 0
    }
}

private struct FilterChips: View {
    @Environment(\.theme) private var theme
    @Binding var filter: ConversationKind?

    var body: some View {
        HStack(spacing: 4) {
            chip(nil, label: "All")
            chip(.direct, label: "Direct")
            chip(.group, label: "Groups")
            chip(.channel, label: "Channels")
            chip(.broadcast, label: "Lists")
            Spacer(minLength: 0)
        }
    }

    private func chip(_ kind: ConversationKind?, label: String) -> some View {
        let on = filter == kind
        return Button { withAnimation(.snappy(duration: 0.25)) { filter = kind } } label: {
            Text(label)
                .font(.system(size: 12, weight: on ? .semibold : .medium))
                .foregroundStyle(on ? theme.accent : Ink.dim)
                .padding(.horizontal, 9).frame(height: 24)
                .background(on ? theme.wash : .clear, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private struct ChatRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var conversation: Conversation
    var selected: Bool
    @State private var hover = false

    var body: some View {
        let c = conversation
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Avatar(image: c.avatar ?? (c.kind == .direct ? model.contact(c.members.first ?? "")?.avatar : nil),
                       seed: c.kind == .direct ? (c.members.first ?? c.id.uuidString) : c.id.uuidString,
                       size: 42, symbol: c.kind == .direct ? nil : c.kind.symbol)
                    .overlay {
                        if c.kind == .direct, let fp = c.members.first {
                            Circle().strokeBorder(model.signature(fp).opacity(0.8), lineWidth: 1.5).padding(-2.5)
                        }
                    }
                if let burner = model.burner(c.persona) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Burn.gradient, in: .circle)
                        .overlay(Circle().strokeBorder(Ink.base, lineWidth: 2))
                        .offset(x: 3, y: 3)
                        .help("Burns \(burner.burnsAt!.formatted(.relative(presentation: .named)))")
                } else if c.kind != .direct {
                    SymbolBadge(symbol: c.kind.symbol, size: 18).offset(x: 3, y: 3)
                } else if let fp = c.members.first, model.isOnline(fp) {
                    OnlineDot(size: 12).offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(c.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                    if c.kind == .direct { BadgeMark(badge: model.contact(c.members.first ?? "")?.badge, size: 14) }
                    if c.muted { Image(systemName: "bell.slash.fill").font(.system(size: 10)).foregroundStyle(Ink.faint) }
                    Spacer(minLength: 4)
                    Text(c.lastActivity.chatStamp)
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.faint)
                }
                HStack(spacing: 6) {
                    if let last = c.messages.last {
                        if last.isMine {
                            StatusTicks(status: last.status).foregroundStyle(Ink.faint)
                        }
                        if last.image != nil { Image(systemName: "photo").font(.system(size: 11)).foregroundStyle(Ink.dim) }
                        if last.voice != nil { Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(Ink.dim) }
                        if last.expiresAt != nil || c.disappearAfter != nil {
                            Image(systemName: "timer").font(.system(size: 10)).foregroundStyle(Ink.faint)
                        }
                        Text(last.text.isEmpty ? (last.voice != nil ? "Voice message" : last.image != nil ? "Photo" : "") : last.text)
                            .font(.system(size: 13))
                            .foregroundStyle(Ink.dim)
                            .lineLimit(1)
                    } else {
                        Text("No messages yet").font(.system(size: 13)).foregroundStyle(Ink.faint)
                    }
                    Spacer(minLength: 4)
                    if c.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Ink.faint) }
                    if c.unread > 0 {
                        Text("\(c.unread)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Ink.onAccent.opacity(0.85))
                            .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18)
                            .background(c.muted ? Ink.faint : theme.accent, in: .capsule)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Ink.raised : (hover ? Ink.surface : .clear))
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

private struct EmptyChat: View {
    var body: some View {
        VStack(spacing: 14) {
            PulseMark(size: 56).opacity(0.35)
            Text("Select a conversation").font(.system(size: 13)).foregroundStyle(Ink.faint)
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                Text("End-to-end encrypted")
            }
            .font(.system(size: 11))
            .foregroundStyle(Ink.faint.opacity(0.7))
        }
    }
}

/// Switch between your main identity and personas, or make a new one.
private struct PersonaSwitcher: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var done: () -> Void
    @State private var adding = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(nil)
            ForEach(model.personas) { p in row(p.id) }
            Divider().overlay(Ink.line).padding(.vertical, 4)
            if adding {
                HStack(spacing: 8) {
                    TextField("", text: $name, prompt: Text("Persona name").foregroundStyle(Ink.faint))
                        .textFieldStyle(PulseFieldStyle())
                        .onSubmit(create)
                    Button(action: create) { Image(systemName: "checkmark") }
                        .buttonStyle(GlowButtonStyle(size: 36))
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if model.canAddPersona {
                Button { withAnimation(.snappy) { adding = true } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus").frame(width: 34, height: 34).background(Ink.raised, in: .circle)
                        Text("New persona").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Ink.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text("You can have up to \(AppModel.personaLimit) personas besides your main one. Burn one to make another.")
                    .font(.system(size: 11)).foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Platform.isPhone ? 20 : 14)
        .frame(width: Platform.isPhone ? nil : 260)
        .frame(maxWidth: Platform.isPhone ? .infinity : nil, maxHeight: Platform.isPhone ? .infinity : nil, alignment: .top)
        .background(Ink.surface)
        .preferredColorScheme(Ink.scheme)
    }

    private func row(_ id: UUID?) -> some View {
        let profile = model.profile(for: id)
        let active = model.activePersona == id
        let unread = model.data.conversations.filter { $0.persona == id && !$0.muted }.reduce(0) { $0 + $1.unread }
        return Button {
            model.switchPersona(id)
            done()
        } label: {
            HStack(spacing: 10) {
                Avatar(image: profile.avatar, seed: model.me(id)?.fingerprint ?? "", size: 34)
                    .overlay(Circle().strokeBorder(Signature.color(profile.color, seed: model.me(id)?.fingerprint ?? ""),
                                                   lineWidth: active ? 2 : 0).padding(-3))
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text)
                    if id == nil { Text("Main").font(.system(size: 10, weight: .medium)).foregroundStyle(Ink.faint) }
                }
                Spacer()
                if unread > 0 {
                    Text("\(unread)").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.onAccent)
                        .padding(.horizontal, 6).frame(height: 17).background(theme.gradient, in: .capsule)
                }
                if active { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.gradient) }
            }
            .padding(6)
            .background(active ? Ink.raised.opacity(0.8) : .clear, in: .rect(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let persona = model.createPersona(name: trimmed) else { return }
        model.switchPersona(persona.id)
        done()
    }
}
