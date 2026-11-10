import SwiftUI
import AVFoundation

/// Picks the part of a clip that becomes stories: a strip of its frames with a handle at each end of the kept part.
/// Drag a handle to move that end, or the middle to slide the whole part; the preview follows the finger to the frame
/// under it, and plays the kept part again on letting go. A tick marks each time the part grows into one more story.
struct StoryTrimBar: View {
    var clip: MemoryClip
    var duration: Double
    @Binding var trim: StoryTrim
    var preview: ClipPreview?

    private enum Grip { case start, end, middle }
    @State private var grip: Grip?
    @State private var origin = StoryTrim()
    @State private var atLimit = false
    @State private var frames: [Int: CGImage] = [:]

    private static let handle: CGFloat = 16
    private static let height: CGFloat = 44
    private static let frameCount = 10

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.black.opacity(0.45), in: .capsule)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.15), value: trim)
            GeometryReader { geo in
                let track = max(geo.size.width - Self.handle * 2, 1)
                let x = { (t: Double) in Self.handle + CGFloat(t / max(duration, 0.001)) * track }
                ZStack(alignment: .topLeading) {
                    strip(width: track)
                        .offset(x: Self.handle)
                    // Outside the kept part is dimmed.
                    Rectangle().fill(.black.opacity(0.6))
                        .frame(width: max(x(trim.start) - Self.handle, 0), height: Self.height)
                        .offset(x: Self.handle)
                    Rectangle().fill(.black.opacity(0.6))
                        .frame(width: max(Self.handle + track - x(trim.end), 0), height: Self.height)
                        .offset(x: x(trim.end))
                    frame(from: x(trim.start), to: x(trim.end))
                    if grip == nil, let preview {
                        Playhead(preview: preview, trim: trim, place: x)
                    }
                }
                .frame(width: geo.size.width, height: Self.height, alignment: .topLeading)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in moved(drag, track: track, x: x) }
                    .onEnded { _ in lifted() })
            }
            .frame(height: Self.height)
        }
        .task(id: duration) { await loadFrames() }
        .accessibilityElement()
        .accessibilityLabel("Trim video")
        .accessibilityValue(label)
        .accessibilityAction(named: "Start later") { nudge(start: 1) }
        .accessibilityAction(named: "Start earlier") { nudge(start: -1) }
        .accessibilityAction(named: "End later") { nudge(end: 1) }
        .accessibilityAction(named: "End earlier") { nudge(end: -1) }
    }

    private var label: String {
        let parts = StoryVideo.parts(of: trim.length)
        let span = "\(Self.clock(trim.start)) – \(Self.clock(trim.end))"
        return parts > 1 ? "\(span) · \(parts) stories" : "\(span) · \(Self.clock(trim.length))"
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The clip's frames, side by side, filling the track.
    private func strip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<Self.frameCount, id: \.self) { i in
                Group {
                    if let image = frames[i] {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.12)
                    }
                }
                .frame(width: width / CGFloat(Self.frameCount), height: Self.height)
                .clipped()
            }
        }
        .frame(width: width, height: Self.height)
        .clipShape(.rect(cornerRadius: 4))
    }

    /// The white frame around the kept part, with a grip at each end.
    private func frame(from start: CGFloat, to end: CGFloat) -> some View {
        let w = end - start + Self.handle * 2
        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.white, lineWidth: 2.5)
            HStack(spacing: 0) {
                gripView(symbol: "chevron.compact.left", held: grip == .start)
                Spacer(minLength: 0)
                gripView(symbol: "chevron.compact.right", held: grip == .end)
            }
        }
        .frame(width: w, height: Self.height)
        .offset(x: start - Self.handle)
        .allowsHitTesting(false)
    }

    private func gripView(symbol: String, held: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.black.opacity(0.75))
            .frame(width: Self.handle, height: Self.height)
            .background(.white, in: .rect(cornerRadius: 6, style: .continuous))
            .scaleEffect(y: held ? 1.08 : 1)
            .animation(.snappy(duration: 0.12), value: held)
    }

    // MARK: Dragging

    private func moved(_ drag: DragGesture.Value, track: CGFloat, x: (Double) -> CGFloat) {
        if grip == nil {
            // Whichever grip is nearer the finger, within reach; otherwise inside the kept part slides it.
            let p = drag.startLocation.x
            let toStart = abs(p - (x(trim.start) - Self.handle / 2)), toEnd = abs(p - (x(trim.end) + Self.handle / 2))
            if min(toStart, toEnd) < 26 {
                grip = toStart <= toEnd ? .start : .end
            } else if p > x(trim.start), p < x(trim.end) {
                grip = .middle
            } else {
                return
            }
            origin = trim
            atLimit = false
        }
        let seconds = Double(drag.translation.width / track) * duration
        let next: StoryTrim
        let wanted: Double
        switch grip {
        case .start:
            wanted = origin.start + seconds
            next = origin.movingStart(to: wanted, duration: duration)
            preview?.scrub(to: next.start)
        case .end:
            wanted = origin.end + seconds
            next = origin.movingEnd(to: wanted, duration: duration)
            preview?.scrub(to: next.end)
        default:
            wanted = origin.start + seconds
            next = origin.sliding(by: seconds, duration: duration)
            preview?.scrub(to: next.start)
        }
        // A knock on reaching a limit (the clip's edge, a second long, five minutes long), and a tick for each
        // story more or fewer.
        let limited = abs((grip == .end ? next.end : next.start) - wanted) > 0.01
        if limited && !atLimit { Haptics.snap() }
        atLimit = limited
        if StoryVideo.parts(of: next.length) != StoryVideo.parts(of: trim.length) { Haptics.tick() }
        trim = next
    }

    private func lifted() {
        guard grip != nil else { return }
        grip = nil
        preview?.play(trim)
    }

    private func nudge(start: Double = 0, end: Double = 0) {
        if start != 0 { trim = trim.movingStart(to: trim.start + start, duration: duration) }
        if end != 0 { trim = trim.movingEnd(to: trim.end + end, duration: duration) }
        preview?.play(trim)
    }

    /// A small still from evenly spaced moments, made in memory. Close enough to each moment is fine, which is quick.
    private func loadFrames() async {
        guard duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: clip.makeAsset())
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let step = duration / Double(Self.frameCount)
        let times = (0..<Self.frameCount).map { CMTime(seconds: step * (Double($0) + 0.5), preferredTimescale: 600) }
        for await result in generator.images(for: times) {
            guard !Task.isCancelled else { return }
            guard let image = try? result.image else { continue }
            let i = Int((result.requestedTime.seconds / step).rounded(.down))
            if (0..<Self.frameCount).contains(i) { frames[i] = image }
        }
    }
}

/// The line across the strip at the moment playing. It reads the preview's clock itself, so only it redraws as
/// the clip plays.
private struct Playhead: View {
    var preview: ClipPreview
    var trim: StoryTrim
    var place: (Double) -> CGFloat

    var body: some View {
        let t = min(max(preview.time, trim.start), trim.end)
        Capsule()
            .fill(.white)
            .frame(width: 3, height: 52)
            .shadow(color: .black.opacity(0.4), radius: 2)
            .offset(x: place(t) - 1.5, y: -4)
            .allowsHitTesting(false)
    }
}
