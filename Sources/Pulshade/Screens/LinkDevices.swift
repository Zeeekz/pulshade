import SwiftUI

/// On a new device: show a code for a logged-in device to scan, or scan (or paste) one from it, wait for it
/// to be approved there, then choose a passcode for this device.
struct LinkLoginFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var back: () -> Void

    @State private var linker = DeviceLinker()
    @State private var scanner = QRScanner()
    @State private var scanning = false
    @State private var pasted = ""
    @State private var style = LockStyle.remembered
    @State private var passcode = ""
    @State private var confirm = ""
    @State private var finishing = false
    @State private var shake = 0

    var body: some View {
        ZStack {
            switch linker.stage {
            case .idle, .failed: entry.transition(.opacity)
            case .waiting: waiting.transition(.opacity)
            case .received: passcodeStep.transition(.push(from: .trailing))
            }
        }
        .animation(.snappy, value: linker.stage)
        .onChange(of: scanner.found) { _, text in
            guard let text else { return }
            scanning = false
            linker.start(text)
        }
        .onAppear { if linker.joinCode == nil { linker.offer() } }
        .onDisappear { scanner.stop() }
    }

    private func leave() {
        linker.cancel()
        scanner.stop()
        back()
    }

    private var entry: some View {
        OnboardingPage(title: "Log in with QR code",
                       subtitle: scanning ? "Hold up the code from Link a new device on your other device."
                           : "On a device that's already logged in, open Settings, then Devices, then Link a new device, and scan this code.",
                       back: leave) {
            VStack(spacing: 16) {
                ZStack {
                    if scanning {
                        RoundedRectangle(cornerRadius: 16).fill(Ink.raised)
                        CameraPreview(session: scanner.session)
                            .clipShape(.rect(cornerRadius: 16))
                    } else if let join = linker.joinCode {
                        QRCode(text: JoinCode.link(join), size: 210)
                    } else {
                        RoundedRectangle(cornerRadius: 16).fill(Ink.raised)
                        ProgressView()
                    }
                }
                .frame(width: 240, height: 240)
                .overlay {
                    if scanning { RoundedRectangle(cornerRadius: 16).strokeBorder(theme.accent.opacity(0.6), lineWidth: 1.5) }
                }
                if !scanning && linker.joinCode != nil {
                    checkCode
                }
                if case let .failed(reason) = linker.stage {
                    ProblemText(reason)
                }
                TextField("", text: $pasted, prompt: Text("Or paste the link code").foregroundStyle(Ink.faint))
                    .textFieldStyle(LargeFieldStyle())
                    .font(.system(size: 13, design: .monospaced))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .onSubmit { linker.start(pasted) }
            }
        } actions: {
            if !pasted.isEmpty {
                Button("Use code") { linker.start(pasted) }.buttonStyle(PrimaryButtonStyle())
            } else if scanning {
                Button("Stop scanning") { scanner.stop(); scanning = false }.buttonStyle(SecondaryButtonStyle())
            } else {
                Button { Task { scanning = await scanner.start() } } label: {
                    Label("Scan their code instead", systemImage: "camera.viewfinder")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    /// The digits the approving device shows too. If they differ, someone else answered the code first.
    private var checkCode: some View {
        VStack(spacing: 4) {
            Text(linker.checkCode).font(.system(size: 24, weight: .semibold, design: .monospaced)).foregroundStyle(Ink.text)
            Text("Your other device shows these same digits before you approve.")
                .font(.system(size: 12)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
        }
    }

    private var waiting: some View {
        OnboardingPage(title: "Approve on your other device",
                       subtitle: "A request has been sent. Tap Link on your other device to continue.", back: leave) {
            VStack(spacing: 24) {
                checkCode
                ProgressView().controlSize(.large)
            }
            .padding(.top, 20)
        } actions: {
            Button("Cancel") {
                linker.cancel()
                linker.offer()
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var passcodeStep: some View {
        OnboardingPage(title: "Choose a \(style.noun)",
                       subtitle: "You're logged in as \(linker.bundle?.profile.displayName ?? "you"). This \(style.noun) locks PULSHADE on this device.",
                       back: leave) {
            VStack(spacing: 12) {
                Avatar(image: linker.bundle?.profile.avatar, seed: "", size: 72).padding(.bottom, 8)
                LockStylePicker(style: $style)
                if let length = style.length {
                    PinSetup(length: length, passcode: $passcode, confirm: $confirm, onDone: finish)
                } else {
                    PasscodeField(placeholder: "Passcode", text: $passcode, onSubmit: finish)
                    PasscodeField(placeholder: "Confirm passcode", text: $confirm, onSubmit: finish)
                        .modifier(Shake(trigger: shake))
                }
            }
        } actions: {
            if !style.isPIN {
                Button(action: finish) { WorkingLabel(title: "Finish", working: finishing) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(finishing)
            }
        }
        .onChange(of: style) { _, _ in passcode = ""; confirm = "" }
    }

    private func finish() {
        guard style.accepts(passcode), passcode == confirm, let bundle = linker.bundle else {
            withAnimation(.default) { shake += 1 }
            return
        }
        finishing = true
        LockStyle.remembered = style
        Task {
            try? await model.finishLink(bundle, deviceID: linker.deviceID, selfMailbox: linker.selfMailbox,
                                        relay: linker.relay, passcode: passcode)
            finishing = false
        }
    }
}

/// On a device that's logged in: show a code for a new device, then approve it.
struct LinkDeviceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var copied = false
    @State private var scanner = QRScanner()
    @State private var scanning = false
    @State private var problem: String?

    var body: some View {
        SheetBody(width: 420) {
            VStack(spacing: 16) {
                SheetHeader(symbol: "qrcode", title: "Link a new device")
                if model.pendingLink != nil {
                    LinkApproval()
                } else if scanning {
                    CameraPreview(session: scanner.session)
                        .frame(width: 220, height: 220)
                        .clipShape(.rect(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.accent.opacity(0.6), lineWidth: 1.5))
                    Text("Point the camera at the code on the new device. Only link devices you own.")
                        .font(.system(size: 12)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                    Button("Show my code instead") {
                        scanner.stop()
                        scanning = false
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                } else {
                    Button {
                        problem = nil
                        Task { scanning = await scanner.start() }
                    } label: {
                        Label("Scan the new device's code", systemImage: "camera.viewfinder")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    if let problem {
                        ProblemText(problem)
                    }
                    Text("Or, if the new device can scan, show it this code.")
                        .font(.system(size: 12)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                    QRCode(text: code, size: 170)
                    Button {
                        copyToClipboard(code, clearAfter: 120)
                        withAnimation(.snappy) { copied = true }
                    } label: {
                        Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the new device…").font(.system(size: 11)).foregroundStyle(Ink.faint)
                    }
                }
            }
            .animation(.snappy, value: model.pendingLink?.request.deviceID)
        }
        .onAppear { if code.isEmpty { code = model.makeLinkCode() } }
        .onChange(of: scanner.found) { _, text in
            guard let text else { return }
            scanning = false
            if !model.acceptJoinCode(text) { problem = "That isn't a code from a new PULSHADE device" }
        }
        .onDisappear { scanner.stop() }
    }
}

/// Settings card listing this account's devices.
struct LinkedDevicesCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var linking = false
    @State private var pending: Pending?

    var body: some View {
        Card(title: "Linked devices") {
            HStack(spacing: 10) {
                Image(systemName: Platform.isPhone ? "iphone" : "laptopcomputer").foregroundStyle(theme.accent).frame(width: 22)
                Text("\(deviceDisplayName) (this device)").foregroundStyle(Ink.text)
                Spacer()
            }
            ForEach(model.linkedDevices, id: \.id) { device in
                Divider().overlay(Ink.line)
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle").foregroundStyle(Ink.dim).frame(width: 22)
                    Text(device.name ?? "Linked device").foregroundStyle(Ink.text)
                    Spacer()
                    Text(device.session == nil ? "Connecting…" : "Linked")
                        .font(.system(size: 11)).foregroundStyle(device.session == nil ? Ink.faint : theme.accent)
                    Menu {
                        Button("Stop syncing with this device", role: .destructive) {
                            pending = Pending(title: "Stop syncing with \(device.name ?? "this device")?",
                                              message: "It stops getting your messages. What's on it stays until wiped.",
                                              confirm: "Stop syncing") { model.unlinkDevice(device.id) }
                        }
                    } label: {
                        Image(systemName: "ellipsis").foregroundStyle(Ink.faint).frame(width: 30, height: 30).contentShape(.rect)
                    }
                    .accessibilityLabel("More for \(device.name ?? "linked device")")
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
            }
            Divider().overlay(Ink.line)
            Button { linking = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "qrcode").frame(width: 22)
                    Text("Link a new device")
                    Spacer()
                }
                .foregroundStyle(theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $linking) { LinkDeviceSheet() }
        .confirms($pending)
    }
}
