import SwiftUI
import AVFoundation
#if canImport(PulshadeShared)
import PulshadeShared
#endif

// MARK: - Rarity colours

extension CollectibleTier {
    var color: Color {
        switch self {
        case .common: Color(red: 0.49, green: 0.53, blue: 0.61)
        case .uncommon: Color(red: 0.18, green: 0.62, blue: 0.42)
        case .rare: Color(red: 0.29, green: 0.39, blue: 0.94)
        case .epic: Color(red: 0.57, green: 0.32, blue: 0.94)
        case .legendary: Color(red: 0.82, green: 0.54, blue: 0.0)
        case .mythic: Color(red: 0.88, green: 0.2, blue: 0.44)
        }
    }
}

struct TierPill: View {
    var tier: CollectibleTier

    var body: some View {
        Text(tier.name.uppercased())
            .font(.system(size: 10, weight: .bold)).tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tier.color, in: .capsule)
    }
}

/// "#7 of 500", with the number's badge if it has one.
struct NumberLine: View {
    var serial: UInt32
    var run: UInt32

    var body: some View {
        let badge = Collectible.badge(of: serial, run: run)
        HStack(spacing: 5) {
            if badge == .first { Image(systemName: "crown.fill").font(.system(size: 10)) }
            else if badge != nil { Image(systemName: "sparkle").font(.system(size: 10)) }
            Text("#\(serial) of \(run)").font(.system(size: 12, weight: badge == nil ? .regular : .semibold).monospacedDigit())
            if let badge { Text("· \(badge.name)").font(.system(size: 11, weight: .medium)) }
        }
        .foregroundStyle(badge == nil ? Ink.faint : Color(red: 0.98, green: 0.72, blue: 0.2))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The picture

/// A collectible's picture: the still at once, then the looping transparent video once it's here. Both come from the
/// media pool (or the relay the first time), checked against the list.
struct CollectibleArt: View {
    @Environment(AppModel.self) private var model
    var item: CollectibleList.Item
    var size: CGFloat
    var animated = true
    @State private var still: Image?
    @State private var video: Data?

    var body: some View {
        ZStack {
            if let still { still.resizable().scaledToFit() }
            else { ProgressView().controlSize(.small).tint(Ink.faint) }
            #if os(iOS)
            if animated, let video {
                LoopingVideo(data: video, id: item.video.sha256).allowsHitTesting(false)
            }
            #endif
        }
        .frame(width: size, height: size)

        .accessibilityLabel(item.name)
        .task(id: item.still.sha256) {
            if let data = await model.collectiblePicture(item.still) { still = Self.image(data) }
            guard animated, size >= 60 else { return }
            if let data = await model.collectiblePicture(item.video) { video = data }
        }
    }

    private static func image(_ data: Data) -> Image? {
        #if os(iOS)
        UIImage(data: data).map(Image.init(uiImage:))
        #else
        NSImage(data: data).map(Image.init(nsImage:))
        #endif
    }
}

#if os(iOS)
/// Plays a short transparent HEVC video from memory, looping and silent. Fed to the player by a resource loader, so the
/// decrypted file never touches the disk.
private struct LoopingVideo: UIViewRepresentable {
    var data: Data
    var id: String

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.play(data, id: id)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.playing != id { view.play(data, id: id) }
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) { view.stop() }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private var player: AVPlayer?
        private var loader: MemoryLoader?
        private(set) var playing: String?

        func play(_ data: Data, id: String) {
            stop()
            backgroundColor = .clear
            let loader = MemoryLoader(data: data)
            let asset = AVURLAsset(url: URL(string: "pulshade-collectible://\(id).mov")!)
            // Fed from a queue of its own: answered on the main thread, the player waited for ever on iPhone.
            asset.resourceLoader.setDelegate(loader, queue: Self.loading)
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.actionAtItemEnd = .none
            player.preventsDisplaySleepDuringVideoPlayback = false
            let layer = self.layer as! AVPlayerLayer
            layer.videoGravity = .resizeAspect
            layer.pixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            layer.player = player
            // Back to the start at the end, for ever.
            ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
            player.play()
            (self.player, self.loader, playing) = (player, loader, id)
        }

        private static let loading = DispatchQueue(label: "app.pulshade.collectible-video")
        private var ended: NSObjectProtocol?

        func stop() {
            if let ended { NotificationCenter.default.removeObserver(ended) }
            ended = nil
            player?.pause()
            (layer as! AVPlayerLayer).player = nil
            (player, loader, playing) = (nil, nil, nil)
        }
    }

