import SwiftUI

/// The Burn tab. At the top, what this phone holds right now. Then a slider picks Lock, Detach or Burn, and holding the
/// ring for five seconds does it, so none can happen by a stray tap. Detach wipes this device once the hold completes
/// (after a few seconds at most spent telling contacts to clear their chats); Burn deletes the account everywhere.
/// Below, Burn persona and the full Burn sheet (what Burn deletes, and burning only this device) still ask for BURN.
struct LeaveView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: LeaveMode = .lock
    @State private var burning = false
    @State private var burningPersona = false

    init(mode: LeaveMode = .lock) { _mode = State(initialValue: mode) }

    var body: some View {
        ScrollView {
            LeaveBody(mode: $mode, burning: $burning, burningPersona: $burningPersona)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .sheet(isPresented: $burning) { BurnSheet() }
        .sheet(isPresented: $burningPersona) {
            if let id = model.activePersona { PersonaBurnSheet(persona: id) }
        }
    }

}

/// Everything on the Burn tab, outside its scroll view.
struct LeaveBody: View {
    @Environment(AppModel.self) private var model
    @Binding var mode: LeaveMode
    @Binding var burning: Bool
    @Binding var burningPersona: Bool
    @State private var burnWorking = false
    @State private var problem: String?

    var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text("Burn").font(.system(size: 20, weight: .bold)).foregroundStyle(Ink.text)
                LeaveStatusCard()
                VStack(spacing: 16) {
                    LeaveModeSlider(mode: $mode)
                    HoldRing(mode: mode, duration: mode.hold(in: model.data.security), busy: model.detaching || burnWorking) { perform(mode) }
                    if let problem {
                        Text(problem).font(.system(size: 13, weight: .medium)).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 320)
                    }
                    Text(branded: detail(mode))
                        .font(.system(size: 14)).foregroundStyle(Ink.dim)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: mode)
                    if !model.data.security.holdTimesChosen {
                        HoldTimeControl(mode: mode, done: {
                            withAnimation(.snappy) { model.updateSecurity { $0.holdTimesChosen = true } }
                        })
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .padding(.horizontal, 16)
                .background(Ink.surface, in: .rect(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Ink.line))
                VStack(alignment: .leading, spacing: 8) {
                    Text("FOR GOOD").font(.system(size: 12, weight: .semibold)).tracking(0.6).foregroundStyle(Ink.faint)
                        .padding(.leading, 4)
                    VStack(spacing: 0) {
                        if model.activePersona != nil {
                            BurnRow(symbol: "flame", title: "Burn persona",
                                    detail: "Delete \(model.activeProfile.displayName) for good.") { burningPersona = true }
                            Divider().overlay(Ink.line).padding(.leading, 62)
                        }
                        BurnRow(symbol: "list.bullet", title: "What Burn deletes",
                                detail: "Every detail, and burning only this phone.") { burning = true }
                    }
                    .background(Ink.surface, in: .rect(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.red.opacity(0.35)))
                }
            }
    }

    private func perform(_ mode: LeaveMode) {
        problem = nil
        switch mode {
        case .lock: model.lock()
        case .detach: Task { await model.detachNow() }
        case .burn:
            burnWorking = true
            Task {
                do {
                    try await model.burn(thisDeviceOnly: false)
                } catch AppModel.LeaveError.burnNotSaved {
                    problem = "Your chats are erased, but this phone couldn't keep the steps the server still has to take, so your account is still here. Hold to burn again."
                } catch {
                    problem = "Something went wrong, so nothing was burned. Try again."
                }
                burnWorking = false
            }
        }
    }

    /// What the chosen action does here, in one or two short lines.
    private func detail(_ mode: LeaveMode) -> String {
        switch mode {
        case .lock:
            return "Closes PULSHADE and clears it from memory. Your passcode opens it again."
        case .detach:
            return model.data.security.keepBackup
                ? "Wipes this phone. Your recovery code brings back contacts and groups, not chats."
                : "Wipes this phone. Backups are off, so nothing comes back."
        case .burn:
            return "Deletes your account everywhere, for good: chats for both sides, contacts, usernames and backup. Your recovery code won't bring it back."
        }
    }
}

