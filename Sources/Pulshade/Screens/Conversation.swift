import SwiftUI
import UniformTypeIdentifiers
#if canImport(PulshadeShared)
import PulshadeShared
#endif
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let id: Conversation.ID
    @State private var draft = ""
    /// The message being forwarded, while the chat picker is up.
    @State private var forwarding: Message?
    /// Someone in the chat whose profile is open (tapped their name).
    @State private var profileOf: MemberRef?
    @State private var attachments: [Data] = []
    /// A video for the next message, while it's made ready and once it is.
    @State private var videoDraft: VideoDraft?
    @State private var videoTask: Task<Void, Never>?
    @State private var takingPhoto = false
    /// What was left out of a pick from the library (a second video, one that wouldn't load), said once.
    @State private var mediaNote: String?
    @State private var choosingFile = false
    /// A file picked to send, waiting for "send" or "send with its name" (see `FileScrub`).
    @State private var pickedFile: URL?
    @State private var quickSending = false
    @State private var showInfo = false
    @State private var verifying = false
    @State private var confirmingAllow = false
    /// Their picture at full size, opened from the header on the phone.
    @State private var headerPicture: Data?
    @State private var recorder = VoiceRecorder()
    @State private var replyingTo: Message?
    @State private var draftPreview: LinkPreview?
    /// People picked from the "@" list for the message being written.
    @State private var picks: [(fingerprint: String, name: String)] = []
    @State private var dismissedPreview: String?
    @State private var previewTask: Task<Void, Never>?
    @State private var flash: UUID?
    /// The chat follows the bottom as it fills and settles, until you scroll away from it yourself.
    @State private var pinnedToEnd = true
    /// The first moment after the chat opens, while its rows are still being measured.
    @State private var opening = true
    /// Updated every scroll frame, so it lives outside view state: only crossing the threshold redraws.
    @State private var scrollTrack = ScrollTrack()
    @State private var showJumpDown = false
    @State private var unreadBelow = 0
    @State private var swipe: (id: UUID, dx: CGFloat)?
    /// A message held on the phone, lifted over the chat with its reactions and actions.
    @State private var lifted: LiftedMessage?
    /// A short note over the chat after saving a video from the hold menu.
    @State private var saveNotice: (text: String, symbol: String)?
    /// A video from the hold menu, waiting on the warning about saving it out of Pulshade.
    @State private var videoToSave: Data?
    @FocusState private var focused: Bool

    /// How far a swipe has to travel before letting go starts a reply.
    private let replyThreshold: CGFloat = 56

    var body: some View {
        // Only a chat of the persona you're using now: never show one identity's chat (and its composer) while another
        // is active, or what you write would go out as someone you don't think you are.
        if let c = model.conversation(id), model.belongsHere(c) {
            VStack(spacing: 0) {
                header(c)
                verifyPrompt(c)
                messages(c)
                if model.canPost(in: c) { composer(c) } else { ReadOnlyBar(kind: c.kind, announcements: c.isAnnouncements, oldFormat: c.isOldFormat, needsUpdate: model.peerNeedingUpdate(in: c), reason: model.cantPostReason(in: c)) }
            }
            .overlay { if let lifted { focus(lifted, in: c) } }
            .saveWarning(isPresented: Binding(get: { videoToSave != nil }, set: { if !$0 { videoToSave = nil } }), kind: "video") {
                if let clip = videoToSave { saveVideo(clip) }
            }
            .overlay(alignment: .top) {
                if let saveNotice {
                    Label(saveNotice.text, systemImage: saveNotice.symbol)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.text)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: .capsule)
                        .padding(.top, 70)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // Fills the whole screen, keyboard or not, so the background doesn't jump when it opens.
            .background { ChatBackdrop(background: model.data.chatBackground, theme: model.theme).equatable().ignoresSafeArea() }
            .onAppear {
                model.openConversation = id
                model.markRead(id)
                #if DEBUG
                // Screenshots: PULSHADE_DEMO_INFO=1 opens the chat's details.
                if AppModel.demoRequested, ProcessInfo.processInfo.environment["PULSHADE_DEMO_INFO"] != nil { showInfo = true }
                #endif
                #if os(iOS)
                KeyboardDismisser.shared.enabled = false
                #endif
            }
            .onDisappear {
                if model.openConversation == id { model.openConversation = nil }
                recorder.cancel()
                previewTask?.cancel()
                #if os(iOS)
                KeyboardDismisser.shared.enabled = true
                #endif
            }
            .onChange(of: c.messages.count) { model.markRead(id) }
            .sheet(isPresented: $showInfo) { ConversationInfo(id: id) }
            .sheet(item: $profileOf) { MemberProfileSheet(fingerprint: $0.fingerprint, conversation: id) }
            .sheet(item: $forwarding) { m in
                ForwardSheet(message: m, from: id).presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $quickSending) {
                QuickSendSheet(conversation: id).presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: Header

    private func header(_ c: Conversation) -> some View {
        ZStack {
            // The name sits in the middle of the bar, whatever is on either side.
            Button { showInfo = true } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 5) {
                        Text(c.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Ink.text)
                            .lineLimit(1)
                        if c.isAnnouncements { Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(theme.accent) }
                        if c.kind == .direct, model.contact(c.members.first ?? "")?.verified == true {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(theme.accent)
                        }
                    }
                    let here = c.kind == .direct && c.members.first.map(model.isOnline) == true
                    let waitingSince = c.kind == .direct ? c.members.first.flatMap(model.keysPendingSince) : nil
                    // New keys are on their way: messages queue and go by themselves, so nothing is said for the first
                    // few minutes, and then only a quiet "Sending soon".
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in
                        let slow = waitingSince.map { timeline.date.timeIntervalSince($0) > AppModel.keysQuietFor } ?? false
                        Group {
                            if slow {
                                Label("Sending soon", systemImage: "clock").labelStyle(.titleAndIcon)
                            } else {
                                Text(here ? "Online" : subtitle(c))
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(here && !slow ? OnlineDot.color : Ink.faint)
                        .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 96)
            .accessibilityLabel("\(c.title), details")

            HStack(spacing: 8) {
                Button { dismiss() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(BarButtonStyle())
                    .accessibilityLabel("Back")
                // Their picture beside the back button: an unwatched story opens first (the picture does that itself),
                // otherwise their profile. A group's or channel's own picture still opens full size.
                let picture = c.avatar ?? (c.kind == .direct ? model.contact(c.members.first ?? "", in: c.persona)?.avatar : nil)
                Button {
                    if c.kind != .direct, let picture { headerPicture = picture } else { showInfo = true }
                } label: {
                    Avatar(image: picture, seed: c.kind == .direct ? (c.members.first ?? "") : c.id.uuidString,
                           size: 34, symbol: c.kind == .direct ? nil : c.kind.symbol)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(c.kind != .direct && picture != nil ? "\(c.title), picture" : "\(c.title), profile")
                Spacer(minLength: 0)
                if let burner = model.burner(c.persona), let at = burner.burnsAt {
                    HStack(spacing: 5) {
                        Image(systemName: "flame.fill")
                        Text(at, style: .timer).monospacedDigit()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Burn.gradient)
                    .padding(.horizontal, 10).frame(height: 28)
                    .glass(8)
                    .help("This burner destroys itself when the timer ends")
                }
                if c.kind == .direct, let peer = c.members.first, model.contact(peer, in: c.persona) != nil {
                    Button { model.startCall(with: peer, persona: c.persona) } label: { Image(systemName: "phone.fill") }
                        .buttonStyle(BarButtonStyle())
                        .disabled(model.call != nil)
                        .help("Call")
                        .accessibilityLabel("Call")
                }
                if c.kind == .direct || (c.kind == .group && !c.isOldFormat) { TimerMenu(conversation: c) }
                // The relay indicator only speaks up when something is wrong.
                if model.link != .online { LinkBadge() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Ink.base)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
        .modifier(ImageViewerCover(isPresented: Binding(get: { headerPicture != nil }, set: { if !$0 { headerPicture = nil } }),
                                   data: headerPicture ?? Data()))
    }

    /// For a friend added in the last two weeks and not verified yet: a short line asking to compare the Pulse check, the
    /// one thing that proves nobody stood in the middle when you connected. Put away until the app is next opened, and gone
    /// for good once verified.
    @ViewBuilder private func verifyPrompt(_ c: Conversation) -> some View {
        if c.kind == .direct, let fp = c.members.first, model.heldDevices(of: fp, persona: c.persona) > 0 {
            // A device their account added while "ask before new devices" is on: your messages wait for it until you say.
            HStack(spacing: 10) {
                Image(systemName: "iphone.gen3").foregroundStyle(Color.orange)
                Text("\(model.displayName(fp))'s account added a new device. Nothing goes to it, and none of its messages are shown, until you allow it. Not sure? Ask them another way first, in person or by call.")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Allow") { confirmingAllow = true }
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Ink.raised)
            .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
            .transition(.move(edge: .top).combined(with: .opacity))
            .confirmationDialog("Let \(model.displayName(fp))'s new device have your messages?", isPresented: $confirmingAllow, titleVisibility: .visible) {
                Button("Allow") { withAnimation(.snappy) { model.allowHeldDevices(of: fp, persona: c.persona) } }
                Button("Not yet", role: .cancel) {}
            } message: {
                Text("What waited for it goes now, and what it sent is shown. Only allow it if they told you it's theirs.")
            }
        } else if c.kind == .direct, let fp = c.members.first, let peer = model.contact(fp, in: c.persona),
           !peer.verified, !peer.isSelf, !peer.hidden, Date().timeIntervalSince(peer.addedAt) < 14 * 86_400,
           !model.verifyPromptDismissed.contains(fp) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield").foregroundStyle(theme.accent)
                Text("Compare your Pulse check with \(model.displayName(fp)) to be sure it's really them.")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Compare") { verifying = true }
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                Button { withAnimation(.snappy) { _ = model.verifyPromptDismissed.insert(fp) } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.faint)
                    .accessibilityLabel("Not now")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Ink.raised)
            .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
            .sheet(isPresented: $verifying) { PulseCheckView(fingerprint: fp, persona: c.persona) }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func subtitle(_ c: Conversation) -> String {
        switch c.kind {
        case .direct: "End-to-end encrypted"
        case .group: "\(c.members.count + 1) members"
        case .channel where c.isAnnouncements: "@\(Announcement.handle) · Official"
        case .channel: c.amAdmin ? counted(model.followers(of: c).count, "follower") : "Channel"
        case .broadcast: "Broadcast to \(c.members.count)"
        }
    }

    // MARK: Messages

    /// One message's bubble. The copy lifted over the chat (`focus`) is drawn by the same code, with nothing to tap.
    private func bubble(_ m: Message, prev: Message?, next: Message?, in c: Conversation, unsent: Set<UUID>,
                        proxy: ScrollViewProxy?, copy: Bool = false) -> Bubble {
        Bubble(message: m, kind: c.kind,
               senderName: m.isMine ? nil : model.displayName(m.sender),
               senderAvatar: m.isMine ? nil : model.contact(m.sender)?.avatar,
               tint: model.signature(m.sender),
               quoteAuthor: m.reply.flatMap { $0.author.isEmpty ? nil : ($0.author == "me" ? "You" : model.displayName($0.author)) },
               first: prev?.sender != m.sender || prev?.isSystem == true,
               last: next?.sender != m.sender,
               canReact: c.kind != .broadcast,
               highlighted: !copy && flash == m.id,
               swipe: !copy && swipe?.id == m.id ? swipe?.dx ?? 0 : 0,
               react: { model.react($0, to: m.id, in: id) },
               reply: { startReply(m) },
               getMedia: { model.getMediaAnyway(messageID: m.id, in: id) },
               unsend: { model.unsend(m.id, in: id) },
               jump: { target in if let proxy { jump(to: target, proxy: proxy) } },
               notSent: unsent.contains(m.id),
               retry: { model.retrySend(m.id, in: id) },
               canForward: model.canForward(m, in: c),
               canCopy: model.canCopy(m),
               forward: { forwarding = m },
               openSender: { profileOf = MemberRef(fingerprint: m.sender) },
               lift: copy ? nil : { frame in
                   guard lifted == nil, swipe == nil else { return }
                   lifted = LiftedMessage(id: m.id, frame: frame)
               },
               isLifted: !copy && lifted?.id == m.id)
    }

    /// The held message over the blurred chat, with its reactions and what can be done with it.
    @ViewBuilder private func focus(_ held: LiftedMessage, in c: Conversation) -> some View {
        if let i = c.messages.firstIndex(where: { $0.id == held.id }) {
            let m = c.messages[i]
            let unsent = model.unsentMessages
            MessageFocus(frame: held.frame,
                         lead: !m.isMine && c.kind == .group ? 34 : 0,
                         mine: m.isMine,
                         current: m.reactions["me"],
                         canReact: c.kind != .broadcast,
                         actions: focusActions(m, in: c, notSent: unsent.contains(m.id)),
                         content: AnyView(bubble(m, prev: i > 0 ? c.messages[i - 1] : nil,
                                                 next: i + 1 < c.messages.count ? c.messages[i + 1] : nil,
                                                 in: c, unsent: unsent, proxy: nil, copy: true)),
                         react: { model.react($0, to: m.id, in: id) },
                         close: { lifted = nil })
                .transition(.identity)
        }
    }

    private func saveVideo(_ clip: Data) {
        Task {
            let outcome = await VideoSaver.save(clip)
            if outcome == .saved { Haptics.tick() }
            guard let said = VideoSaver.notice(outcome) else { return }
            withAnimation(.snappy) { saveNotice = said }
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut) { saveNotice = nil }
        }
    }

    private func focusActions(_ m: Message, in c: Conversation, notSent: Bool) -> [MessageFocus.Action] {
        var actions: [MessageFocus.Action] = []
        if notSent && m.isMine {
            actions.append(.init(title: "Try sending again", symbol: "arrow.clockwise") { model.retrySend(m.id, in: id) })
        }
        actions.append(.init(title: "Reply", symbol: "arrowshape.turn.up.left") { startReply(m) })
        if model.canForward(m, in: c) {
            actions.append(.init(title: "Forward", symbol: "arrowshape.turn.up.right") { forwarding = m })
        }
        if let wallet = Bubble.wallet(in: m) {
            actions.append(.init(title: "Copy address", symbol: "doc.on.doc") { copyToClipboard(wallet.address, clearAfter: 120) })
        } else if !m.text.isEmpty, model.canCopy(m) {
            actions.append(.init(title: "Copy", symbol: "doc.on.doc") { copyToClipboard(m.text, clearAfter: 60) })
        }
        if let clip = model.videoData(for: m), !clip.isEmpty, model.canCopy(m) {
            actions.append(.init(title: "Save video", symbol: "arrow.down.to.line") {
                if model.data.security.warnBeforeSaving { videoToSave = clip } else { saveVideo(clip) }
            })
        }
        if m.isMine {
            actions.append(.init(title: "Unsend for everyone", symbol: "trash", destructive: true) { model.unsend(m.id, in: id) })
        }
        return actions
    }

    private func messages(_ c: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if c.messages.isEmpty && c.isAnnouncements {
                        Constellation(symbol: "megaphone", text: "News from PULSHADE shows up here")
                            .padding(.top, 120)
                    } else if c.messages.isEmpty {
                        Constellation(symbol: "lock", text: "Messages here are end-to-end encrypted")
                            .padding(.top, 120)
                    }
                    let unsent = model.unsentMessages
                    ForEach(Array(c.messages.enumerated()), id: \.element.id) { i, m in
                        let prev = i > 0 ? c.messages[i - 1] : nil
                        let next = i + 1 < c.messages.count ? c.messages[i + 1] : nil
                        // One view per message, its day marker inside it, so the list measures and moves each row
                        // as a whole instead of rows that come and go beside it.
                        VStack(spacing: 0) {
                            if prev.map({ m.date.timeIntervalSince($0.date) > 3600 }) ?? true {
                                DayPill(date: m.date).padding(.vertical, 14)
                            }
                            if m.isSystem {
                                SystemPill(text: m.text).padding(.vertical, 8)
                            } else {
                                bubble(m, prev: prev, next: next, in: c, unsent: unsent, proxy: proxy)
                                    .equatable()
                            }
                        }
                        .id(m.id)
                        .modifier(PhoneSwipe(enabled: !m.isSystem, gesture: swipeGesture(for: m)))
                        .transition(messageTransition)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 16)
                TypingDots(names: model.typers(in: id).map(model.displayName))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .id("typing")
                Color.clear.frame(height: 1).id("end")
            }
            .scrollIndicators(.automatic)
            // Opens at the newest message, and a short chat sits at the bottom like any messenger.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            // Following the bottom, like other messengers: whenever the chat or its window changes size (a new
            // message, the three dots, the keyboard, the text box growing as you type, a photo measured late) and
            // you were at or near the newest message, it moves down with it. Scrolled up to read, it stays where you
            // are. Never while your finger is on it. This is the one place that moves the chat on its own, so
            // nothing fights it.
            .onScrollGeometryChange(for: ScrollShape.self) {
                ScrollShape(content: $0.contentSize.height, container: $0.containerSize.height, bottom: $0.visibleRect.maxY)
            } action: { old, new in
                scrollTrack.distance = new.content - new.bottom
                guard new.content != old.content || new.container != old.container, !scrollTrack.touching else { return }
                let wasNear = old.content - old.bottom < 120
                guard pinnedToEnd || wasNear else { return }
                // Rows are only measured as they come into view, so a chat that has just opened settles from a guess:
                // straight there, not in a glide.
                if opening {
                    proxy.scrollTo("end", anchor: .bottom)
                } else {
                    withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            .onAppear {
                opening = true
                DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { opening = false }
            }
            .onScrollGeometryChange(for: Bool.self) { $0.contentSize.height - $0.visibleRect.maxY > 320 } action: { _, far in
                if showJumpDown != far { withAnimation(.snappy(duration: 0.2)) { showJumpDown = far } }
                if !far { unreadBelow = 0 }
            }
            .onScrollPhaseChange { old, new in
                scrollTrack.touching = new == .interacting || new == .decelerating
                if new == .interacting { opening = false }
                if new == .interacting, pinnedToEnd { pinnedToEnd = false }
                if new == .idle, old == .interacting || old == .decelerating {
                    let near = scrollTrack.distance < 80
                    if pinnedToEnd != near { pinnedToEnd = near }
                }
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { focused = false }
            #endif
            .onChange(of: c.messages.count) { old, new in
                guard new > old, let last = c.messages.last else { return }
                // Near the bottom, following it (above) brings a new message into view. Scrolled up to read, it
                // waits below with a count, except your own, which takes you down to it.
                if last.isMine, !pinnedToEnd {
                    pinnedToEnd = true
                    unreadBelow = 0
                    withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo("end", anchor: .bottom) }
                } else if !pinnedToEnd, !last.isMine, !last.isSystem {
                    unreadBelow += 1
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // Only once you've scrolled up yourself: while the chat follows the bottom it can be far from it for
                // a moment (a tall photo arriving, a chat still settling as it opens), and the button flashed up.
                if showJumpDown && !pinnedToEnd {
                    Button {
                        pinnedToEnd = true
                        unreadBelow = 0
                        withAnimation(.smooth(duration: 0.35)) { proxy.scrollTo("end", anchor: .bottom) }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Ink.text)
                                .frame(width: 40, height: 40)
                                .background(Ink.raised, in: .circle)
                                .overlay(Circle().strokeBorder(Ink.line))
                                .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                            if unreadBelow > 0 {
                                Text(unreadBelow > 99 ? "99+" : "\(unreadBelow)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Ink.onAccent)
                                    .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                                    .background(theme.accent, in: .capsule)
                                    .offset(x: 6, y: -6)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 14).padding(.bottom, 12)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel(unreadBelow > 0 ? "Scroll to latest, \(unreadBelow) new" : "Scroll to latest")
                }
            }
        }
    }

    private func jump(to target: UUID, proxy: ScrollViewProxy) {
        withAnimation(.smooth(duration: 0.35)) { proxy.scrollTo(target, anchor: .center) }
        withAnimation(.easeOut(duration: 0.2)) { flash = target }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.easeOut(duration: 0.6)) { if flash == target { flash = nil } }
        }
    }

    private func startReply(_ message: Message) {
        withAnimation(.snappy(duration: 0.25)) { replyingTo = message }
        focused = true
    }

    /// On iPhone: drag a message sideways to reply.
    private func swipeGesture(for message: Message) -> some Gesture {
        // Left only: a right swipe means "go back" on iPhone.
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard value.translation.width < 0, abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                swipe = (message.id, max(-110, value.translation.width))
            }
            .onEnded { value in
                if value.translation.width <= -replyThreshold, !message.isSystem { startReply(message) }
                withAnimation(.snappy(duration: 0.3)) { swipe = nil }
            }
    }

    // MARK: Composer

    /// What's typed after the last "@" when it starts a word, for picking someone to mention. Nil when not typing one.
    private var mentionQuery: String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let query = String(draft[draft.index(after: at)...])
        return query.count > 30 || query.contains(where: \.isNewline) ? nil : query
    }

    private func mentionSuggestions(_ c: Conversation) -> [Contact] {
        guard let query = mentionQuery else { return [] }
        let all = model.mentionable(in: c)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(all.prefix(5)) }
        let starts = all.filter { $0.displayName.localizedCaseInsensitiveContains(q) && $0.displayName.lowercased().hasPrefix(q.lowercased()) }
        let rest = all.filter { c in c.displayName.localizedCaseInsensitiveContains(q) && !starts.contains { $0.fingerprint == c.fingerprint } }
        return Array((starts + rest).prefix(5))
    }

    private func pick(_ contact: Contact) {
        guard let at = draft.lastIndex(of: "@") else { return }
        draft = String(draft[..<at]) + "@" + contact.displayName + " "
        picks.removeAll { $0.fingerprint == contact.fingerprint }
        picks.append((contact.fingerprint, contact.displayName))
    }

    private func composer(_ c: Conversation) -> some View {
        VStack(spacing: 8) {
            let suggestions = mentionSuggestions(c)
            if !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions, id: \.fingerprint) { person in
                        Button { pick(person) } label: {
                            HStack(spacing: 10) {
                                Text("@").foregroundStyle(theme.accent)
                                Text(person.displayName).foregroundStyle(Ink.text).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 14))
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Mention \(person.displayName)")
                    }
                }
                .background(Ink.raised, in: .rect(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let replyingTo {
                ComposerContext(symbol: "arrowshape.turn.up.left.fill",
                                title: replyingTo.isMine ? "Replying to yourself" : "Replying to \(model.displayName(replyingTo.sender))",
                                detail: AppModel.snippet(of: replyingTo),
                                image: model.imageData(for: replyingTo)) {
                    withAnimation(.snappy(duration: 0.2)) { self.replyingTo = nil }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let draftPreview {
                ComposerContext(symbol: "link", title: draftPreview.title ?? draftPreview.site ?? "Link",
                                detail: draftPreview.site ?? draftPreview.url, image: draftPreview.image) {
                    dismissedPreview = draftPreview.url
                    withAnimation(.snappy(duration: 0.2)) { self.draftPreview = nil }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !attachments.isEmpty || videoDraft != nil {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        if let videoDraft {
                            VideoDraftTile(draft: videoDraft) {
                                videoTask?.cancel()
                                withAnimation(.snappy) { self.videoDraft = nil }
                            }
                        }
                        ForEach(Array(attachments.enumerated()), id: \.offset) { i, data in
                            if let img = PlatformImage(data: data) {
                                Image(platformImage: img).resizable().scaledToFill()
                                    .frame(width: 84, height: 84).clipShape(.rect(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line))
                                    .overlay(alignment: .topTrailing) {
                                        Button {
                                            // `i` comes from a ForEach snapshot; a second tap can outlive a removal.
                                            guard attachments.indices.contains(i) else { return }
                                            withAnimation(.snappy) { _ = attachments.remove(at: i) }
                                        } label: { Image(systemName: "xmark") }
                                            .buttonStyle(IconButtonStyle(size: 22)).offset(x: 6, y: -6)
                                            .accessibilityLabel("Remove photo")
                                    }
                            }
                        }
                    }
                    .padding(.top, 8).padding(.trailing, 8)
                }
                .scrollIndicators(.never)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.scale(scale: 0.8, anchor: .bottomLeading).combined(with: .opacity))
            }
            if recorder.isRecording {
                RecordingBar(recorder: recorder, cancel: { withAnimation(.snappy) { recorder.cancel() } }, send: sendVoice)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    // Camera, files and pinned items behind one pulse button, so the text box gets the room.
                    // Pinned only shows when there's something pinned to send.
                    AttachMenu(hasPinned: !(model.activeProfile.links ?? []).isEmpty || !(model.activeProfile.notes ?? []).isEmpty,
                               camera: { takingPhoto = true },
                               library: chooseMedia,
                               file: { choosingFile = true },
                               pinned: { quickSending = true })

                    TextField("", text: $draft, prompt: Text(placeholder(c)).foregroundStyle(Ink.faint), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: Bubble.textSize))
                        .lineLimit(1...6)
                        // Autocorrect learns what you type and keeps it outside Pulshade's encryption.
                        .autocorrectionDisabled()
                        .focused($focused)
                        .padding(.leading, 16)
                        .padding(.trailing, 16)
                        .padding(.vertical, 9)
                        .frame(minHeight: Self.barHeight)
                        // Round ends, like other messengers: a pill on one line, softly rounded as it grows.
                        .background(Ink.raised, in: .rect(cornerRadius: Self.barHeight / 2, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Self.barHeight / 2, style: .continuous)
                                .strokeBorder(focused ? theme.accent.opacity(0.45) : Ink.line)
                        }
                        .animation(.easeOut(duration: 0.15), value: focused)
                        .onSubmit(send)
                        #if os(iOS)
                        // Pasted text keeps its paragraphs and lists (PastedText).
                        .onChange(of: focused, initial: true) { _, now in if now { ShapedPaste.attachToFocusedField() } }
                        #endif
                        .onChange(of: draft) { old, new in
                            if !new.isEmpty { model.noteTyping(in: id) }
                            refreshPreview(for: new, pasted: new.count - old.count >= 8)
                        }

                    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty && videoDraft == nil {
                        Button { Task { _ = await recorder.start() } } label: { Image(systemName: "mic") }
                            .buttonStyle(BarButtonStyle(size: Self.barHeight))
                            .help("Record a voice message")
                            .accessibilityLabel("Record voice note")
                            .transition(.opacity)
                    } else {
                        Button(action: send) { Image(systemName: "arrow.up") }
                            .buttonStyle(BarButtonStyle(prominent: true, size: Self.barHeight))
                            .keyboardShortcut(.return, modifiers: .command)
                            .accessibilityLabel("Send")
                            // A video still being made ready can't go yet.
                            .disabled(videoDraft?.preparing == true)
                            .opacity(videoDraft?.preparing == true ? 0.4 : 1)
                            .transition(.opacity)
                    }
                }
                .animation(.snappy(duration: 0.2), value: draft.isEmpty && attachments.isEmpty && videoDraft == nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Ink.base)
        .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
        .chatCamera(isPresented: $takingPhoto) { photos in
            withAnimation(.snappy) { attachments = Array((attachments + photos).prefix(10)) }
        } filmed: { clip, zoom in
            prepareVideo(clip, zoom)
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result { pickedFile = url }
        }
        .confirmationDialog("Send file", isPresented: Binding(get: { pickedFile != nil }, set: { if !$0 { pickedFile = nil } }),
                            titleVisibility: .visible, presenting: pickedFile) { url in
            Button("Send as \"\(FileScrub.neutralName(for: url, type: Self.fileType(url)))\"") { sendPicked(url, keepName: false) }
            Button("Send as \"\(url.lastPathComponent)\"") { sendPicked(url, keepName: true) }
            Button("Cancel", role: .cancel) { pickedFile = nil }
        } message: { url in
            Text(Self.fileNote(url))
        }
        .alert("Some of it wasn't added", isPresented: Binding(get: { mediaNote != nil }, set: { if !$0 { mediaNote = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(mediaNote ?? "") }
        .alert("Can't send that file", isPresented: Binding(get: { model.fileProblem != nil }, set: { if !$0 { model.fileProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.fileProblem ?? "") }
        .animation(.snappy(duration: 0.25), value: videoDraft)
        .animation(.snappy(duration: 0.25), value: recorder.isRecording)
        .animation(.snappy(duration: 0.25), value: attachments.count)
        .animation(.snappy(duration: 0.25), value: replyingTo?.id)
        .animation(.snappy(duration: 0.25), value: draftPreview)
    }

    private func sendPicked(_ url: URL, keepName: Bool) {
        model.sendFile(url, keepName: keepName, replyTo: replyingTo, in: id)
        replyingTo = nil
        pickedFile = nil
    }

    static func fileType(_ url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
    }

    /// What a picked file gives away besides what's in it, said before it goes.
    static func fileNote(_ url: URL) -> String {
        let name = "Its own name stays on this device unless you choose to send it."
        switch FileScrub.kind(of: fileType(url)) {
        case .image:
            return "Pulshade takes out the picture's hidden details (where and when it was taken, the camera or phone) before it goes. " + name
        case .mayCarryDetails:
            return "Documents, videos and other files can carry hidden details of their own, such as an author, edit history or a location, which Pulshade can't take out. Remove them first if they matter. " + name
        case .plain:
            return name
        }
    }

    /// The height of the text box on one line, and of the round buttons beside it.
    static let barHeight: CGFloat = 40

    private func placeholder(_ c: Conversation) -> String {
        switch c.kind {
        case .direct, .group: "Message"
        case .channel: "Post to followers"
        case .broadcast: "Broadcast to \(c.members.count)"
        }
    }

    /// Builds a preview for the first link in the draft once it's whole: pasted in (eight or more characters at once, so a
    /// suggested word or the ".com" key doesn't count), or typed and followed by a space or a new line. A link still being typed is never fetched (each half-typed address would be visited along the way).
    private func refreshPreview(for text: String, pasted: Bool) {
        previewTask?.cancel()
        guard model.data.security.linkPreviews, let url = LinkPreviews.firstLink(in: text) else {
            if draftPreview != nil { draftPreview = nil }
            return
        }
        guard url.absoluteString != draftPreview?.url, url.absoluteString != dismissedPreview else { return }
        guard pasted || LinkPreviews.linkIsFinished(in: text) else { return }
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let preview = await LinkPreviews.fetch(url), !Task.isCancelled,
                  LinkPreviews.firstLink(in: draft)?.absoluteString == preview.url else { return }
            draftPreview = preview
        }
    }

    /// Photos and a video from the library, picked together, go into the message being written like ones from the camera.
    private func chooseMedia() {
        let room = max(0, 10 - attachments.count)
        guard room > 0 || videoDraft == nil else {
            mediaNote = "This message already has 10 photos and a video. Send it, or remove some, to add more."
            return
        }
        ChatMediaPicker.present(limit: room + (videoDraft == nil ? 1 : 0), maxSide: 1600) { picked in
            var picked = picked
            let fits = min(picked.photos.count, max(0, 10 - attachments.count))
            picked.dropped += picked.photos.count - fits
            if fits > 0 {
                withAnimation(.snappy) { attachments += picked.photos.prefix(fits) }
            }
            if let clip = picked.clip { prepareVideo(clip, .none) }
            mediaNote = picked.note
        }
    }

    /// Shrinks a recorded or picked video to what a chat carries (30 seconds, its own shape), off the main thread;
    /// the tile shows a spinner until it's done.
    private func prepareVideo(_ clip: MemoryClip, _ zoom: ZoomTrack) {
        videoTask?.cancel()
        withAnimation(.snappy) { videoDraft = VideoDraft() }
        videoTask = Task {
            let made = await ChatVideo.prepare(clip, zoom: zoom)
            guard !Task.isCancelled else { return }
            if let made {
                videoDraft = VideoDraft(poster: made.poster, clip: made.clip, seconds: made.seconds, preparing: false)
            } else {
                videoDraft = VideoDraft(preparing: false, failed: true)
            }
        }
    }

    private func send() {
        let preview = draftPreview.flatMap { draft.contains($0.url) ? $0 : nil }
        if videoDraft?.preparing == true { return }
        if let video = videoDraft, let clip = video.clip {
            // The video takes the text and the reply; any photos follow as their own messages.
            model.sendVideo(clip, poster: video.poster, seconds: video.seconds, caption: draft, replyTo: replyingTo, in: id)
            for photo in attachments { model.send("", image: photo, in: id) }
        } else if videoDraft != nil, attachments.isEmpty,
                  draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Only a video that couldn't be read: nothing to send.
            videoDraft = nil
            return
        } else if attachments.isEmpty {
            // Nothing but spaces: don't wipe the draft for a message that won't be sent.
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            // A chat that has become read-only refuses the send; keep what was typed.
            guard model.send(draft, replyTo: replyingTo, preview: preview, mentioning: picks, in: id) else { return }
        } else {
            for (i, photo) in attachments.enumerated() {
                model.send(i == 0 ? draft : "", image: photo, replyTo: i == 0 ? replyingTo : nil,
                           preview: i == 0 ? preview : nil, mentioning: i == 0 ? picks : [], in: id)
            }
        }
        model.playSendSound()
        draft = ""
        picks = []
        attachments = []
        videoDraft = nil
        replyingTo = nil
        draftPreview = nil
        dismissedPreview = nil
        previewTask?.cancel()
    }

    private func sendVoice() {
        guard let note = recorder.finish() else { return }
        model.send("", voice: note, replyTo: replyingTo, in: id)
        model.playSendSound()
        replyingTo = nil
    }

    private func avatar(_ c: Conversation) -> Data? {
        c.avatar ?? (c.kind == .direct ? model.contact(c.members.first ?? "")?.avatar : nil)
    }

    private func seed(_ c: Conversation) -> String {
        c.kind == .direct ? (c.members.first ?? c.id.uuidString) : c.id.uuidString
    }
}

/// The pulse button left of the text box. It opens a short menu: take a photo or video, upload photos and videos from
/// the library, a file, and pinned when there is any.
private struct AttachMenu: View {
    @Environment(\.theme) private var theme
    var hasPinned: Bool
    var camera: () -> Void
    var library: () -> Void
    var file: () -> Void
    var pinned: () -> Void

    var body: some View {
        Menu {
            Button(action: camera) {
                Label { Text("Take photo"); Text("Hold the button for a video") } icon: { Image(systemName: "camera") }
            }
            Button(action: library) {
                Label { Text("Upload media"); Text("Photos and videos") } icon: { Image(systemName: "photo.on.rectangle") }
            }
            Button(action: file) { Label("File", systemImage: "paperclip") }
            if hasPinned { Button(action: pinned) { Label("Pinned", systemImage: "pin") } }
        } label: {
            PulseLine()
                .stroke(theme.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .frame(width: 20, height: 15)
                .frame(width: ConversationView.barHeight, height: ConversationView.barHeight)
                .background(Circle().fill(Ink.raised))
                .overlay(Circle().strokeBorder(Ink.line))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .menuOrder(.fixed)
        .fixedSize()
        .help("Photo, video, file or pinned")
        .accessibilityLabel("Add a photo, video, file or something pinned")
    }
}

/// What the next message is attached to: a reply, or a link preview. Click × to drop it.
private struct ComposerContext: View {
    @Environment(\.theme) private var theme
    var symbol: String
    var title: String
    var detail: String
    var image: Data?
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(theme.accent).frame(width: 2).clipShape(.capsule)
            if let image, let ns = PlatformImage.checked(image) {
                Image(platformImage: ns).resizable().scaledToFill().frame(width: 34, height: 34).clipShape(.rect(cornerRadius: 6))
            } else {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(theme.accent).frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accent).lineLimit(1)
                Text(detail).font(.system(size: 12)).foregroundStyle(Ink.dim).lineLimit(1)
            }
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Ink.faint)
                .frame(width: 22, height: 22)
                .accessibilityLabel("Remove")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(height: 46)
        .background(Ink.surface, in: .rect(cornerRadius: 10))
    }
}

private struct DayPill: View {
    var date: Date
    var body: some View {
        Text(date.chatStamp)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Ink.faint)
    }
}

/// Shown instead of the composer where you can't post.
private struct ReadOnlyBar: View {
    var kind: ConversationKind
    var announcements = false
    /// A group or channel saved in the format from before groups shared one mailbox: readable, but closed.
    var oldFormat = false
    /// The friend in a one-to-one chat whose app has to update first.
    var needsUpdate: String?
    /// Why posting is closed when it isn't who-can-post (joining, left), so the bar never blames the admins wrongly.
    var reason: String?
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
            Text(needsUpdate.map { "\($0) needs to update Pulshade first." } ?? reason ?? (oldFormat ? "This \(kind == .channel ? "channel" : "group") is on an old format and can't be used. Ask the owner to start it again."
                 : announcements ? "Only PULSHADE can post here"
                 : kind == .channel ? "Only admins can post in this channel" : "Only admins can post in this group"))
                .multilineTextAlignment(.center)
        }
        .font(.system(size: 12))
        .foregroundStyle(Ink.faint)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity).frame(minHeight: 52)
        .background(Ink.base)
        .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
    }
}

fileprivate struct Bubble: View, Equatable {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var model
    var message: Message
    var kind: ConversationKind
    var senderName: String?
    var senderAvatar: Data?
    /// The sender's signature colour.
    var tint: Color
    var quoteAuthor: String?
    var first: Bool
    var last: Bool
    var canReact: Bool
    var highlighted: Bool
    /// How far a swipe has pulled this message sideways.
    var swipe: CGFloat
    var react: (String) -> Void
    var reply: () -> Void
    /// Asks the sender for media that was not saved because this device is holding too much already.
    var getMedia: () -> Void = {}
    var unsend: () -> Void
    var jump: (UUID) -> Void
    /// It never reached the relay: said under the bubble, with a tap to send it again.
    var notSent = false
    var retry: () -> Void = {}
    /// Forward is offered (see `AppModel.canForward`), and Copy (not on the messages of someone who said no to both).
    var canForward = false
    var canCopy = true
    var forward: () -> Void = {}
    /// Opens the sender's profile (their name was tapped).
    var openSender: () -> Void = {}
    /// On the phone, holding the message lifts it into `MessageFocus`, given where its row is on screen. Nil keeps the
    /// system menu (the lifted copy itself).
    var lift: ((CGRect) -> Void)? = nil
    /// Lifted right now: the copy over the blur stands in for it.
    var isLifted = false
    /// Where the row is on screen, kept out of view state: it changes with every scroll frame.
    @State private var rowBox = RowBox()
    @State private var viewingImage = false
    /// Where an opened photo grows out of, and shrinks back into.
    @Namespace private var zoomSpace
    /// A wallet card's address was just copied: its pill says so for a moment.
    @State private var copiedAddress = false
    /// Counts double-tap hearts, so each one plays the burst again.
    @State private var hearts = 0

    /// A bubble is drawn again only when what it shows changes, not each time anything in the app does (someone
    /// typing, a tick on another message, a chat elsewhere). The actions only carry the message's id, so they
    /// stay right between redraws.
    static func == (a: Bubble, b: Bubble) -> Bool {
        a.message == b.message && a.kind == b.kind && a.senderName == b.senderName && a.senderAvatar == b.senderAvatar
            && a.tint == b.tint && a.quoteAuthor == b.quoteAuthor && a.first == b.first && a.last == b.last
            && a.canReact == b.canReact && a.highlighted == b.highlighted && a.swipe == b.swipe && a.notSent == b.notSent
            && a.canForward == b.canForward && a.canCopy == b.canCopy && a.isLifted == b.isLifted
    }

    /// Message text: a size up from before, so chats read easily at a glance.
    static let textSize: CGFloat = 17

    static let quick = ["❤️", "😂", "🔥", "😮", "😢", "👍"]

    private var showsSender: Bool { !message.isMine && kind == .group }

    /// The "@Name" parts of the words in bold, and in the accent colour when they name you (on your own
    /// messages the bubble already is the accent colour, so there it is bold only).
    private func mentioned(_ text: AttributedString) -> AttributedString {
        var out = text
        let plain = message.text
        for m in message.mentions {
            guard let r = Range(NSRange(location: m.start, length: m.length), in: plain),
                  let lower = AttributedString.Index(r.lowerBound, within: out),
                  let upper = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lower..<upper].font = .system(size: Self.textSize, weight: .bold)
            if !message.isMine { out[lower..<upper].foregroundColor = m.fingerprint == "me" ? theme.accent : Ink.text }
        }
        return out
    }

    var body: some View {
        let mine = message.isMine
        HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 44) }
            if showsSender {
                // An unwatched story opens first (the picture does that itself); otherwise their profile.
                Avatar(image: senderAvatar, seed: message.sender, size: 26).opacity(last ? 1 : 0)
                    .contentShape(.circle)
                    .onTapGesture { if last { openSender() } }
                    .accessibilityAddTraits(last ? .isButton : [])
                    .accessibilityHint(last ? "Shows their profile" : "")
            }
            VStack(alignment: mine ? .trailing : .leading, spacing: -5) {
                bubble
                    .overlay { if canReact { HeartBurst(trigger: hearts) } }
                    // A double tap loves the message, at once. It only adds: taking it back is the reaction itself.
                    .simultaneousGesture(TapGesture(count: 2).onEnded { loveIt() })
                    .accessibilityAction(named: "Love") { loveIt() }
                if !message.reactions.isEmpty {
                    ReactionChips(reactions: message.reactions, mine: mine) { react($0) }
                        .padding(.horizontal, 8)
                        .transition(.scale(scale: 0.6, anchor: mine ? .topTrailing : .topLeading).combined(with: .opacity))
                }
                if notSent && mine {
                    Button(action: retry) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle.fill")
                            Text("Not sent · Tap to retry")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.red)
                        .padding(.top, 9).padding(.horizontal, 4)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Not sent. Try again")
                    .transition(.opacity)
                }
            }
            .offset(x: swipe * 0.6)
            .overlay(alignment: mine ? .leading : .trailing) {
                // The reply arrow that appears as you swipe.
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(abs(swipe) >= 56 ? theme.accent : Ink.faint)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Ink.raised))
                    .opacity(min(1, abs(swipe) / 40))
                    .scaleEffect(abs(swipe) >= 56 ? 1.1 : 0.85)
                    .offset(x: swipe < 0 ? (mine ? -36 : 36) : (mine ? -36 : 36))
                    .allowsHitTesting(false)
            }
            if !mine { Spacer(minLength: 44) }
        }
        .padding(.top, first ? 8 : 0)
        .padding(.bottom, message.reactions.isEmpty ? 0 : 8)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.accent.opacity(highlighted ? 0.12 : 0))
                .padding(.horizontal, -8)
        }
        .opacity(isLifted ? 0 : 1)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowBox.rect = $0 }
        .modifier(HoldToLift(lift: lift.map { lift in { lift(rowBox.rect) } }, menu: AnyView(menuItems)))
    }

    /// The message's context menu; the reactions sit in one submenu instead of a line each.
    @ViewBuilder private var menuItems: some View {
        let mine = message.isMine
        if notSent && mine { Button("Try sending again", action: retry) }
        Button("Reply", action: reply)
        if canForward { Button("Forward", action: forward) }
        if let wallet {
            Button("Copy address") { copyAddress(wallet) }
        } else if !message.text.isEmpty, canCopy {
            Button("Copy") { copyToClipboard(message.text, clearAfter: 60) }
        }
        if canReact {
            Menu("React") {
                ForEach(Self.quick, id: \.self) { e in
                    Button(message.reactions["me"] == e ? "\(e)  ✓" : e) { react(e) }
                }
            }
        }
        if mine {
            Divider()
            Button("Unsend for everyone", role: .destructive, action: unsend)
        }
    }

    private func loveIt() {
        guard canReact, !message.isSystem else { return }
        if message.reactions["me"] != "❤️" { react("❤️") }
        hearts += 1
        Haptics.tick()
    }

    @ViewBuilder private var bubble: some View {
        if let wallet {
            walletBubble(wallet)
        } else if let natural = mediaSize {
            mediaBubble(MediaFrame.size(for: natural))
        } else {
            textBubble
        }
    }

    /// A wallet address sent from someone's pinned sheet: drawn as its card, whatever picture came with it.
    private var wallet: WalletMessage? { Self.wallet(in: message) }

    static func wallet(in message: Message) -> WalletMessage? {
        guard message.note == nil, message.voice == nil, !message.isVideo else { return nil }
        return WalletMessage(text: message.text)
    }

    /// The wallet card is the whole bubble. A tap copies the address.
    private func walletBubble(_ wallet: WalletMessage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasHeader {
                VStack(alignment: .leading, spacing: 6) { header }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            WalletCard(wallet: wallet, width: MediaFrame.maxWidth, copied: copiedAddress,
                       corner: AnyView(timeLine.foregroundStyle(.white.opacity(0.85))))
                .contentShape(.rect)
                .onTapGesture { copyAddress(wallet) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(wallet.kind.title) address \(wallet.address)")
                .accessibilityHint("Copies the address")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { copyAddress(wallet) }
        }
        .frame(width: MediaFrame.maxWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background { shape }
        .clipShape(corners)
        .help("Click to copy the address")
    }

    private func copyAddress(_ wallet: WalletMessage) {
        copyToClipboard(wallet.address, clearAfter: 120)
        Haptics.tick()
        withAnimation(.snappy) { copiedAddress = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { withAnimation(.snappy) { copiedAddress = false } }
    }

    /// The shape of the photo or video this message shows, if it shows one.
    private var mediaSize: CGSize? {
        guard let data = model.imageData(for: message), let img = DecodedImages.image(data, fit: 1100) else {
            return message.isVideo ? CGSize(width: 9, height: 16) : nil
        }
        return img.size.width > 0 && img.size.height > 0 ? img.size : CGSize(width: 1, height: 1)
    }

    /// The sender's name in a group, and the message answered: above everything else in the bubble.
    @ViewBuilder private var header: some View {
        let mine = message.isMine
        if showsSender, first, let senderName {
            Text(senderName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .contentShape(.rect)
                .onTapGesture(perform: openSender)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows their profile")
        }
        if message.forwarded == true {
            // Only that it was forwarded: never from whom, or from where.
            Label("Forwarded", systemImage: "arrowshape.turn.up.right")
                .font(.system(size: 12).italic())
                .foregroundStyle(mine ? Ink.onAccent.opacity(0.65) : Ink.dim)
                .labelStyle(.titleAndIcon)
        }
        if let quote = message.reply {
            Button { jump(quote.id) } label: {
                HStack(spacing: 8) {
                    Rectangle().fill(mine ? Ink.onAccent.opacity(0.35) : tint).frame(width: 2).clipShape(.capsule)
                    if let data = quote.picture, let img = DecodedImages.image(data, fit: 200) {
                        // A story's quote is tall, like the story; a photo's is a small square.
                        let tall = img.size.height > img.size.width * 1.5
                        Image(platformImage: img).resizable().scaledToFill()
                            .frame(width: tall ? 36 : 44, height: tall ? 64 : 44)
                            .clipShape(.rect(cornerRadius: 5))
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        if let quoteAuthor, !quoteAuthor.isEmpty {
                            Text(quoteAuthor)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(mine ? Ink.onAccent.opacity(0.7) : tint)
                        }
                        Text(quote.snippet)
                            .font(.system(size: 13))
                            .foregroundStyle(mine ? Ink.onAccent.opacity(0.6) : Ink.dim)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
                .frame(maxWidth: 320, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .background(mine ? Ink.onAccent.opacity(0.08) : Ink.surface, in: .rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Show the original")
        }
    }

    private var hasHeader: Bool { (showsSender && first && senderName != nil) || message.reply != nil || message.forwarded == true }

    @ViewBuilder private var words: some View {
        let mine = message.isMine
        let full = mentioned(LinkPreviews.linked(message.text))
        Group {
            if ListLine.hasList(message.text), let rows = Self.rows(message.text, in: full) {
                // A list keeps its shape: each item's lines wrap under its words, not under its bullet.
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rows.indices, id: \.self) { n in
                        let row = rows[n]
                        if let marker = row.marker {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(marker).monospacedDigit()
                                    .frame(minWidth: marker.count > 1 ? 18 : 10, alignment: .trailing)
                                Text(row.words)
                            }
                            .padding(.leading, CGFloat(row.level) * 16)
                        } else {
                            // An empty line keeps its height, as a gap between paragraphs.
                            Text(row.words.characters.isEmpty ? AttributedString(" ") : row.words)
                        }
                    }
                }
            } else {
                Text(full)
            }
        }
            .font(.system(size: Self.textSize))
            .foregroundStyle(mine ? Ink.onAccent.opacity(0.88) : Ink.text)
            .tint(mine ? Ink.onAccent.opacity(0.85) : theme.accent)
            .modifier(SelectableText(enabled: canCopy))
            .confirmsLinkTaps()
    }

    private struct Row { var level: Int; var marker: String?; var words: AttributedString }

    /// The message cut into lines, list items split into marker and words, each keeping its links and @mentions. Nil if
    /// the styled text doesn't line up with the plain one, and the bubble shows it whole instead.
    private static func rows(_ text: String, in full: AttributedString) -> [Row]? {
        // A very long message is shown whole: thousands of rows would make the chat slow to draw.
        guard text.count <= 5_000 else { return nil }
        var rows: [Row] = []
        var start = text.startIndex
        while start <= text.endIndex {
            let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[start..<end]
            var from = start
            var row = Row(level: 0, marker: nil, words: AttributedString())
            if let item = ListLine.parse(line), let r = line.range(of: item.rest, options: [.backwards, .anchored]) {
                row.level = item.level
                row.marker = item.marker
                from = r.lowerBound
            }
            guard let lower = AttributedString.Index(from, within: full),
                  let upper = AttributedString.Index(end, within: full) else { return nil }
            row.words = AttributedString(full[lower..<upper])
            rows.append(row)
            if rows.count > 200 { return nil }
            if end == text.endIndex { break }
            start = text.index(after: end)
        }
        return rows
    }

    private var timeLine: some View {
        HStack(spacing: 4) {
            if message.expiresAt != nil { Image(systemName: "timer") }
            Text(message.date.formatted(date: .omitted, time: .shortened))
            if message.isMine {
                StatusTicks(status: message.status).animation(.snappy(duration: 0.2), value: message.status)
            }
        }
        .font(.system(size: 11, weight: .medium))
    }

    /// A photo or video fills its bubble to the edges, as on Telegram. Words sent with it sit underneath; without
    /// any, the time floats on the picture.
    private func mediaBubble(_ size: CGSize) -> some View {
        let mine = message.isMine
        let caption = !message.text.isEmpty
        let below = caption || message.preview != nil
        return VStack(alignment: .leading, spacing: 0) {
            if hasHeader {
                VStack(alignment: .leading, spacing: 6) { header }
                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            media(size)
                .overlay(alignment: .bottomTrailing) {
                    if !below && last {
                        timeLine
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.45), in: .capsule)
                            .padding(7)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
            if below {
                VStack(alignment: .leading, spacing: 6) {
                    if caption { words.frame(maxWidth: .infinity, alignment: .leading) }
                    if let preview = message.preview { PreviewCard(preview: preview, mine: mine) }
                    if last {
                        timeLine
                            .foregroundStyle(mine ? Ink.onAccent.opacity(0.5) : Ink.faint)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 9)
            }
        }
        .frame(width: size.width)
        .fixedSize(horizontal: false, vertical: true)
        .background { shape }
        .clipShape(corners)
        .overlay { if !mine { corners.strokeBorder(tint.opacity(0.22)) } }
        .help(message.status == .queued ? "Sealed, waiting for the relay" : "")
    }

    @ViewBuilder private func media(_ size: CGSize) -> some View {
        if message.isVideo {
            VideoBubble(message: message, fill: size)
        } else if message.awaiting == .photo {
            // The photo is still on its way: its tiny preview, softened, until it lands.
            ZStack {
                if let data = message.image, let img = DecodedImages.image(data, fit: 64) {
                    Image(platformImage: img).resizable().scaledToFill().blur(radius: 14)
                } else {
                    Ink.text.opacity(0.08)
                }
                ProgressView().tint(.white)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photo, loading")
        } else if let data = model.imageData(for: message), let img = DecodedImages.image(data, fit: 1100) {
            Image(platformImage: img).resizable().scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .contentShape(.rect)
                .matchedTransitionSource(id: message.id, in: zoomSpace)
                .onTapGesture { viewingImage = true }
                .modifier(ImageViewerCover(isPresented: $viewingImage, data: data,
                                           title: message.isMine ? "You" : senderName, date: message.date,
                                           caption: message.text.isEmpty ? nil : message.text,
                                           source: (message.id, zoomSpace)))
                .accessibilityLabel("Photo")
                .accessibilityAddTraits(.isButton)
        }
    }

    /// A file-backed item whose sealed file is missing or cannot be opened.
    private var storedMediaMissing: Bool {
        if message.videoFile != nil { return model.videoData(for: message) == nil }
        if message.imageFile != nil { return model.imageData(for: message) == nil }
        if message.voice?.audioFile != nil { return model.voiceAudio(for: message) == nil }
        return false
    }

    /// The voice note with its sound, which may come from the sealed pool.
    private var playableVoice: VoiceNote? {
        guard var voice = message.voice else { return nil }
        if voice.audio.isEmpty, let audio = model.voiceAudio(for: message) { voice.audio = audio }
        return voice
    }

    private var mediaUnavailable: some View {
        Label("Media unavailable", systemImage: "exclamationmark.triangle")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(message.isMine ? Ink.onAccent.opacity(0.8) : Ink.dim)
    }

    @ViewBuilder private var droppedMedia: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(message.mediaGone == true ? "No longer available" : "Not saved - storage full",
                  systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
            if message.mediaGone != true {
                Button("Get it anyway", action: getMedia)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .foregroundStyle(message.isMine ? Ink.onAccent.opacity(0.8) : Ink.dim)
        .padding(.vertical, 2)
    }

    private var textBubble: some View {
        let mine = message.isMine
        return VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
            header
            if message.mediaDropped == true {
                droppedMedia
            } else if storedMediaMissing {
                mediaUnavailable
            } else if let voice = playableVoice {
                VoiceBubble(note: voice, id: message.id, mine: mine, loading: message.awaiting == .voice)
            }
            if message.attachment?.kind == .file {
                FileBubble(message: message, mine: mine)
            }
            if let card = message.note {
                NoteCardView(card: card, message: message, mine: mine)
            }
            if message.note != nil {
                // The card says it all; the words are only for apps that don't know cards.
            } else if bare {
                BigEmoji(text: message.text, fresh: Date().timeIntervalSince(message.date) < 6)
            } else if !message.text.isEmpty {
                words
            }
            if let preview = message.preview {
                PreviewCard(preview: preview, mine: mine)
            }
            if last {
                timeLine
                    .foregroundStyle(mine && !bare ? Ink.onAccent.opacity(0.5) : Ink.faint)
                    .transition(.opacity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, bare ? 2 : 14)
        .padding(.vertical, bare ? 2 : 10)
        .background {
            if !bare { shape }
        }
        .help(message.status == .queued ? "Sealed, waiting for the relay" : "")
    }

    /// Emoji-only messages float without a bubble, big.
    private var bare: Bool {
        message.image == nil && message.imageFile == nil && !message.isVideo && message.voice == nil && message.reply == nil
            && message.text.isOnlyEmoji
    }

    /// The bubble's outline: rounder on the outside, tighter where it joins the one above or below.
    private var corners: UnevenRoundedRectangle {
        let mine = message.isMine
        let r: CGFloat = 18, tight: CGFloat = 6
        return UnevenRoundedRectangle(cornerRadii: .init(
            topLeading: !mine && !first ? tight : r, bottomLeading: !mine && !last ? tight : r,
            bottomTrailing: mine && !last ? tight : r, topTrailing: mine && !first ? tight : r))
    }

    private var shape: some View {
        let mine = message.isMine
        return corners
            .fill(mine ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Ink.raised))
            .overlay {
                if !mine { corners.strokeBorder(tint.opacity(0.22)) }
            }
    }
}

/// A few emoji on their own float without a bubble. One is big, like WhatsApp's, and pops in when it arrives and
/// bounces when it's tapped, like Telegram's. With Reduce Motion on it just sits there, big.
private struct BigEmoji: View {
    var text: String
    @State private var popped: Bool
    @State private var taps = 0

    init(text: String, fresh: Bool) {
        self.text = text
        // Old messages are simply there: only one that has just arrived pops in.
        _popped = State(initialValue: !fresh || Platform.reduceMotion)
    }

    /// One emoji is the biggest; each one more makes them smaller, so three still fit a line.
    private var size: CGFloat {
        switch text.filter({ !$0.isWhitespace }).count {
        case 1: 96
        case 2: 68
        default: 52
        }
    }

    private struct Bounce {
        var scale = 1.0
        var angle = 0.0
    }

    var body: some View {
        Text(text)
            .font(.system(size: size))
            .scaleEffect(popped ? 1 : 0.2)
            .rotationEffect(.degrees(popped ? 0 : -16))
            .keyframeAnimator(initialValue: Bounce(), trigger: taps) { view, bounce in
                view.scaleEffect(bounce.scale).rotationEffect(.degrees(bounce.angle))
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.3, duration: 0.16, spring: .snappy)
                    SpringKeyframe(0.92, duration: 0.14)
                    SpringKeyframe(1.0, duration: 0.3, spring: .bouncy)
                }
                KeyframeTrack(\.angle) {
                    LinearKeyframe(-12, duration: 0.09)
                    LinearKeyframe(12, duration: 0.11)
                    LinearKeyframe(-7, duration: 0.1)
                    SpringKeyframe(0, duration: 0.3, spring: .bouncy)
                }
            }
            .onAppear {
                guard !popped else { return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.42)) { popped = true }
            }
            .onTapGesture {
                guard !Platform.reduceMotion else { return }
                taps += 1
                Haptics.tick()
            }
            .accessibilityLabel(text)
    }
}


/// A note sent as a card. Only its title travelled: tapping reads it from the sender's profile, so a locked one asks
/// for its password, one made for you says "Access Granted", and one that isn't yours to read says so.
private struct NoteCardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var card: NoteCard
    var message: Message
    var mine: Bool
    @State private var reading: ProfileNote?
    @State private var unavailable = false

    private var symbol: String { card.locked ? "lock.fill" : card.restricted ? "person.fill.checkmark" : "doc.text.fill" }

    private var subtitle: String {
        card.locked ? "Locked with a password" : card.restricted ? "Only for chosen people" : "Note"
    }

    /// The note itself: yours, or what the sender's profile has given you.
    private func note() -> ProfileNote? {
        model.note(for: card, sentBy: message.sender, mine: message.isMine)
    }

    var body: some View {
        Button {
            if let found = note() { reading = found } else { unavailable = true }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(mine ? Ink.onAccent : theme.accent)
                    .frame(width: 40, height: 40)
                    .background((mine ? Ink.onAccent : theme.accent).opacity(0.16), in: .rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(mine ? Ink.onAccent : Ink.text).lineLimit(2).multilineTextAlignment(.leading)
                    Text(subtitle).font(.system(size: 12))
                        .foregroundStyle(mine ? Ink.onAccent.opacity(0.7) : Ink.dim)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(mine ? Ink.onAccent.opacity(0.6) : Ink.faint)
            }
            .frame(minWidth: 210, maxWidth: 270, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card.title), \(subtitle). Opens the note.")
        .sheet(item: $reading) { found in NoteReaderSheet(note: found, tint: theme.accent) }
        .alert("You can't read this note", isPresented: $unavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("It isn't shared with you, or it hasn't reached your phone yet. Ask \(message.isMine ? "yourself" : "them") to check who can read it.")
        }
    }
}

/// A link preview inside a message. Opening it is your choice; nothing is fetched to show it.
private struct PreviewCard: View {
    @Environment(\.theme) private var theme
    var preview: LinkPreview
    var mine: Bool
    @State private var asking: URL?

    var body: some View {
        Button {
            if let url = URL(string: preview.url), LinkPreviews.isWebLink(preview.url) { asking = url }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let image = preview.image, let ns = DecodedImages.image(image, fit: 900) {
                    Image(platformImage: ns).resizable().scaledToFill()
                        .frame(width: 250, height: 125).clipped()
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let title = preview.title {
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            .foregroundStyle(mine ? Ink.onAccent.opacity(0.85) : Ink.text)
                    }
                    // The real host, never the sender's own word for it.
                    Text(LinkPreviews.openable(URL(string: preview.url))?.host() ?? URL(string: preview.url)?.host() ?? "link")
                        .font(.system(size: 11))
                        .foregroundStyle(mine ? Ink.onAccent.opacity(0.55) : Ink.faint)
                        .lineLimit(1)
                }
                .padding(10)
                .frame(width: 250, alignment: .leading)
            }
            .background(mine ? Ink.onAccent.opacity(0.1) : Ink.surface)
            .clipShape(.rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(mine ? Ink.onAccent.opacity(0.08) : Ink.line))
        }
        .buttonStyle(.plain)
        .help(preview.url)
        .confirmsExternalLink($asking)
    }
}

private struct EmojiButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 38, height: 38)
            .background(Circle().fill(selected ? AnyShapeStyle(theme.gradient.opacity(0.35)) : AnyShapeStyle(.clear)))
            .scaleEffect(configuration.isPressed ? 1.35 : 1)
            .animation(.snappy(duration: 0.25), value: configuration.isPressed)
    }
}

private struct ReactionChips: View {
    @Environment(\.theme) private var theme
    var reactions: [String: String]
    var mine: Bool
    var tap: (String) -> Void

    var body: some View {
        let counts = Dictionary(grouping: reactions.values, by: { $0 }).mapValues(\.count)
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        HStack(spacing: 3) {
            ForEach(counts, id: \.key) { emoji, count in
                Button { tap(emoji) } label: {
                    HStack(spacing: 3) {
                        if emoji == "❤️" { PulseHeart(size: 15) } else { Text(emoji).font(.system(size: 13)) }
                        if count > 1 { Text("\(count)").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.dim) }
                    }
                    .padding(.horizontal, 7).frame(height: 24)
                    .background(Ink.surface, in: .capsule)
                    .overlay(Capsule().strokeBorder(reactions["me"] == emoji ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Ink.line)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Play button, waveform and time for a voice note.
private struct VoiceBubble: View {
    @Environment(\.theme) private var theme
    var note: VoiceNote
    var id: UUID
    var mine: Bool
    /// The sound is still on its way: the length and waveform show, but nothing plays yet.
    var loading = false
    private var player: VoicePlayer { .shared }

    var body: some View {
        let playing = player.playing == id
        HStack(spacing: 10) {
            if loading {
                ProgressView()
                    .controlSize(.small)
                    .tint(mine ? theme.colors[0] : Ink.onAccent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(mine ? AnyShapeStyle(Ink.onAccent.opacity(0.8)) : AnyShapeStyle(theme.gradient)))
                    .accessibilityLabel("Voice note, loading")
            } else {
            Button { player.toggle(note, id: id) } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(mine ? AnyShapeStyle(theme.colors[0]) : AnyShapeStyle(Ink.onAccent.opacity(0.85)))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(mine ? AnyShapeStyle(Ink.onAccent.opacity(0.8)) : AnyShapeStyle(theme.gradient)))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing ? "Pause" : "Play voice note")
            }
            Waveform(levels: note.levels, progress: playing ? player.progress : 0,
                     color: mine ? Ink.onAccent.opacity(0.75) : Ink.text)
                .frame(width: 150, height: 28)
            Text(Duration.seconds(note.duration).formatted(.time(pattern: .minuteSecond)))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(mine ? Ink.onAccent.opacity(0.6) : Ink.dim)
            Button { Haptics.tick(); player.cycleRate() } label: {
                Text(player.rate == 1 ? "1×" : (player.rate == 2 ? "2×" : "1.5×"))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(mine ? Ink.onAccent.opacity(0.85) : Ink.text)
                    .frame(minWidth: 30)
                    .padding(.vertical, 3)
                    .background(mine ? Ink.onAccent.opacity(0.18) : Ink.text.opacity(0.1), in: .capsule)
                    .contentTransition(.numericText())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Playback speed \(player.rate == 1.5 ? "1.5" : "\(Int(player.rate))") times")
        }
    }
}

struct Waveform: View {
    var levels: [UInt8]
    var progress: Double
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let count = max(levels.count, 1)
            let bar = geo.size.width / CGFloat(count)
            HStack(alignment: .center, spacing: bar * 0.35) {
                ForEach(Array(levels.enumerated()), id: \.offset) { i, level in
                    Capsule()
                        .fill(color.opacity(Double(i) / Double(count) <= progress ? 1 : 0.4))
                        .frame(width: bar * 0.65, height: max(3, geo.size.height * CGFloat(level) / 255))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// Live recording: pulsing dot, rolling waveform, timer, cancel and send.
private struct RecordingBar: View {
    @Environment(\.theme) private var theme
    var recorder: VoiceRecorder
    var cancel: () -> Void
    var send: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: cancel) { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle(size: 42))
                .accessibilityLabel("Cancel recording")
            Circle().fill(.red).frame(width: 10, height: 10)
                .phaseAnimator(Platform.reduceMotion ? [1.0] : [1.0, 0.3]) { v, o in v.opacity(o) } animation: { _ in .easeInOut(duration: 0.6) }
            Waveform(levels: Array(recorder.levels.suffix(60)), progress: 1, color: theme.accent)
                .frame(height: 30)
                .animation(.linear(duration: 0.1), value: recorder.levels.count)
            Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Ink.text)
                .contentTransition(.numericText())
            Button(action: send) { Image(systemName: "arrow.up") }
                .buttonStyle(GlowButtonStyle(size: 44))
                .keyboardShortcut(.return, modifiers: [])
                .accessibilityLabel("Send voice note")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Ink.raised.opacity(0.85), in: .capsule)
        .overlay(Capsule().strokeBorder(theme.gradient.opacity(0.5)))
    }
}

/// Three bouncing dots and who's typing.
/// A value that changes often but shouldn't redraw anything when it does.
private final class ScrollTrack {
    var distance: CGFloat = 0
    /// A finger on the chat, or the chat still gliding from one: it's yours, nothing moves it.
    var touching = false
}

/// The sizes that decide whether the chat should follow the bottom.
private struct ScrollShape: Equatable {
    var content: CGFloat
    var container: CGFloat
    /// The bottom of what's on screen, in the content's own measure: at the newest message it equals `content`.
    var bottom: CGFloat
}

private struct TypingDots: View {
    @Environment(\.theme) private var theme
    var names: [String]

    var body: some View {
        HStack(spacing: 8) {
            if !names.isEmpty {
                HStack(spacing: 4) {
                    ForEach(0..<3) { i in
                        Circle().fill(theme.gradient).frame(width: 7, height: 7)
                            .phaseAnimator(Platform.reduceMotion ? [0.0] : [0.0, -5.0, 0.0]) { v, y in v.offset(y: y) } animation: { _ in
                                .easeInOut(duration: 0.35).delay(Double(i) * 0.12)
                            }
                    }
                }
                .padding(.horizontal, 14).frame(height: 32)
                .background(Ink.raised.opacity(0.92), in: .capsule)
                Text(names.joined(separator: ", "))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ink.faint)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: names.isEmpty ? 0 : 34)
        .opacity(names.isEmpty ? 0 : 1)
        .animation(.snappy, value: names)
    }
}

private struct SystemPill: View {
    @Environment(\.theme) private var theme
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(theme.gradient)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Ink.raised.opacity(0.6), in: .capsule)
            .overlay(Capsule().strokeBorder(theme.accent.opacity(0.25)))
            .frame(maxWidth: .infinity)
    }
}

/// Header button for the disappearing-message timer.
private struct TimerMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var conversation: Conversation

    var body: some View {
        let on = conversation.disappearAfter != nil
        Menu {
            Button { model.setDisappearing(nil, in: conversation.id) } label: {
                Label("Off", systemImage: on ? "circle" : "checkmark.circle.fill")
            }
            ForEach(Disappear.allCases) { d in
                Button { model.setDisappearing(d.rawValue, in: conversation.id) } label: {
                    Label(d.short, systemImage: conversation.disappearAfter == d.rawValue ? "checkmark.circle.fill" : "circle")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "timer")
                if on { Text(Disappear.short(conversation.disappearAfter)) }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(on ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Ink.dim))
            .padding(.horizontal, on ? 12 : 0)
            .frame(minWidth: 38, minHeight: 38)
            .background(Ink.raised, in: .capsule)
            .overlay(Capsule().strokeBorder(Ink.line))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Disappearing messages")
        .accessibilityLabel("Disappearing messages")
    }
}

extension String {
    /// One to three emoji and nothing else: shown big, like other messengers do.
    var isOnlyEmoji: Bool {
        let trimmed = filter { !$0.isWhitespace }
        return !trimmed.isEmpty && trimmed.count <= 3
            && trimmed.allSatisfy { $0.unicodeScalars.first?.properties.isEmojiPresentation == true || ($0.unicodeScalars.count > 1 && $0.unicodeScalars.first?.properties.isEmoji == true) }
    }
}

/// Live relay status: a heartbeat when connected, a dim dot when not.
struct LinkBadge: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let online = model.link == .online
        HStack(spacing: 7) {
            ZStack {
                if online, !Platform.reduceMotion {
                    Circle().fill(theme.accent).frame(width: 8, height: 8)
                        .phaseAnimator([1.0, 2.6]) { v, s in v.scaleEffect(s).opacity(2.8 - s) } animation: { _ in .easeOut(duration: 1.4) }
                }
                Circle().fill(online ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Color.orange)).frame(width: 8, height: 8)
            }
            Image(systemName: online ? "waveform.path.ecg" : "wifi.slash")
                .contentTransition(.symbolEffect(.replace))
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(online ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Ink.faint))
        .padding(.horizontal, 11).frame(height: 30)
        .glass(15)
        .animation(.smooth, value: online)
        .help(online ? "Connected to the relay" : "Relay unreachable. Messages wait, sealed, on this iPhone.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(online ? "Connected to the relay" : "Relay unreachable")
    }
}

// MARK: - Details

/// Details and management for any chat: a person's nickname and verification, or a group or
/// channel's name, description, posting rights, admins and members.
struct ConversationInfo: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let id: Conversation.ID
    /// Drawn without its scroll view and already faded in, for rendering it in tests.
    var flat = false
    @State private var nickname = ""
    @State private var title = ""
    @State private var about = ""
    @State private var avatar: Data?
    @State private var copied = false
    @State private var pulseCheck = false
    @State private var confirmDelete = false
    @State private var confirmRemove = false
    @State private var confirmBlock = false
    @State private var pending: Pending?
    @State private var reporting: ReportSubject?
    @State private var adding = false
    /// A member whose profile is open.
    @State private var profileOf: MemberRef?
    /// Flips on as the sheet opens, so the profile eases in instead of just appearing.
    @State private var arrived = false

    var body: some View {
        if let c = model.conversation(id) {
            let person = c.kind == .direct ? model.contact(c.members.first ?? "", in: c.persona) : nil
            VStack(spacing: 0) {
                // Every sheet keeps its title bar, so a person's profile is plainly a profile.
                Group {
                    HStack {
                        Text(c.kind == .direct || person != nil ? "Profile" : c.kind.label)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Ink.text)
                        Spacer()
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .buttonStyle(IconButtonStyle(size: 26))
                            .keyboardShortcut(.cancelAction)
                            .accessibilityLabel("Close")
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    Rectangle().fill(Ink.line).frame(height: 1)
                }

                scroller {
                    if let person {
                        personProfile(person, in: c)
                            .opacity(arrived || flat ? 1 : 0)
                            .offset(y: arrived || flat ? 0 : 18)
                    }
                    VStack(spacing: 18) {
                        if person == nil {
                            if c.isGroupLike { groupHero(c) } else { identity(c) }
                        }
                        if let persona = c.persona, model.isBurner(persona) { burnButton(persona) }
                        switch c.kind {
                        case .direct: directSection(c)
                        case .channel where c.isAnnouncements: announcementsSection(c)
                        case .group, .channel: groupSections(c)
                        case .broadcast: membersSection(c)
                        }
                        // A person's chat has its own cards under their profile; everything else keeps this one.
                        if c.isGroupLike { leaveCard(c) }
                        else if c.kind != .direct || model.contact(c.members.first ?? "", in: c.persona) == nil { actions(c) }
                    }
                    .padding(20)
                    .confirms($pending)
                    .opacity(arrived || flat ? 1 : 0)
                    .offset(y: arrived || flat ? 0 : 18)
                    .scaleEffect(arrived || flat ? 1 : 0.96, anchor: .top)
                }
            }
            .background(Ink.base)
            .preferredColorScheme(Ink.scheme)
            .onAppear {
                withAnimation(.smooth(duration: 0.55).delay(0.08)) { arrived = true }
                nickname = model.contact(c.members.first ?? "")?.nickname ?? ""
                title = c.title
                about = c.about ?? ""
                avatar = c.avatar
            }
            .sheet(isPresented: $adding) { AddPeopleSheet(id: id) }
            .sheet(item: $profileOf) { MemberProfileSheet(fingerprint: $0.fingerprint, conversation: id) }
        }
    }

    @ViewBuilder private func scroller<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if flat { VStack(spacing: 0) { content() } } else { ScrollView { content() }.scrollIndicators(.never) }
    }

    // MARK: Top

    @ViewBuilder private func identity(_ c: Conversation) -> some View {
        if c.kind == .direct, let peer = model.contact(c.members.first ?? "", in: c.persona) {
            personProfile(peer, in: c)
        } else {
            let editable = c.kind != .direct && c.amAdmin && !c.isOldFormat
            VStack(spacing: 10) {
                if editable {
                    AvatarPicker(image: Binding(get: { avatar }, set: { avatar = $0; commitDetails(c) }), seed: c.id.uuidString, size: 84)
                } else {
                    Avatar(image: c.avatar, seed: c.kind == .direct ? (c.members.first ?? "") : c.id.uuidString,
                           size: 84, symbol: c.kind == .direct ? nil : c.kind.symbol)
                }
                if editable {
                    TextField("", text: $title, prompt: Text("Name").foregroundStyle(Ink.faint))
                        .textFieldStyle(.plain)
                        .font(.system(size: 18, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .onSubmit { commitDetails(c) }
                } else {
                    Text(c.title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Ink.text)
                }
                Text(summary(c)).font(.system(size: 12)).foregroundStyle(Ink.faint)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// A person's whole profile, as they made it: the card with Message, Call and Mute, then the tabs. What only you
    /// set for them (nickname, safety number, pin) and the ways to report, block or delete come after, in
    /// `directSection`.
    private func personProfile(_ peer: Contact, in c: Conversation) -> some View {
        let theirName = peer.name.isEmpty ? "Anonymous" : peer.name
        let shared = model.data.conversations.filter { $0.kind == .group && $0.persona == c.persona && $0.members.contains(peer.fingerprint) }
            .map { ProfileGroupRef(id: $0.id, title: $0.title, avatar: $0.avatar, count: $0.members.count + 1) }
        return VStack(spacing: 14) {
            ProfileHero(avatar: c.avatar ?? peer.avatar, seed: peer.fingerprint,
                        name: peer.nickname.isEmpty ? theirName : peer.nickname,
                        subtitle: peer.isSelf ? "This is you" : peer.nickname.isEmpty ? nil : "Calls themselves \(theirName)",
                        handle: peer.handle, bio: peer.bio, verified: peer.verified,
                        links: peer.links ?? [], walletChangedAt: peer.walletChangedAt, isMine: peer.isSelf,
                        facts: peer.isSelf ? [] : friendFacts(peer, in: c, groups: shared.count)) {
                HStack(spacing: 8) {
                    ProfileActionTile(title: "Message", symbol: "bubble.left.fill", prominent: true) { dismiss() }
                    if !peer.isSelf {
                        ProfileActionTile(title: "Call", symbol: "phone.fill") {
                            dismiss()
                            model.startCall(with: peer.fingerprint, persona: c.persona)
                        }
                    }
                    ProfileActionTile(title: c.muted ? "Unmute" : "Mute", symbol: c.muted ? "bell.fill" : "bell.slash.fill") {
                        model.toggleMute(c.id)
                    }
                }
            }
            ProfileTabs(notes: peer.notes ?? [],
                        collectibles: peer.isSelf ? model.showcase(for: c.persona) : model.showcase(of: peer),
                        groups: shared, messages: c.messages, isMine: peer.isSelf,
                        hasCollectibleList: model.collectibleList != nil)
        }
        .padding(.horizontal, 16).padding(.top, 16)
        .frame(maxWidth: .infinity)
    }

    /// When you became friends, the groups you share and how much you've said to each other.
    private func friendFacts(_ peer: Contact, in c: Conversation, groups: Int) -> [ProfileFact] {
        let messages = c.messages.filter { !$0.isSystem }.count
        return [ProfileFact(value: peer.addedAt.formatted(.dateTime.month(.abbreviated).year()), label: "Friends since"),
                ProfileFact(value: "\(groups)", label: groups == 1 ? "Group" : "Groups"),
                ProfileFact(value: messages.formatted(.number.notation(.compactName)), label: messages == 1 ? "Message" : "Messages")]
    }

    private func summary(_ c: Conversation) -> String {
        switch c.kind {
        case .direct: "End-to-end encrypted"
        case .group: "Group · \(c.members.count + 1) members"
        case .channel where c.isAnnouncements: "@\(Announcement.handle) · Official"
        case .channel: c.amAdmin ? "Channel · \(counted(model.followers(of: c).count, "follower"))" : "Channel"
        case .broadcast: "Broadcast list · \(c.members.count == 1 ? "1 person" : "\(c.members.count) people")"
        }
    }

    private func commitDetails(_ c: Conversation) {
        model.updateDetails(c.id, title: title, about: about.trimmingCharacters(in: .whitespacesAndNewlines), avatar: avatar)
    }

    private func burnButton(_ persona: UUID) -> some View {
        Button {
            pending = Pending(title: "Burn this persona now?",
                              message: "It's deleted for good, with its chats and contacts.",
                              confirm: "Burn") {
                dismiss()
                model.burn(persona)
            }
        } label: {
            Label("Burn now", systemImage: "flame.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(Burn.gradient, in: .rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    // MARK: Direct

    /// Under a person's profile: first what only you see (your nickname for them, whether you've checked their safety
    /// number, the chat's encryption, pinning it), then reporting, blocking, removing and deleting, together in red.
    @ViewBuilder private func directSection(_ c: Conversation) -> some View {
        if let fp = c.members.first, let contact = model.contact(fp, in: c.persona) {
            VStack(spacing: 7) {
                ProfileSectionTitle(title: "Only you see this")
                ProfileCard {
                    if !contact.isSelf {
                        manageRow("pencil", "Nickname") {
                            TextField("", text: $nickname, prompt: Text(contact.name.isEmpty ? "Add one" : contact.name)
                                .foregroundStyle(Ink.faint))
                                .textFieldStyle(.plain)
                                .font(.system(size: 15))
                                .foregroundStyle(Ink.text)
                                .multilineTextAlignment(.trailing)
                                .onSubmit { model.rename(fp, to: nickname.trimmingCharacters(in: .whitespaces)) }
                                // On iPhone the sheet is usually closed without pressing Return.
                                .onDisappear {
                                    let wanted = nickname.trimmingCharacters(in: .whitespaces)
                                    if wanted != contact.name { model.rename(fp, to: wanted) }
                                }
                        }
                        RowDivider(inset: 52)
                        Button { pulseCheck = true } label: {
                            manageRow(contact.verified ? "checkmark.seal.fill" : "checkmark.seal", "Safety number") {
                                HStack(spacing: 6) {
                                    Text(contact.verified ? "Verified" : "Not verified")
                                        .font(.system(size: 14))
                                        .foregroundStyle(contact.verified ? theme.accent : Ink.faint)
                                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.faint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .sheet(isPresented: $pulseCheck) { PulseCheckView(fingerprint: fp, persona: c.persona) }
                        RowDivider(inset: 52)
                    }
                    manageRow("lock.fill", "Encryption") {
                        Text(summary(c)).font(.system(size: 14)).foregroundStyle(Ink.faint)
                    }
                    RowDivider(inset: 52)
                    Button { model.togglePin(id) } label: {
                        manageRow(c.pinned ? "pin.slash" : "pin", c.pinned ? "Unpin chat" : "Pin chat to top") { EmptyView() }
                    }
                    .buttonStyle(.plain)
                }
            }
            ProfileCard {
                if !contact.isSelf {
                    Button { reporting = ReportSubject(key: contact.signingKey, handle: nil, name: contact.name) } label: {
                        manageRow("flag", "Report", tint: .red) { EmptyView() }
                    }
                    .buttonStyle(.plain)
                    .sheet(item: $reporting) { ReportSheet(subject: $0) }
                    RowDivider(inset: 52)
                    Button { confirmBlock = true } label: {
                        manageRow("hand.raised", "Block", tint: .red) { EmptyView() }
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog("Block \(contact.displayName)?", isPresented: $confirmBlock, titleVisibility: .visible) {
                        Button("Block", role: .destructive) {
                            dismiss()
                            model.blockContact(fp, persona: c.persona)
                        }
                    } message: {
                        Text("Deleted on your side; anything they send is dropped. They aren't told. Unblock in Privacy & Security.")
                    }
                    if !contact.hidden {
                        RowDivider(inset: 52)
                        Button { confirmRemove = true } label: {
                            manageRow("person.crop.circle.badge.minus", "Remove contact", tint: .red) { EmptyView() }
                        }
                        .buttonStyle(.plain)
                        .confirmationDialog(RemoveContact.title(contact), isPresented: $confirmRemove, titleVisibility: .visible) {
                            Button("Remove", role: .destructive) {
                                dismiss()
                                model.removeContact(fp, persona: c.persona)
                            }
                        } message: {
                            Text(RemoveContact.detail)
                        }
                    }
                    RowDivider(inset: 52)
                }
                Button { confirmDelete = true } label: {
                    manageRow("trash", "Delete chat", tint: .red) { EmptyView() }
                }
                .buttonStyle(.plain)
                .confirmationDialog(c.deleteWarning.title, isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        dismiss()
                        model.delete(id)
                    }
                } message: {
                    Text(c.deleteWarning.detail)
                }
            }
        }
    }

    private func manageRow<Trailing: View>(_ symbol: String, _ title: String, tint: Color? = nil,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint.map { $0.opacity(0.9) } ?? theme.accent).frame(width: 26)
            Text(title).font(.system(size: 15)).foregroundStyle(tint.map { $0.opacity(0.9) } ?? Ink.text).lineLimit(1)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .contentShape(.rect)
    }

    // MARK: Groups & channels

    private func announcementsSection(_ c: Conversation) -> some View {
        Card(title: "About", footer: "Signed by PULSHADE and checked on this device.") {
            Text(c.about ?? "")
                .foregroundStyle(Ink.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Group & channel card

    /// A group's or channel's card, like a person's profile: cover, picture and name (editable by admins), what it is and
    /// your role, its description, a strip of numbers, and Mute, Pin and Add.
    private func groupHero(_ c: Conversation) -> some View {
        let editable = c.amAdmin && !c.isOldFormat
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return VStack(spacing: 0) {
            ProfileCover().frame(height: 92)
            Group {
                if editable {
                    AvatarPicker(image: Binding(get: { avatar }, set: { avatar = $0; commitDetails(c) }), seed: c.id.uuidString, size: 96)
                } else {
                    Avatar(image: c.avatar, seed: c.id.uuidString, size: 96, symbol: c.kind.symbol)
                }
            }
            .padding(4)
            .background(Ink.surface, in: .circle)
            .padding(.top, -52)
            VStack(spacing: 0) {
                if editable {
                    TextField("", text: $title, prompt: Text("Name").foregroundStyle(Ink.faint))
                        .textFieldStyle(.plain)
                        .font(.system(size: 24, weight: .bold))
                        .multilineTextAlignment(.center)
                        .onSubmit { commitDetails(c) }
                        .padding(.top, 10)
                } else {
                    Text(c.title)
                        .font(.system(size: 24, weight: .bold)).foregroundStyle(Ink.text)
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
                        .padding(.top, 10)
                }
                HStack(spacing: 8) {
                    Label(c.kind.label, systemImage: c.kind.symbol)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.dim)
                    Text(roleName(c))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(theme.accent.opacity(0.14), in: .capsule)
                }
                .padding(.top, 6)
                aboutField(c, editable: editable).padding(.top, 12)
                ProfileFactStrip(facts: groupFacts(c)).padding(.top, 14)
                HStack(spacing: 8) {
                    ProfileActionTile(title: c.muted ? "Unmute" : "Mute", symbol: c.muted ? "bell.fill" : "bell.slash.fill") {
                        model.toggleMute(id)
                    }
                    ProfileActionTile(title: c.pinned ? "Unpin" : "Pin", symbol: c.pinned ? "pin.slash.fill" : "pin.fill") {
                        model.togglePin(id)
                    }
                    if c.amAdmin && !c.isOldFormat && c.shared?.gone != true {
                        ProfileActionTile(title: c.kind == .channel ? "Add followers" : "Add members",
                                          symbol: "person.badge.plus", prominent: true) { adding = true }
                    }
                }
                .padding(.top, 14)
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(Ink.surface)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Ink.line, lineWidth: 1))
        .onDisappear { if c.amAdmin && (about != (c.about ?? "") || title != c.title) { commitDetails(c) } }
    }

    @ViewBuilder private func aboutField(_ c: Conversation, editable: Bool) -> some View {
        if editable {
            TextField("", text: $about, prompt: Text("Add a description").foregroundStyle(Ink.faint), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .lineLimit(1...6)
                .onSubmit { commitDetails(c) }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Ink.raised.opacity(0.6), in: .rect(cornerRadius: 12, style: .continuous))
        } else if let text = c.about, !text.isEmpty {
            Text(LinkPreviews.linked(text))
                .font(.system(size: 15)).foregroundStyle(Ink.text)
                .tint(theme.accent)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func roleName(_ c: Conversation) -> String {
        c.amOwner ? "Owner" : c.amAdmin ? "Admin" : c.amMod ? "Mod" : c.kind == .channel ? "Follower" : "Member"
    }

    /// Members (or followers, for a channel's staff), admins, messages, and when it started.
    private func groupFacts(_ c: Conversation) -> [ProfileFact] {
        var facts: [ProfileFact] = []
        if c.kind == .group {
            let n = c.members.count + 1
            facts.append(ProfileFact(value: "\(n)", label: n == 1 ? "Member" : "Members"))
        } else if c.amAdmin {
            let n = model.followers(of: c).count
            facts.append(ProfileFact(value: n.formatted(.number.notation(.compactName)), label: n == 1 ? "Follower" : "Followers"))
        }
        let admins = Set([c.owner] + c.admins).count
        facts.append(ProfileFact(value: "\(admins)", label: admins == 1 ? "Admin" : "Admins"))
        let posts = c.messages.filter { !$0.isSystem }.count
        facts.append(ProfileFact(value: posts.formatted(.number.notation(.compactName)),
                                 label: c.kind == .channel ? (posts == 1 ? "Post" : "Posts") : (posts == 1 ? "Message" : "Messages")))
        // Three fit the card; when it already has three, when it started is the one left out.
        if facts.count < 3 {
            facts.append(ProfileFact(value: c.createdAt.formatted(.dateTime.month(.abbreviated).year()), label: "Since"))
        }
        return facts
    }

    @ViewBuilder private func groupSections(_ c: Conversation) -> some View {
        mailboxSection(c)

        if model.isFollower(c), c.shared?.missedKey == true { missedKeySection(c) }

        if c.kind == .channel && c.amAdmin && !c.isOldFormat { inviteSection(c) }

        if model.canNamePublicly(c.id) { PublicNameSection(id: c.id, kind: c.kind) }

        settingsCard(c)

        if c.kind == .group, let shared = c.shared, !shared.gone, !shared.joining, c.amAdmin { GroupLinksSection(id: c.id) }

        membersSection(c)
    }

    /// Who can post, and for a channel you post in, whether followers can copy what you post.
    private func settingsCard(_ c: Conversation) -> some View {
        let noun = c.kind == .channel ? "channel" : "group"
        return VStack(spacing: 6) {
            ProfileSectionTitle(title: "Settings")
            ProfileCard {
                manageRow("text.bubble", "Who can post") {
                    if c.amOwner && !c.isOldFormat {
                        Menu {
                            Picker("", selection: Binding(get: { c.postPolicy }, set: { model.setPostPolicy(c.id, $0) })) {
                                ForEach(c.kind == .channel ? [PostPolicy.admins, .owner] : PostPolicy.allCases) { Text($0.label).tag($0) }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(c.postPolicy.label)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                            }
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(theme.accent)
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                    } else {
                        Text(c.postPolicy.label).font(.system(size: 14)).foregroundStyle(Ink.dim)
                    }
                }
                if c.kind == .channel && c.amAdmin && !c.isOldFormat {
                    Divider().overlay(Ink.line).padding(.leading, 52)
                    manageRow("hand.raised", "Protect posts") {
                        Toggle("", isOn: Binding(get: { c.protectPosts == true }, set: { model.setProtectPosts(c.id, $0) }))
                            .labelsHidden()
                            .toggleStyle(GlowToggleStyle())
                    }
                }
            }
            Text(c.kind == .channel && c.amAdmin
                 ? "Protect posts asks followers' apps not to offer Copy, Forward or Save on what you post from now on. Anyone can still take a screenshot."
                 : c.amOwner ? "Only you can change who can post in this \(noun)." : "The owner decides who can post in this \(noun).")
                .font(.system(size: 11)).foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
        }
    }

    /// Leave, or delete a group you own, in red at the very bottom.
    private func leaveCard(_ c: Conversation) -> some View {
        let deletes = c.amOwner
        return ProfileCard {
            Button { confirmDelete = true } label: {
                manageRow(deletes ? "trash" : "rectangle.portrait.and.arrow.right",
                          deletes ? "Delete \(c.kind == .channel ? "channel" : "group")" : c.kind == .channel ? "Leave channel" : "Leave group",
                          tint: .red) { EmptyView() }
            }
            .buttonStyle(.plain)
            .confirmationDialog(c.deleteWarning.title, isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(deletes ? "Delete" : "Leave", role: .destructive) {
                    dismiss()
                    model.delete(id)
                }
            } message: {
                Text(c.deleteWarning.detail + (model.isFollower(c) && !model.canTellInviter(c)
                     ? " The person who added you can't be reached from here, so the staff won't be told: you leave on this device only, and may keep being sent the channel's keys until they take you out."
                     : ""))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.red.opacity(0.35)))
    }

    /// What the group says about itself when it can't be used: joining, left, or saved in an older format.
    @ViewBuilder
    private func mailboxSection(_ c: Conversation) -> some View {
        if let shared = c.shared {
            if shared.joining || shared.gone {
                Card(title: "Group") {
                    Text(shared.gone ? "You're no longer in this group." : "Joining. You can post once an admin's phone has added you.")
                        .font(.system(size: 12)).foregroundStyle(Ink.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if c.isOldFormat {
            Card(title: "Group") {
                Text("This group is on an old format and can't be used any more. Its past messages stay here. Ask the owner to start it again.")
                    .font(.system(size: 12)).foregroundStyle(Ink.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// A follower who was away while the channel changed its key can't read new posts until the staff member who added them
    /// sends it again.
    private func missedKeySection(_ c: Conversation) -> some View {
        let asked = c.shared?.keyAskedAt
        let reachable = model.canTellInviter(c)
        return Card(title: "Key", footer: !reachable ? "The person who added you can't be reached from here (they may have left the staff, or the chat is gone). Ask the channel's staff to add you again."
                    : asked == nil ? nil
                    : "If nothing comes, the owner's app may need to update, they may be offline, or you may no longer be a follower.") {
            VStack(alignment: .leading, spacing: 8) {
                Text(asked.map { "You asked \($0.formatted(.relative(presentation: .named)))." }
                     ?? "You were away while this channel changed its key, so you can't read new posts.")
                    .font(.system(size: 12)).foregroundStyle(Ink.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { model.askForKeyAgain(c.id) } label: {
                    Label(asked == nil ? "Ask for the key again" : "Ask again", systemImage: "key")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
                .disabled(!model.canAskForKey(c))
            }
        }
    }

    private func inviteSection(_ c: Conversation) -> some View {
        let code = model.makeInviteCode(channel: c.id)
        return VStack(spacing: 6) {
            ProfileSectionTitle(title: "Invite link")
            ProfileCard(padded: true) {
                HStack(spacing: 14) {
                    QRCode(text: WebLinks.long(code), size: 84)
                        .padding(6)
                        .background(Color.white, in: .rect(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Anyone with this link or code can follow.")
                            .font(.system(size: 13)).foregroundStyle(Ink.dim)
                            .fixedSize(horizontal: false, vertical: true)
                        CopyLinkButton(target: code) { withAnimation(.snappy) { copied = true } } label: {
                            Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "link")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Ink.onAccent)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(theme.accent.gradient, in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func membersSection(_ c: Conversation) -> some View {
        let people = c.members
        let title = c.kind == .channel ? (c.amAdmin ? "Followers & admins" : "Admins") : "Members"
        let invited = model.contactsInvited(to: c)
        return VStack(spacing: 6) {
            ProfileSectionTitle(title: "\(title) · \(people.count + (c.kind == .group ? 1 : 0))")
            ProfileCard {
                // Groups and channels have Add on their card above.
                if c.kind == .broadcast, c.amAdmin {
                    Button { adding = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                                .frame(width: 34, height: 34).background(theme.wash, in: .circle)
                                .foregroundStyle(theme.accent)
                            Text(c.kind == .channel ? "Add followers" : c.kind == .broadcast ? "Add people" : "Add members")
                                .font(.system(size: 15, weight: .medium)).foregroundStyle(theme.accent)
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Ink.line).padding(.leading, 60)
                }
                if c.kind == .group {
                    personRow(name: "\(model.profile(for: c.persona).displayName) (you)", fp: "me", c: c, avatar: model.profile(for: c.persona).avatar,
                              seed: model.me(c.persona)?.fingerprint ?? "")
                }
                ForEach(Array(people.enumerated()), id: \.element) { i, fp in
                    if i > 0 || c.kind == .group { Divider().overlay(Ink.line).padding(.leading, 60) }
                    personRow(name: model.displayName(fp), fp: fp, c: c, avatar: model.contact(fp, in: c.persona)?.avatar, seed: fp)
                }
                // Added, but their app hasn't answered yet: in the group already as far as you're concerned.
                ForEach(invited, id: \.self) { fp in
                    Divider().overlay(Ink.line).padding(.leading, 60)
                    HStack(spacing: 12) {
                        Avatar(image: model.contact(fp, in: c.persona)?.avatar, seed: fp, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.displayName(fp)).font(.system(size: 15)).foregroundStyle(Ink.text).lineLimit(1)
                            Text("Invited · joins when they open Pulshade").font(.system(size: 11)).foregroundStyle(Ink.faint)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                }
            }
        }
    }

    private func personRow(name: String, fp: String, c: Conversation, avatar: Data?, seed: String) -> some View {
        HStack(spacing: 10) {
            Button { if fp != "me" { profileOf = MemberRef(fingerprint: fp) } } label: {
            HStack(spacing: 12) {
            Avatar(image: avatar, seed: seed, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 15)).foregroundStyle(Ink.text).lineLimit(1)
            }
            Spacer()
            if let role = model.role(of: fp, in: c) {
                Text(role)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(theme.accent.opacity(0.14), in: .capsule)
            }
            }
            .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if fp != "me", c.kind != .broadcast, !c.isOldFormat, c.amAdmin || (c.amMod && c.canRemove(fp, by: "me")), fp != c.owner {
                Menu {
                    if c.amOwner {
                        if c.admins.contains(fp) {
                            Button("Remove as admin") { model.setAdmin(c.id, fp, false) }
                        } else {
                            Button("Make admin") { model.setAdmin(c.id, fp, true) }
                        }
                        if c.kind == .group, !c.isAdmin(fp) {
                            if c.mods.contains(fp) {
                                Button("Remove as mod") { model.setMod(c.id, fp, false) }
                            } else {
                                Button("Make mod") { model.setMod(c.id, fp, true) }
                            }
                        }
                    }
                    if c.canRemove(fp, by: "me") {
                        Button("Remove from \(c.kind == .channel ? "channel" : "group")", role: .destructive) {
                            // A removed member still knows every open link, so they're told they can come back that way
                            // unless banned.
                            let openLinks = c.kind == .group && c.shared?.links?.links.contains(where: { $0.isOpen() }) == true
                            let title = "Remove \(name) from the \(c.kind == .channel ? "channel" : "group")?"
                                + (openLinks ? " They can still ask to join again through your open links. Use Remove and ban to stop that." : "")
                            pending = Pending(title: title, confirm: "Remove") {
                                model.removeMember(c.id, fp)
                            }
                        }
                        if c.shared != nil, c.amAdmin {
                            Button("Remove and ban", role: .destructive) {
                                pending = Pending(title: "Remove \(name) and turn down their requests to join again?", confirm: "Ban") {
                                    model.banMember(fp, in: c.id)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Ink.faint).frame(width: 30, height: 30)
                        .contentShape(.rect)
                }
                .accessibilityLabel("More for \(name)")
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: Bottom

    private func actions(_ c: Conversation) -> some View {
        Card {
            Button { model.togglePin(id) } label: {
                Field(label: c.pinned ? "Unpin" : "Pin to top") { Image(systemName: c.pinned ? "pin.slash" : "pin").foregroundStyle(Ink.dim) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().overlay(Ink.line)
            Button { model.toggleMute(id) } label: {
                Field(label: c.muted ? "Unmute" : "Mute notifications") {
                    Image(systemName: c.muted ? "bell" : "bell.slash").foregroundStyle(Ink.dim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if c.kind == .direct, let fp = c.members.first, let contact = model.contact(fp, in: c.persona) {
                Divider().overlay(Ink.line)
                Button { reporting = ReportSubject(key: contact.signingKey, handle: nil, name: contact.name) } label: {
                    Field(label: "Report") { Image(systemName: "flag").foregroundStyle(Ink.dim) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sheet(item: $reporting) { ReportSheet(subject: $0) }
                if !contact.isSelf {
                    Divider().overlay(Ink.line)
                    Button { confirmBlock = true } label: {
                        HStack {
                            Text("Block").foregroundStyle(Color.red.opacity(0.9))
                            Spacer()
                            Image(systemName: "hand.raised").foregroundStyle(Color.red.opacity(0.9))
                        }
                        .font(.system(size: 13, weight: .medium))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog("Block \(contact.displayName)?", isPresented: $confirmBlock, titleVisibility: .visible) {
                        Button("Block", role: .destructive) {
                            dismiss()
                            model.blockContact(fp, persona: c.persona)
                        }
                    } message: {
                        Text("Deleted on your side; anything they send is dropped. They aren't told. Unblock in Privacy & Security.")
                    }
                }
                if !contact.hidden && !contact.isSelf {
                    Divider().overlay(Ink.line)
                    Button { confirmRemove = true } label: {
                        HStack {
                            Text("Remove contact").foregroundStyle(Color.red.opacity(0.9))
                            Spacer()
                        }
                        .font(.system(size: 13, weight: .medium))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog(RemoveContact.title(contact), isPresented: $confirmRemove, titleVisibility: .visible) {
                        Button("Remove", role: .destructive) {
                            dismiss()
                            model.removeContact(fp, persona: c.persona)
                        }
                    } message: {
                        Text(RemoveContact.detail)
                    }
                }
            }
            Divider().overlay(Ink.line)
            Button { confirmDelete = true } label: {
                HStack {
                    Text(c.kind == .direct || c.amOwner || c.kind == .broadcast ? "Delete chat" : c.kind == .channel && !c.isAnnouncements ? "Leave channel" : "Leave")
                        .foregroundStyle(Color.red.opacity(0.9))
                    Spacer()
                }
                .font(.system(size: 13, weight: .medium))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .confirmationDialog(c.deleteWarning.title, isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(c.kind == .direct || c.amOwner || c.kind == .broadcast ? "Delete" : "Leave", role: .destructive) {
                    dismiss()
                    model.delete(id)
                }
            } message: {
                Text(c.deleteWarning.detail + (model.isFollower(c) && !model.canTellInviter(c)
                     ? " The person who added you can't be reached from here, so the staff won't be told: you leave on this device only, and may keep being sent the channel's keys until they take you out."
                     : ""))
            }
        }
    }
}

/// A titled group of rows, like System Settings.
struct Card<Content: View>: View {
    var title: String?
    /// A short explanation under the card.
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { ProfileSectionTitle(title: title) }
            VStack(alignment: .leading, spacing: 10) { content }
                .font(.system(size: 14))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.surface, in: .rect(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Ink.line))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }
        }
    }
}

/// A label on the left and a value or control on the right.
struct Field<Trailing: View>: View {
    var label: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Ink.text)
            Spacer()
            trailing
        }
        .font(.system(size: 13))
    }
}

/// Pick contacts to add to a group or channel.
private struct AddPeopleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let id: Conversation.ID
    @State private var picked: Set<String> = []

    var body: some View {
        if let c = model.conversation(id) {
            let already = model.contactsIn(c)
            let candidates = model.data.contacts.filter {
                !$0.hidden && !$0.awaitingAcceptance && $0.persona == c.persona && !already.contains($0.fingerprint)
            }
            SheetBody(width: 440) {
                VStack(spacing: 16) {
                    SheetHeader(symbol: "person.badge.plus", title: c.kind == .channel ? "Add followers" : "Add members")
                    if candidates.isEmpty {
                        Constellation(symbol: "person.2", text: "Everyone you know is already here")
                            .padding(.vertical, 20)
                    } else {
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(candidates) { person in
                                    let on = picked.contains(person.fingerprint)
                                    // A group that shares one mailbox can only take people whose app can.
                                    let able = c.shared == nil || model.takesSharedGroups(person)
                                    Button {
                                        if on { picked.remove(person.fingerprint) } else { picked.insert(person.fingerprint) }
                                    } label: {
                                        HStack(spacing: 10) {
                                            Avatar(image: person.avatar, seed: person.fingerprint, size: 30)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(person.displayName).font(.system(size: 13)).foregroundStyle(able ? Ink.text : Ink.faint)
                                                if !able {
                                                    Text("Needs a newer Pulshade").font(.system(size: 11)).foregroundStyle(Ink.faint)
                                                }
                                            }
                                            Spacer()
                                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(on ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Ink.faint))
                                        }
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(on ? Ink.raised : .clear, in: .rect(cornerRadius: 8))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!able)
                                }
                            }
                        }
                        .frame(maxHeight: 300)
                        Button {
                            model.addMembers(id, Array(picked))
                            dismiss()
                        } label: {
                            Text(picked.isEmpty ? "Add" : "Add \(picked.count)")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 14)
                        }
                        .buttonStyle(GlowButtonStyle(size: 34))
                        .disabled(picked.isEmpty)
                    }
                }
            }
        }
    }
}

/// Where a message's row is on screen (`Bubble.rowBox`).
private final class RowBox {
    var rect = CGRect.zero
}

/// Holding a message: on the phone it lifts into `MessageFocus`; elsewhere the system menu opens.
private struct HoldToLift: ViewModifier {
    var lift: (() -> Void)?
    var menu: AnyView
    func body(content: Content) -> some View {
        if let lift {
            content.simultaneousGesture(LongPressGesture(minimumDuration: 0.3).onEnded { _ in
                Haptics.tick()
                lift()
            })
        } else {
            content.contextMenu { menu }
        }
    }
}

/// A message lifted into `MessageFocus`, and where its row was.
private struct LiftedMessage: Equatable {
    var id: UUID
    var frame: CGRect
}

/// Adds the swipe-to-reply drag, except on system messages.
private struct PhoneSwipe<G: Gesture>: ViewModifier {
    var enabled: Bool
    var gesture: G
    func body(content: Content) -> some View {
        if enabled { content.simultaneousGesture(gesture) } else { content }
    }
}

/// The Message and Call buttons on a person's profile.
struct ProfileActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Ink.text)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(Ink.surface, in: .capsule)
            .overlay(Capsule().strokeBorder(Ink.line))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(.capsule)
    }
}


/// An unsent message goes out like a zap: it flashes bright, swells and blurs into a pulse, and is gone.
struct ZapTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        let gone = phase == .identity ? 0.0 : 1.0
        content
            .brightness(gone * 0.55)
            .saturation(1 + gone * 0.6)
            .scaleEffect(1 + gone * 0.14)
            .blur(radius: gone * 9)
            .opacity(1 - gone)
    }
}

/// New messages slide up; unsent ones zap out. Kept out of the message list's body so it still type-checks quickly.
private let messageTransition: AnyTransition = .asymmetric(
    // A short rise and fade, like other messengers: the bubble arrives without the rows around it jumping.
    insertion: .offset(y: 14).combined(with: .opacity),
    removal: AnyTransition(ZapTransition()))

/// Text that can be selected (and so copied), unless its sender asked that it isn't passed on.
private struct SelectableText: ViewModifier {
    var enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) } else { content.textSelection(.disabled) }
    }
}

/// Picks the chat to forward a message to: this persona's chats where you can write. Tapping one sends it there.
struct ForwardSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var message: Message
    var from: Conversation.ID
    @State private var query = ""

    private var targets: [Conversation] {
        let all = model.forwardTargets(from: from)
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Forward to").font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.text)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(Ink.dim)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 16).frame(height: 52)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Ink.surface, in: .rect(cornerRadius: 10))
                .padding(.horizontal, 16).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(targets) { c in
                        Button {
                            model.forward(message, from: from, to: c.id)
                            Haptics.tick()
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Avatar(image: c.avatar ?? (c.kind == .direct ? model.contact(c.members.first ?? "")?.avatar : nil),
                                       seed: c.kind == .direct ? (c.members.first ?? c.id.uuidString) : c.id.uuidString,
                                       size: 40, symbol: c.kind == .direct ? nil : c.kind.symbol, showsStory: false)
                                Text(c.title).font(.system(size: 16)).foregroundStyle(Ink.text).lineLimit(1)
                                Spacer()
                                Image(systemName: "arrowshape.turn.up.right").foregroundStyle(Ink.faint)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    if targets.isEmpty {
                        Text(query.isEmpty ? "No chats to forward to" : "No chats match")
                            .font(.system(size: 13)).foregroundStyle(Ink.faint).padding(.top, 30)
                    }
                }
            }
        }
        .background(Ink.base)
    }
}
