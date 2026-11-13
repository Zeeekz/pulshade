import SwiftUI
import AVKit

/// A video being got ready in the message box: a still once there is one, a spinner until then.
struct VideoDraft: Equatable {
    var poster: Data?
    var clip: Data?
    var seconds: Double = 0
    var preparing = true
    var failed = false
}

/// The tile for a video in the message box, beside any photos.
struct VideoDraftTile: View {
    var draft: VideoDraft
    var remove: () -> Void

    var body: some View {
        ZStack {
            if let poster = draft.poster, let img = PlatformImage(data: poster) {
                Image(platformImage: img).resizable().scaledToFill()
            } else {
                Ink.raised
            }
            if draft.preparing {
                ProgressView().controlSize(.small).tint(.white)
                    .padding(8).background(.black.opacity(0.45), in: .circle)
            } else if draft.failed {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(.orange)
            } else {
                VideoBadge(seconds: draft.seconds)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(5)
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 22)).offset(x: 6, y: -6)
                .accessibilityLabel("Remove video")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(draft.preparing ? "Video, getting ready" : draft.failed ? "Video that couldn't be read" : "Video")
    }
}

/// "▶ 0:12" in the corner of a video.
struct VideoBadge: View {
    var seconds: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "play.fill").font(.system(size: 8))
            Text(String(format: "%d:%02d", Int(seconds.rounded()) / 60, Int(seconds.rounded()) % 60))
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.black.opacity(0.55), in: .capsule)
    }
}

/// A video in a chat: its still with a play button, or how far it has got while its pieces arrive. A tap plays it.
struct VideoBubble: View {
    @Environment(AppModel.self) private var model
    var message: Message
    /// The size it fills inside a media bubble, edge to edge; without one it sits in its own rounded frame.
    var fill: CGSize? = nil
    @State private var playing = false

    private var ready: Bool { message.video?.isEmpty == false }

    private var loadingLabel: String {
        guard let got = model.clipProgress(ofMessage: message.id), got.have > 0, got.of > 1 else { return "Loading video" }
        return "Loading video · \(got.have) of \(got.of)"
    }

    var body: some View {
        ZStack {
            if let data = message.image, let img = DecodedImages.image(data, fit: 1100) {
                if let fill {
                    Image(platformImage: img).resizable().scaledToFill().frame(width: fill.width, height: fill.height).clipped()
                } else {
                    Image(platformImage: img).resizable().scaledToFit()
                }
            } else if let fill {
                Rectangle().fill(.black).frame(width: fill.width, height: fill.height)
            } else {
                Rectangle().fill(.black).aspectRatio(9 / 16, contentMode: .fit)
            }
            if ready {
                Image(systemName: "play.fill")
                    .font(.system(size: 20)).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.black.opacity(0.5), in: .circle)
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            } else {
                VStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text(loadingLabel).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).monospacedDigit()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.black.opacity(0.5), in: .rect(cornerRadius: 12))
            }
            if let seconds = message.clipSeconds, ready {
                VideoBadge(seconds: seconds)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(8)
            }
        }
        .frame(width: fill?.width, height: fill?.height)
        .frame(maxWidth: fill == nil ? (Platform.isPhone ? 250 : 320) : nil, maxHeight: fill == nil ? 340 : nil)
        .clipShape(.rect(cornerRadius: fill == nil ? 10 : 0))
        .contentShape(.rect)
        .onTapGesture { if ready { playing = true } }
        .modifier(VideoPlayerCover(isPresented: $playing, clip: message.video ?? Data()))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ready ? "Video" : loadingLabel)
        .accessibilityAddTraits(ready ? .isButton : [])
    }
}

struct VideoPlayerCover: ViewModifier {
    @Binding var isPresented: Bool
    var clip: Data

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $isPresented) { ChatVideoPlayer(clip: clip) }
        #else
        content.sheet(isPresented: $isPresented) { ChatVideoPlayer(clip: clip).frame(minWidth: 520, minHeight: 620) }
        #endif
    }
}