enum LeaveMode: CaseIterable {
    case lock, detach, burn

    var title: String {
        switch self { case .lock: "Lock"; case .detach: "Detach"; case .burn: "Burn" }
    }
    var symbol: String {
        switch self { case .lock: "lock.fill"; case .detach: "person.crop.circle.badge.minus"; case .burn: "flame.fill" }
    }
    var verb: String {
        switch self { case .lock: "lock"; case .detach: "detach"; case .burn: "burn" }
    }
    var working: String {
        switch self { case .lock: "Locking"; case .detach: "Detaching"; case .burn: "Burning" }
    }
    /// How long the ring is held for this action, and the range it can be set to.
    func hold(in s: SecuritySettings) -> Double {
        switch self { case .lock: s.lockHold; case .detach: s.detachHold; case .burn: s.burnHold }
    }
    var holdRange: ClosedRange<Double> { self == .lock ? SecuritySettings.lockHoldRange : SecuritySettings.leaveHoldRange }
    func setHold(_ value: Double, in s: inout SecuritySettings) {
        let v = SecuritySettings.clamp(value, to: holdRange)
        switch self { case .lock: s.lockHold = v; case .detach: s.detachHold = v; case .burn: s.burnHold = v }
    }
    func tint(_ accent: Color) -> Color {
        switch self { case .lock: accent; case .detach: .orange; case .burn: .red }
    }
}

/// What a lock or detach would act on right now: chats, friends, messages, and how this phone protects them.
private struct LeaveStatusCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    private var messageCount: Int { model.data.conversations.reduce(0) { $0 + $1.messages.count } }
    /// Friends as the Contacts list shows them, across every persona, each person once: not people hidden from the
    /// list (channel followers, removed friends still being told), requests not yet accepted, or your own devices.
    private var friendCount: Int {
        Set(model.data.contacts.filter { !$0.hidden && !$0.awaitingAcceptance && !$0.isSelf && $0.departing == nil }
            .map(\.fingerprint)).count
    }

    private var autoLock: String {
        let s = model.data.security
        if s.lockImmediately { return "Instantly" }
        if s.autoLockMinutes == 0 { return "Never" }
        return s.autoLockMinutes < 60 ? "\(s.autoLockMinutes) min" : "\(s.autoLockMinutes / 60) h"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accent)
                Text("On this phone").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim)
                Spacer()
                if model.activePersona != nil {
                    Text(model.activeProfile.displayName)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.dim)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Ink.raised, in: .capsule)
                }
            }
            HStack(spacing: 0) {
                stat(model.data.conversations.count, "Chats")
                divider
                stat(friendCount, "Friends")
                divider
                stat(messageCount, "Messages")
            }
            HStack(spacing: 8) {
                chip(symbol: model.data.security.keepBackup ? "lock.icloud.fill" : "icloud.slash",
                     title: model.data.security.keepBackup ? "Sealed backup on" : "Backup off",
                     on: model.data.security.keepBackup)
                chip(symbol: "timer", title: "Auto-lock \(autoLock)", on: model.data.security.autoLockMinutes > 0 || model.data.security.lockImmediately)
            }
        }
        .padding(16)
        .background(
            LinearGradient(colors: [theme.accent.opacity(Ink.scheme == .light ? 0.10 : 0.16), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 20))
        .background(Ink.surface, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Ink.line))
    }

    private var divider: some View {
        Rectangle().fill(Ink.line).frame(width: 1, height: 30)
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .number.notation(.compactName))
                .font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(Ink.text)
                .contentTransition(.numericText())
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.dim)
        }
        .frame(maxWidth: .infinity)
    }

    private func chip(symbol: String, title: String, on: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(on ? Ink.text : .orange)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(on ? Ink.raised : Color.orange.opacity(0.12), in: .capsule)
    }
}

