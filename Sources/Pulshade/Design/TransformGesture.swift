import SwiftUI

/// One move, pinch and twist, measured from where it started. With two fingers the move follows the point between
/// them, so lifting or adding a finger never makes what is held jump.
struct TransformValue: Equatable {
    var translation = CGSize.zero
    var scale: CGFloat = 1
    var rotation: Double = 0
    /// Where the touch began, and where it is now (between the fingers when there are two), in the surface's space.
    var startLocation = CGPoint.zero
    var location = CGPoint.zero
    var fingers = 1
}

/// Soft limits: past the edge a value still moves, but less and less, the way a list stretches past its end.
enum RubberBand {
    /// `value` kept within `range`, with what goes past it shrunk; `span` sets how far it can stretch.
    static func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>, span: CGFloat) -> CGFloat {
        guard span > 0 else { return min(max(value, range.lowerBound), range.upperBound) }
        func stretch(_ over: CGFloat) -> CGFloat { (1 - 1 / (over * 0.55 / span + 1)) * span }
        if value < range.lowerBound { return range.lowerBound - stretch(range.lowerBound - value) }
        if value > range.upperBound { return range.upperBound + stretch(value - range.upperBound) }
        return value
    }
}

extension Haptics {
    /// A light knock, for something clicking into place.
    @MainActor static func snap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.8)
        #endif
    }

    /// A firmer knock, for something about to be deleted.
    @MainActor static func warn() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}

/// A clear surface that reports taps and one combined move, pinch and twist. On the iPhone a single UIKit recogniser
/// tracks the fingers itself, so the three never fight; on the Mac the mouse moves and the trackpad pinches and turns.
struct TransformSurface: View {
    var began: (TransformValue) -> Void
    var changed: (TransformValue) -> Void
    var ended: (TransformValue) -> Void
    var tapped: (CGPoint) -> Void = { _ in }

    var body: some View {
        #if os(iOS)
        TouchSurface(began: began, changed: changed, ended: ended, tapped: tapped)
        #else
        MouseSurface(began: began, changed: changed, ended: ended, tapped: tapped)
        #endif
    }
}

#if os(iOS)
import UIKit

/// Tracks up to two fingers. Moving one finger past a few points, or putting down a second, begins it; lifting the
/// last ends it. A short touch that hardly moved is a tap.
final class TransformRecognizer: UIGestureRecognizer {
    private var tracked: [UITouch] = []
    private var base = TransformValue()
    private var anchor = (centroid: CGPoint.zero, distance: CGFloat(1), angle: Double(0))
    private var downAt: TimeInterval = 0
    private(set) var value = TransformValue()
    private(set) var isTap = false
    private static let slop: CGFloat = 6

    private func centroid() -> CGPoint {
        let points = tracked.map { $0.location(in: view) }
        guard !points.isEmpty else { return value.location }
        return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
    }

    private func pair() -> (distance: CGFloat, angle: Double)? {
        guard tracked.count >= 2 else { return nil }
        let a = tracked[0].location(in: view), b = tracked[1].location(in: view)
        return (max(hypot(b.x - a.x, b.y - a.y), 1), atan2(Double(b.y - a.y), Double(b.x - a.x)))
    }

    /// Starts measuring afresh from the fingers down now, keeping what was done so far.
    private func reanchor() {
        base = value
        let c = centroid()
        let p = pair()
        anchor = (c, p?.distance ?? 1, p?.angle ?? 0)
        value.location = c
        value.fingers = max(tracked.count, 1)
    }

