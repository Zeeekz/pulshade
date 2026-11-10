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
        .overlay { PersonaSwitchOverlay() }
        .animation(.smooth(duration: 0.3), value: model.call == nil)
        // A glowing picture anywhere in the app plays its story from here.
        .background {
            Color.clear.viewerCover(item: Binding(get: { model.storyToOpen }, set: { model.storyToOpen = $0 })) { reel in
                StoryViewer(stories: reel.stories, start: reel.start, following: reel.following, preceding: reel.preceding)
            }
        }
    }
}

#if os(iOS)
/// The story camera sliding in from the left of the chats, under the finger, as on Instagram.
@Observable final class CameraSlide {
    /// How far in the camera is, 0 to 1. Nil when it's away (and not running).
    var progress: CGFloat?
    /// The screen's width, which a full slide covers.
    var width: CGFloat = 390
    /// A drag has taken hold and is moving the camera.
    var dragging = false

    func settle(open: Bool) {
        dragging = false
        withAnimation(.spring(duration: 0.35, bounce: 0.05)) {
            progress = open ? 1 : 0
        } completion: { [self] in
            if !open, !dragging, progress == 0 { progress = nil }
        }
    }
}

/// iPhone: tabs along the bottom, chats pushed onto a navigation stack.
private struct PhoneMainView: View {
    @Environment(AppModel.self) private var model
    @State private var slide = CameraSlide()
    @State private var section: Section = .chats
    @State private var selection: Conversation.ID?
    @State private var switchingPersona = false
    @State private var screenHeight: CGFloat = 800

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
            .badge(model.unreadInView)
            Tab("Contacts", systemImage: "person.2", value: Section.contacts) {
                ContactsView(openChat: open).background(Ink.base)
            }
            .badge(model.requests.count)
            Tab("Burn", systemImage: "flame", value: Section.burn) {
                LeaveView().background(Ink.base)
            }
            // Your account: its picture is the tab. A tap opens settings; double-tapping it switches to your next persona, and holding it picks one or adds one.
            Tab(value: Section.settings) {
                SettingsView().background(Ink.base)
            } label: {
                Label { Text("Account") } icon: { accountIcon }
            }
        }
        .tint(model.theme.accent)
        // The chats give way a little as the camera comes across them.
        .offset(x: (slide.progress ?? 0) * slide.width * 0.3)
        .overlay {
            if let progress = slide.progress {
                StoryCamera(close: { slide.settle(open: false) })
                    .offset(x: -(1 - progress) * slide.width)
                    // Swipe left on the picture to put the camera away, following the finger like opening it.
                    // The bottom controls (looks, shutter) keep their own touches.
                    .simultaneousGesture(DragGesture(minimumDistance: 20, coordinateSpace: .global)
                        .onChanged { drag in
                            let dx = drag.translation.width, dy = drag.translation.height
                            if !slide.dragging {
                                guard dx < -24, abs(dx) > abs(dy) * 2, drag.startLocation.y < screenHeight - 230 else { return }
                                slide.dragging = true
                            }
                            slide.progress = min(max(1 + dx / slide.width, 0), 1)
                        }
                        .onEnded { drag in
                            guard slide.dragging else { return }
                            let shut = drag.translation.width < -slide.width * 0.33 || drag.predictedEndTranslation.width < -slide.width * 0.6
                            if shut { Haptics.tick() }
                            slide.settle(open: !shut)
                        })
                    .accessibilityHidden(progress < 1)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { slide.width = max($0, 1) }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { screenHeight = $0 }
        .environment(slide)
        .inAppBanners()
        .onChange(of: section, initial: true) {
            model.onChatsTab = section == .chats
            if section == .chats { model.dismissBanner() }
        }
        .background(TabHold(tab: 3, action: { switchingPersona = true }, doubleTap: { model.switchToNextPersona() }))
        .sheet(isPresented: $switchingPersona) {
            PersonaSwitcher(done: { switchingPersona = false })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #if DEBUG
        .onAppear {
            // Screenshots: PULSHADE_DEMO_SCREEN=contacts|burn|settings|chat opens that screen (Invite is a page in Account: PULSHADE_DEMO_SETTINGS=invite).
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
        // Switching persona closes a chat that belongs to another: what's on screen must always be the persona that
        // sends.
        .onChange(of: model.activePersona) {
            if let open = selection, let c = model.conversation(open), !model.belongsHere(c) { selection = nil }
        }
    }

    private func open(_ id: Conversation.ID) {
        model.becomeOwner(of: id)
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
    /// A quick double tap on the same tab, if it should do something.
    var doubleTap: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.coordinator = context.coordinator
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        context.coordinator.tab = tab
        context.coordinator.action = action
        context.coordinator.doubleTap = doubleTap
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
        var doubleTap: (() -> Void)?
        static let name = "pulshade.tabhold"
        static let doubleName = "pulshade.tabdouble"

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
            // The tap still selects the tab; this only notices the second one.
            for b in buttons where b.frame == target && !(b.view.gestureRecognizers ?? []).contains(where: { $0.name == Self.doubleName }) {
                let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
                tap.name = Self.doubleName
                tap.numberOfTapsRequired = 2
                tap.cancelsTouchesInView = false
                tap.delegate = self
                b.view.addGestureRecognizer(tap)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func doubleTapped(_ tap: UITapGestureRecognizer) {
            guard tap.state == .ended else { return }
            doubleTap?()
        }

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
        #if DEBUG
        .onAppear {
            // Screenshots: PULSHADE_DEMO_CHAT=Kai opens the chat with that title.
            if AppModel.demoRequested, let title = ProcessInfo.processInfo.environment["PULSHADE_DEMO_CHAT"],
               let chat = model.data.conversations.first(where: { $0.title == title }) { selection = chat.id }
            // PULSHADE_DEMO_SCREEN=settings (or contacts, burn, people) opens that section.
            if AppModel.demoRequested, let name = ProcessInfo.processInfo.environment["PULSHADE_DEMO_SCREEN"],
               let wanted = Section(rawValue: name) { section = wanted }
        }
        #endif
        .onChange(of: model.requestedConversation, initial: true) { _, id in
            guard let id, model.conversation(id) != nil else { return }
            model.becomeOwner(of: id)
            withAnimation(.smooth) {
                section = .chats
                selection = id
            }
            model.markRead(id)
            model.requestedConversation = nil
        }
        // Switching persona closes a chat that belongs to another: what's on screen must always be the persona that
        // sends.
        .onChange(of: model.activePersona) {
            if let open = selection, let c = model.conversation(open), !model.belongsHere(c) { selection = nil }
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
    /// The burn sheet, which only goes ahead once BURN is typed.
    @State private var burningAccount = false
    /// How tall the search bar and stories are together, so the list can snap past them.
    @State private var storiesHeight: CGFloat = 0
    /// Where the story strip is on screen, kept out of view state: it changes with every scroll frame.
    @State private var stripBox = FrameBox()
    #if os(iOS)
    @Environment(CameraSlide.self) private var slide
    #endif

    private var items: [Conversation] {
        model.sortedConversations.filter { c in
            (filter == nil || c.kind == filter) &&
                (search.isEmpty || c.title.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Lock and burn on the left, scan and a new chat on the right, and the title between them.
            HStack(spacing: 8) {
                Button { Haptics.tick(); model.lock() } label: { Image(systemName: "lock.fill") }
                    .buttonStyle(BarButtonStyle())
                    .help("Lock Pulshade")
                    .accessibilityLabel("Lock")
                Button { burningAccount = true } label: { Image(systemName: "flame.fill") }
                    .buttonStyle(BarButtonStyle(tint: AnyShapeStyle(Burn.gradient)))
                    .help("Burn your account")
                    .accessibilityLabel("Burn")
                Spacer(minLength: 4)
                Menu {
                    Button("Clear all chats…", role: .destructive) { confirmClear = true }
                        .disabled(model.clearableChats.isEmpty)
                } label: {
                    HStack(spacing: 4) {
                        Text("Chats").font(.system(size: 20, weight: .bold)).foregroundStyle(Ink.text)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.faint)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Chats, more")
                Spacer(minLength: 4)
                Button { scanningCode = true } label: { Image(systemName: "qrcode.viewfinder") }
                    .buttonStyle(BarButtonStyle())
                    .help("Scan a code")
                    .accessibilityLabel("Scan a code")
                Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(BarButtonStyle(prominent: true))
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
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("chatlist")) } action: { stripBox.rect = $0 }
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
            // Pull down to check for new messages now.
            .refreshable { await model.refresh() }
            .coordinateSpace(.named("chatlist"))
            #if os(iOS)
            // Swipe right on the chats, as "back" from the first page, and the story camera opens, as on Instagram.
            // A swipe that starts on the story strip scrolls the strip instead.
            // It follows the finger: let go past a third of the way (or with a flick) and it comes all the way in.
            .simultaneousGesture(DragGesture(minimumDistance: 20, coordinateSpace: .named("chatlist"))
                .onChanged { drag in
                    let dx = drag.translation.width, dy = drag.translation.height
                    if !slide.dragging {
                        guard slide.progress == nil, dx > 24, abs(dx) > abs(dy) * 2,
                              !stripBox.rect.contains(drag.startLocation) else { return }
                        slide.dragging = true
                    }
                    slide.progress = min(max(dx / slide.width, 0), 1)
                }
                .onEnded { drag in
                    guard slide.dragging else { return }
                    let open = drag.translation.width > slide.width * 0.33 || drag.predictedEndTranslation.width > slide.width * 0.6
                    if open { Haptics.tick() }
                    slide.settle(open: open)
                })
            #endif
        }
        .sheet(isPresented: $burningAccount) { BurnSheet() }
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
                StoryViewer(stories: reel.stories, start: reel.start, following: reel.following, preceding: reel.preceding)
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
            ChatRow(conversation: c, selected: selection == c.id) { viewingStory = $0 }
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
    /// Opens their story when the picture is tapped and they have one.
    var openStory: (StoryReel) -> Void = { _ in }
    @State private var hover = false
    /// Rows are roomier on the phone, like Telegram's and WhatsApp's; the Mac's sidebar is narrower.
    private var avatarSize: CGFloat { Platform.isPhone ? 56 : 46 }
    private var titleSize: CGFloat { Platform.isPhone ? 16.5 : 14.5 }
    private var lineSize: CGFloat { Platform.isPhone ? 15 : 13.5 }
    private var stampSize: CGFloat { Platform.isPhone ? 12.5 : 11.5 }

    /// Their live stories, when this is a one-to-one chat with someone who has posted.
    private var stories: [Story] {
        guard conversation.kind == .direct, let fp = conversation.members.first else { return [] }
        return model.friendStories.first { $0.author == fp }?.stories ?? []
    }

    var body: some View {
        let c = conversation
        let stories = stories
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Avatar(image: c.avatar ?? (c.kind == .direct ? model.contact(c.members.first ?? "")?.avatar : nil),
                       seed: c.kind == .direct ? (c.members.first ?? c.id.uuidString) : c.id.uuidString,
                       size: avatarSize, symbol: c.kind == .direct ? nil : c.kind.symbol, showsStory: false)
                    .overlay {
                        if c.kind == .direct, let fp = c.members.first {
                            Circle().strokeBorder(model.signature(fp).opacity(0.8), lineWidth: 1.5).padding(-2.5)
                        }
                    }
                    .overlay {
                        if !stories.isEmpty {
                            let fresh = stories.contains { !$0.seen }
                            Circle().strokeBorder(fresh ? theme.accent : Ink.faint, lineWidth: 2.5).padding(-5)
                                .shadow(color: theme.accent.opacity(fresh ? 0.85 : 0), radius: fresh ? 5 : 0)
                        }
                    }
                    .contentShape(Circle())
                    .onTapGesture {
                        guard !stories.isEmpty else { return }
                        Haptics.tick()
                        openStory(StoryReel(stories: stories, start: stories.firstIndex { !$0.seen } ?? 0))
                    }
                    .accessibilityAddTraits(stories.isEmpty ? [] : .isButton)
                if let burner = model.burner(c.persona) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Burn.gradient, in: .circle)
                        .overlay(Circle().strokeBorder(Ink.base, lineWidth: 2))
                        .offset(x: 3, y: 3)
                        .help("Burns \(burner.burnsAt!.formatted(.relative(presentation: .named)))")
                } else if c.kind != .direct {
                    SymbolBadge(symbol: c.kind.symbol, size: 20).offset(x: 3, y: 3)
                } else if let fp = c.members.first, model.isOnline(fp) {
                    OnlineDot(size: 14).offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(c.title)
                        .font(.system(size: titleSize, weight: .semibold))
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                    if c.kind == .direct { BadgeMark(badge: model.contact(c.members.first ?? "")?.badge, size: titleSize) }
                    if stories.contains(where: { !$0.seen }) {
                        Text("New story")
                            .font(.system(size: stampSize - 1.5, weight: .semibold))
                            .foregroundStyle(Ink.onAccent.opacity(0.9))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(theme.accent, in: .capsule)
                    }
                    if c.muted { Image(systemName: "bell.slash.fill").font(.system(size: 10)).foregroundStyle(Ink.faint) }
                    Spacer(minLength: 4)
                    // Like Telegram: your own last message's ticks sit beside the time, top right.
                    if let last = c.messages.last, last.isMine {
                        StatusTicks(status: last.status).foregroundStyle(Ink.faint)
                    }
                    Text(c.lastActivity.chatStamp)
                        .font(.system(size: stampSize))
                        .foregroundStyle(Ink.faint)
                }
                HStack(spacing: 6) {
                    if let last = c.messages.last {
                        if last.image != nil { Image(systemName: "photo").font(.system(size: lineSize - 2)).foregroundStyle(Ink.dim) }
                        if last.voice != nil { Image(systemName: "waveform").font(.system(size: lineSize - 2)).foregroundStyle(Ink.dim) }
                        if last.expiresAt != nil || c.disappearAfter != nil {
                            Image(systemName: "timer").font(.system(size: 10)).foregroundStyle(Ink.faint)
                        }
                        Text(last.text.isEmpty ? (last.voice != nil ? "Voice message" : last.image != nil ? "Photo" : "") : last.text)
                            .font(.system(size: lineSize))
                            .foregroundStyle(Ink.dim)
                            .lineLimit(1)
                    } else {
                        Text("No messages yet").font(.system(size: lineSize)).foregroundStyle(Ink.faint)
                    }
                    Spacer(minLength: 4)
                    if c.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Ink.faint) }
                    if c.unread > 0 {
                        Text("\(c.unread)")
                            .font(.system(size: stampSize, weight: .semibold))
                            .foregroundStyle(Ink.onAccent.opacity(0.85))
                            .padding(.horizontal, 7).frame(minWidth: 21, minHeight: 21)
                            .background(c.muted ? Ink.faint : theme.accent, in: .capsule)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Platform.isPhone ? 11 : 9)
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
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("Create persona")
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
                Text("Up to \(AppModel.personaLimit) personas besides your main. Burn one to make another.")
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

/// A rectangle that can change without redrawing anything that holds it.
private final class FrameBox {
    var rect = CGRect.null
}


/// A short animation over the app when you switch persona: the app dims and blurs, the new persona's picture rises into
/// the middle with a ring that opens round it and its name beneath, then it all lets go. Touches go through it.
private struct PersonaSwitchOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        ZStack {
            if let flash = model.personaFlash, shown {
                Rectangle().fill(.ultraThinMaterial).overlay(Color.black.opacity(0.25))
                    .ignoresSafeArea()
                    .transition(.opacity)
                VStack(spacing: 14) {
                    ZStack {
                        Circle().strokeBorder(theme.accent.opacity(0.5), lineWidth: 2)
                            .frame(width: 128, height: 128)
                            .scaleEffect(shown ? 1.25 : 0.8).opacity(shown ? 0 : 1)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.9), value: shown)
                        Avatar(image: flash.avatar, seed: flash.seed, size: 96, showsStory: false)
                            .overlay(Circle().strokeBorder(theme.accent, lineWidth: 3).padding(-5))
                            .shadow(color: theme.accent.opacity(0.6), radius: 24)
                    }
                    VStack(spacing: 2) {
                        Text(flash.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(Ink.text)
                        Text(flash.isMain ? "Main account" : "Persona").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.dim)
                    }
                }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Switched to \(flash.name)")
            }
        }
        .allowsHitTesting(false)
        .onChange(of: model.personaFlash) { _, flash in
            guard flash != nil else { return }
            Haptics.tick()
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.3)) { shown = true }
        }
        .task(id: model.personaFlash?.id) {
            guard model.personaFlash != nil else { return }
            try? await Task.sleep(for: .seconds(1.0))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { shown = false }
            try? await Task.sleep(for: .seconds(0.35))
            if !Task.isCancelled { model.personaFlash = nil }
        }
    }
}