/// Lock, Detach or Burn, as a three-stop slider: drag the knob or tap a stop.
private struct LeaveModeSlider: View {
    @Environment(\.theme) private var theme
    @Binding var mode: LeaveMode
    @State private var drag: CGFloat?

    private static let modes = LeaveMode.allCases

    var body: some View {
        GeometryReader { geo in
            let seg = (geo.size.width - 8) / CGFloat(Self.modes.count)
            let index = CGFloat(Self.modes.firstIndex(of: mode) ?? 0)
            let x = min(max(index * seg + (drag ?? 0), 0), seg * CGFloat(Self.modes.count - 1))
            let nearest = Self.modes[min(max(Int((x / seg).rounded()), 0), Self.modes.count - 1)]
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.raised)
                Capsule()
                    .fill(nearest.tint(theme.accent).gradient)
                    .frame(width: seg)
                    .offset(x: x + 4)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                HStack(spacing: 0) {
                    ForEach(Self.modes, id: \.self) { m in
                        Label(m.title, systemImage: m.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .labelStyle(SliderLabelStyle())
                            .foregroundStyle(nearest == m ? (m == .lock ? Ink.onAccent : Color.white) : Ink.dim)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(.rect)
                            .onTapGesture { withAnimation(.snappy) { mode = m } }
                    }
                }
                .padding(.horizontal, 4)
            }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { drag = $0.translation.width }
                    .onEnded { _ in withAnimation(.snappy) { mode = nearest; drag = nil } }
            )
        }
        .frame(height: 52)
        .frame(maxWidth: 360)
        .sensoryFeedback(.selection, trigger: mode)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Action")
        .accessibilityValue(mode.title)
        .accessibilityAdjustableAction { direction in
            let i = Self.modes.firstIndex(of: mode) ?? 0
            let next = direction == .increment ? min(i + 1, Self.modes.count - 1) : max(i - 1, 0)
            withAnimation(.snappy) { mode = Self.modes[next] }
        }
    }
}

private struct SliderLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon; configuration.title }.lineLimit(1)
    }
}

/// The big ring: press and hold for five seconds and it fills, counting down; let go early and it drains back.
private struct HoldRing: View {
    @Environment(\.theme) private var theme
    var mode: LeaveMode
    var duration: Double
    var busy: Bool
    var action: () -> Void

    @State private var progress: Double = 0
    @State private var holding = false
    @State private var ticker: Task<Void, Never>?
    @State private var fired = 0