    private func measure() {
        let c = centroid()
        var next = base
        next.translation = CGSize(width: base.translation.width + c.x - anchor.centroid.x,
                                  height: base.translation.height + c.y - anchor.centroid.y)
        if let p = pair(), anchor.distance > 0 {
            next.scale = base.scale * p.distance / anchor.distance
            var turn = p.angle - anchor.angle
            if turn > .pi { turn -= 2 * .pi } else if turn < -.pi { turn += 2 * .pi }
            next.rotation = base.rotation + turn
        }
        next.location = c
        next.fingers = max(tracked.count, 1)
        value = next
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let first = tracked.isEmpty
        if first {
            value = TransformValue()
            downAt = event.timestamp
            isTap = false
        }
        for touch in touches where tracked.count < 2 { tracked.append(touch) }
        if first { value.startLocation = centroid() }
        reanchor()
        if state == .possible, tracked.count >= 2 { state = .began }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.contains(where: { tracked.contains($0) }) else { return }
        measure()
        switch state {
        case .possible:
            if hypot(value.translation.width, value.translation.height) > Self.slop { state = .began }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    private func lift(_ touches: Set<UITouch>, cancelled: Bool) {
        measure()
        tracked.removeAll { touches.contains($0) }
        guard tracked.isEmpty else { reanchor(); if state == .began || state == .changed { state = .changed }; return }
        switch state {
        case .possible:
            let quick = (touches.first?.timestamp ?? downAt) - downAt < 0.5
            if !cancelled, quick, hypot(value.translation.width, value.translation.height) <= Self.slop {
                isTap = true
                state = .ended
            } else {
                state = .failed
            }
        case .began, .changed:
            state = cancelled ? .cancelled : .ended
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, cancelled: true) }

    override func reset() {
        super.reset()
        tracked = []
        base = TransformValue()
        value = TransformValue()
        isTap = false
    }
}

/// A plain view under the SwiftUI content that the recogniser lives on, so its points are the surface's own.
private struct TouchSurface: UIViewRepresentable {
    var began: (TransformValue) -> Void
    var changed: (TransformValue) -> Void
    var ended: (TransformValue) -> Void
    var tapped: (CGPoint) -> Void

    final class Coordinator: NSObject {
        var parent: TouchSurface
        init(_ parent: TouchSurface) { self.parent = parent }

        @MainActor @objc func handle(_ recognizer: TransformRecognizer) {
            switch recognizer.state {
            case .began: parent.began(recognizer.value)
            case .changed: parent.changed(recognizer.value)
            case .ended:
                if recognizer.isTap { parent.tapped(recognizer.value.startLocation) } else { parent.ended(recognizer.value) }
            case .cancelled: parent.ended(recognizer.value)
            default: break
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let recognizer = TransformRecognizer(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }
}
#else

/// The Mac: drag with the mouse to move, pinch and turn on the trackpad. A click that hardly moved is a tap.
private struct MouseSurface: View {
    var began: (TransformValue) -> Void
    var changed: (TransformValue) -> Void
    var ended: (TransformValue) -> Void
    var tapped: (CGPoint) -> Void
    @State private var value = TransformValue()
    @State private var dragging = false
    @State private var pinching = false
    @State private var turning = false
    @State private var live = false

    private func update(_ change: (inout TransformValue) -> Void) {
        change(&value)
        if live { changed(value) } else { live = true; began(value) }
    }

    private func finishIfIdle() {
        guard !dragging, !pinching, !turning else { return }
        if live { ended(value) }
        live = false
        value = TransformValue()
    }

    var body: some View {
        Color.clear
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard dragging || hypot(drag.translation.width, drag.translation.height) > 4 else { return }
                    if !live { value.startLocation = drag.startLocation }
                    dragging = true
                    update { $0.translation = drag.translation; $0.location = drag.location }
                }
                .onEnded { drag in
                    if !dragging, !live { tapped(drag.startLocation); return }
                    dragging = false
                    finishIfIdle()
                })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { pinch in
                    if !live { value.startLocation = pinch.startLocation; value.location = pinch.startLocation; value.fingers = 2 }
                    pinching = true
                    update { $0.scale = pinch.magnification }
                }
                .onEnded { _ in pinching = false; finishIfIdle() })
            .simultaneousGesture(RotateGesture()
                .onChanged { turn in
                    if !live { value.fingers = 2 }
                    turning = true
                    update { $0.rotation = turn.rotation.radians }
                }
                .onEnded { _ in turning = false; finishIfIdle() })
    }
}
#endif