/// Plays a chat video from memory. Nothing is written to disk to play it. Swipe up or down to throw it away; tap to
/// show or hide the controls. On the Mac it uses the system's own controls.
private struct ChatVideoPlayer: View {
    @Environment(\.dismiss) private var dismiss
    var clip: Data
    @State private var player: AVPlayer?
    /// Kept for as long as the player is: the asset reads its bytes through it.
    @State private var source: MemoryClip?
    @State private var controls = true
    @State private var swiped: CGFloat = 0
    @State private var playing = true
    @State private var position: Double = 0
    @State private var length: Double = 0
    /// While the bar is held, where it's being dragged to.
    @State private var scrubbing: Double?
    @State private var observer: Any?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Group {
                if let player {
                    #if os(iOS)
                    PlayerSurface(player: player)
                        .contentShape(.rect)
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { controls.toggle() }; scheduleHide() }
                    #else
                    VideoPlayer(player: player)
                    #endif
                } else {
                    ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .swipeToClose(moved: { swiped = $0 }) { dismiss() }
            overlay
                .opacity(controls && swiped < 0.03 ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: swiped < 0.03)
                .allowsHitTesting(controls)
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden(!controls)
        #endif
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private var overlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.5), in: .circle)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
                Spacer()
            }
            .padding(14)
            Spacer()
            #if os(iOS)
            if player != nil {
                Button(action: togglePlay) {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 26)).foregroundStyle(.white)
                        .frame(width: 68, height: 68)
                        .background(.black.opacity(0.45), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playing ? "Pause" : "Play")
                Spacer()
                HStack(spacing: 10) {
                    Text(Self.time(scrubbing ?? position)).monospacedDigit()
                    Slider(value: Binding(get: { scrubbing ?? position }, set: { scrubbing = $0 }), in: 0...max(length, 0.1)) { held in
                        if held { hideTask?.cancel(); return }
                        if let to = scrubbing {
                            player?.seek(to: CMTime(seconds: to, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                            position = to
                        }
                        scrubbing = nil
                        scheduleHide()
                    }
                    .tint(.white)
                    Text(Self.time(length)).monospacedDigit()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.top, 30).padding(.bottom, 14)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            }
            #endif
        }
    }

    private static func time(_ seconds: Double) -> String {
        let s = Int(seconds.isFinite ? max(seconds, 0).rounded() : 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func start() {
        guard player == nil, !clip.isEmpty else { return }
        let source = MemoryClip(clip)
        self.source = source
        let item = AVPlayerItem(asset: source.makeAsset())
        let player = AVPlayer(playerItem: item)
        self.player = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
            MainActor.assumeIsolated {
                if scrubbing == nil { position = time.seconds }
                let total = player.currentItem?.duration.seconds ?? 0
                if total.isFinite, total > 0 { length = total }
                // Played to the end: back to the start, ready to play again.
                if player.rate == 0, playing, length > 0, position >= length - 0.3 {
                    playing = false
                    controls = true
                    player.seek(to: .zero)
                }
            }
        }
        player.play()
        scheduleHide()
    }

    private func stop() {
        hideTask?.cancel()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        source = nil
    }

    private func togglePlay() {
        guard let player else { return }
        if playing { player.pause() } else { player.play() }
        playing.toggle()
        scheduleHide()
    }

    /// The controls step aside a moment after the video starts or is touched, while it plays.
    private func scheduleHide() {
        hideTask?.cancel()
        guard playing else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, playing, scrubbing == nil else { return }
            withAnimation(.easeOut(duration: 0.25)) { controls = false }
        }
    }
}

#if os(iOS)
/// Just the picture of a playing video, filling the space with its own shape kept, and no controls of its own to
/// fight the swipe.
private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    final class Surface: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.backgroundColor = .clear
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: Surface, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
#endif
