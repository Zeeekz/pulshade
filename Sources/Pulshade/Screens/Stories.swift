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
    @State private var viewing: StoryReel?
    @State private var composing = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                Button { model.myStories.isEmpty ? (composing = true) : (viewing = StoryReel(stories: model.myStories)) } label: {
                    StoryBubble(image: model.activeProfile.avatar, seed: model.fingerprint, name: "Your story",
                                active: !model.myStories.isEmpty, adding: model.myStories.isEmpty)
                }
                .buttonStyle(.plain)
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
                        viewing = StoryReel(stories: entry.stories, start: entry.stories.firstIndex { !$0.seen } ?? 0)
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
        .storyCamera(isPresented: $composing)
        .sheet(item: $viewing) { reel in StoryViewer(stories: reel.stories, start: reel.start) }
    }
}

struct StoryReel: Identifiable {
    let id = UUID()
    var stories: [Story]
    var start = 0
}

private struct StoryBubble: View {
    var image: Data?
    var seed: String
    var name: String
    var active: Bool
    var adding: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            StoryRing(active: active, size: 60) {
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
struct StoryFace: View {
    var story: Story
    var compact = false

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
                if let img = PlatformImage(data: data) {
                    Image(platformImage: img).resizable().scaledToFill()
                }
                if !caption.isEmpty {
                    VStack {
                        Spacer()
                        Text(caption)
                            .font(.system(size: compact ? 13 : 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.black.opacity(0.45), in: .capsule)
                            .padding(.bottom, compact ? 36 : 60)
                    }
                }
            }
        }
        .clipped()
    }
}

// MARK: - Composer