    private var tint: Color { mode.tint(theme.accent) }
    private var secondsLeft: Int { Int((duration * (1 - progress)).rounded(.up)) }
    private var instant: Bool { duration <= 0 }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(holding ? 0.35 : 0.18), .clear],
                                     center: .center, startRadius: 40, endRadius: 115))
                .frame(width: 230, height: 230)
                .animation(.easeInOut(duration: 0.3), value: holding)
            Circle().stroke(Ink.line, lineWidth: 10).frame(width: 184, height: 184)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 184, height: 184)
            Circle()
                .fill(Ink.raised)
                .overlay(Circle().strokeBorder(tint.opacity(0.35), lineWidth: 1))
                .frame(width: 156, height: 156)
                .scaleEffect(holding ? 0.94 : 1)
                .animation(.spring(duration: 0.25), value: holding)
            VStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.large).tint(tint)
                    Text(mode.working).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim)
                } else if holding {
                    Text("\(secondsLeft)")
                        .font(.system(size: 52, weight: .bold, design: .rounded)).foregroundStyle(tint)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.snappy, value: secondsLeft)
                    Text("Keep holding").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.dim)
                } else {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 34, weight: .semibold)).foregroundStyle(tint)
                        .contentTransition(.symbolEffect(.replace))
                    Text(instant ? "Tap to \(mode.verb)" : "Hold to \(mode.verb)")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.text)
                    Text(holdLabel(duration)).font(.system(size: 12)).foregroundStyle(Ink.faint)
                }
            }
        }
        .frame(width: 230, height: 230)
        .contentShape(.circle)
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 60, perform: {}) { pressing in
            pressing ? start() : stop()
        }
        .disabled(busy)
        .sensoryFeedback(.impact(weight: .medium), trigger: holding ? secondsLeft : 0) { _, new in holding && new > 0 }
        .sensoryFeedback(.success, trigger: fired)
        .onChange(of: mode) { stop() }
        .onChange(of: duration) { stop() }
        .onDisappear { stop() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold to \(mode.verb)")
        .accessibilityHint(instant ? "Tap to \(mode.verb) at once." : "Touch and hold for \(holdLabel(duration)).")
        .accessibilityAddTraits(.isButton)
    }

    private func start() {
        guard !busy, ticker == nil else { return }
        if instant {
            fired += 1
            action()
            return
        }
        holding = true
        let began = Date.now
        let duration = duration
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                let p = min(Date.now.timeIntervalSince(began) / duration, 1)
                progress = p
                if p >= 1 {
                    ticker = nil
                    holding = false
                    fired += 1
                    action()
                    withAnimation(.easeOut(duration: 0.4)) { progress = 0 }
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stop() {
        ticker?.cancel()
        ticker = nil
        holding = false
        withAnimation(.spring(duration: 0.45)) { progress = 0 }
    }
}

/// "Instant", "1 second", "2.5 seconds".
func holdLabel(_ seconds: Double) -> String {
    if seconds <= 0 { return "Instant" }
    let n = seconds.formatted(.number.precision(.fractionLength(0...1)))
    return seconds == 1 ? "1 second" : "\(n) seconds"
}

/// Sets how long the ring is held for the chosen action: a row of times in half seconds, saved as soon as one is tapped.
struct HoldTimeControl: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var mode: LeaveMode
    /// On the Burn tab before the times are chosen: a Done button that puts the picker away for good.
    var done: (() -> Void)? = nil

    private var steps: [Double] {
        stride(from: mode.holdRange.lowerBound, through: mode.holdRange.upperBound, by: 0.5).map { $0 }
    }

    var body: some View {
        let current = mode.hold(in: model.data.security)
        let tint = mode.tint(theme.accent)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "timer").font(.system(size: 12, weight: .semibold))
                Text("\(mode.title) hold time").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Ink.dim)
            HStack(spacing: 4) {
                ForEach(steps, id: \.self) { step in
                    let chosen = step == current
                    Button {
                        withAnimation(.snappy) { model.updateSecurity { mode.setHold(step, in: &$0) } }
                    } label: {
                        Text(short(step))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(chosen ? (mode == .lock ? Ink.onAccent : Color.white) : Ink.dim)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(chosen ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Ink.surface), in: .rect(cornerRadius: 9))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(holdLabel(step))
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            if let done {
                HStack(alignment: .center, spacing: 10) {
                    Text("Set all three, then Done hides this. Change them later in Me › Privacy & Security.")
                        .font(.system(size: 11)).foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Done", action: done)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.onAccent)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(theme.accent.gradient, in: .capsule)
                        .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Ink.raised, in: .rect(cornerRadius: 14))
        .frame(maxWidth: 360)
        .sensoryFeedback(.selection, trigger: current)
    }

    private func short(_ seconds: Double) -> String { shortHold(seconds) }
}

/// "Now", "0.5s", "2s".
func shortHold(_ seconds: Double) -> String {
    seconds <= 0 ? "Now" : seconds.formatted(.number.precision(.fractionLength(0...1))) + "s"
}

private struct BurnRow: View {
    var symbol: String
    var title: String
    var detail: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Burn.gradient, in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.red)
                    Text(branded: detail).font(.system(size: 13)).foregroundStyle(Ink.dim)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.faint)
            }
            .padding(14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Burn: the account is gone everywhere, as if it never existed. Typing BURN makes sure it's meant.
struct BurnSheet: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        SheetBody(width: 460) {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeader(symbol: "flame.fill", title: "Burn")
                Text("This deletes your account everywhere. It can't be undone, and the recovery code won't bring it back.")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                BurnPoints()
                BurnConfirmField(confirm: $confirm)
                if let problem {
                    ProblemText(problem)
                }
                BurnButton(working: working, enabled: confirm == "BURN", action: { burn() })
                Text("Burn wipes this phone at once and keeps erasing on the server until done. Detach leaves the sealed backup on the relay, erased within 180 days.")
                    .font(.system(size: 13)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Text(BurnSheet.leftBehind)
                    .font(.system(size: 13)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Burn this device only") { burn(deviceOnly: true) }
                    .disabled(working || confirm != "BURN")
            }
        }
    }

    /// What Burn can't take with it on an iPhone: Apple's wake-up token belongs to this copy of the app, not the account.
    static let pushTokenNote = "Apple's wake-up token for this iPhone outlives the account. The relay is told to forget it, but a new account made in this copy of Pulshade would get the same token, which the relay could match to this one. To start completely fresh, delete Pulshade and install it again: that gets a new token."

    /// What a Burn leaves on this device until the server side is done, said plainly (see docs/burn-order.md).
    static let leftBehind = "Until the server confirms, which can take up to 30 days if it can't be reached, this device keeps a sealed list of what's still to erase there. Someone who examines the device in that time can tell an account was burned here, and see the mailbox codes of the contacts it is still saying goodbye to, though not their names or any messages. It is deleted as soon as the server is done."

    private func burn(deviceOnly: Bool = false) {
        working = true
        problem = nil
        Task {
            do {
                try await model.burn(thisDeviceOnly: deviceOnly)
            } catch AppModel.LeaveError.burnNotSaved {
                problem = "Your chats are erased, but this device couldn't keep the steps the server still has to take, so your account is still here. Try Burn again."
            } catch {
                problem = "Something went wrong, so nothing was burned. Try again."
            }
            working = false
        }
    }
}

