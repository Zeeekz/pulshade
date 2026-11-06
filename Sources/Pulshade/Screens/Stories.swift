import SwiftUI

/// Story palettes for text stories: always dark, always glowing.
enum StoryPalette {
    static let all: [[Color]] = [
        [.hex(0x2EF2C8), .hex(0x6A5CFF)], [.hex(0xFF7A3D), .hex(0x9B1DFF)], [.hex(0x3DB8FF), .hex(0x0B0B40)],
        [.hex(0xB6FF3D), .hex(0x00494A)], [.hex(0xFF5FD2), .hex(0x2B0B4A)], [.hex(0xFFC93D), .hex(0x6A0F3A)],
    ]
    static func gradient(_ i: Int) -> LinearGradient {
        LinearGradient(colors: all[i % all.count], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Horizontal row at the top of the chat list: you first, then friends with live stories.
struct StoryStrip: View {
    @Environment(AppModel.self) private var model
    @Binding var composing: Bool
    @Binding var viewing: StoryReel?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                Button {
                    model.myStories.isEmpty ? (composing = true)
                        : (viewing = StoryReel(stories: model.myStories, following: unseenReels(after: nil)))
                } label: {
                    StoryBubble(image: model.activeProfile.avatar, seed: model.fingerprint, name: "Your story",
                                active: !model.myStories.isEmpty, adding: model.myStories.isEmpty,
                                uploading: model.storyUpload, glow: model.hasUnviewedStory)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .topLeading) {
                    // Once you have a story the bubble opens it, so adding another gets its own button on the corner.
                    if !model.myStories.isEmpty {
                        Button { composing = true } label: {
                            SymbolBadge(symbol: "plus", size: 22)
                                .frame(width: 40, height: 40)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 32, y: 30)
                        .accessibilityLabel("New story")
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .contextMenu {
                    Button("New story", systemImage: "plus") { composing = true }
                    ForEach(model.myStories) { story in
                        Button("Delete story from \(story.date.formatted(date: .omitted, time: .shortened))",
                               systemImage: "trash", role: .destructive) { model.deleteStory(story.id) }
                    }
                }
                .accessibilityLabel(model.myStories.isEmpty ? "New story" : "Your story")

                ForEach(model.friendStories, id: \.author) { entry in
                    let contact = model.contact(entry.author)
                    Button {
                        viewing = StoryReel(stories: entry.stories, start: entry.stories.firstIndex { !$0.seen } ?? 0,
                                            following: unseenReels(after: entry.author))
                    } label: {
                        StoryBubble(image: contact?.avatar, seed: entry.author, name: model.displayName(entry.author),
                                    active: entry.stories.contains { !$0.seen }, adding: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.displayName(entry.author))
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)

    }

    /// The row's stories that haven't all been seen, after `author`'s (or all of them, from your own).
    private func unseenReels(after author: String?) -> [[Story]] {
        let all = model.friendStories
        let rest = author.flatMap { a in all.firstIndex { $0.author == a }.map { Array(all[($0 + 1)...]) } } ?? all
        return rest.filter { $0.stories.contains { !$0.seen } }.map(\.stories)
    }
}

struct StoryReel: Identifiable {
    let id = UUID()
    var stories: [Story]
    var start = 0
    /// Whose stories play next when these run out: the people after them in the row who have something unseen.
    var following: [[Story]] = []
}

private struct StoryBubble: View {
    var image: Data?
    var seed: String
    var name: String
    var active: Bool
    var adding: Bool
    var uploading: Double?
    var glow = false
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            StoryRing(active: active, size: 60, uploading: uploading, glow: glow) {
                ZStack(alignment: .bottomTrailing) {
                    Avatar(image: image, seed: seed, size: 50)
                    if adding { SymbolBadge(symbol: "plus", size: 18) }
                }
            }
            Text(name)
                .font(.system(size: 10, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Ink.text : Ink.faint)
                .lineLimit(1)
                .frame(width: 64)
        }
        .scaleEffect(hover ? 1.05 : 1)
        .onHover { h in withAnimation(.snappy(duration: 0.3)) { hover = h } }
    }
}

/// The visible face of a story, shared by the card, the composer preview and the viewer.
/// Story pictures, decoded once. Decoding a photo takes long enough to be felt when it happens as the next story
/// slides in, so the ones either side of the story on screen are decoded ahead, off the main thread.
enum StoryImages {
    private static let cache = NSCache<NSString, PlatformImage>()

    static func image(id: UUID, data: Data) -> PlatformImage? {
        let key = "\(id.uuidString)-\(data.count)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        #if os(iOS)
        guard let raw = UIImage(data: data) else { return nil }
        let image = raw.preparingForDisplay() ?? raw
        #else
        guard let image = NSImage(data: data) else { return nil }
        #endif
        cache.setObject(image, forKey: key)
        return image
    }

    static func prefetch(_ story: Story) {
        guard case let .image(data, _) = story.style else { return }
        let id = story.id
        Task.detached(priority: .userInitiated) { _ = image(id: id, data: data) }
    }
}

struct StoryFace: View {
    var story: Story
    var compact = false
    /// Set while a video story is playing.
    var clip: StoryClip?

    var body: some View {
        ZStack {
            switch story.style {
            case let .text(text, palette):
                StoryPalette.gradient(palette)
                GenerativeArt(seed: story.id.uuidString).opacity(0.18).blendMode(.overlay)
                Text(text)
                    .font(.system(size: compact ? 20 : 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.35), radius: 10)
                    .padding(compact ? 16 : 40)
            case let .image(data, caption):
                Color.black
                if let img = StoryImages.image(id: story.id, data: data) {
                    Image(platformImage: img).resizable().scaledToFill()
                }
                if !caption.isEmpty { StoryCaption(text: caption, compact: compact) }
            case let .video(data, caption):
                Color.black
                if data.isEmpty {
                    // Still arriving: it plays as soon as the last piece is in.
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        if !compact { Text("Loading video").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8)) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Loading video")
                } else if let clip {
                    LayerView(layer: clip.layer).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    StoryPoster(data: data)
                }
                if !caption.isEmpty { StoryCaption(text: caption, compact: compact) }
            }
        }
        .clipped()
    }
}

struct StoryCaption: View {
    var text: String
    var compact: Bool

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: compact ? 13 : 18, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.45), in: .capsule)
                .padding(.bottom, compact ? 36 : 60)
        }
    }
}

