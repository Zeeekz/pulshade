import SwiftUI

struct WelcomeView: View {
    enum Route { case home, create, restore, link }
    @State private var route: Route = .home
    @State private var appeared = false
    @State private var signingIn = false

    var body: some View {
        ZStack {
            switch route {
            case .home: home.transition(.opacity)
            case .create: CreateFlow(back: { go(.home) }).transition(.push(from: .trailing))
            case .restore: RestoreFlow(back: { go(.home) }).transition(.push(from: .trailing))
            case .link: LinkLoginFlow(back: { go(.home) }).transition(.push(from: .trailing))
            }
        }
        .onAppear { withAnimation(.smooth(duration: 1.0).delay(0.1)) { appeared = true } }
    }

    private var home: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            VStack(spacing: 22) {
                PulseMark(size: Platform.isPhone ? 92 : 104, animated: true)
                Wordmark(size: Platform.isPhone ? 20 : 22)
            }
            Spacer(minLength: 40)
            actions
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
        .onboardingColumn()
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if signingIn {
                Button { go(.link) } label: { Label("Log in with QR code", systemImage: "qrcode") }
                    .buttonStyle(PrimaryButtonStyle())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                Button { go(.restore) } label: { Label("Use recovery code", systemImage: "key.horizontal") }
                    .buttonStyle(SecondaryButtonStyle())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                Button("Back") { withAnimation(.smooth(duration: 0.35)) { signingIn = false } }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Ink.dim)
                    .padding(.top, 4)
            } else {
                Button("Log in") { withAnimation(.smooth(duration: 0.35)) { signingIn = true } }
                    .buttonStyle(PrimaryButtonStyle())
                    .transition(.opacity)
                Button("Create account") { go(.create) }
                    .buttonStyle(SecondaryButtonStyle())
                    .transition(.opacity)
            }
        }
        .padding(.bottom, Platform.isPhone ? 8 : 0)
    }

    private func go(_ r: Route) { withAnimation(.smooth(duration: 0.45)) { route = r } }
}

/// The shared frame of every sign-in screen: a back button, a title, one line of explanation,
/// the content, and the actions pinned to the bottom.
struct OnboardingPage<Content: View, Actions: View>: View {
    var title: String
    var subtitle: String
    var step: (current: Int, count: Int)? = nil
    var back: (() -> Void)?
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let step { StepDots(count: step.count, current: step.current) }
                HStack {
                    if let back {
                        Button(action: back) { Image(systemName: "chevron.left") }
                            .buttonStyle(IconButtonStyle(size: 36))
                            .accessibilityLabel("Back")
                    }
                    Spacer()
                }
            }
            .frame(height: 44)
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(Ink.text)
                            .multilineTextAlignment(.center)
                        Text(branded: subtitle)
                            .font(.system(size: 15))
                            .foregroundStyle(Ink.dim)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    content
                }
                .padding(.top, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 12) { actions }
                .padding(.top, 12)
        }
        .onboardingColumn()
    }
}