/// Burns one persona for good, like Burn does the whole account, leaving everything else alone.
struct PersonaBurnSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var persona: UUID
    @State private var confirm = ""
    @State private var working = false
    @State private var problem: String?

    private var name: String { model.activeProfile.displayName }

    var body: some View {
        SheetBody(width: 460) {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeader(symbol: "flame.fill", title: "Burn \(name)")
                Text("This deletes the persona \(name) everywhere. It can't be undone.")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    BurnPoint(symbol: "bubble.left.and.bubble.right", text: "Its chats are deleted for both sides. Groups it owns are deleted for everyone; it leaves the rest.")
                    BurnPoint(symbol: "person.crop.circle.badge.xmark", text: "Its contacts forget it, along with its messages, stories and requests.")
                    BurnPoint(symbol: "at", text: "Its usernames can't be claimed for 3 months, and the relay forgets they were its.")
                }
                BurnConfirmField(confirm: $confirm)
                if let problem {
                    ProblemText(problem)
                }
                BurnButton(working: working, enabled: confirm == "BURN", action: burn)
            }
        }
    }

    private func burn() {
        working = true
        problem = nil
        Task {
            do {
                try await model.burnPersona(persona)
                dismiss()
            } catch {
                problem = "Can't reach the relay, so nothing was burned yet. Check your connection and try again."
            }
            working = false
        }
    }
}

