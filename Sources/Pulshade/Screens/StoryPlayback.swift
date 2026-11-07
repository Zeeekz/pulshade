import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

// MARK: - Playing a received clip

/// A story clip being played, straight from memory: the player is given the bytes without a file.
@MainActor
@Observable
final class StoryClip {
    @ObservationIgnored let player: AVPlayer
    @ObservationIgnored let layer: AVPlayerLayer
    @ObservationIgnored private let clip: MemoryClip
    @ObservationIgnored private var ticker: Any?
    @ObservationIgnored private var end: NSObjectProtocol?
    /// How long it plays, in seconds; 0 until the file has been read.
    private(set) var duration: Double = 0
    /// 0 to 1.
    private(set) var progress: Double = 0
    private(set) var finished = false
    var muted = false { didSet { player.isMuted = muted } }

    init?(data: Data) {
        guard !data.isEmpty else { return nil }
        clip = MemoryClip(data)
        let item = AVPlayerItem(asset: clip.makeAsset())
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        Task { [weak self] in
            let seconds = (try? await item.asset.load(.duration).seconds) ?? 0
            self?.duration = seconds.isFinite ? min(seconds, StoryVideo.maxSeconds) : 0
        }
        ticker = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.duration > 0 else { return }
                self.progress = min(max(time.seconds / self.duration, 0), 1)
            }
        }
        end = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished = true; self?.progress = 1 }
        }
    }

    func play() { if !finished { player.play() } }
    func pause() { player.pause() }

    func restart() {
        finished = false
        progress = 0
        player.seek(to: .zero)
        player.play()
    }

    /// Stops playing and lets go of the clip.
    func close() {
        player.pause()
        if let ticker { player.removeTimeObserver(ticker) }
        ticker = nil
        if let end { NotificationCenter.default.removeObserver(end) }
        end = nil
        player.replaceCurrentItem(with: nil)
    }
}

/// A still of a clip, for places that don't play it.
struct StoryPoster: View {
    var data: Data
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            Color.black
            if let image { Image(platformImage: image).resizable().scaledToFill() }
            Image(systemName: "play.fill")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(.black.opacity(0.4), in: .circle)
        }
        .task(id: data.count) {
            guard !data.isEmpty else { return }
            if let cg = await StoryVideo.poster(of: MemoryClip(data)) { image = PlatformImage.from(cgImage: cg) }
        }
    }
}

// MARK: - Previewing a clip in the composer

/// Plays a clip you picked or recorded, on a loop, with the chosen look applied live.
@MainActor
@Observable
final class ClipPreview {
    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored let layer: AVPlayerLayer
    @ObservationIgnored private let asset: AVURLAsset
    @ObservationIgnored private let zoom: ZoomTrack
    @ObservationIgnored private var end: NSObjectProtocol?

    init(clip: MemoryClip, filter: StoryFilter, zoom: ZoomTrack = .none) {
        asset = clip.makeAsset()
        self.zoom = zoom
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = StoryVideo.composition(for: asset, filter: filter, zoom: zoom)
        // Only the first 15 seconds are kept.
        item.forwardPlaybackEndTime = CMTime(seconds: StoryVideo.maxSeconds, preferredTimescale: 600)
        player.replaceCurrentItem(with: item)
        layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        end = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.player.seek(to: .zero); self?.player.play() }
        }
        player.play()
    }

    func set(_ filter: StoryFilter) {
        player.currentItem?.videoComposition = StoryVideo.composition(for: asset, filter: filter, zoom: zoom)
    }

    func close() {
        player.pause()
        if let end { NotificationCenter.default.removeObserver(end) }
        end = nil
        player.replaceCurrentItem(with: nil)
    }
}

// MARK: - Swiping between looks

enum Haptics {
    @MainActor static func tick() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}

