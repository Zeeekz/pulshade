import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif
#if os(macOS)
import AppKit
#endif

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let id: Conversation.ID
    @State private var draft = ""
    @State private var attachments: [Data] = []
    /// A video for the next message, while it's made ready and once it is.
    @State private var videoDraft: VideoDraft?
    @State private var videoTask: Task<Void, Never>?
    @State private var takingPhoto = false
    @State private var quickSending = false
    @State private var showInfo = false
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
    /// Updated every scroll frame, so it lives outside view state: only crossing the threshold redraws.
    @State private var scrollTrack = ScrollTrack()
    @State private var showJumpDown = false
    @State private var unreadBelow = 0
    @State private var hovered: UUID?
    @State private var swipe: (id: UUID, dx: CGFloat)?
    #if os(macOS)
    @State private var scrollMonitor: Any?
    #endif
    @FocusState private var focused: Bool

    /// How far a swipe has to travel before letting go starts a reply.
    private let replyThreshold: CGFloat = 56

    var body: some View {
        if let c = model.conversation(id) {
            VStack(spacing: 0) {
                header(c)
                messages(c)
                if model.canPost(in: c) { composer(c) } else { ReadOnlyBar(kind: c.kind, announcements: c.isAnnouncements) }
            }
            .background(Ink.base)
            .onAppear {
                focused = !Platform.isPhone
                model.openConversation = id
                model.markRead(id)
                #if DEBUG
                // Screenshots: PULSHADE_DEMO_INFO=1 opens the chat's details.
                if AppModel.demoRequested, ProcessInfo.processInfo.environment["PULSHADE_DEMO_INFO"] != nil { showInfo = true }
                #endif
                #if os(macOS)
                startSwipeMonitor()
                #else
                KeyboardDismisser.shared.enabled = false
                #endif
            }
            .onDisappear {
                if model.openConversation == id { model.openConversation = nil }
                recorder.cancel()
                previewTask?.cancel()
                #if os(macOS)
                if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
                #else
                KeyboardDismisser.shared.enabled = true
                #endif
            }
            .onChange(of: c.messages.count) { model.markRead(id) }
            .sheet(isPresented: $showInfo) { ConversationInfo(id: id) }
            .sheet(isPresented: $quickSending) {
                QuickSendSheet(conversation: id).presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: Header

    private func header(_ c: Conversation) -> some View {
        let phone = Platform.isPhone
        return ZStack {
            // The name sits in the middle of the bar, whatever is on either side.
            Button { showInfo = true } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 5) {
                        Text(c.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Ink.text)
                            .lineLimit(1)
                        if c.kind == .direct { BadgeMark(badge: model.contact(c.members.first ?? "")?.badge, size: 14) }
                        if c.isAnnouncements { Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(theme.accent) }
                        if c.kind == .direct, model.contact(c.members.first ?? "")?.verified == true {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(theme.accent)
                        }
                    }
                    let here = c.kind == .direct && c.members.first.map(model.isOnline) == true
                    let settingUp = c.kind == .direct && c.members.first.map(model.keysPending) == true
                    Text(settingUp ? "Setting up new keys. Done when they open Pulshade" : here ? "Online" : subtitle(c))
                        .font(.system(size: 11))
                        .foregroundStyle(settingUp ? Color.orange : here ? OnlineDot.color : Ink.faint)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, phone ? 96 : 300)
            .accessibilityLabel("\(c.title), details")

            HStack(spacing: 8) {
                if phone {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(BarButtonStyle())
                        .accessibilityLabel("Back")
                    // Their picture beside the back button: tap it to see it full size, or the details if they have none.
                    let picture = c.avatar ?? (c.kind == .direct ? model.contact(c.members.first ?? "", in: c.persona)?.avatar : nil)
                    Button {
                        if let picture { headerPicture = picture } else { showInfo = true }
                    } label: {
                        Avatar(image: picture, seed: c.kind == .direct ? (c.members.first ?? "") : c.id.uuidString,
                               size: 34, symbol: c.kind == .direct ? nil : c.kind.symbol)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(picture != nil ? "\(c.title), picture" : "\(c.title), details")
                }
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
                if c.kind == .direct || c.kind == .group { TimerMenu(conversation: c) }
                // On the phone the relay indicator only speaks up when something is wrong.
                if !phone || model.link != .online { LinkBadge() }
                if !phone {
                    Button { showInfo = true } label: { Image(systemName: "sidebar.right") }
                        .buttonStyle(IconButtonStyle(size: 28))
                        .help("Details")
                        .accessibilityLabel("Details")
                }
            }
        }
        .padding(.horizontal, phone ? 12 : 18)
        .padding(.top, phone ? 6 : 30)
        .padding(.bottom, 10)
        .background(Ink.base)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }
        .modifier(ImageViewerCover(isPresented: Binding(get: { headerPicture != nil }, set: { if !$0 { headerPicture = nil } }),
                                   data: headerPicture ?? Data()))
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
                    ForEach(Array(c.messages.enumerated()), id: \.element.id) { i, m in
                        let prev = i > 0 ? c.messages[i - 1] : nil
                        let next = i + 1 < c.messages.count ? c.messages[i + 1] : nil
                        if prev.map({ m.date.timeIntervalSince($0.date) > 3600 }) ?? true {
                            DayPill(date: m.date).padding(.vertical, 14)
                        }
                        Group {
                            if m.isSystem {
                                SystemPill(text: m.text).padding(.vertical, 8)
                            } else {
                                Bubble(message: m, kind: c.kind,
                                       senderName: m.isMine ? nil : model.displayName(m.sender),
                                       senderAvatar: m.isMine ? nil : model.contact(m.sender)?.avatar,
                                       tint: model.signature(m.sender),
                                       quoteAuthor: m.reply.map { $0.author == "me" ? "You" : model.displayName($0.author) },
                                       first: prev?.sender != m.sender || prev?.isSystem == true,
                                       last: next?.sender != m.sender,
                                       canReact: c.kind != .broadcast,
                                       highlighted: flash == m.id,
                                       swipe: swipe?.id == m.id ? swipe?.dx ?? 0 : 0,
                                       react: { model.react($0, to: m.id, in: id) },
                                       reply: { startReply(m) },
                                       unsend: { model.unsend(m.id, in: id) },
                                       jump: { target in jump(to: target, proxy: proxy) },
                                       hover: { inside in if inside { hovered = m.id } else if hovered == m.id { hovered = nil } })
                            }
                        }
                        .id(m.id)
                        .modifier(PhoneSwipe(enabled: Platform.isPhone && !m.isSystem, gesture: swipeGesture(for: m)))
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity))
                    }
                }
                .padding(.horizontal, Platform.isPhone ? 10 : 20)
                .padding(.vertical, 16)
                TypingDots(names: model.typers(in: id).map(model.displayName))
                    .padding(.horizontal, Platform.isPhone ? 10 : 20)
                    .padding(.bottom, 8)
                    .id("typing")
                Color.clear.frame(height: 1).id("end")
            }
            .scrollIndicators(.automatic)
            .defaultScrollAnchor(.bottom)
            // Rows are only measured as they come into view, so a chat opened at the bottom can grow under you
            // (photos, previews) and end up scrolled up. While it's following the bottom, it stays there.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height - $0.contentOffset.y - $0.containerSize.height } action: { _, new in
                scrollTrack.distance = new
            }
            .onScrollGeometryChange(for: Bool.self) { $0.contentSize.height - $0.contentOffset.y - $0.containerSize.height > 320 } action: { _, far in
                if showJumpDown != far { withAnimation(.snappy(duration: 0.2)) { showJumpDown = far } }
                if !far { unreadBelow = 0 }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
                if pinnedToEnd, new != old { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onScrollPhaseChange { old, new in
                if new == .interacting { pinnedToEnd = false }
                if new == .idle, old == .interacting || old == .decelerating { pinnedToEnd = scrollTrack.distance < 80 }
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { focused = false }
            #endif
            .onChange(of: c.messages.count) {
                // A new message follows you down, unless you've scrolled up to read: then it waits, except yours.
                if let last = c.messages.last, pinnedToEnd || last.isMine {
                    pinnedToEnd = true
                    withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo("end", anchor: .bottom) }
                } else if let last = c.messages.last, !last.isMine, !last.isSystem {
                    unreadBelow += 1
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showJumpDown {
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
                    .padding(.trailing, Platform.isPhone ? 14 : 22).padding(.bottom, 12)
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

    #if os(macOS)
    /// Two-finger trackpad swipe sideways on a message starts a reply. Vertical scrolling passes through.
    private func startSwipeMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.hasPreciseScrollingDeltas else { return event }
            if event.phase == .began {
                swipe = nil
            }
            if event.phase == .changed || event.phase == .began, let target = hovered {
                let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.4
                if swipe?.id == target || (swipe == nil && horizontal) {
                    let total = (swipe?.dx ?? 0) + event.scrollingDeltaX
                    swipe = (target, max(-110, min(110, total)))
                    return nil
                }
            }
            if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .began, let current = swipe {
                if abs(current.dx) >= replyThreshold,
                   let message = model.conversation(id)?.messages.first(where: { $0.id == current.id }), !message.isSystem {
                    startReply(message)
                }
                withAnimation(.snappy(duration: 0.3)) { swipe = nil }
                return nil
            }
            return swipe == nil ? event : nil
        }
    }
    #endif

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
                                image: replyingTo.image) {
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
                    Button { takingPhoto = true } label: { Image(systemName: "camera") }
                        .buttonStyle(IconButtonStyle(size: 36))
                        .help("Take or choose a photo or video")
                        .accessibilityLabel("Take or choose a photo or video")
                    // Only when there's something pinned to send, so the bar stays clear otherwise.
                    if !(model.activeProfile.links ?? []).isEmpty || !(model.activeProfile.notes ?? []).isEmpty {
                        Button { quickSending = true } label: { Image(systemName: "pin") }
                            .buttonStyle(IconButtonStyle(size: 36))
                            .help("Send something pinned to your profile")
                            .accessibilityLabel("Send something pinned to your profile")
                    }

                    TextField("", text: $draft, prompt: Text(placeholder(c)).foregroundStyle(Ink.faint), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .lineLimit(1...6)
                        // Autocorrect learns what you type and keeps it outside Pulshade's encryption.
                        .autocorrectionDisabled()
                        .focused($focused)
                        .padding(.leading, 12)
                        .padding(.trailing, 34)
                        .padding(.vertical, 9)
                        .background(Ink.raised, in: .rect(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(focused ? theme.accent.opacity(0.45) : Ink.line)
                        }
                        .animation(.easeOut(duration: 0.15), value: focused)
                        .onSubmit(send)
                        .onChange(of: draft) { _, new in
                            if !new.isEmpty { model.noteTyping(in: id) }
                            refreshPreview(for: new)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if !Platform.isPhone {
                                Button {
                                    focused = true
                                    Platform.showEmojiPicker()
                                } label: { Image(systemName: "face.smiling") }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Ink.faint)
                                    .padding(.trailing, 10)
                                    .padding(.bottom, 9)
                                    .accessibilityLabel("Emoji")
                            }
                        }

                    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty && videoDraft == nil {
                        Button { Task { _ = await recorder.start() } } label: { Image(systemName: "mic") }
                            .buttonStyle(IconButtonStyle(size: 36))
                            .help("Record a voice message")
                            .accessibilityLabel("Record voice note")
                            .transition(.opacity)
                    } else {
                        Button(action: send) { Image(systemName: "arrow.up") }
                            .buttonStyle(GlowButtonStyle(size: 36))
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
        .padding(.horizontal, Platform.isPhone ? 10 : 18)
        .padding(.top, 10)
        .padding(.bottom, Platform.isPhone ? 8 : 14)
        .background(Ink.base)
        .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
        .chatCamera(isPresented: $takingPhoto) { photos in
            withAnimation(.snappy) { attachments = Array((attachments + photos).prefix(10)) }
        } filmed: { clip, zoom in
            prepareVideo(clip, zoom)
        }
        .animation(.snappy(duration: 0.25), value: videoDraft)
        .animation(.snappy(duration: 0.25), value: recorder.isRecording)
        .animation(.snappy(duration: 0.25), value: attachments.count)
        .animation(.snappy(duration: 0.25), value: replyingTo?.id)
        .animation(.snappy(duration: 0.25), value: draftPreview)
    }

    private func placeholder(_ c: Conversation) -> String {
        switch c.kind {
        case .direct, .group: "Message"
        case .channel: "Post to followers"
        case .broadcast: "Broadcast to \(c.members.count)"
        }
    }

    /// Builds a preview for the first link in the draft, after typing pauses.
    private func refreshPreview(for text: String) {
        previewTask?.cancel()
        guard model.data.security.linkPreviews, let url = LinkPreviews.firstLink(in: text) else {
            if draftPreview != nil { draftPreview = nil }
            return
        }
        guard url.absoluteString != draftPreview?.url, url.absoluteString != dismissedPreview else { return }
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let preview = await LinkPreviews.fetch(url), !Task.isCancelled,
                  LinkPreviews.firstLink(in: draft)?.absoluteString == preview.url else { return }
            draftPreview = preview
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
            model.send(draft, replyTo: replyingTo, preview: preview, mentioning: picks, in: id)
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
            if let image, let ns = PlatformImage(data: image) {
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
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
            Text(announcements ? "Only PULSHADE can post here"
                 : kind == .channel ? "Only admins can post in this channel" : "Only admins can post in this group")
        }
        .font(.system(size: 12))
        .foregroundStyle(Ink.faint)
        .frame(maxWidth: .infinity).frame(height: 52)
        .background(Ink.base)
        .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
    }
}

private struct Bubble: View {
    @Environment(\.theme) private var theme
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
    /// How far a trackpad swipe has pulled this message sideways.
    var swipe: CGFloat
    var react: (String) -> Void
    var reply: () -> Void
    var unsend: () -> Void
    var jump: (UUID) -> Void
    var hover: (Bool) -> Void
    @State private var hovering = false
    @State private var picking = false
    @State private var viewingImage = false
    /// Counts double-tap hearts, so each one plays the burst again.
    @State private var hearts = 0

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
            out[lower..<upper].font = .system(size: 14, weight: .bold)
            if !message.isMine { out[lower..<upper].foregroundColor = m.fingerprint == "me" ? theme.accent : Ink.text }
        }
        return out
    }

    var body: some View {
        let mine = message.isMine
        HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: Platform.isPhone ? 44 : 160) }
            if showsSender {
                Avatar(image: senderAvatar, seed: message.sender, size: 26).opacity(last ? 1 : 0)
            }
            if mine && !Platform.isPhone { actions }
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
            if !mine && !Platform.isPhone { actions }
            if !mine { Spacer(minLength: Platform.isPhone ? 44 : 160) }
        }
        .padding(.top, first ? 8 : 0)
        .padding(.bottom, message.reactions.isEmpty ? 0 : 8)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.accent.opacity(highlighted ? 0.12 : 0))
                .padding(.horizontal, -8)
        }
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
            hover(h)
        }
        .contextMenu {
            Button("Reply", action: reply)
            if !message.text.isEmpty { Button("Copy") { copyToClipboard(message.text, clearAfter: 60) } }
            if canReact {
                Divider()
                ForEach(Self.quick, id: \.self) { e in Button(e) { react(e) } }
            }
            if mine {
                Divider()
                Button("Unsend for everyone", role: .destructive, action: unsend)
            }
        }
    }

    private func loveIt() {
        guard canReact, !message.isSystem else { return }
        if message.reactions["me"] != "❤️" { react("❤️") }
        hearts += 1
        Haptics.tick()
    }

    private var bubble: some View {
        let mine = message.isMine
        return VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
            if showsSender, first, let senderName {
                Text(senderName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
            if let quote = message.reply {
                Button { jump(quote.id) } label: {
                    HStack(spacing: 8) {
                        Rectangle().fill(mine ? Ink.onAccent.opacity(0.35) : tint).frame(width: 2).clipShape(.capsule)
                        if let data = quote.picture, let img = PlatformImage(data: data) {
                            // A story's quote is tall, like the story; a photo's is a small square.
                            let tall = img.size.height > img.size.width * 1.5
                            Image(platformImage: img).resizable().scaledToFill()
                                .frame(width: tall ? 36 : 44, height: tall ? 64 : 44)
                                .clipShape(.rect(cornerRadius: 5))
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(quoteAuthor ?? "")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(mine ? Ink.onAccent.opacity(0.7) : tint)
                            Text(quote.snippet)
                                .font(.system(size: 12))
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
            if message.isVideo {
                VideoBubble(message: message)
            } else if let data = message.image, let img = PlatformImage(data: data) {
                Image(platformImage: img).resizable().scaledToFit()
                    .frame(maxWidth: Platform.isPhone ? 250 : 320, maxHeight: 340)
                    .clipShape(.rect(cornerRadius: 10))
                    .contentShape(.rect(cornerRadius: 10))
                    .onTapGesture { viewingImage = true }
                    .modifier(ImageViewerCover(isPresented: $viewingImage, data: data))
                    .accessibilityLabel("Photo")
                    .accessibilityAddTraits(.isButton)
            }
            if let voice = message.voice {
                VoiceBubble(note: voice, id: message.id, mine: mine)
            }
            if let collectible = message.collectible, collectible.kind != nil {
                CollectibleCard(collectible: collectible, mine: mine)
            }
            if let card = message.note {
                NoteCardView(card: card, message: message, mine: mine)
            }
            if message.collectible?.kind != nil || message.note != nil {
                // The card says it all; the words are only for apps that don't know cards.
            } else if bare {
                BigEmoji(text: message.text, fresh: Date().timeIntervalSince(message.date) < 6)
            } else if !message.text.isEmpty {
                Text(mentioned(LinkPreviews.linked(message.text)))
                    .font(.system(size: 14))
                    .foregroundStyle(mine ? Ink.onAccent.opacity(0.88) : Ink.text)
                    .tint(mine ? Ink.onAccent.opacity(0.85) : theme.accent)
                    .textSelection(.enabled)
            }
            if let preview = message.preview {
                PreviewCard(preview: preview, mine: mine)
            }
            if last || hovering {
                HStack(spacing: 4) {
                    if message.expiresAt != nil { Image(systemName: "timer") }
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                    if mine {
                        StatusTicks(status: message.status).animation(.snappy(duration: 0.2), value: message.status)
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(mine && !bare ? Ink.onAccent.opacity(0.5) : Ink.faint)
                .transition(.opacity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, bare ? 2 : 12)
        .padding(.vertical, bare ? 2 : 8)
        .background {
            if !bare { shape }
        }
        .help(message.status == .queued ? "Sealed, waiting for the relay" : "")
    }

    /// Emoji-only messages float without a bubble, big.
    private var bare: Bool {
        message.image == nil && message.voice == nil && message.reply == nil && message.text.isOnlyEmoji
    }

    private var shape: some View {
        let mine = message.isMine
        let r: CGFloat = 16, tight: CGFloat = 5
        return UnevenRoundedRectangle(cornerRadii: .init(
            topLeading: !mine && !first ? tight : r, bottomLeading: !mine && !last ? tight : r,
            bottomTrailing: mine && !last ? tight : r, topTrailing: mine && !first ? tight : r))
            .fill(mine ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Ink.raised))
            .overlay {
                if !mine {
                    UnevenRoundedRectangle(cornerRadii: .init(
                        topLeading: !first ? tight : r, bottomLeading: !last ? tight : r,
                        bottomTrailing: r, topTrailing: r))
                        .strokeBorder(tint.opacity(0.22))
                }
            }
    }

    /// Hover tools beside the bubble: reply and react.
    private var actions: some View {
        HStack(spacing: 2) {
            Button(action: reply) { Image(systemName: "arrowshape.turn.up.left") }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("Reply")
                .accessibilityLabel("Reply")
            if canReact {
                Button { picking.toggle() } label: { Image(systemName: "face.smiling") }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .help("React")
                    .accessibilityLabel("React")
                    .popover(isPresented: $picking, arrowEdge: .top) {
                        HStack(spacing: 4) {
                            ForEach(Self.quick, id: \.self) { e in
                                Button {
                                    react(e)
                                    picking = false
                                } label: { if e == "❤️" { PulseHeart(size: 22) } else { Text(e).font(.system(size: 20)) } }
                                    .buttonStyle(EmojiButtonStyle(selected: message.reactions["me"] == e))
                            }
                        }
                        .padding(6)
                    }
            }
        }
        .opacity((hovering || picking) && swipe == 0 ? 1 : 0)
        .padding(.bottom, 4)
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

/// A collectible someone showed in the chat, drawn at a good size with its name and number.
private struct CollectibleCard: View {
    @Environment(\.theme) private var theme
    var collectible: Collectible
    var mine: Bool

    var body: some View {
        if let kind = collectible.kind {
            VStack(spacing: 4) {
                CollectibleIcon(item: kind, size: 132)
                Text(kind.name).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(mine ? Ink.onAccent : Ink.text).lineLimit(1)
                Text("#\(collectible.serial)").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(mine ? Ink.onAccent.opacity(0.7) : Ink.dim)
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(kind.name), number \(collectible.serial)")
        }
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
        if message.isMine { return model.activeProfile.notes?.first { $0.id == card.id } }
        return model.contact(message.sender, in: model.activePersona)?.notes?.first { $0.id == card.id }
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

    var body: some View {
        Button {
            if let url = URL(string: preview.url), LinkPreviews.isWebLink(preview.url) { Platform.open(url) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let image = preview.image, let ns = PlatformImage(data: image) {
                    Image(platformImage: ns).resizable().scaledToFill()
                        .frame(width: Platform.isPhone ? 250 : 300, height: Platform.isPhone ? 125 : 150).clipped()
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let title = preview.title {
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            .foregroundStyle(mine ? Ink.onAccent.opacity(0.85) : Ink.text)
                    }
                    Text(preview.site ?? URL(string: preview.url)?.host() ?? preview.url)
                        .font(.system(size: 11))
                        .foregroundStyle(mine ? Ink.onAccent.opacity(0.55) : Ink.faint)
                        .lineLimit(1)
                }
                .padding(10)
                .frame(width: Platform.isPhone ? 250 : 300, alignment: .leading)
            }
            .background(mine ? Ink.onAccent.opacity(0.1) : Ink.surface)
            .clipShape(.rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(mine ? Ink.onAccent.opacity(0.08) : Ink.line))
        }
        .buttonStyle(.plain)
        .help(preview.url)
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
    private var player: VoicePlayer { .shared }

    var body: some View {
        let playing = player.playing == id
        HStack(spacing: 10) {
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
            Waveform(levels: note.levels, progress: playing ? player.progress : 0,
                     color: mine ? Ink.onAccent.opacity(0.75) : Ink.text)
                .frame(width: 150, height: 28)
            Text(Duration.seconds(note.duration).formatted(.time(pattern: .minuteSecond)))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(mine ? Ink.onAccent.opacity(0.6) : Ink.dim)
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
        .help(online ? "Connected to the relay" : "Relay unreachable. Messages wait, sealed, on this \(Platform.isPhone ? "iPhone" : "Mac").")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(online ? "Connected to the relay" : "Relay unreachable")
    }
}

// MARK: - Details

/// Details and management for any chat: a person's nickname and verification, or a group or
/// channel's name, description, posting rights, admins and members.
private struct ConversationInfo: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let id: Conversation.ID
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
    /// Flips on as the sheet opens, so the profile eases in instead of just appearing.
    @State private var arrived = false

    var body: some View {
        if let c = model.conversation(id) {
            let person = c.kind == .direct ? model.contact(c.members.first ?? "", in: c.persona) : nil
            VStack(spacing: 0) {
                // A person's profile opens straight onto their banner; anything else keeps its title bar.
                if person == nil {
                    HStack {
                        Text(c.kind == .direct ? "Profile" : c.kind.label)
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

                ScrollView {
                    if let person {
                        personProfile(person, in: c)
                            .opacity(arrived ? 1 : 0)
                            .offset(y: arrived ? 0 : 18)
                    }
                    VStack(spacing: 18) {
                        if person == nil { identity(c) }
                        if let persona = c.persona, model.isBurner(persona) { burnButton(persona) }
                        switch c.kind {
                        case .direct: directSection(c)
                        case .channel where c.isAnnouncements: announcementsSection(c)
                        case .group, .channel: groupSections(c)
                        case .broadcast: membersSection(c)
                        }
                        actions(c)
                    }
                    .padding(20)
                    .confirms($pending)
                    .opacity(arrived ? 1 : 0)
                    .offset(y: arrived ? 0 : 18)
                    .scaleEffect(arrived ? 1 : 0.96, anchor: .top)
                }
                .scrollIndicators(.never)
                .ignoresSafeArea(edges: person == nil ? [] : .top)
            }
            .overlay(alignment: .topTrailing) {
                if person != nil {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.black.opacity(0.45), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .padding(14)
                    .accessibilityLabel("Close")
                }
            }
            .frame(width: Platform.isPhone ? nil : 440, height: Platform.isPhone ? nil : 640)
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
        }
    }

    // MARK: Top

    @ViewBuilder private func identity(_ c: Conversation) -> some View {
        if c.kind == .direct, let peer = model.contact(c.members.first ?? "", in: c.persona) {
            personProfile(peer, in: c)
        } else {
            let editable = c.kind != .direct && c.amAdmin
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

    /// A person's whole profile, as they made it. The banner runs edge to edge and fades into the page, their picture
    /// sits half over it inside a ring of their own colour, then the name, @handle, bio and the things they've
    /// pinned. Pulling down stretches the banner; everything eases in when the sheet opens.
    private func personProfile(_ peer: Contact, in c: Conversation) -> some View {
        let tint = Signature.color(peer.color, seed: peer.fingerprint)
        let theirName = peer.name.isEmpty ? "Anonymous" : peer.name
        let bannerHeight: CGFloat = 196
        return VStack(spacing: 0) {
            Banner(image: peer.banner, seed: peer.fingerprint, height: bannerHeight)
                .overlay {
                    // Their colour comes up from under the picture, and the banner melts into the page.
                    ZStack {
                        RadialGradient(colors: [tint.opacity(0.45), .clear], center: .bottom, startRadius: 0, endRadius: 220)
                        LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: Ink.base.opacity(0.7), location: 0.8),
                                               .init(color: Ink.base, location: 1)], startPoint: .top, endPoint: .bottom)
                    }
                }
                .visualEffect { content, proxy in
                    let pull = max(0, proxy.frame(in: .scrollView).minY)
                    return content.scaleEffect(1 + pull / bannerHeight, anchor: .bottom)
                }
                .accessibilityHidden(true)
            VStack(spacing: 14) {
                Avatar(image: c.avatar ?? peer.avatar, seed: peer.fingerprint, size: 112)
                    .padding(5)
                    .background(Ink.base, in: .circle)
                    .overlay {
                        Circle().strokeBorder(AngularGradient(colors: [tint, tint.opacity(0.35), tint], center: .center), lineWidth: 3)
                    }
                    .shadow(color: tint.opacity(0.55), radius: 28, y: 6)
                    .scaleEffect(arrived ? 1 : 0.8)
                VStack(spacing: 5) {
                    HStack(spacing: 7) {
                        Text(peer.nickname.isEmpty ? theirName : peer.nickname)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(Ink.text)
                            .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.7)
                        BadgeMark(badge: peer.badge, size: 24)
                        if peer.verified {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 16)).foregroundStyle(theme.accent)
                                .help("You checked their safety code in person")
                                .accessibilityLabel("Verified in person")
                        }
                    }
                    if !peer.nickname.isEmpty {
                        Text("Calls themselves \(theirName)").font(.system(size: 12)).foregroundStyle(Ink.faint)
                    }
                }
                if let handle = peer.handle {
                    HStack(spacing: 6) {
                        Text("@\(handle)").font(.system(size: 13, weight: .bold)).foregroundStyle(tint)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(tint.opacity(0.14), in: .capsule)
                            .overlay(Capsule().strokeBorder(tint.opacity(0.3)))
                        if DirectoryProfile.isReserved(handle) {
                            Label("Creator", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Ink.onAccent.opacity(0.85))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(theme.gradient, in: .capsule)
                                .help("This handle can only belong to PULSHADE's creator")
                        }
                    }
                }
                if peer.badge.isModerator { ModeratorTag() }
                if let bio = peer.bio, !bio.isEmpty {
                    Text(LinkPreviews.linked(bio))
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.dim)
                        .tint(tint)
                        .lineSpacing(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                        .textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    profileAction("Message", "bubble.left.fill", tint: tint) { dismiss() }
                    if !peer.isSelf {
                        profileAction("Call", "phone.fill", tint: tint) {
                            dismiss()
                            model.startCall(with: peer.fingerprint, persona: c.persona)
                        }
                    }
                    profileAction(c.muted ? "Unmute" : "Mute", c.muted ? "bell.fill" : "bell.slash.fill", tint: tint) {
                        model.toggleMute(c.id)
                    }
                }
                .padding(.top, 4)
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                    Text(summary(c)).font(.system(size: 12))
                }
                .foregroundStyle(Ink.faint)
                VStack(spacing: 14) {
                    ContactCollectibles(items: peer.collectibles ?? [], tint: tint)
                    ProfileLinkList(links: peer.links ?? [], tint: tint, walletChangedAt: peer.walletChangedAt, isMine: peer.isSelf)
                    ProfileNoteList(notes: peer.notes ?? [], tint: tint)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .offset(y: -62)
            .padding(.bottom, -62)
        }
        .frame(maxWidth: .infinity)
    }

    /// One of the round buttons under a profile: an icon in the person's colour, with its name beneath.
    private func profileAction(_ title: String, _ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 52, height: 52)
                    .background(tint.opacity(0.14), in: .circle)
                    .overlay(Circle().strokeBorder(tint.opacity(0.28)))
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.dim)
            }
            .frame(width: 72)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
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
                              message: "It's deleted for good, with its chats and contacts. Your main identity and other personas aren't touched.",
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

    @ViewBuilder private func directSection(_ c: Conversation) -> some View {
        if let fp = c.members.first, let contact = model.contact(fp, in: c.persona) {
            Card {
                Field(label: "Nickname") {
                    TextField("", text: $nickname, prompt: Text(contact.name.isEmpty ? "Add a nickname" : contact.name)
                        .foregroundStyle(Ink.faint))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { model.rename(fp, to: nickname.trimmingCharacters(in: .whitespaces)) }
                        // On iPhone the sheet is usually closed without pressing Return.
                        .onDisappear {
                            let wanted = nickname.trimmingCharacters(in: .whitespaces)
                            if wanted != contact.name { model.rename(fp, to: wanted) }
                        }
                }
                Divider().overlay(Ink.line)
                Button { pulseCheck = true } label: {
                    Field(label: "Pulse check") {
                        HStack(spacing: 6) {
                            Text(contact.verified ? "Verified" : "Not verified")
                                .foregroundStyle(contact.verified ? theme.accent : Ink.faint)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.faint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $pulseCheck) { PulseCheckView(fingerprint: fp, persona: c.persona) }
            }
        }
    }

    // MARK: Groups & channels

    private func announcementsSection(_ c: Conversation) -> some View {
        Card(title: "About", footer: "Each announcement is signed by PULSHADE and checked on this device, so nobody else can post here. Fetching them tells nobody who you are.") {
            Text(c.about ?? "")
                .foregroundStyle(Ink.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func groupSections(_ c: Conversation) -> some View {
        Card(title: "About") {
            if c.amAdmin {
                TextField("", text: $about, prompt: Text("Describe this \(c.kind == .channel ? "channel" : "group")")
                    .foregroundStyle(Ink.faint), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...5)
                    .onSubmit { commitDetails(c) }
            } else {
                Text(c.about?.isEmpty == false ? LinkPreviews.linked(c.about!) : AttributedString("No description"))
                    .foregroundStyle(c.about?.isEmpty == false ? Ink.text : Ink.faint)
                    .tint(theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onDisappear { if c.amAdmin && (about != (c.about ?? "") || title != c.title) { commitDetails(c) } }

        if c.kind == .channel && c.amAdmin { inviteSection(c) }

        Card(title: "Permissions") {
            Field(label: "Who can post") {
                if c.amOwner {
                    Picker("", selection: Binding(get: { c.postPolicy }, set: { model.setPostPolicy(c.id, $0) })) {
                        ForEach(c.kind == .channel ? [PostPolicy.admins, .owner] : PostPolicy.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text(c.postPolicy.label).foregroundStyle(Ink.dim)
                }
            }
            Divider().overlay(Ink.line)
            Field(label: "Your role") {
                Text(c.amOwner ? "Owner" : c.amAdmin ? "Admin" : c.amMod ? "Mod" : c.kind == .channel ? "Follower" : "Member")
                    .foregroundStyle(Ink.dim)
            }
        }

        membersSection(c)
    }

    private func inviteSection(_ c: Conversation) -> some View {
        let code = model.makeInviteCode(channel: c.id)
        return Card(title: "Invite link") {
            HStack(spacing: 14) {
                QRCode(text: Invite.link(code), size: 74)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Anyone with this link can follow.").font(.system(size: 12)).foregroundStyle(Ink.dim)
                    Button {
                        copyToClipboard(code)
                        withAnimation(.snappy) { copied = true }
                    } label: {
                        Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "link")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                }
                Spacer()
            }
        }
    }

    private func membersSection(_ c: Conversation) -> some View {
        let people = c.members
        let title = c.kind == .channel ? (c.amAdmin ? "Followers & admins" : "Admins") : "Members"
        return Card(title: "\(title) · \(people.count + (c.kind == .group ? 1 : 0))") {
            if c.kind != .broadcast, c.amAdmin {
                Button { adding = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28).background(theme.wash, in: .circle)
                            .foregroundStyle(theme.accent)
                        Text(c.kind == .channel ? "Add followers" : "Add members")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.accent)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().overlay(Ink.line)
            }
            if c.kind == .group {
                personRow(name: "\(model.profile(for: c.persona).displayName) (you)", fp: "me", c: c, avatar: model.profile(for: c.persona).avatar,
                          seed: model.me(c.persona)?.fingerprint ?? "")
            }
            ForEach(people, id: \.self) { fp in
                personRow(name: model.displayName(fp), fp: fp, c: c, avatar: model.contact(fp, in: c.persona)?.avatar, seed: fp)
            }
        }
    }

    private func personRow(name: String, fp: String, c: Conversation, avatar: Data?, seed: String) -> some View {
        HStack(spacing: 10) {
            Avatar(image: avatar, seed: seed, size: 28)
            Text(name).font(.system(size: 13)).foregroundStyle(Ink.text).lineLimit(1)
            Spacer()
            if let role = model.role(of: fp, in: c) {
                Text(role)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(theme.wash, in: .rect(cornerRadius: 4))
            }
            if fp != "me", c.kind != .broadcast, c.amAdmin || (c.amMod && c.canRemove(fp, by: "me")), fp != c.owner {
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
                            pending = Pending(title: "Remove \(name) from the \(c.kind == .channel ? "channel" : "group")?", confirm: "Remove") {
                                model.removeMember(c.id, fp)
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
        .padding(.vertical, 3)
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
                        Text("This chat is deleted on your side and anything they send is dropped. They aren't told. You can unblock them in Privacy & Security.")
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
                    Text(c.kind == .direct || c.amOwner || c.kind == .broadcast ? "Delete chat" : "Leave")
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
                Text(c.deleteWarning.detail)
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
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Ink.faint)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 10) { content }
                .font(.system(size: 13))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.surface, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
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
            let candidates = model.data.contacts.filter {
                !$0.hidden && !$0.awaitingAcceptance && $0.persona == c.persona && !c.members.contains($0.fingerprint)
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
                                    Button {
                                        if on { picked.remove(person.fingerprint) } else { picked.insert(person.fingerprint) }
                                    } label: {
                                        HStack(spacing: 10) {
                                            Avatar(image: person.avatar, seed: person.fingerprint, size: 30)
                                            Text(person.displayName).font(.system(size: 13)).foregroundStyle(Ink.text)
                                            Spacer()
                                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(on ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Ink.faint))
                                        }
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(on ? Ink.raised : .clear, in: .rect(cornerRadius: 8))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
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

/// Adds the swipe-to-reply drag on iPhone only; on the Mac a drag would fight with selecting text.
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