/// The lock screen's flame: Burn or Detach without the passcode, using the recovery code instead.
struct LockedLeaveSheet: View {
    @Environment(AppModel.self) private var model
    @State private var burning = false
    @State private var code = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        SheetBody(width: 460) {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeader(symbol: "flame.fill", title: "Burn or detach")
                VStack(spacing: 8) {
                    LeaveChoice(title: "Detach", detail: "This device lets go of the account. Your profile, contacts and groups wait up to 180 days for your recovery code.",
                                chosen: !burning) { burning = false }
                    LeaveChoice(title: "Burn", detail: "The account is deleted everywhere.",
                                chosen: burning) { burning = true }
                }
                Text("Without the passcode, your recovery code proves it's yours.")
                    .font(.system(size: 14)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
                RecoveryCodeField(code: $code)
                if burning {
                    BurnPoints()
                    BurnConfirmField(confirm: $confirm)
                }
                if let problem {
                    ProblemText(problem)
                }
                if burning {
                    BurnButton(working: working, enabled: confirm == "BURN" && !code.isEmpty, action: leave)
                } else {
                    Button(action: leave) { WorkingLabel(title: "Detach", working: working) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(working || code.isEmpty)
                }
            }
        }
    }

    private func leave() {
        working = true
        problem = nil
        Task {
            do {
                try await model.leaveFromLock(burning: burning, recoveryCode: code)
            } catch AppModel.LeaveError.wrongRecoveryCode {
                problem = "That isn't the recovery code of the account on this device"
            } catch AppModel.LeaveError.burnNotSaved {
                problem = "Your chats are erased, but this device couldn't keep the steps the server still has to take, so your account is still here. Try Burn again."
            } catch AppModel.LeaveError.backupNotRemoved {
                problem = "Your saved backup couldn't be removed from the relay, so nothing was burned. Try again."
            } catch {
                problem = "Can't reach the relay. Check your connection and try again."
            }
            working = false
        }
    }
}

// MARK: Pieces

private struct LeaveChoice: View {
    @Environment(\.theme) private var theme
    var title: String
    var detail: String
    var chosen: Bool
    var choose: () -> Void

    var body: some View {
        Button { withAnimation(.snappy) { choose() } } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(chosen ? theme.accent : Ink.faint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text)
                    Text(detail).font(.system(size: 13)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Ink.raised, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(chosen ? theme.accent.opacity(0.6) : Ink.line))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct RecoveryCodeField: View {
    @Binding var code: String

    var body: some View {
        TextField("", text: $code, prompt: Text("Recovery code").foregroundStyle(Ink.faint), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14, design: .monospaced))
            .foregroundStyle(Ink.text)
            #if os(iOS)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            #endif
            .lineLimit(2...4)
            .padding(14)
            .background(Ink.raised, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line))
    }
}

private struct BurnPoints: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BurnPoint(symbol: "bubble.left.and.bubble.right", text: "Every chat is deleted for both sides. Groups you own are deleted for everyone; you leave the rest.")
            BurnPoint(symbol: "person.crop.circle.badge.xmark", text: "Your contacts forget you, along with your messages, stories and requests.")
            BurnPoint(symbol: "at", text: "Your usernames can't be claimed for 3 months, and the relay forgets they were yours.")
            BurnPoint(symbol: "server.rack", text: "The relay keeps nothing: no backup, no waiting messages.")
            BurnPoint(symbol: "iphone.gen3", text: "This iPhone is wiped and keeps no trace of it.")
            #if os(iOS)
            BurnPoint(symbol: "bell.slash", text: BurnSheet.pushTokenNote)
            #endif
        }
    }
}

private struct BurnPoint: View {
    var symbol: String
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Ink.dim).frame(width: 20)
            Text(text).font(.system(size: 13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct BurnConfirmField: View {
    @Binding var confirm: String

    var body: some View {
        TextField("", text: $confirm, prompt: Text("Type BURN to confirm").foregroundStyle(Ink.faint))
            .textFieldStyle(LargeFieldStyle())
            #if os(iOS)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            #endif
    }
}

private struct BurnButton: View {
    var working: Bool
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if working { ProgressView().controlSize(.small).tint(.white) } else { Label("Burn", systemImage: "flame.fill") }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.red.opacity(enabled ? 0.9 : 0.35), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(working || !enabled)
    }
}