// MARK: - Composer

/// Writes a new story, or edits one you posted: its words, who sees it and how long it lasts.
struct StoryComposer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = ""
    @State private var palette = 0
    @State private var image: Data?
    /// A recorded or picked clip, not yet compressed. Held in memory only.
    @State private var clip: MemoryClip?
    /// Zoom recorded with the clip, for cameras that couldn't zoom for real.
    @State private var clipZoom = ZoomTrack.none
    @State private var clipPreview: ClipPreview?
    @State private var filter = StoryFilter.none
    /// The photo with the look applied, for the preview.
    @State private var looked: Data?
    @State private var exporting = false
    @State private var failure: String?
    @State private var audience: StoryAudience = .everyone
    @State private var lifetime = StoryLifetime.day.rawValue
    @State private var choosingAudience = false
    /// Text placed on the picture, clip or colours, and the piece being worked on.
    @State private var overlays: [StoryTextOverlay] = []
    /// The piece being typed, and the one pinch and twist act on (the last touched).
    @State private var typing: UUID?
    @State private var active: UUID?
    @State private var choosingSettings = false
    @State private var seed = UUID().uuidString
    /// The story being edited, if this isn't a new one.
    private var editing: Story?
    /// After posting, so the camera behind closes too.
    var posted: () -> Void = {}

    init(image: Data? = nil, clip: MemoryClip? = nil, zoom: ZoomTrack = .none, filter: StoryFilter = .none, posted: @escaping () -> Void = {}) {
        _image = State(initialValue: image)
        _clip = State(initialValue: clip)
        _clipZoom = State(initialValue: zoom)
        _filter = State(initialValue: filter)
        self.posted = posted
    }

    init(editing story: Story) {
        editing = story
        switch story.style {
        case let .text(text, palette):
            _text = State(initialValue: text)
            _palette = State(initialValue: palette)
        case let .image(data, caption):
            _image = State(initialValue: data)
            _text = State(initialValue: caption)
        case let .video(_, caption):
            _text = State(initialValue: caption)
        }
        _audience = State(initialValue: story.shownTo)
        _lifetime = State(initialValue: story.lifetime ?? StoryLifetime.day.rawValue)
    }

    /// Whether the picture or clip can still change its look (a posted story keeps the one it was posted with).
    private var canFilter: Bool { editing == nil && (image != nil || clip != nil) }

    private var preview: Story {
        if let editing, case let .video(clip, _) = editing.style {
            return Story(id: editing.id, author: "me", style: .video(clip, caption: text))
        }
        return Story(id: editing?.id ?? UUID(), author: "me",
                     style: (looked ?? image).map { .image($0, caption: text) } ?? .text(text.isEmpty ? "✦" : text, palette: palette))
    }

    var body: some View {
        Group {
            if editing == nil { creator } else { legacyBody }
        }
        .onAppear {
            guard editing == nil else { return }
            audience = model.storyChoice.audience
            lifetime = model.storyChoice.lifetime
            startTyping()
        }
        .onChange(of: image == nil && clip == nil) { _, plain in if plain { startTyping() } }
        .task(id: clip?.id) { openClip() }
        .task(id: [filter.rawValue, String(image?.count ?? 0)]) { await look() }
        .onChange(of: filter) { _, new in clipPreview?.set(new) }
        .onDisappear {
            clipPreview?.close()
            clip = nil
        }
    }

    private var legacyBody: some View {
        legacyContent
            .sheet(isPresented: $choosingAudience) { StoryAudiencePicker(audience: $audience) }
    }

    private var legacyContent: some View {
        SheetBody(width: 440) {
            VStack(spacing: 18) {
                SheetHeader(symbol: "circle.dashed.inset.filled", title: editing == nil ? "Story" : "Edit story")
                face
                    .frame(width: 260, height: 400)
                    .clipShape(.rect(cornerRadius: 26))
                    .shadow(color: theme.accent.opacity(0.35), radius: 30)
                    .animation(.smooth, value: palette)
                    .animation(.smooth, value: image)
                if canFilter { FilterDots(filter: $filter) }

                if image == nil && clip == nil && !isVideoEdit {
                    HStack(spacing: 10) {
                        ForEach(0..<StoryPalette.all.count, id: \.self) { i in
                            Circle().fill(StoryPalette.gradient(i))
                                .frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(.white, lineWidth: palette == i ? 2.5 : 0))
                                .scaleEffect(palette == i ? 1.15 : 1)
                                .onTapGesture { withAnimation(.snappy) { palette = i } }
                        }
                    }
                }

                TextField(image == nil && clip == nil && !isVideoEdit ? "Say something" : "Caption", text: $text)
                    .textFieldStyle(PulseFieldStyle())

                SettingsGroup {
                    Button { choosingAudience = true } label: {
                        SettingRow("Who can see it", symbol: "person.2") {
                            Text(model.summary(of: audience)).font(.system(size: 14)).foregroundStyle(Ink.faint).lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.faint)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    RowDivider(inset: 52)
                    SettingRow("Lasts", symbol: "clock") {
                        Picker("", selection: $lifetime) {
                            ForEach(StoryLifetime.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                if let failure {
                    Text(failure).font(.system(size: 13)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    if editing == nil {
                        if image != nil || clip != nil {
                            Button { withAnimation { image = nil; clip = nil; looked = nil; filter = .none } } label: { Image(systemName: "textformat") }
                                .buttonStyle(IconButtonStyle(size: 46))
                                .disabled(exporting)
                                .accessibilityLabel("Write a text story instead")
                        } else {
                            StoryMediaPicker(picked: { kind in
                                withAnimation {
                                    switch kind {
                                    case let .photo(data): image = data
                                    case let .clip(picked, zoom): clip = picked; clipZoom = zoom
                                    }
                                }
                            }) {
                                Image(systemName: "photo.fill")
                            }
                            .buttonStyle(IconButtonStyle(size: 46))
                            .accessibilityLabel("Choose a photo or video")
                        }
                    }
                    Button { post() } label: {
                        if exporting {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: editing == nil ? "arrow.up" : "checkmark")
                        }
                    }
                    .buttonStyle(GlowButtonStyle(size: 46))
                    .disabled(exporting || !canPost)
                    .accessibilityLabel(exporting ? "Preparing video" : editing == nil ? "Post" : "Save")
                }
            }
        }
    }


    // MARK: New story

    /// The biggest 9:16 frame that fits.
    private func fit(_ size: CGSize) -> CGSize {
        let width = max(min(size.width, size.height * 9 / 16), 1)
        return CGSize(width: width, height: width * 16 / 9)
    }

    private func addText() {
        // New text starts like the last piece, so a few lines match without fiddling.
        var item = StoryTextOverlay()
        if let last = overlays.last(where: { !$0.isEmpty }) {
            item.color = last.color; item.face = last.face; item.backed = last.backed; item.size = last.size
        }
        withAnimation(.snappy(duration: 0.2)) { overlays.append(item) }
        active = item.id
        typing = item.id
    }

    /// The editor: the story full screen with text on it, controls floating over the edges.
    private var creator: some View {
        GeometryReader { geo in
            let canvas = fit(geo.size)
            ZStack {
                Color.black.ignoresSafeArea()
                ZStack {
                    baseFace
                        .frame(width: canvas.width, height: canvas.height)
                        .modifier(OptionalFilterSwipe(filter: $filter, enabled: canFilter && typing == nil))
                    StoryOverlayCanvas(items: $overlays, active: $active, typing: $typing, canvas: canvas, add: addText)
                }
                .frame(width: canvas.width, height: canvas.height)
                .clipShape(.rect(cornerRadius: Platform.isPhone ? 0 : 16))

                if typing == nil {
                    VStack {
                        HStack {
                            floating("xmark", label: "Close") { dismiss() }
                            Spacer()
                            floating("textformat", label: "Add text") { addText() }
                        }
                        .padding(.horizontal, 14).padding(.top, 6)
                        Spacer()
                        bottomControls
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .transition(.opacity)
                }
                if typing != nil {
                    StoryTypingOverlay(items: $overlays, typing: $typing, canvasWidth: canvas.width)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .animation(.snappy(duration: 0.2), value: typing)
        .sheet(isPresented: $choosingSettings) { settingsSheet }
    }

    private func floating(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.4), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            if let failure {
                Text(failure).font(.system(size: 13)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(.black.opacity(0.5), in: .capsule)
            }
            if canFilter { FilterDots(filter: $filter) }
            if image == nil && clip == nil {
                HStack(spacing: 12) {
                    ForEach(0..<StoryPalette.all.count, id: \.self) { i in
                        Circle().fill(StoryPalette.gradient(i))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(.white, lineWidth: palette == i ? 2.5 : 0))
                            .scaleEffect(palette == i ? 1.15 : 1)
                            .onTapGesture { withAnimation(.snappy) { palette = i } }
                    }
                }
            }
            HStack(spacing: 10) {
                if image != nil || clip != nil {
                    floating("textformat.abc", label: "Write a text story instead") {
                        withAnimation { image = nil; clip = nil; looked = nil; filter = .none }
                    }
                    .disabled(exporting)
                } else {
                    StoryMediaPicker(picked: { kind in
                        withAnimation {
                            switch kind {
                            case let .photo(data): image = data
                            case let .clip(picked, zoom): clip = picked; clipZoom = zoom
                            }
                        }
                    }) {
                        Image(systemName: "photo.fill")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(.black.opacity(0.4), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose a photo or video")
                }
                Spacer()
                Button { choosingSettings = true } label: {
                    Label(model.summary(of: audience), systemImage: "person.2.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        .padding(.horizontal, 14).frame(height: 40)
                        .background(.black.opacity(0.4), in: .capsule)
                }
                .buttonStyle(.plain)
                Button { post() } label: {
                    if exporting { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: "arrow.up") }
                }
                .buttonStyle(GlowButtonStyle(size: 44))
                .disabled(exporting || !canPost)
                .accessibilityLabel(exporting ? "Preparing video" : "Post")
            }
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 8)
    }

    /// Who can see it and how long it lasts, one tap from the editor.
    private var settingsSheet: some View {
        SheetBody(width: 420) {
            VStack(spacing: 18) {
                SheetHeader(symbol: "person.2.fill", title: "Share story")
                SettingsGroup {
                    Button { choosingAudience = true } label: {
                        SettingRow("Who can see it", symbol: "person.2") {
                            Text(model.summary(of: audience)).font(.system(size: 14)).foregroundStyle(Ink.faint).lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.faint)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    RowDivider(inset: 52)
                    SettingRow("Lasts", symbol: "clock") {
                        Picker("", selection: $lifetime) {
                            ForEach(StoryLifetime.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .sheet(isPresented: $choosingAudience) { StoryAudiencePicker(audience: $audience) }
    }

    /// Whether there's something to post: text on a colour, a picture or a clip, or an edit.
    private var canPost: Bool {
        if editing != nil { return image != nil || isVideoEdit || !text.trimmingCharacters(in: .whitespaces).isEmpty }
        return image != nil || clip != nil || overlays.contains { !$0.isEmpty }
    }

    /// A story of only colours and words opens with a line of text ready to type, in the middle.
    private func startTyping() {
        guard editing == nil, image == nil, clip == nil, overlays.allSatisfy(\.isEmpty) else { return }
        var first = StoryTextOverlay()
        first.size = 0.1
        overlays = [first]
        active = first.id
        typing = first.id
    }

    @ViewBuilder private var baseFace: some View {
        if clip != nil, let clipPreview {
            ZStack {
                Color.black
                LayerView(layer: clipPreview.layer)
            }
            .accessibilityLabel("Video preview")
        } else if clip != nil {
            Color.black.overlay { ProgressView().tint(.white) }
        } else if let shown = looked ?? image, let img = PlatformImage(data: shown) {
            ZStack {
                Color.black
                Image(platformImage: img).resizable().scaledToFill()
            }
            .clipped()
        } else {
            StoryTextBackdrop(palette: palette, seed: seed)
        }
    }

    private var isVideoEdit: Bool {
        if let editing, case .video = editing.style { return true }
        return false
    }

    @ViewBuilder private var face: some View {
        if clip != nil, let clipPreview {
            ZStack {
                Color.black
                LayerView(layer: clipPreview.layer)
                if !text.isEmpty { StoryCaption(text: text, compact: false) }
            }
            .accessibilityLabel("Video preview")
        } else if clip != nil {
            Color.black.overlay { ProgressView().tint(.white) }
        } else {
            StoryFace(story: preview)
        }
    }

    private func openClip() {
        clipPreview?.close()
        clipPreview = nil
        guard let clip else { return }
        clipPreview = ClipPreview(clip: clip, filter: filter, zoom: clipZoom)
    }

    /// Colours the photo for the preview.
    private func look() async {
        guard let image, editing == nil else { looked = nil; return }
        if filter == .none { looked = nil; return }
        let look = filter
        let made = await Task.detached(priority: .userInitiated) { look.bake(into: image, maxSide: 900) }.value
        guard look == filter else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { looked = made }
    }

    private func post() {
        if let editing {
            model.editStory(editing.id, style: preview.style, audience: audience, lifetime: lifetime)
            finish()
        } else if let clip {
            exporting = true
            failure = nil
            let look = filter, track = clipZoom
            let words = StoryOverlayRender.text(overlays)
            Task {
                do {
                    let began = Date()
                    let data = try await StoryVideo.export(from: clip, filter: look, zoom: track, text: words)
                    model.postStory(.video(data, caption: ""), audience: audience, lifetime: lifetime)
                    exporting = false
                    finish()
                } catch {
                    exporting = false
                    failure = (error as? LocalizedError)?.errorDescription ?? "The video couldn't be prepared."
                }
            }
        } else if let image {
            // The look is baked into the pixels that are sent, not just the preview.
            let words = StoryOverlayRender.text(overlays)
            let sent = (filter == .none && words == nil) ? image : (filter.bake(into: image, text: words) ?? image)
            model.postStory(.image(sent, caption: ""), audience: audience, lifetime: lifetime)
            finish()
        } else if let made = StoryOverlayRender.textStory(overlays, palette: palette, seed: seed) {
            // A story of colours and words goes out as a picture, so it looks the same for everyone, however
            // the text was placed.
            model.postStory(.image(made, caption: ""), audience: audience, lifetime: lifetime)
            finish()
        } else {
            failure = "The story couldn't be prepared."
        }
    }

    private func finish() {
        dismiss()
        posted()
    }
}

extension View {
    /// The story viewer: full screen on the phone, so the picture reaches the top and bottom of the screen, and a
    /// sheet on the Mac.
    func viewerCover<Item: Identifiable, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(item: item) { content($0) }
        #else
        sheet(item: item) { content($0) }
        #endif
    }

    /// The story editor: full screen on the phone, a sheet the size of a story on the Mac.
    func composerCover<Item: Identifiable, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(item: item) { content($0) }
        #else
        sheet(item: item) { content($0).frame(width: 420, height: 740) }
        #endif
    }

    func composerCover<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented) { content().frame(width: 420, height: 740) }
        #endif
    }
}

/// Adds the swipe-to-change-look gesture only when there's something to colour.
private struct OptionalFilterSwipe: ViewModifier {
    @Binding var filter: StoryFilter
    var enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.filterSwipe($filter) } else { content }
    }
}

/// Who sees a story: all contacts, only some, or all but some.
struct StoryAudiencePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Binding var audience: StoryAudience
    @State private var mode = Mode.everyone
    @State private var picked: Set<String> = []

    enum Mode: CaseIterable {
        case everyone, only, except
        var label: String {
            switch self {
            case .everyone: "All contacts"
            case .only: "Selected contacts"
            case .except: "All contacts except…"
            }
        }
    }

    private var chosen: StoryAudience {
        let list = model.visibleContacts.map(\.fingerprint).filter(picked.contains)
        switch mode {
        case .everyone: return .everyone
        case .only: return .only(list)
        case .except: return .except(list)
        }
    }

    private var contacts: [Contact] {
        model.visibleContacts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        SheetBody(width: 420) {
            VStack(alignment: .leading, spacing: 20) {
                SheetHeader(symbol: "person.2.fill", title: "Who can see it")
                SettingsGroup(footer: footer) {
                    ForEach(Array(Mode.allCases.enumerated()), id: \.offset) { i, m in
                        if i > 0 { RowDivider() }
                        Button { withAnimation(.snappy) { mode = m } } label: {
                            SettingRow(m.label) {
                                if mode == m {
                                    Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if mode != .everyone {
                    SettingsGroup(mode == .only ? "Share with" : "Hide from") {
                        if contacts.isEmpty {
                            SettingRow("No contacts yet") { EmptyView() }
                        }
                        ForEach(Array(contacts.enumerated()), id: \.element.id) { i, c in
                            if i > 0 { RowDivider(inset: 62) }
                            Button {
                                withAnimation(.snappy(duration: 0.2)) {
                                    if picked.contains(c.fingerprint) { picked.remove(c.fingerprint) } else { picked.insert(c.fingerprint) }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Avatar(image: c.avatar, seed: c.fingerprint, size: 34)
                                    Text(c.displayName).font(.system(size: 15)).foregroundStyle(Ink.text).lineLimit(1)
                                    Spacer()
                                    Image(systemName: picked.contains(c.fingerprint) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundStyle(picked.contains(c.fingerprint) ? theme.accent : Ink.faint)
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 52)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .transition(.opacity)
                }
                Button("Done") {
                    audience = chosen
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(mode == .only && picked.isEmpty)
            }
        }
        .onAppear {
            switch audience {
            case .everyone: mode = .everyone
            case let .only(list): mode = .only; picked = Set(list)
            case let .except(list): mode = .except; picked = Set(list)
            }
        }
    }

    private var footer: String {
        switch mode {
        case .everyone: "Everyone in your contacts sees it."
        case .only: "Only the people you pick see it."
        case .except: "Everyone in your contacts sees it, except the people you pick."
        }
    }
}

/// The progress of the story on screen.
@Observable
final class StoryClock {
    var progress: Double = 0
}

/// One bar per story, filling as each plays. It is the only thing that redraws as time passes.
private struct StoryBars: View {
    var count: Int
    var index: Int
    var clock: StoryClock

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                GeometryReader { geo in
                    Capsule().fill(.white.opacity(0.25))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white)
                                .frame(width: geo.size.width * (i < index ? 1 : i == index ? clock.progress : 0))
                        }
                }
                .frame(height: 3)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Who viewed one of your stories.
struct StoryViewers: View {
    @Environment(AppModel.self) private var model
    var story: Story

    var body: some View {
        let viewers = model.viewers(of: story.id)
        SheetBody(width: 420) {
            VStack(alignment: .leading, spacing: 20) {
                SheetHeader(symbol: "eye.fill", title: viewers.isEmpty ? "Views" : "Views · \(viewers.count)")
                SettingsGroup(footer: footer) {
                    if viewers.isEmpty {
                        SettingRow(model.data.security.storyViews ? "No views yet" : "Story views are off") { EmptyView() }
                    }
                    ForEach(Array(viewers.enumerated()), id: \.element.fingerprint) { i, v in
                        if i > 0 { RowDivider(inset: 62) }
                        HStack(spacing: 12) {
                            Avatar(image: model.contact(v.fingerprint, in: story.persona)?.avatar, seed: v.fingerprint, size: 34)
                            Text(model.contact(v.fingerprint, in: story.persona)?.displayName ?? "Unknown")
                                .font(.system(size: 15)).foregroundStyle(Ink.text).lineLimit(1)
                            Spacer()
                            Text(v.at.formatted(.relative(presentation: .named)))
                                .font(.system(size: 13)).foregroundStyle(Ink.faint)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 52)
                    }
                }
                SettingsGroup {
                    SettingRow("Shared with", symbol: "person.2") {
                        Text(model.summary(of: story.shownTo)).font(.system(size: 14)).foregroundStyle(Ink.faint)
                    }
                    RowDivider(inset: 52)
                    SettingRow("Disappears", symbol: "clock") {
                        Text(story.expires.formatted(.relative(presentation: .named))).font(.system(size: 14)).foregroundStyle(Ink.faint)
                    }
                }
            }
        }
    }

    private var footer: String {
        model.data.security.storyViews
            ? "Views travel encrypted like messages; the server never sees them. People with story views off aren't listed."
            : "Turn on Story views in Privacy & Security to see who viewed your stories. While it's off, nobody sees that you viewed theirs."
    }
}

// MARK: - Camera

extension View {
    /// The story camera: full screen on iPhone, a sheet on the Mac.
    func storyCamera(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented) { StoryCamera() }
        #else
        sheet(isPresented: isPresented) { StoryCamera().frame(width: 420, height: 720) }
        #endif
    }
}

/// Where a new story starts: the camera, with the library and text stories a tap away. Tap the button for a
/// photo, hold it for a video (drag up and down while holding to zoom, up to 15 seconds). Swipe left or right on
/// the picture to change the look, pinch to zoom (out to the ultra wide lens where there is one), tap to focus,
/// double-tap to switch cameras, also while recording. A photo is framed to the story's shape, then captioned and
/// posted; a clip goes straight to the composer.
struct StoryCamera: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera = Camera()
    @State private var ready: Bool?
    @State private var pending: PendingCrop?
    /// What the camera has opened over itself: the editor for a picked item, or the text-story editor. One cover, not
    /// two: SwiftUI can't keep two full-screen covers on one view straight, and it dismissed the photo picker.
    private enum Cover: Identifiable {
        case framed(StoryPick), writing
        var id: String {
            switch self {
            case let .framed(pick): "framed-\(pick.id)"
            case .writing: "writing"
            }
        }
    }
    @State private var cover: Cover?
    @State private var filter = StoryFilter.none
    // The shutter: a press that lasts becomes a clip.
    @State private var pressStart: Date?
    @State private var holdTask: Task<Void, Never>?
    @State private var holdRecording = false
    @State private var zoomAtPress: CGFloat = 1
    // Pinching to zoom.
    @State private var pinchBase: CGFloat?
    @State private var pinching = false
    @State private var zoomShown = false
    @State private var zoomToken = UUID()
    // Tap to focus: where, and a token so the ring fades by itself.
    @State private var focusAt: CGPoint?
    @State private var focusToken = UUID()
    /// The picture blurs for a moment as the camera switches.
    @State private var flipBlur: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if ready == true {
                GeometryReader { geo in
                    ZStack {
                        LayerView(layer: camera.preview)
                            .blur(radius: flipBlur)
                        if let focusAt {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.yellow, lineWidth: 1.5)
                                .frame(width: 72, height: 72)
                                .position(focusAt)
                                .transition(.scale(scale: 1.3).combined(with: .opacity))
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(ExclusiveGesture(SpatialTapGesture(count: 2), SpatialTapGesture(count: 1))
                        .onEnded { result in
                            switch result {
                            case .first: flipCamera()
                            case let .second(tap): focus(at: tap.location, in: geo.size)
                            }
                        })
                }
                .ignoresSafeArea()
                    .filterSwipe($filter, enabled: !pinching && pressStart == nil)
                    .simultaneousGesture(MagnifyGesture()
                        .onChanged { value in
                            pinching = true
                            if pinchBase == nil { pinchBase = camera.zoom }
                            camera.setZoom((pinchBase ?? 1) * value.magnification)
                        }
                        .onEnded { _ in pinchBase = nil; pinching = false })
                    #if os(macOS)
                    .background(ScrollZoom { dy in camera.setZoom(camera.zoom * exp(dy * 0.03)) })
                    #endif
                    .accessibilityLabel("Camera preview")
            } else if ready == false {
                VStack(spacing: 10) {
                    Image(systemName: "camera.fill").font(.system(size: 34)).foregroundStyle(Ink.faint)
                    Text("No camera available").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text)
                    Text("Choose a photo or video, or write a text story.").font(.system(size: 13)).foregroundStyle(Ink.dim)
                }
            }
            if zoomShown {
                Text(ZoomMath.label(camera.zoom))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(.black.opacity(0.45), in: .capsule)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 190)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            VStack {
                HStack {
                    control("xmark", label: "Close") { dismiss() }
                    Spacer()
                    if camera.recording, let start = camera.recordingStart {
                        TimelineView(.periodic(from: start, by: 0.25)) { context in
                            let seconds = min(Int(context.date.timeIntervalSince(start)), Int(StoryVideo.maxSeconds))
                            Text("0:" + String(format: "%02d", seconds))
                                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12).frame(height: 32)
                                .background(.red.opacity(0.85), in: .capsule)
                                .accessibilityLabel("Recording, \(seconds) seconds")
                        }
                    }
                    Spacer()
                    if camera.hasFlash && ready == true {
                        control(camera.flash ? "bolt.fill" : "bolt.slash.fill", label: camera.flash ? "Flash on" : "Flash off") {
                            camera.flash.toggle()
                        }
                    }
                }
                Spacer()
                if camera.lensStops.count > 1 && ready == true { lensPills.padding(.bottom, 10) }
                FilterDots(filter: $filter).padding(.bottom, 6)
                    .opacity(camera.recording ? 0 : 1)
                HStack(alignment: .center) {
                    StoryMediaPicker(picked: { kind in cover = .framed(StoryPick(kind: kind, filter: filter)) }) {
                        controlFace("photo.on.rectangle")
                    }
                    .accessibilityLabel("Choose a photo or video")
                    .disabled(camera.recording)
                    .opacity(camera.recording ? 0.35 : 1)
                    Spacer()
                    shutter
                    Spacer()
                    #if os(iOS)
                    control("arrow.triangle.2.circlepath.camera", label: "Switch camera") { flipCamera() }
                        .disabled(ready != true)
                    #else
                    controlFace("camera").opacity(0)
                    #endif
                }
                .padding(.horizontal, 28)
                HStack(spacing: 12) {
                    Text("Tap for photo · Hold for video · Double-tap to flip")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    Button { cover = .writing } label: {
                        Text("Aa  Text")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.white.opacity(0.15), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Text story")
                }
                .padding(.top, 14)
                .opacity(camera.recording ? 0 : 1)
                .disabled(camera.recording)
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 16)
        }
        .preferredColorScheme(.dark)
        .task {
            ready = await camera.start()
            if ready == true { await camera.allowSound() }
        }
        .onDisappear { camera.stop() }
        .onChange(of: filter) { _, new in camera.filter = new }
        .onChange(of: camera.zoom) { _, _ in
            withAnimation(.easeOut(duration: 0.15)) { zoomShown = true }
            zoomToken = UUID()
        }
        .onChange(of: camera.recording) { _, now in if !now { holdRecording = false } }
        .task(id: focusToken) {
            guard focusAt != nil else { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { focusAt = nil }
        }
        .task(id: zoomToken) {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { zoomShown = false }
        }
        .cropper($pending, frame: .story) { data in cover = .framed(StoryPick(kind: .photo(data), filter: filter)) }
        .composerCover(item: $cover) { cover in
            switch cover {
            case let .framed(pick):
                switch pick.kind {
                case let .photo(data): StoryComposer(image: data, filter: pick.filter, posted: { dismiss() })
                case let .clip(url, zoom): StoryComposer(clip: url, zoom: zoom, filter: pick.filter, posted: { dismiss() })
                }
            case .writing: StoryComposer(posted: { dismiss() })
            }
        }
    }

    // MARK: Camera controls

    private func flipCamera() {
        #if os(iOS)
        guard ready == true else { return }
        Haptics.tick()
        camera.flip()
        guard !reduceMotion else { return }
        withAnimation(.easeIn(duration: 0.1)) { flipBlur = 24 }
        Task {
            try? await Task.sleep(for: .seconds(0.3))
            withAnimation(.easeOut(duration: 0.25)) { flipBlur = 0 }
        }
        #endif
    }

    private func focus(at point: CGPoint, in size: CGSize) {
        guard ready == true else { return }
        camera.focus(at: point, in: size)
        withAnimation(.spring(duration: 0.25)) { focusAt = point }
        focusToken = UUID()
    }

    /// Jumps between the lenses, as 0.5 · 1 · 3 above the shutter.
    private var lensPills: some View {
        HStack(spacing: 6) {
            ForEach(camera.lensStops, id: \.self) { stop in
                let on = abs(camera.zoom - stop) < 0.08
                Button { camera.setZoom(stop) } label: {
                    Text(on ? ZoomMath.label(stop) : String(format: "%g", Double(stop)))
                        .font(.system(size: on ? 13 : 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(on ? Color.yellow : .white)
                        .frame(width: on ? 40 : 32, height: on ? 40 : 32)
                        .background(.black.opacity(0.4), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom \(String(format: "%g", Double(stop))) times")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.black.opacity(0.25), in: .capsule)
        .animation(reduceMotion ? nil : .snappy, value: camera.zoom)
    }

    // MARK: Shutter

    /// Down starts the clock; a press that lasts starts a clip, and dragging up or down then zooms.
    private func shutterMoved(_ drag: DragGesture.Value) {
        guard ready == true else { return }
        if pressStart == nil {
            pressStart = Date()
            zoomAtPress = camera.zoom
            holdTask = Task {
                try? await Task.sleep(for: .seconds(ShutterTiming.holdAfter))
                guard !Task.isCancelled else { return }
                startClip()
            }
        }
        if holdRecording {
            camera.setZoom(ZoomMath.zoom(start: zoomAtPress, drag: drag.translation.height, min: camera.minZoom, max: camera.maxZoom))
        }
    }

    /// Up: stops the clip, or, if it was only a tap, takes the photo.
    private func shutterLifted(_ drag: DragGesture.Value) {
        holdTask?.cancel()
        let start = pressStart
        pressStart = nil
        if holdRecording {
            holdRecording = false
            camera.finishRecording()
        } else if let start, ready == true,
                  ShutterTiming.isTap(duration: Date().timeIntervalSince(start), travel: hypot(drag.translation.width, drag.translation.height)) {
            Haptics.tick()
            camera.capture { image in pending = PendingCrop(image: image) }
        }
    }

    private func startClip() {
        guard !holdRecording, !camera.recording else { return }
        holdRecording = true
        Haptics.tick()
        camera.record { made, track in
            if let made { cover = .framed(StoryPick(kind: .clip(made, track), filter: filter)) }
        }
    }

    /// The button: white for a photo, and while you hold it a red square inside a ring that fills over the 15
    /// seconds.
    private var shutter: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.5), lineWidth: 4).frame(width: 82, height: 82)
            if camera.recording, let start = camera.recordingStart {
                TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                    Circle()
                        .trim(from: 0, to: min(context.date.timeIntervalSince(start) / StoryVideo.maxSeconds, 1))
                        .stroke(.red, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 82, height: 82)
                }
            }
            RoundedRectangle(cornerRadius: camera.recording ? 10 : 33)
                .fill(camera.recording ? Color.red : .white)
                .frame(width: camera.recording ? 36 : 66, height: camera.recording ? 36 : 66)
                .animation(reduceMotion ? nil : .snappy, value: camera.recording)
        }
        .frame(width: 90, height: 90)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged(shutterMoved).onEnded(shutterLifted))
        .opacity(ready == true ? 1 : 0.35)
        .accessibilityElement()
        .accessibilityLabel(camera.recording ? "Stop recording" : "Take photo")
        .accessibilityHint("Hold to record a video")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if camera.recording { camera.finishRecording() } else { camera.capture { image in pending = PendingCrop(image: image) } }
        }
        .accessibilityAction(named: camera.recording ? "Stop recording" : "Record video") {
            if camera.recording { camera.finishRecording() } else { startClip() }
        }
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { controlFace(symbol) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func controlFace(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.35), in: .circle)
    }
}

// MARK: - Viewer

/// Shows the cover while a story of yours is going out. Apart from the viewer, so the viewer isn't drawn again every
/// time one more copy leaves.
private struct UploadingGate: View {
    @Environment(AppModel.self) private var model
    var story: Story.ID

    var body: some View {
        if model.isUploading(story) {
            UploadingCover(progress: model.uploadProgress(of: story)).transition(.opacity)
        }
    }
}

/// Over a story of yours that hasn't finished going out, as on Instagram.
struct UploadingCover: View {
    var progress: Double?

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(.white)
                Text("Uploading")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                if let progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.smooth(duration: 0.3), value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Uploading")
    }
}

struct StoryViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var start = 0
    /// The stories on screen now, and the people queued after them.
    @State private var reel: [Story]
    @State private var upcoming: [[Story]]
    @State private var index = 0
    /// How far through the story on screen. Kept out of the view's own state so the 30 ticks a second redraw only
    /// the bars, not the picture, the header and the buttons.
    @State private var clock = StoryClock()
    @State private var editing: Story?
    @State private var showingViewers: Story?
    @State private var confirmDelete = false
    /// How far the story has been dragged down, on its way to closing.
    @State private var dragY: CGFloat = 0
    /// Stories deleted while the viewer is open.
    @State private var gone: Set<Story.ID> = []
    /// The video of the story on screen, if it is one.
    @State private var clip: StoryClip?
    /// A finger is held down: the story waits.
    @State private var holding = false
    @State private var touching = false
    @State private var holdTask: Task<Void, Never>?
    /// A reply being written to a friend's story. Typing holds the story still.
    @State private var replyText = ""
    @FocusState private var replying: Bool
    /// Shown for a moment after a like or reply goes.
    @State private var sentNote: String?
    private let duration: Double = 5

    init(stories: [Story], start: Int = 0, following: [[Story]] = []) {
        self.start = start
        _reel = State(initialValue: stories)
        _upcoming = State(initialValue: following)
    }
    private let tick = Timer.publish(every: 1 / 30, on: .main, in: .common).autoconnect()

    /// The stories still up, as they are now (one may have been edited since the viewer opened).
    private var current: [Story] {
        // Only what's still up: one deleted or expired elsewhere while this is open goes from it too.
        reel.filter { !gone.contains($0.id) }.compactMap { s in model.data.stories.first { $0.id == s.id } }
    }

    private var paused: Bool {
        editing != nil || showingViewers != nil || confirmDelete || holding || replying || !replyText.isEmpty || loading
    }

    /// The story on screen is a video still arriving: it waits, unwatched, until it can play.
    private var loading: Bool { current.indices.contains(index) && !current[index].isReady }

    private var currentID: Story.ID? { current.indices.contains(index) ? current[index].id : nil }

    var body: some View {
        let stories = current
        ZStack(alignment: .top) {
            if stories.indices.contains(index) {
                // The picture goes under the status bar and home bar; everything written over it stays inside them.
                StoryFace(story: stories[index], clip: clip)
                    .ignoresSafeArea()
                    .id(stories[index].id)
                    .transition(.opacity)
                if stories[index].author == "me" { UploadingGate(story: stories[index].id) }
            }
            StoryBars(count: stories.count, index: index, clock: clock)
                .padding(14)
                .opacity(holding ? 0 : 1)
            GeometryReader { geo in
                Color.clear.contentShape(Rectangle())
                    .ignoresSafeArea()
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in touchBegan(); dragMoved(drag) }
                        .onEnded { drag in touchEnded(drag, width: geo.size.width) })
                    .accessibilityElement()
                    .accessibilityLabel("Story")
                    .accessibilityAction(named: "Next story") { step(1) }
                    .accessibilityAction(named: "Previous story") { step(-1) }
            }
            if stories.indices.contains(index), !holding {
                storyHeader(stories[index])
            }
            if clip != nil, !holding {
                HStack {
                    Spacer()
                    Button { clip?.muted.toggle() } label: {
                        Image(systemName: clip?.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.black.opacity(0.45), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(clip?.muted == true ? "Unmute" : "Mute")
                }
                .padding(.top, 26).padding(.horizontal, 14)
            }
            if stories.indices.contains(index), stories[index].author == "me", !holding {
                VStack {
                    Spacer()
                    ownerBar(stories[index])
                }
            }
            if stories.indices.contains(index), stories[index].author != "me", !holding {
                VStack {
                    Spacer()
                    if let sentNote {
                        Text(sentNote)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.black.opacity(0.55), in: .capsule)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                            .padding(.bottom, 8)
                    }
                    friendBar(stories[index])
                }
            }
        }
        .scaleEffect(1 - min(dragY, 400) / 2000, anchor: .top)
        .offset(y: dragY)
        // A video has no size of its own, so on the Mac the window is given the story's shape outright.
        .frame(minWidth: Platform.isPhone ? nil : 400, maxWidth: Platform.isPhone ? .infinity : 400,
               minHeight: Platform.isPhone ? nil : 680, maxHeight: Platform.isPhone ? .infinity : 680)
        .background(.black.opacity(1 - Double(min(dragY, 300)) / 600))
        .onAppear { index = min(start, max(stories.count - 1, 0)) }
        .onChange(of: index, initial: true) { markSeenIfReady(); prefetchAround(index) }
        .onChange(of: loading) { _, now in
            // The last piece just came in: play it from the start.
            guard !now else { return }
            openClip()
            markSeenIfReady()
        }
        .onChange(of: currentID, initial: true) { openClip() }
        .onChange(of: currentID) { replyText = ""; replying = false }
        .onChange(of: paused) { _, now in
            if now { clip?.pause() } else { clip?.play() }
        }
        .onDisappear { clip?.close(); clip = nil }
        .onReceive(tick) { _ in
            guard !paused else { return }
            if let clip {
                clock.progress = clip.progress
                if clip.finished { step(1) }
                return
            }
            clock.progress += 1 / (duration * 30)
            if clock.progress >= 1 { step(1) }
        }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onChange(of: current.isEmpty) { _, empty in if empty { dismiss() } }
        // The drag down closes it, so the sheet's own swipe doesn't fight it.
        .interactiveDismissDisabled()
        .sheet(item: $editing) { StoryComposer(editing: $0) }
        .sheet(item: $showingViewers) { StoryViewers(story: $0) }
        .confirmationDialog("Delete this story?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteCurrent() }
        } message: {
            Text("It disappears for everyone who can see it.")
        }
    }

    /// Decodes the pictures either side of the one now showing, so the next tap finds them ready.
    private func prefetchAround(_ i: Int) {
        let stories = current
        for n in [i + 1, i - 1] where stories.indices.contains(n) { StoryImages.prefetch(stories[n]) }
    }

    private func markSeenIfReady() {
        if current.indices.contains(index), current[index].isReady { model.markSeen(current[index].id) }
    }

    /// Plays the video of the story now on screen, and lets go of the last one.
    private func openClip() {
        clip?.close()
        clip = nil
        clock.progress = 0
        guard current.indices.contains(index), case let .video(data, _) = current[index].style, !data.isEmpty else { return }
        clip = StoryClip(data: data)
        if !paused { clip?.play() }
    }

    /// Touch down starts a hold (the story waits); a quick tap on the left or right side steps.
    private func touchBegan() {
        guard !touching else { return }
        touching = true
        holdTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            if !Task.isCancelled { holding = true }
        }
    }

    /// A drag that is mostly downward pulls the story down with the finger.
    private func dragMoved(_ drag: DragGesture.Value) {
        let down = drag.translation.height
        dragY = down > abs(drag.translation.width) ? max(down, 0) : 0
    }

    private func touchEnded(_ drag: DragGesture.Value, width: Double) {
        holdTask?.cancel()
        touching = false
        let wasHolding = holding
        holding = false
        // Pulled down far enough, or flicked: close it. Otherwise it springs back.
        if drag.translation.height > abs(drag.translation.width), drag.translation.height > 120 || drag.predictedEndTranslation.height > 400 {
            dismiss()
            return
        }
        withAnimation(.smooth(duration: 0.25)) { dragY = 0 }
        // Swiping up on your own story shows who has seen it.
        if drag.translation.height < -70, abs(drag.translation.height) > abs(drag.translation.width) * 1.5,
           current.indices.contains(index), current[index].author == "me" {
            showingViewers = current[index]
            return
        }
        guard !wasHolding, abs(drag.translation.width) < 24, abs(drag.translation.height) < 24 else { return }
        step(drag.startLocation.x < width / 2 ? -1 : 1)
    }

    /// Under a friend's story: write them a reply, or like it. Either arrives in your chat with them.
    private func friendBar(_ story: Story) -> some View {
        let liked = story.liked == true
        let canSend = !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 10) {
            TextField("", text: $replyText, prompt: Text("Reply to \(model.displayName(story.author))")
                .foregroundStyle(.white.opacity(0.7)))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .focused($replying)
                .submitLabel(.send)
                .onSubmit { sendReply(to: story) }
                .padding(.horizontal, 16).frame(height: 40)
                .background(.black.opacity(0.35), in: .capsule)
                .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 1))
            if canSend {
                barButton("arrow.up", label: "Send reply") { sendReply(to: story) }
            } else {
                Button { like(story) } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(liked ? Color.red : .white)
                        .frame(width: 40, height: 40)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(liked)
                .accessibilityLabel(liked ? "Liked" : "Like story")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
    }

    private func like(_ story: Story) {
        guard story.liked != true else { return }
        flash("Liked")
        model.playSendSound()
        Task { await model.answerStory(story, like: true) }
    }

    private func sendReply(to story: Story) {
        let words = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        Task { await model.answerStory(story, text: words) }
        model.playSendSound()
        replyText = ""
        replying = false
        flash("Reply sent")
    }

    private func flash(_ note: String) {
        withAnimation(.snappy) { sentNote = note }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if sentNote == note { withAnimation(.snappy) { sentNote = nil } }
        }
    }

    /// Who posted the story on screen and how long ago, under the progress bars.
    private func storyHeader(_ story: Story) -> some View {
        let mine = story.author == "me"
        let name = mine ? "Your story" : model.displayName(story.author)
        let avatar = mine ? model.activeProfile.avatar : model.contact(story.author)?.avatar
        return HStack(spacing: 8) {
            Avatar(image: avatar, seed: mine ? model.fingerprint : story.author, size: 30)
            Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Text(Self.age(of: story.date)).font(.system(size: 13)).opacity(0.75)
            Spacer()
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 4)
        .padding(.top, 26).padding(.leading, 14).padding(.trailing, clip != nil ? 54 : 14)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    /// "Just now", "12 min ago", "3 hr ago".
    private static func age(of date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "Just now" }
        return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    private func ownerBar(_ story: Story) -> some View {
        let views = model.viewers(of: story.id).count
        return HStack(spacing: 10) {
            Button { showingViewers = story } label: {
                Label(model.data.security.storyViews ? (views == 1 ? "1 view" : "\(views) views") : "Views",
                      systemImage: "eye")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(.black.opacity(0.45), in: .capsule)
            }
            .buttonStyle(.plain)
            Spacer()
            barButton("pencil", label: "Edit story") { editing = story }
            barButton("trash", label: "Delete story") { confirmDelete = true }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
    }

    private func barButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.45), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func deleteCurrent() {
        guard current.indices.contains(index) else { return }
        let id = current[index].id
        model.deleteStory(id)
        gone.insert(id)
        clock.progress = 0
        if current.isEmpty { dismiss() } else { index = min(index, current.count - 1) }
    }

    /// Past the last story of this person: on to the next person with something new, or close.
    private func nextReel() {
        guard !upcoming.isEmpty else { dismiss(); return }
        clip?.close()
        clip = nil
        let next = upcoming.removeFirst()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35)) {
            reel = next
            gone = []
            index = next.firstIndex { !$0.seen } ?? 0
        }
        clock.progress = 0
    }

    private func step(_ d: Int) {
        let next = index + d
        guard current.indices.contains(next) else {
            if d > 0 { nextReel() } else { clock.progress = 0; clip?.restart() }
            return
        }
        // Let go of this clip now, so a late tick can't step twice.
        clip?.close()
        clip = nil
        withAnimation(.easeOut(duration: 0.18)) { index = next }
        clock.progress = 0
        prefetchAround(next)
    }
}
