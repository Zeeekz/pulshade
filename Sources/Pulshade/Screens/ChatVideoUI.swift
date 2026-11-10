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

private struct VideoPlayerCover: ViewModifier {
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

/// Plays a chat video from memory, with the system's own controls. Nothing is written to disk to play it.
private struct ChatVideoPlayer: View {
    @Environment(\.dismiss) private var dismiss
    var clip: Data
    @State private var player: AVPlayer?
    /// Kept for as long as the player is: the asset reads its bytes through it.
    @State private var source: MemoryClip?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea(edges: .bottom)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.5), in: .circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(14)
            .accessibilityLabel("Close")
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard player == nil, !clip.isEmpty else { return }
            let source = MemoryClip(clip)
            self.source = source
            let player = AVPlayer(playerItem: AVPlayerItem(asset: source.makeAsset()))
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
            source = nil
        }
    }
}
