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
    @State private var showingAll = false

    var body: some View {
        if let list = model.collectibleList {
            VStack(spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                    ForEach(copies) { copy in
                        if let item = list.item(copy.item) {
                            Button { open = copy } label: { CollectibleTile(item: item, copy: copy) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                if isMine {
                    Button { showingAll = true } label: {
                        Label(copies.isEmpty ? "Choose collectibles to show" : "Your collection", systemImage: "square.grid.2x2")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .sheet(item: $open) { copy in CollectibleDetail(copy: copy, isMine: isMine) }
            .sheet(isPresented: $showingAll) { NavigationStack { CollectionScreen() } }
        }
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
                Toggle(isOn: Binding(get: { model.data.hideCollection != true }, set: { model.setHideCollection(!$0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show to friends").font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.text)
                        Text("Friends see the ones you pick for your profile. Nobody else does.")
                            .font(.system(size: 12)).foregroundStyle(Ink.faint)
                    }
                }
                .padding(14)
                .background(Ink.surface, in: .rect(cornerRadius: 14, style: .continuous))
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
