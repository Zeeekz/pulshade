import SwiftUI

/// Closing a full-screen photo, video or story the way Telegram does: it follows your finger, the chat shows through
/// behind it as it goes, and letting go far enough (or with a flick) up or down throws it off the screen. Anything
/// short of that springs it back.
enum SwipeAway {
    /// How far a drag has gone toward closing, 0 to 1, for fading what's behind.
    static func progress(_ offset: CGSize) -> CGFloat { min(abs(offset.height) / 360, 1) }

    /// A little smaller the further it's pulled, like a card being lifted away.
    static func scale(_ offset: CGSize) -> CGFloat { 1 - progress(offset) * 0.18 }

    /// Whether a drag starting this way is a swipe to close: it has to start out more up-and-down than sideways, so
    /// sideways swipes (the next story, the next person) still do what they did.
    static func starts(_ translation: CGSize) -> Bool {
        abs(translation.height) > 6 && abs(translation.height) > abs(translation.width)
    }

    /// Whether letting go here closes it.
    static func closes(_ translation: CGSize, predicted: CGSize) -> Bool {
        abs(translation.height) > 110 || abs(predicted.height) > 420
    }

    /// Throws it off the screen the way it was going, then closes without the cover's own slide, so it doesn't jump
    /// back to the middle first.
    @MainActor static func fling(_ offset: Binding<CGSize>, predicted: CGSize, height: CGFloat, close: @escaping () -> Void) {
        let up = predicted.height < 0
        let distance = max(height, 600) * 1.15
        withAnimation(.easeOut(duration: 0.2)) {
            offset.wrappedValue = CGSize(width: offset.wrappedValue.width + predicted.width * 0.25, height: up ? -distance : distance)
        }
        Haptics.tick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { close() }
        }
    }
}

/// Puts the swipe on a whole viewer: the black behind fades as it moves, and the content follows the finger.
/// `enabled` is off while something else owns the drag, such as a zoomed-in photo being moved around.
struct SwipeToClose: ViewModifier {
    var enabled = true
    /// Told how far along it is (0 to 1), so buttons and captions can fade out while it moves.
    var moved: (CGFloat) -> Void = { _ in }
    var close: () -> Void
    @State private var offset: CGSize = .zero
    /// Decided when a drag starts: whether it's a swipe to close, or something else's drag to leave alone.
    @State private var swiping: Bool?

    func body(content: Content) -> some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(1 - Double(SwipeAway.progress(offset)) * 0.95).ignoresSafeArea()
                content
                    .scaleEffect(SwipeAway.scale(offset))
                    .offset(offset)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        guard enabled else { return }
                        if swiping == nil { swiping = SwipeAway.starts(value.translation) }
                        if swiping == true { offset = value.translation; moved(SwipeAway.progress(offset)) }
                    }
                    .onEnded { value in
                        defer { swiping = nil }
                        guard enabled, swiping == true else { return }
                        if SwipeAway.closes(value.translation, predicted: value.predictedEndTranslation) {
                            SwipeAway.fling($offset, predicted: value.predictedEndTranslation, height: geo.size.height, close: close)
                        } else {
                            withAnimation(.smooth(duration: 0.28)) { offset = .zero }
                            moved(0)
                        }
                    },
                isEnabled: enabled)
        }
        // Something else took the drag over (a pinch zoomed the photo in): put it back where it was.
        .onChange(of: enabled) { _, on in
            guard !on, offset != .zero || swiping != nil else { return }
            swiping = nil
            withAnimation(.smooth(duration: 0.2)) { offset = .zero }
            moved(0)
        }
        #if os(iOS)
        // What's behind shows through as it's pulled away.
        .presentationBackground(.clear)
        #endif
    }
}

extension View {
    func swipeToClose(enabled: Bool = true, moved: @escaping (CGFloat) -> Void = { _ in }, close: @escaping () -> Void) -> some View {
        modifier(SwipeToClose(enabled: enabled, moved: moved, close: close))
    }
}