/// Swipe left or right to change the look; its name appears for a moment. Works with the arrow keys and
/// VoiceOver's adjust gesture, and fades instead of moving when Reduce Motion is on.
private struct FilterSwipe: ViewModifier {
    @Binding var filter: StoryFilter
    /// Off while a pinch or a hold on the shutter has the touch.
    var enabled = true
    /// Whether a swipe changes the look. The camera turns it off: there a swipe left closes it, and the looks
    /// come from `FilterStrip`. The keys, VoiceOver and the name flash still work.
    var swipes = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: StoryFilter?
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 24).onEnded { drag in
                let dx = drag.translation.width, dy = drag.translation.height
                guard enabled, swipes, abs(dx) > 48, abs(dx) > abs(dy) * 1.5 else { return }
                step(dx < 0 ? 1 : -1)
            })
            .onKeyPress(.leftArrow) { step(-1); return .handled }
            .onKeyPress(.rightArrow) { step(1); return .handled }
            .accessibilityAdjustableAction { direction in step(direction == .increment ? 1 : -1) }
            .accessibilityValue(filter.label)
            .accessibilityHint("Swipe left or right to change the filter")
            .overlay(alignment: .center) {
                if let shown {
                    Text(shown.label)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 10)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .allowsHitTesting(false)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: filter) { _, new in
                withAnimation(reduceMotion ? .linear(duration: 0.15) : .snappy(duration: 0.28)) { shown = new }
                token = UUID()
            }
            .task(id: token) {
                try? await Task.sleep(for: .seconds(1.1))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { shown = nil }
            }
    }

    private func step(_ d: Int) {
        Haptics.tick()
        filter = filter.shifted(by: d)
    }
}

extension View {
    func filterSwipe(_ filter: Binding<StoryFilter>, enabled: Bool = true, swipes: Bool = true) -> some View {
        modifier(FilterSwipe(filter: filter, enabled: enabled, swipes: swipes))
    }
}

/// The looks by name in a row that scrolls, for the camera: tapping one picks it, and the row keeps the chosen
/// one in view. It is the only place on the camera that moves sideways, so it never fights the swipe that closes it.
struct FilterStrip: View {
    @Binding var filter: StoryFilter
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(StoryFilter.allCases) { look in
                        Button {
                            Haptics.tick()
                            withAnimation(reduceMotion ? nil : .snappy) { filter = look }
                        } label: {
                            Text(look.label)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(look == filter ? theme.accent : .white.opacity(0.85))
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(look == filter ? theme.accent.opacity(0.22) : .black.opacity(0.35), in: .capsule)
                                .overlay(Capsule().strokeBorder(look == filter ? theme.accent : .white.opacity(0.18), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .id(look)
                        .accessibilityLabel(look.label)
                        .accessibilityAddTraits(look == filter ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.never)
            .onChange(of: filter) { _, new in
                withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .frame(height: 30)
    }
}

/// A row of dots under the preview: the current look's is long. Tapping one picks that look.
struct FilterDots: View {
    @Binding var filter: StoryFilter
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(StoryFilter.allCases) { look in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) { filter = look }
                } label: {
                    Capsule()
                        .fill(look == filter ? theme.accent : Color.white.opacity(0.35))
                        .frame(width: look == filter ? 18 : 6, height: 6)
                        .frame(height: 24).padding(.horizontal, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(look.label)
                .accessibilityAddTraits(look == filter ? .isSelected : [])
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: filter)
    }
}

// MARK: - Choosing a photo or video from the library

/// What a story starts from.
struct StoryPick: Identifiable {
    enum Kind { case photo(Data), clip(MemoryClip, ZoomTrack) }
    let id = UUID()
    let kind: Kind
    var filter = StoryFilter.none
}

#if os(iOS)
import PhotosUI

/// A dimmed screen with a spinner and a few words, over everything, for work that takes a moment.
@MainActor
enum LoadingHUD {
    private static var view: UIView?

    static func show(_ text: String) {
        guard view == nil, let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?.keyWindow else { return }
        let dim = UIView(frame: window.bounds)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.startAnimating()
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .medium)
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        dim.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: dim.centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: dim.centerYAnchor)])
        dim.isAccessibilityElement = true
        dim.accessibilityLabel = text
        window.addSubview(dim)
        view = dim
    }

    static func hide() {
        view?.removeFromSuperview()
        view = nil
    }
}

/// Apple's own photo picker, shown straight from UIKit: it hands back the picture, or a copy of the video's file, to
/// the callback. (SwiftUI's PhotosPicker, shown over the story camera, was closed before it could answer.)
@MainActor
final class LibraryPicker: NSObject, PHPickerViewControllerDelegate {
    private static var current: LibraryPicker?
    private var done: ((StoryPick.Kind?, UIImage?) -> Void)?