    /// Answers the player's reads from bytes in memory.
    final class MemoryLoader: NSObject, AVAssetResourceLoaderDelegate {
        let data: Data
        init(data: Data) { self.data = data }

        func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
            if let info = request.contentInformationRequest {
                info.contentType = AVFileType.mov.rawValue
                info.contentLength = Int64(data.count)
                info.isByteRangeAccessSupported = true
            }
            if let wanted = request.dataRequest {
                let start = Int(max(0, wanted.requestedOffset))
                let length = wanted.requestsAllDataToEndOfResource ? data.count - start : wanted.requestedLength
                let end = min(data.count, start + max(0, length))
                if start < end { wanted.respond(with: data.subdata(in: start..<end)) }
            }
            request.finishLoading()
            return true
        }
    }
}
#endif

// MARK: - On a profile

/// The collectibles a profile shows: a small grid; tap one for its card.
struct CollectibleShowcase: View {
    @Environment(AppModel.self) private var model
    var copies: [Collectible]
    var isMine = false
    @State private var open: Collectible?

    var body: some View {
        if let list = model.collectibleList {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                ForEach(copies) { copy in
                    if let item = list.item(copy.item) {
                        Button { open = copy } label: { CollectibleTile(item: item, copy: copy) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .sheet(item: $open) { copy in CollectibleDetail(copy: copy, isMine: isMine) }
        }
    }
}

// MARK: - Picking what your profile shows

/// The Collectibles part of Edit profile: the showcase as six slots (tap any to choose), whether friends see it,
/// and the way into your whole collection.
struct ShowcaseEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var picking = false
    @State private var pickingBadge = false
    @State private var showingAll = false

    var body: some View {
        let held = model.collection(for: model.activePersona)
        let shown = model.showcase(for: model.activePersona)
        let list = model.collectibleList
        SettingsGroup("Collectibles", footer: "Friends see the ones you pick, up to \(AppModel.showcaseLimit). Nobody else does.") {
            if let list, !held.isEmpty {
                Button { picking = true } label: {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(0..<AppModel.showcaseLimit, id: \.self) { i in
                            slot(i < shown.count ? shown[i] : nil, list: list)
                        }
                    }
                    .padding(12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose what your profile shows, \(shown.count) of \(AppModel.showcaseLimit) picked")
                RowDivider()
                let badge = model.nameBadge(for: model.activePersona)
                Button { pickingBadge = true } label: {
                    SettingRow("Next to your name") {
                        HStack(spacing: 6) {
                            if let badge, let item = list.item(badge.item) {
                                CollectibleArt(item: item, size: 22, animated: false)
                                Text(item.name).font(.system(size: 14)).foregroundStyle(Ink.faint).lineLimit(1)
                            } else {
                                Text("None").font(.system(size: 14)).foregroundStyle(Ink.faint)
                            }
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.faint)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                RowDivider()
            }
            SettingRow("Show to friends") {
                Toggle("Show to friends", isOn: Binding(get: { model.data.hideCollection != true },
                                                       set: { model.setHideCollection(!$0) }))
                    .labelsHidden()
                    .toggleStyle(GlowToggleStyle())
            }
            RowDivider()
            Button { showingAll = true } label: {
                SettingRow("Your collection") {
                    HStack(spacing: 6) {
                        Text(list == nil ? "Loading…" : held.isEmpty ? "None yet" : "\(held.count)")
                            .font(.system(size: 14)).foregroundStyle(Ink.faint)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.faint)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $picking) { NavigationStack { ShowcasePicker() } }
        .sheet(isPresented: $pickingBadge) { NavigationStack { NameBadgePicker() } }
        .sheet(isPresented: $showingAll) { NavigationStack { CollectionScreen() } }
    }

    private func slot(_ copy: Collectible?, list: CollectibleList) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return ZStack {
            if let copy, let item = list.item(copy.item) {
                VStack(spacing: 4) {
                    CollectibleArt(item: item, size: 54, animated: false)
                    Text("#\(copy.serial)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Ink.faint)
                }
            } else {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.faint)
            }
        }
        .frame(maxWidth: .infinity).frame(height: 84)
        .background(copy == nil ? Color.clear : Ink.raised, in: shape)
        .overlay(shape.strokeBorder(Ink.line, style: StrokeStyle(lineWidth: 1, dash: copy == nil ? [5, 4] : [])))
    }
}

/// Everything you hold, to tick the ones your profile shows. The order you tick them is the order they appear.
struct ShowcasePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        let held = model.collection(for: model.activePersona)
        let chosen = model.showcase(for: model.activePersona).map(\.id)
        ScrollView {
            VStack(spacing: 12) {
                Text("\(chosen.count) of \(AppModel.showcaseLimit) picked. Tap to add or take one off.")
                    .font(.system(size: 13)).foregroundStyle(Ink.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let list = model.collectibleList {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                        ForEach(held) { copy in
                            if let item = list.item(copy.item) {
                                let index = chosen.firstIndex(of: copy.id)
                                let full = index == nil && chosen.count >= AppModel.showcaseLimit
                                Button {
                                    Haptics.tick()
                                    model.setShowcase(index == nil ? chosen + [copy.id] : chosen.filter { $0 != copy.id })
                                } label: {
                                    CollectibleTile(item: item, copy: copy)
                                        .overlay(alignment: .topTrailing) {
                                            if let index {
                                                Text("\(index + 1)")
                                                    .font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.onAccent)
                                                    .frame(width: 22, height: 22)
                                                    .background(theme.accent, in: .circle)
                                                    .padding(6)
                                            }
                                        }
                                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(index == nil ? .clear : theme.accent, lineWidth: 2))
                                        .opacity(full ? 0.45 : 1)
                                }
                                .buttonStyle(.plain)
                                .disabled(full)
                                .accessibilityAddTraits(index == nil ? [] : .isSelected)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Ink.base)
        .navigationTitle("Show on profile")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

/// Everything you hold, to pick the one friends see beside your name in a chat, or none.
struct NameBadgePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        let held = model.collection(for: model.activePersona)
        let chosen = model.nameBadge(for: model.activePersona)?.id
        ScrollView {
            VStack(spacing: 12) {
                Text("Friends see it beside your name at the top of your chat. Tap it again to take it off.")
                    .font(.system(size: 13)).foregroundStyle(Ink.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let list = model.collectibleList {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                        ForEach(held) { copy in
                            if let item = list.item(copy.item) {
                                let on = chosen == copy.id
                                Button {
                                    Haptics.tick()
                                    model.setNameBadge(on ? nil : copy.id)
                                } label: {
                                    CollectibleTile(item: item, copy: copy)
                                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(on ? theme.accent : .clear, lineWidth: 2))
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Ink.base)
        .navigationTitle("Next to your name")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

struct CollectibleTile: View {
    var item: CollectibleList.Item
    var copy: Collectible

    var body: some View {
        VStack(spacing: 6) {
            CollectibleArt(item: item, size: 76)
            Text(item.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
            Text("#\(copy.serial)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Ink.faint)
        }
        .padding(.vertical, 10).padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(Ink.surface, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(item.tier.color.opacity(item.tier >= .rare ? 0.55 : 0.15)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Your collection

/// Everything the current identity holds, rarest first, and whether friends see it.
struct CollectionScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var open: Collectible?
    @State private var copied = false

    var body: some View {
        let held = model.collection(for: model.activePersona)
        let list = model.collectibleList
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if held.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(Ink.faint)
                        Text("No collectibles yet").font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.text)
                        Text("Pulshade gives them out now and then, and friends can give you theirs. Each one is numbered, and the number is random.")
                            .font(.system(size: 14)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60).padding(.horizontal, 24)
                } else if let list {
                    ForEach(CollectibleTier.allCases.reversed(), id: \.self) { tier in
                        let here = held.filter { list.item($0.item)?.tier == tier }
                        if !here.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { TierPill(tier: tier); Text("\(here.count)").font(.system(size: 13)).foregroundStyle(Ink.faint) }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                                    ForEach(here) { copy in
                                        Button { open = copy } label: { CollectibleTile(item: list.item(copy.item)!, copy: copy) }
                                            .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
                if let code = model.collectorCode(for: model.activePersona) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Collector code").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text)
                        Text("Pulshade gives collectibles to this code. It's only for that: it isn't your profile, and nothing ties it to you.")
                            .font(.system(size: 12)).foregroundStyle(Ink.faint)
                        HStack {
                            Text(code).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.dim)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(copied ? "Copied" : "Copy") {
                                #if os(iOS)
                                UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: code]],
                                                              options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                                #endif
                                copied = true
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    .padding(14)
                    .background(Ink.surface, in: .rect(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(16)
        }
        .background(Ink.base)
        .navigationTitle(held.isEmpty ? "Collectibles" : "\(held.count) collectible\(held.count == 1 ? "" : "s")")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(item: $open) { copy in CollectibleDetail(copy: copy, isMine: true) }
        .task {
            model.newCollectibles = 0
            await model.refreshCollectibles()
        }
    }
}

// MARK: - One collectible

struct CollectibleDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var copy: Collectible
    var isMine: Bool
    @State private var confirmLetGo = false
    @State private var working = false
    @State private var failed = false

    var body: some View {
        if let item = model.collectibleList?.item(copy.item) {
            let shown = model.activeProfile.showcase ?? []
            ScrollView {
                VStack(spacing: 14) {
                    CollectibleArt(item: item, size: 240)
                        .padding(.top, 24)
                    Text(item.name).font(.system(size: 24, weight: .bold)).foregroundStyle(Ink.text)
                    HStack(spacing: 8) { TierPill(tier: item.tier); NumberLine(serial: copy.serial, run: item.run) }
                    if let season = item.season { Text(season).font(.system(size: 13)).foregroundStyle(Ink.dim) }
                    if !item.blurb.isEmpty {
                        Text(item.blurb).font(.system(size: 15)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    if isMine {
                        VStack(spacing: 10) {
                            let on = shown.contains(copy.id)
                            Button {
                                model.setShowcase(on ? shown.filter { $0 != copy.id } : shown + [copy.id])
                            } label: {
                                Label(on ? "Shown on your profile" : "Show on your profile", systemImage: on ? "checkmark.circle.fill" : "plus.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!on && shown.count >= AppModel.showcaseLimit)
                            if !on && shown.count >= AppModel.showcaseLimit {
                                Text("Your profile shows \(AppModel.showcaseLimit) at most.").font(.system(size: 12)).foregroundStyle(Ink.faint)
                            }
                            Button(role: .destructive) { confirmLetGo = true } label: {
                                Text("Let go").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(working)
                            if failed { Text("Couldn't reach Pulshade. Try again in a moment.").font(.system(size: 12)).foregroundStyle(.red) }
                        }
                        .padding(.horizontal, 24).padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            }
            .background(Ink.base)
            .presentationDetents([.large])
            .confirmationDialog("Let go of \(item.name) #\(copy.serial)?", isPresented: $confirmLetGo, titleVisibility: .visible) {
                Button("Let go", role: .destructive) {
                    working = true
                    Task {
                        let done = await model.letGo(copy)
                        working = false
                        if done { dismiss() } else { failed = true }
                    }
                }
            } message: {
                Text("It's gone for good, and its number goes back for someone else to get.")
            }
        }
    }
}
