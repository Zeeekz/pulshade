import SwiftUI

/// Verify someone face to face: same emoji, same colours, same code on both screens.
/// Scan their screen with the camera, or compare by eye and confirm.
struct PulseCheckView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let fingerprint: String
    /// Which of your personas knows them.
    let persona: UUID?

    @State private var scanner = QRScanner()
    @State private var scanning = false
    @State private var result: Bool?

    private var mine: String { model.me(persona)?.fingerprint ?? "" }
    private var code: SafetyCode { SafetyCode(mine: mine, theirs: fingerprint) }
    private var contact: Contact? { model.contact(fingerprint, in: persona) }
    private var verified: Bool { contact?.verified ?? false }

    var body: some View {
        SheetBody(width: 460) {
            VStack(spacing: 20) {
                SheetHeader(symbol: "waveform.path.ecg", title: "Pulse check")

                HStack(spacing: 0) {
                    Avatar(image: model.profile(for: persona).avatar, seed: mine, size: 64)
                    BeatBridge(colors: code.colors, success: verified || result == true)
                        .frame(width: 180, height: 64)
                    Avatar(image: contact?.avatar, seed: fingerprint, size: 64)
                }

                VStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(row * 5..<row * 5 + 5, id: \.self) { i in
                                Text(code.emoji[i]).font(.system(size: 28))
                                    .frame(width: 46, height: 48)
                                    .glass(12)
                                    .phaseAnimator(Platform.reduceMotion ? [0.0] : [0.0, -4.0, 0.0]) { v, y in v.offset(y: y) } animation: { _ in
                                        .easeInOut(duration: 0.4).delay(Double(i) * 0.06 + 2)
                                    }
                            }
                        }
                    }
                }

                Group {
                    if scanning {
                        CameraPreview(session: scanner.session)
                            .frame(width: 260, height: 196)
                            .clipShape(.rect(cornerRadius: 20))
                            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(theme.gradient, lineWidth: 2))
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        QRCode(text: code.scanText, size: 150)
                            .shadow(color: code.colors[0].opacity(0.5), radius: 24)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(height: 200)

                Text(code.digits.joined(separator: "  "))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Ink.faint)
                    .textSelection(.enabled)

                if let result {
                    HStack(spacing: 8) {
                        Image(systemName: result ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        Text(result ? "Verified" : "Codes don't match")
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(result ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Color.red))
                    .transition(.scale.combined(with: .opacity))
                }

                HStack(spacing: 14) {
                    Button(action: toggleScan) { Image(systemName: scanning ? "qrcode" : "camera.viewfinder") }
                        .buttonStyle(IconButtonStyle(size: 50, active: scanning))
                        .help(scanning ? "Show my code" : "Scan their screen")
                        .accessibilityLabel(scanning ? "Show my code" : "Scan their screen")
                    if verified {
                        Button { model.setVerified(fingerprint, false); result = nil } label: { Image(systemName: "seal") }
                            .buttonStyle(IconButtonStyle(size: 50))
                            .help("Remove verification")
                            .accessibilityLabel("Remove verification")
                    } else {
                        Button { confirm(true) } label: { Image(systemName: "checkmark") }
                            .buttonStyle(GlowButtonStyle(size: 50))
                            .help("The emoji match")
                            .accessibilityLabel("The emoji match")
                    }
                }
            }
            .animation(.snappy, value: scanning)
            .animation(.snappy, value: result)
        }
        .onChange(of: scanner.found) { _, text in
            guard let text else { return }
            withAnimation(.snappy) { scanning = false }
            confirm(text == code.scanText)
        }
        .onDisappear { scanner.stop() }
    }

    private func toggleScan() {
        if scanning {
            scanner.stop()
            scanning = false
        } else {
            result = nil
            Task { if await scanner.start() { scanning = true } }
        }
    }

    private func confirm(_ match: Bool) {
        withAnimation(.snappy) { result = match }
        if match { model.setVerified(fingerprint, true) }
    }
}

/// A heartbeat travelling between two avatars in the code's own colours. It flares when verified.
private struct BeatBridge: View {
    var colors: [Color]
    var success: Bool

    var body: some View {
        TimelineView(.animation(paused: Platform.reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let head = (t.truncatingRemainder(dividingBy: 1.6)) / 1.6 * 1.4
            ZStack {
                PulseLine()
                    .stroke(Ink.faint.opacity(0.3), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                PulseLine()
                    .trim(from: max(0, head - 0.4), to: min(1, head))
                    .stroke(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: success ? 5 : 3.5, lineCap: .round, lineJoin: .round))
                    .shadow(color: colors[0].opacity(success ? 1 : 0.7), radius: success ? 12 : 6)
            }
            .padding(.horizontal, 10)
        }
    }
}
