import SwiftUI

/// The call screen: who, how long, and the controls. It covers everything while a call rings or runs.
struct CallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        if let call = model.call {
            let contact = model.contact(call.peer, in: call.persona)
            ZStack {
                Aurora()
                VStack(spacing: 0) {
                    Spacer(minLength: 40)
                    VStack(spacing: 16) {
                        Avatar(image: contact?.avatar, seed: call.peer, size: 112)
                            .overlay {
                                if call.phase == .ringing, !Platform.reduceMotion {
                                    Circle().strokeBorder(theme.accent.opacity(0.5), lineWidth: 2)
                                        .phaseAnimator([1.0, 1.25]) { v, s in v.scaleEffect(s).opacity(2 - s * 1.4) } animation: { _ in
                                            .easeOut(duration: 1.4)
                                        }
                                }
                            }
                        Text(contact?.displayName ?? "Unknown")
                            .font(.system(size: 28, weight: .semibold)).foregroundStyle(Ink.text)
                        status(call)
                            .font(.system(size: 15, design: .monospaced)).foregroundStyle(Ink.dim)
                        Label("End-to-end encrypted", systemImage: "lock.fill")
                            .font(.system(size: 12)).foregroundStyle(Ink.faint)
                    }
                    Spacer(minLength: 40)
                    controls(call)
                        .padding(.bottom, Platform.isPhone ? 24 : 48)
                }
                .padding(.horizontal, 24)
            }
            .transition(.opacity)
            #if os(iOS)
            // Held to your ear, the screen goes dark and the sound moves to the earpiece.
            .onAppear { UIDevice.current.isProximityMonitoringEnabled = true }
            .onDisappear { UIDevice.current.isProximityMonitoringEnabled = false }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.proximityStateDidChangeNotification)) { _ in
                model.heldToEar(UIDevice.current.proximityState)
            }
            #endif
        }
    }

    @ViewBuilder private func status(_ call: ActiveCall) -> some View {
        switch call.phase {
        case .ringing: Text(call.outgoing ? "Ringing…" : "Incoming call")
        case .connecting: Text("Connecting…")
        case let .live(since): Text(since, style: .timer).monospacedDigit()
        }
    }

    @ViewBuilder private func controls(_ call: ActiveCall) -> some View {
        if !call.outgoing && call.phase == .ringing {
            HStack(spacing: 64) {
                round("phone.down.fill", "Decline", tint: .red) { model.declineCall() }
                round("phone.fill", "Accept", tint: .green) { model.answerCall() }
            }
        } else {
            HStack(spacing: 28) {
                round(call.muted ? "mic.slash.fill" : "mic.fill", call.muted ? "Unmute" : "Mute",
                      tint: call.muted ? .white : nil) { model.toggleMute() }
                round("phone.down.fill", "End", tint: .red) { model.hangUp() }
                if Platform.isPhone {
                    round("speaker.wave.2.fill", "Speaker",
                          tint: call.speaker ? .white : nil) { model.toggleSpeaker() }
                }
            }
        }
    }

    /// A round call button with its label under it. A tint fills it; without one it's a quiet glass circle.
    private func round(_ symbol: String, _ label: String, tint: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(tint == nil ? Ink.text : (tint == .white ? .black : .white))
                    .frame(width: 68, height: 68)
                    .background(tint ?? Ink.raised, in: .circle)
                    .overlay(Circle().strokeBorder(tint == nil ? Ink.line : .clear))
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.dim)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