    /// A clip comes back as `.clip` (already copied somewhere that stays), a picture as an image to be framed.
    static func present(videosOnly: Bool = false, done: @escaping (StoryPick.Kind?, UIImage?) -> Void) {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = videosOnly ? .videos : .any(of: [.images, .videos])
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: configuration)
        let picker = LibraryPicker()
        picker.done = done
        controller.delegate = picker
        current = picker
        guard var top = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?.keyWindow?.rootViewController else {
            current = nil
            return
        }
        while let next = top.presentedViewController { top = next }
        top.present(controller, animated: true)
    }

    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        DispatchQueue.main.async { picker.dismiss(animated: true) }
        guard let provider = results.first?.itemProvider else {
            Task { @MainActor in self.finish(nil, nil) }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            // At once, so the screen says something while the video is fetched (one kept in iCloud is downloaded first)
            // and read in: that can take a while, and it used to look like nothing was happening.
            Task { @MainActor in LoadingHUD.show("Getting your video…") }
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                // The file is only there until this returns, so it is read into memory now. Pulshade makes no copy of it
                // on disk. Anything past the limit is too big to hold; the story only uses 15 seconds of it anyway.
                guard let url, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
                    Task { @MainActor in self.fail("That video couldn't be loaded. If it's kept in iCloud, check you're online and try again.") }
                    return
                }
                guard size <= Self.largest else {
                    Task { @MainActor in self.fail("That video is too big (\(size / 1_000_000) MB; the limit is \(Self.largest / 1_000_000) MB). Trim it to under a minute in Photos and try again.") }
                    return
                }
                guard let bytes = try? Data(contentsOf: url) else {
                    Task { @MainActor in self.fail("That video couldn't be read.") }
                    return
                }
                let clip = MemoryClip(bytes)
                Task { @MainActor in self.finish(.clip(clip, .none), nil) }
            }
        } else if provider.canLoadObject(ofClass: UIImage.self) {
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                let image = object as? UIImage
                Task { @MainActor in self.finish(nil, image) }
            }
        } else {
            Task { @MainActor in self.finish(nil, nil) }
        }
    }

    /// The biggest video that is held in memory to take 15 seconds from.
    nonisolated static let largest = 700_000_000

    /// Says why nothing was picked, instead of leaving the person looking at an unchanged screen.
    private func fail(_ message: String) {
        LoadingHUD.hide()
        let alert = UIAlertController(title: "Couldn't use that video", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        if var top = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?.keyWindow?.rootViewController {
            while let next = top.presentedViewController { top = next }
            top.present(alert, animated: true)
        }
        done = nil
        Self.current = nil
    }

    private func finish(_ kind: StoryPick.Kind?, _ image: UIImage?) {
        LoadingHUD.hide()
        done?(kind, image)
        done = nil
        Self.current = nil
    }
}
#endif

/// Pick a photo (framed to the story's shape first) or a video (first 15 seconds are used) from the library:
/// the photo picker on iPhone, a file panel on the Mac.
struct StoryMediaPicker<Label: View>: View {
    var picked: (StoryPick.Kind) -> Void
    @ViewBuilder var label: Label
    @State private var pending: PendingCrop?

    var body: some View {
        Button { choose() } label: { label }
            // Its own anchor: a sheet and the photo picker on one view cancel each other out.
            .background { Color.clear.cropper($pending, frame: .story) { picked(.photo($0)) } }
    }

    private func choose() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType, type.conforms(to: .movie) {
            // Read in place and held in memory: no copy is made on disk.
            if let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) { picked(.clip(MemoryClip(bytes), .none)) }
        } else if let image = NSImage(contentsOf: url) {
            pending = PendingCrop(image: image)
        }
        #else
        LibraryPicker.present { kind, image in
            if let kind { picked(kind) } else if let image { pending = PendingCrop(image: image) }
        }
        #endif
    }
}

#if os(macOS)
/// Scroll wheel and trackpad scrolling over a view, reported as a vertical amount (up is positive). It lets clicks
/// through to what's underneath.
struct ScrollZoom: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void

    final class Catcher: NSView {
        var onScroll: (CGFloat) -> Void = { _ in }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window == self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(point) { self.onScroll(event.scrollingDeltaY) }
                return event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) { view.onScroll = onScroll }
}
#endif