/// Writes a new story, or edits one you posted: its words, who sees it and how long it lasts.
struct StoryComposer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var palette = 0
    @State private var image: Data?
    @State private var audience: StoryAudience = .everyone
    @State private var lifetime = StoryLifetime.day.rawValue
    @State private var choosingAudience = false
    /// The story being edited, if this isn't a new one.
    private var editing: Story?
    /// After posting, so the camera behind closes too.
    var posted: () -> Void = {}

    init(image: Data? = nil, posted: @escaping () -> Void = {}) {
        _image = State(initialValue: image)
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
        }
        _audience = State(initialValue: story.shownTo)
        _lifetime = State(initialValue: story.lifetime ?? StoryLifetime.day.rawValue)
    }

    private var preview: Story {
        Story(id: editing?.id ?? UUID(), author: "me",
              style: image.map { .image($0, caption: text) } ?? .text(text.isEmpty ? "✦" : text, palette: palette))
    }

    var body: some View {
        SheetBody(width: 440) {
            VStack(spacing: 18) {
                SheetHeader(symbol: "circle.dashed.inset.filled", title: editing == nil ? "Story" : "Edit story")
                StoryFace(story: preview)
                    .frame(width: 260, height: 400)
                    .clipShape(.rect(cornerRadius: 26))
                    .shadow(color: theme.accent.opacity(0.35), radius: 30)
                    .animation(.smooth, value: palette)
                    .animation(.smooth, value: image)

                if image == nil {
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

                TextField(image == nil ? "Say something" : "Caption", text: $text)
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

                HStack(spacing: 12) {
                    if editing == nil {
                        if image != nil {
                            Button { withAnimation { image = nil } } label: { Image(systemName: "textformat") }
                                .buttonStyle(IconButtonStyle(size: 46))
                        } else {
                            ImagePickButton(maxSide: 1600, crop: .story, picked: { data in withAnimation { image = data } }) {
                                Image(systemName: "photo.fill")
                            }
                            .buttonStyle(IconButtonStyle(size: 46))
                        }
                    }
                    Button {
                        if let editing {
                            model.editStory(editing.id, style: preview.style, audience: audience, lifetime: lifetime)
                        } else {
                            model.postStory(preview.style, audience: audience, lifetime: lifetime)
                        }
                        dismiss()
                        posted()
                    } label: { Image(systemName: editing == nil ? "arrow.up" : "checkmark") }
                        .buttonStyle(GlowButtonStyle(size: 46))
                        .disabled(image == nil && text.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel(editing == nil ? "Post" : "Save")
                }
            }
        }
        .onAppear {
            guard editing == nil else { return }
            audience = model.storyChoice.audience
            lifetime = model.storyChoice.lifetime
        }
        .sheet(isPresented: $choosingAudience) { StoryAudiencePicker(audience: $audience) }
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

/// Where a new story starts: the camera, with the photo library and text stories a tap away. A photo is
/// framed to the story's shape, then captioned and posted.
struct StoryCamera: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var camera = Camera()
    @State private var ready: Bool?
    @State private var pending: PendingCrop?
    @State private var framed: FramedPhoto?
    @State private var writing = false

    private struct FramedPhoto: Identifiable {
        let id = UUID()
        let data: Data
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if ready == true {
                LayerView(layer: camera.preview).ignoresSafeArea()
            } else if ready == false {
                VStack(spacing: 10) {
                    Image(systemName: "camera.fill").font(.system(size: 34)).foregroundStyle(Ink.faint)
                    Text("No camera available").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text)
                    Text("Choose a photo, or write a text story.").font(.system(size: 13)).foregroundStyle(Ink.dim)
                }
            }
            VStack {
                HStack {
                    control("xmark", label: "Close") { dismiss() }
                    Spacer()
                    if camera.hasFlash && ready == true {
                        control(camera.flash ? "bolt.fill" : "bolt.slash.fill", label: camera.flash ? "Flash on" : "Flash off") {
                            camera.flash.toggle()
                        }
                    }
                }
                Spacer()
                HStack(alignment: .center) {
                    ImagePickButton(maxSide: CropFrame.story.maxSide, crop: .story, picked: { data in framed = FramedPhoto(data: data) }) {
                        controlFace("photo.on.rectangle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose a photo")
                    Spacer()
                    Button {
                        camera.capture { image in pending = PendingCrop(image: image) }
                    } label: {
                        Circle().fill(.white).frame(width: 66, height: 66)
                            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 4).padding(-8))
                    }
                    .buttonStyle(.plain)
                    .disabled(ready != true)
                    .opacity(ready == true ? 1 : 0.35)
                    .accessibilityLabel("Take photo")
                    Spacer()
                    #if os(iOS)
                    control("arrow.triangle.2.circlepath.camera", label: "Switch camera") { camera.flip() }
                        .disabled(ready != true)
                    #else
                    controlFace("camera").opacity(0)
                    #endif
                }
                .padding(.horizontal, 28)
                Button { writing = true } label: {
                    Text("Aa  Text story")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.white.opacity(0.15), in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 16)
        }
        .preferredColorScheme(.dark)
        .task { ready = await camera.start() }
        .onDisappear { camera.stop() }
        .cropper($pending, frame: .story) { data in framed = FramedPhoto(data: data) }
        .sheet(item: $framed) { photo in StoryComposer(image: photo.data, posted: { dismiss() }) }
        .sheet(isPresented: $writing) { StoryComposer(posted: { dismiss() }) }
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

struct StoryViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var stories: [Story]
    var start = 0
    @State private var index = 0
    @State private var progress: Double = 0
    @State private var editing: Story?
    @State private var showingViewers: Story?
    @State private var confirmDelete = false
    /// Stories deleted while the viewer is open.
    @State private var gone: Set<Story.ID> = []
    private let duration: Double = 5
    private let tick = Timer.publish(every: 1 / 30, on: .main, in: .common).autoconnect()

    /// The stories still up, as they are now (one may have been edited since the viewer opened).
    private var current: [Story] {
        stories.filter { !gone.contains($0.id) }.map { s in model.data.stories.first { $0.id == s.id } ?? s }
    }

    private var paused: Bool { editing != nil || showingViewers != nil || confirmDelete }

    var body: some View {
        let stories = current
        ZStack(alignment: .top) {
            if stories.indices.contains(index) {
                StoryFace(story: stories[index])
                    .id(stories[index].id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            }
            HStack(spacing: 4) {
                ForEach(stories.indices, id: \.self) { i in
                    GeometryReader { geo in
                        Capsule().fill(.white.opacity(0.25))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white)
                                    .frame(width: geo.size.width * (i < index ? 1 : i == index ? progress : 0))
                            }
                    }
                    .frame(height: 3)
                }
            }
            .padding(14)
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { step(-1) }
                Color.clear.contentShape(Rectangle()).onTapGesture { step(1) }
            }
            if stories.indices.contains(index), stories[index].author == "me" {
                VStack {
                    Spacer()
                    ownerBar(stories[index])
                }
            }
        }
        .frame(maxWidth: Platform.isPhone ? .infinity : 400, maxHeight: Platform.isPhone ? .infinity : 680)
        .background(.black)
        .onAppear { index = min(start, max(stories.count - 1, 0)) }
        .onChange(of: index, initial: true) { if current.indices.contains(index) { model.markSeen(current[index].id) } }
        .onReceive(tick) { _ in
            guard !paused else { return }
            progress += 1 / (duration * 30)
            if progress >= 1 { step(1) }
        }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .sheet(item: $editing) { StoryComposer(editing: $0) }
        .sheet(item: $showingViewers) { StoryViewers(story: $0) }
        .confirmationDialog("Delete this story?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteCurrent() }
        } message: {
            Text("It disappears for everyone who can see it.")
        }
    }

    /// Under your own story: who viewed it, and editing or deleting it.
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
        progress = 0
        if current.isEmpty { dismiss() } else { index = min(index, current.count - 1) }
    }

    private func step(_ d: Int) {
        let next = index + d
        guard current.indices.contains(next) else {
            if d > 0 { dismiss() } else { progress = 0 }
            return
        }
        withAnimation(.smooth(duration: 0.35)) { index = next }
        progress = 0
    }
}