extension View {
    /// A narrow centred column: the full screen on iPhone, a calm panel in the middle of the Mac window.
    func onboardingColumn() -> some View {
        padding(.horizontal, 24)
            .padding(.vertical, Platform.isPhone ? 8 : 36)
            .frame(maxWidth: 420, maxHeight: Platform.isPhone ? .infinity : 660)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The label for a primary button, or a spinner while it works.
struct WorkingLabel: View {
    var title: String
    var working: Bool
    var body: some View {
        if working { ProgressView().controlSize(.small).tint(Ink.onAccent) } else { Text(title) }
    }
}

// MARK: - Create

struct CreateFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var back: () -> Void

    enum Step: Int { case profile, passcode, recovery }
    @State private var step: Step = .profile
    @State private var identity = Identity.generate()
    @State private var profile = Profile()
    @State private var passcode = ""
    @State private var confirm = ""
    @State private var problem: String?
    @State private var working = false
    @State private var shake = 0

    var body: some View {
        ZStack {
            switch step {
            case .profile: profileStep.transition(.asymmetric(insertion: .push(from: .trailing), removal: .push(from: .leading)))
            case .passcode: passcodeStep.transition(.asymmetric(insertion: .push(from: .trailing), removal: .push(from: .leading)))
            case .recovery: recoveryStep.transition(.asymmetric(insertion: .push(from: .trailing), removal: .push(from: .leading)))
            }
        }
    }

    private var profileStep: some View {
        OnboardingPage(title: "Set up your profile", subtitle: "Only people you chat with see this. Both are optional.",
                       step: (0, 3), back: stepBack) {
            VStack(spacing: 22) {
                AvatarPicker(image: $profile.avatar, seed: identity.fingerprint, size: 112)
                TextField("", text: $profile.name, prompt: Text("Name").foregroundStyle(Ink.faint))
                    .textFieldStyle(LargeFieldStyle())
                    .onSubmit(next)
            }
        } actions: {
            Button("Continue", action: next).buttonStyle(PrimaryButtonStyle())
        }
    }

    private var passcodeStep: some View {
        OnboardingPage(title: "Choose a passcode", subtitle: "It locks and encrypts PULSHADE on this device. Use at least 6 characters.",
                       step: (1, 3), back: stepBack) {
            VStack(spacing: 12) {
                PasscodeField(placeholder: "Passcode", text: $passcode, onSubmit: next)
                PasscodeField(placeholder: "Confirm passcode", text: $confirm, onSubmit: next)
                    .modifier(Shake(trigger: shake))
                StrengthBar(passcode: passcode).padding(.top, 4)
                if let problem {
                    Text(branded: problem).font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                }
            }
        } actions: {
            Button("Continue", action: next).buttonStyle(PrimaryButtonStyle())
        }
    }

    private var recoveryStep: some View {
        OnboardingPage(title: "Save your recovery code",
                       subtitle: "It's the only way back into your account. Write it down and keep it somewhere offline.",
                       step: (2, 3), back: stepBack) {
            VStack(spacing: 16) {
                RecoveryCodeGrid(code: identity.recoveryCode)
                // No copy button: clipboards sync between devices and clipboard apps keep history.
                Text("Write it on paper. It isn't offered for copying, because clipboards sync to other devices and keep history.")
                    .font(.system(size: 12)).foregroundStyle(Ink.faint).multilineTextAlignment(.center)
            }
        } actions: {
            Button(action: finish) { WorkingLabel(title: "I've saved it", working: working) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(working)
        }
    }

    private func next() {
        switch step {
        case .profile: advance(to: .passcode)
        case .passcode:
            guard passcode.count >= 6, passcode == confirm else {
                problem = passcode.count < 6 ? "Use at least 6 characters" : "The passcodes don't match"
                withAnimation(.default) { shake += 1 }
                return
            }
            problem = nil
            advance(to: .recovery)
        case .recovery: finish()
        }
    }

    private func finish() {
        working = true
        Task {
            try? await model.create(identity: identity, profile: profile, passcode: passcode)
            working = false
        }
    }

    private func stepBack() {
        switch step {
        case .profile: back()
        case .passcode: advance(to: .profile)
        case .recovery: advance(to: .passcode)
        }
    }

    private func advance(to s: Step) { withAnimation(.smooth(duration: 0.4)) { step = s } }
}

// MARK: - Restore

struct RestoreFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var back: () -> Void

    @State private var code = ""
    @State private var passcode = ""
    @State private var shake = 0
    @State private var working = false
    /// More than one public profile was found: which to keep.
    @State private var choices: [DirectoryProfile] = []
    @State private var chosen: String?
    @State private var problem: String?
    /// Asking the relay for the account, so it can be cancelled.
    @State private var lookup: Task<Void, Never>?
    @State private var startedAt = Date()

    /// How long to wait for the relay before saying so. Over Tor, a relay that has just moved networks can take a
    /// few minutes to be reachable again; better to say that than to spin.
    private static let patience: Duration = .seconds(75)

    private var seed: Data? { Identity.seed(fromRecoveryCode: code) }

    var body: some View {
        ZStack {
            if choices.isEmpty {
                entry.transition(.opacity)
            } else {
                chooser.transition(.push(from: .trailing))
            }
        }
        .animation(.smooth(duration: 0.35), value: choices.isEmpty)
    }

    private var entry: some View {
        OnboardingPage(title: "Restore your account",
                       subtitle: "Enter your recovery code, then choose a new passcode for this device.", back: back) {
            VStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    TextField("", text: $code, prompt: Text("Recovery code").foregroundStyle(Ink.faint), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(Ink.text)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        #endif
                        .lineLimit(3...5)
                        .padding(14)
                        .padding(.trailing, 24)
                        .background(Ink.raised, in: .rect(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(seed == nil ? Ink.line : theme.accent.opacity(0.6)))
                    Image(systemName: seed == nil ? "circle.dashed" : "checkmark.circle.fill")
                        .foregroundStyle(seed == nil ? AnyShapeStyle(Ink.faint) : AnyShapeStyle(theme.accent))
                        .contentTransition(.symbolEffect(.replace))
                        .padding(14)
                }
                .modifier(Shake(trigger: shake))
                PasscodeField(placeholder: "New passcode", text: $passcode, onSubmit: lookUp)
                if working && choices.isEmpty {
                    LookUpProgress(relay: model.data.relay, since: startedAt)
                }
                if let problem {
                    Text(branded: problem).font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                Text("If you logged out, everything comes back: your profile, contacts and chats.")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.faint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        } actions: {
            if working && lookup != nil {
                Button("Cancel", action: cancelLookUp)
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Button(action: lookUp) { WorkingLabel(title: "Restore", working: working) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(working || seed == nil || passcode.count < 6)
            }
        }
    }

    private var chooser: some View {
        OnboardingPage(title: "Choose your profile",
                       subtitle: "This account has more than one @handle. Keep one; the others are released.",
                       back: { choices = []; working = false }) {
            VStack(spacing: 10) {
                ForEach(choices, id: \.handle) { profile in
                    Button { withAnimation(.snappy) { chosen = profile.handle } } label: {
                        HStack(spacing: 12) {
                            Avatar(image: profile.avatar, seed: profile.fingerprint, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name.isEmpty ? "Anonymous" : profile.name)
                                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.text)
                                Text("@\(profile.handle)").font(.system(size: 13)).foregroundStyle(theme.accent)
                            }
                            Spacer()
                            Image(systemName: chosen == profile.handle ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(chosen == profile.handle ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Ink.faint))
                        }
                        .padding(12)
                        .background(Ink.raised, in: .rect(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(chosen == profile.handle ? theme.accent.opacity(0.6) : Ink.line))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        } actions: {
            Button { finish(keeping: choices.first { $0.handle == chosen }) } label: {
                WorkingLabel(title: "Continue", working: working)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(working || chosen == nil)
        }
    }

    /// Looks for what a log out left behind first. Without it, the account's public profiles are the next best thing.
    private func lookUp() {
        guard let seed, passcode.count >= 6, let identity = try? Identity(seed: seed) else {
            withAnimation(.default) { shake += 1 }
            return
        }
        working = true
        problem = nil
        startedAt = Date()
        let task = Task {
            let timer = Task {
                try? await Task.sleep(for: Self.patience)
                guard !Task.isCancelled, lookup != nil else { return }
                lookup?.cancel()
                lookup = nil
                working = false
                withAnimation(.snappy) {
                    problem = "The relay didn't answer in time. If you just changed networks, Tor can take a few minutes to reach it again; try once more shortly."
                }
            }
            defer { timer.cancel() }
            let result = await model.backup(of: identity)
            // Cancelled, or out of time: nothing more happens, and nothing is restored.
            guard !Task.isCancelled else { return }
            switch result {
            case let .found(backup):
                lookup = nil
                finish(keeping: nil, backup: backup)
                return
            case .unreachable:
                // Restoring without it would start the account over, so it waits until the relay answers.
                lookup = nil
                working = false
                withAnimation(.snappy) { problem = "Can't reach the relay. Check your connection and try again." }
                return
            case .none:
                break
            }
            let found = await model.publicProfiles(of: identity)
            guard !Task.isCancelled else { return }
            lookup = nil
            if found.count > 1 {
                chosen = found.first?.handle
                working = false
                choices = found
            } else {
                finish(keeping: found.first)
            }
        }
        lookup = task
    }

    private func cancelLookUp() {
        lookup?.cancel()
        lookup = nil
        working = false
        problem = nil
    }

    private func finish(keeping profile: DirectoryProfile?, backup: AppData? = nil) {
        guard let seed else { return }
        working = true
        let others = choices
        Task {
            do {
                try await model.restore(seed: seed, passcode: passcode, from: backup)
            } catch {
                working = false
                withAnimation(.default) { shake += 1 }
                return
            }
            if let profile { await model.adoptRestoredProfile(profile, releasing: others) }
        }
    }
}

/// What restoring is waiting on: Tor connecting, then the relay answering.
private struct LookUpProgress: View {
    var relay: String
    var since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let tor = URL(string: relay).map(Tor.uses) ?? false
            let progress = Tor.progress
            let waited = context.date.timeIntervalSince(since)
            VStack(spacing: 3) {
                Text(!tor ? "Asking the relay for your account…"
                     : progress < 0 ? "Tor couldn't start."
                     : progress < 100 ? "Connecting to Tor… \(progress)%"
                     : "Asking the relay for your account, over Tor…")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.dim)
                    .monospacedDigit()
                if waited > 15 {
                    Text("This can take up to a minute.").font(.system(size: 11)).foregroundStyle(Ink.faint)
                }
            }
            .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Unlock

struct UnlockView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var passcode = ""
    @State private var shake = 0
    @State private var working = false
    @State private var leaving = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            PulseMark(size: 72, animated: true)
            Text("Welcome back")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Ink.text)
                .padding(.top, 22)
            Text("Enter your passcode to unlock.")
                .font(.system(size: 15))
                .foregroundStyle(Ink.dim)
                .padding(.top, 6)
            PasscodeField(placeholder: "Passcode", text: $passcode, onSubmit: unlock)
                .modifier(Shake(trigger: shake))
                .disabled(working)
                .padding(.top, 28)
                .task { model.warmUp() }
            if model.dataUnreadable {
                Text(branded: "That passcode is right, but this account's data couldn't be read, so PULSHADE didn't open it. Nothing on this device was changed. An update to PULSHADE may fix it.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
            Spacer()
            VStack(spacing: 12) {
                Button(action: unlock) { WorkingLabel(title: "Unlock", working: working) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(working || passcode.isEmpty)
                    .keyboardShortcut(.defaultAction)
                if model.biometricsOn {
                    Button(action: unlockWithTouchID) {
                        Label("Unlock with \(Vault.biometryName)", systemImage: Vault.biometrySymbol)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(working)
                }
            }
            Button { leaving = true } label: { Image(systemName: "flame.fill") }
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Ink.faint)
                .padding(.top, 20)
                .help("Burn or detach")
                .accessibilityLabel("Burn or detach")
        }
        .onboardingColumn()
        .onAppear { if model.biometricsOn { unlockWithTouchID() } }
        .sheet(isPresented: $leaving) { LockedLeaveSheet() }
    }

    private func unlockWithTouchID() {
        guard !working else { return }
        working = true
        Task {
            _ = await model.unlockWithBiometrics()
            working = false
        }
    }

    private func unlock() {
        guard !passcode.isEmpty, !working else { return }
        working = true
        Task {
            let ok = await model.unlock(passcode: passcode)
            working = false
            if !ok {
                passcode = ""
                withAnimation(.default) { shake += 1 }
            }
        }
    }
}

// MARK: - Pieces

struct PasscodeField: View {
    var placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void

    var body: some View {
        SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(Ink.faint))
            .textFieldStyle(LargeFieldStyle())
            .onSubmit(onSubmit)
    }
}

private struct StrengthBar: View {
    @Environment(\.theme) private var theme
    var passcode: String

    private var score: Double {
        var s = min(Double(passcode.count) / 14, 1) * 0.6
        if passcode.contains(where: \.isNumber) { s += 0.1 }
        if passcode.contains(where: \.isUppercase) { s += 0.1 }
        if passcode.contains(where: { !$0.isLetter && !$0.isNumber }) { s += 0.2 }
        return min(s, 1)
    }

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(Ink.raised)
                .overlay(alignment: .leading) {
                    Capsule().fill(theme.gradient).frame(width: geo.size.width * score)
                        .animation(.snappy, value: score)
                }
        }
        .frame(height: 5)
    }
}

/// A roomy text box for the sign-in screens.
struct LargeFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .foregroundStyle(Ink.text)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Ink.raised, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line))
    }
}

struct StepDots: View {
    @Environment(\.theme) private var theme
    var count: Int
    var current: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Ink.hover))
                    .frame(width: i == current ? 22 : 6, height: 6)
            }
        }
        .animation(.snappy, value: current)
    }
}

struct RecoveryCodeGrid: View {
    var code: String
    var body: some View {
        let groups = code.split(separator: " ").map(String.init)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Platform.isPhone ? 72 : 78), spacing: 10), count: Platform.isPhone ? 4 : 5), spacing: 10) {
            ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
                Text(g)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Ink.text)
                    .frame(width: 78, height: 36)
                    .glass(10)
                    .transition(.scale.combined(with: .opacity))
                    .animation(.snappy.delay(Double(i) * 0.03), value: code)
            }
        }
        .textSelection(.enabled)
    }
}

struct Shake: GeometryEffect {
    var trigger: Int
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    private var progress: CGFloat = 0

    init(trigger: Int) {
        self.trigger = trigger
        progress = CGFloat(trigger)
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(progress * .pi * 6), y: 0))
    }
}
