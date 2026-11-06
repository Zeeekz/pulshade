import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// The pages Settings opens, each from a row on the main list.
enum SettingsPage: String, Hashable {
    case profile, handles, collectibles, privacy, notifications, appearance, devices, network, anonymity, account, updates
}

/// Settings, laid out like a phone's own: your profile on top, then a short list of rows,
/// each opening its own page.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var path: [SettingsPage] = []
    @State private var burning = false
    #if DEBUG
    @State private var demoCrop: PendingCrop?
    @State private var demoFrame = CropFrame.avatar
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    SettingsGroup {
                        MenuRow(page: .profile, symbol: "person.crop.circle.fill", color: .hex(0x3D8BFF), title: "Profile",
                                value: model.activeProfile.handle.map { "@\($0)" } ?? "Private")
                        if Platform.isPhone {
                            RowDivider(inset: 54)
                            MenuRow(page: .collectibles, symbol: "crown.fill", color: .hex(0xE5383B), title: "Collectibles",
                                    value: model.activeProfile.badge?.kind?.name)
                        }
                    }
                    SettingsGroup {
                        MenuRow(page: .privacy, symbol: "lock.fill", color: .hex(0x8E8E93), title: "Privacy & Security")
                        RowDivider(inset: 54)
                        MenuRow(page: .notifications, symbol: "bell.badge.fill", color: .hex(0xFF453A), title: "Notifications",
                                value: model.data.security.notifications ? "On" : "Off")
                        RowDivider(inset: 54)
                        MenuRow(page: .appearance, symbol: "paintpalette.fill", color: .hex(0x30B0FF), title: "Appearance",
                                value: model.theme.name)
                        RowDivider(inset: 54)
                        MenuRow(page: .devices, symbol: "laptopcomputer.and.iphone", color: .hex(0xFF9F0A), title: "Devices",
                                value: "\(model.linkedDevices.count + 1)")
                    }
                    SettingsGroup {
                        MenuRow(page: .network, symbol: "antenna.radiowaves.left.and.right", color: .hex(0x30D158), title: "Network",
                                value: model.link == .online ? anonymityValue : model.connecting ? "Connecting…" : "Offline")
                        RowDivider(inset: 54)
                        MenuRow(page: .account, symbol: "key.fill", color: .hex(0xBF5AF2), title: "Account & Recovery")
                    }
                    #if os(macOS)
                    if Updater.enabled {
                        SettingsGroup {
                            MenuRow(page: .updates, symbol: "arrow.down.circle.fill", color: .hex(0x2EC4A0), title: "Updates",
                                    value: Updater.shared.ready ? "Update ready" : "Version \(Updater.version)")
                        }
                    }
                    #endif
                    SettingsGroup {
                        ActionRow(title: "Lock") { model.lock() }
                        RowDivider()
                        ActionRow(title: "Detach") { model.wipeNow() }
                        RowDivider()
                        ActionRow(title: "Burn", destructive: true) { burning = true }
                    }
                    HStack(spacing: 8) {
                        PulseMark(size: 18)
                        Wordmark(size: 9, color: Ink.faint)
                    }
                    .padding(.vertical, 6)
                }
                .padding(.horizontal, 16)
                .padding(.top, Platform.isPhone ? 12 : 40)
                .padding(.bottom, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .background(Ink.base)
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .navigationDestination(for: SettingsPage.self) { page in
                Group {
                    switch page {
                    case .profile: ProfileSettings()
                    case .handles: HandleSettings()
                    case .collectibles: CollectiblesView(inSettings: true)
                    case .privacy: PrivacySettings()
                    case .notifications: NotificationSettings()
                    case .appearance: AppearanceSettings()
                    case .devices: DevicesSettings()
                    case .network: NetworkSettings()
                    case .anonymity: AnonymityReport()
                    case .account: AccountSettings()
                    case .updates:
                        #if os(macOS)
                        UpdateSettings()
                        #else
                        EmptyView()
                        #endif
                    }
                }
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
            }
        }
        .sheet(isPresented: $burning) { BurnSheet() }
        #if DEBUG
        .onAppear {
            // Screenshots: PULSHADE_DEMO_SETTINGS=privacy opens that page.
            if AppModel.demoRequested, let raw = ProcessInfo.processInfo.environment["PULSHADE_DEMO_SETTINGS"],
               let page = SettingsPage(rawValue: raw) { path = [page] }
            // PULSHADE_DEMO_CROP=avatar|banner|story opens the framing editor on a sample picture.
            if AppModel.demoRequested, let kind = ProcessInfo.processInfo.environment["PULSHADE_DEMO_CROP"],
               let art = ImageRenderer(content: GenerativeArt(seed: "crop").frame(width: 1200, height: 900)).cgImage {
                demoFrame = kind == "banner" ? .banner : kind == "story" ? .story : .avatar
                demoCrop = PendingCrop(image: .from(cgImage: art))
            }
        }
        .cropper($demoCrop, frame: demoFrame) { _ in }
        #endif
    }

    private var anonymityValue: String {
        guard let relay = URL(string: model.data.relay) else { return "Direct" }
        if Tor.isOnion(relay) { return "Tor" }
        let local = relay.host().map { Invite.isLocal($0.lowercased()) } ?? false
        return model.data.security.tor ? (local ? "Offline" : "Tor") : "Direct"
    }

    /// Picture, name and @handle, centred, as the top of the page.
    private var header: some View {
        VStack(spacing: 10) {
            VStack(spacing: -46) {
                Banner(image: model.activeProfile.banner, seed: model.fingerprint, height: 110)
                AvatarPicker(image: Binding(get: { model.activeProfile.avatar },
                                            set: { v in model.updateProfile { $0.avatar = v } }),
                             seed: model.fingerprint, size: 92)
                    .background(Circle().fill(Ink.base).padding(-4))
            }
            HStack(spacing: 6) {
                Text(model.activeProfile.displayName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Ink.text)
                BadgeMark(badge: model.activeProfile.badge, size: 22)
            }
            Text(model.activeProfile.handle.map { "@\($0)" } ?? "Private profile")
                .font(.system(size: 14))
                .foregroundStyle(model.activeProfile.handle == nil ? Ink.dim : theme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}

// MARK: - Building blocks

/// A row on the main list: coloured icon, title, an optional value, and a chevron.
private struct MenuRow: View {
    var page: SettingsPage
    var symbol: String
    var color: Color
    var title: String
    var value: String?

    var body: some View {
        NavigationLink(value: page) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(color, in: .rect(cornerRadius: 8))
                Text(title).font(.system(size: 15)).foregroundStyle(Ink.text)
                Spacer(minLength: 8)
                if let value {
                    Text(value).font(.system(size: 14)).foregroundStyle(Ink.faint).lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.faint)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 50)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A rounded block of rows.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(Ink.faint)
                    .padding(.leading, 14)
            }
            VStack(spacing: 0) { content }
                .background(Ink.surface, in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line))
            if let footer {
                Text(branded: footer)
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }
        }
    }
}

struct RowDivider: View {
    var inset: CGFloat = 16
    var body: some View { Divider().overlay(Ink.line).padding(.leading, inset) }
}

/// A plain row inside a group: title on the left, a control on the right.
struct SettingRow<Trailing: View>: View {
    var title: String
    var symbol: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, symbol: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.symbol = symbol
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Ink.dim).frame(width: 24)
            }
            Text(title).font(.system(size: 15)).foregroundStyle(Ink.text).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
    }
}

/// A switch bound to one of the security settings.
private struct SecurityToggle: View {
    @Environment(AppModel.self) private var model
    var title: String
    var key: WritableKeyPath<SecuritySettings, Bool>

    var body: some View {
        SettingRow(title) {
            Toggle("", isOn: Binding(get: { model.data.security[keyPath: key] },
                                     set: { v in withAnimation(.snappy) { model.updateSecurity { $0[keyPath: key] = v } } }))
                .toggleStyle(GlowToggleStyle())
        }
    }
}

/// A whole-row button, red when it destroys something.
struct ActionRow: View {
    @Environment(\.theme) private var theme
    var title: String
    var destructive = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(destructive ? Color.red : theme.accent)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .padding(.horizontal, 16)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A row of choices; the chosen one is ticked, as in a phone's own settings.
private struct ChoiceRows<Value: Hashable>: View {
    @Environment(\.theme) private var theme
    var values: [Value]
    var selected: Value
    var label: (Value) -> String
    var choose: (Value) -> Void

    var body: some View {
        ForEach(Array(values.enumerated()), id: \.offset) { i, v in
            if i > 0 { RowDivider() }
            Button { withAnimation(.snappy) { choose(v) } } label: {
                SettingRow(label(v)) {
                    if v == selected {
                        Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}

/// One settings page: a back button and title, then its groups.
struct SettingsScreen<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    /// Where the back button goes.
    var back = "Settings"
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.text)
                HStack {
                    Button { dismiss() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                            Text(back).font(.system(size: 15))
                        }
                        .foregroundStyle(Ink.dim)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .padding(.top, Platform.isPhone ? 0 : 30)
            ScrollView {
                VStack(spacing: 26) { content }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 30)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
        .background(Ink.base)
        #if os(macOS)
        .navigationBarBackButtonHidden()
        #endif
    }
}

// MARK: - Profile

private struct ProfileSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var name = ""
    @State private var handle = ""
    @State private var bio = ""
    @State private var claiming = false
    @State private var handleProblem: String?
    @State private var burningPersona = false

    private var listed: Bool { model.activeProfile.handle != nil }

    var body: some View {
        SettingsScreen(title: "Profile") {
            VStack(spacing: -50) {
                BannerPicker(image: Binding(get: { model.activeProfile.banner },
                                            set: { v in model.updateProfile { $0.banner = v } }),
                             seed: model.fingerprint)
                AvatarPicker(image: Binding(get: { model.activeProfile.avatar },
                                            set: { v in model.updateProfile { $0.avatar = v } }),
                             seed: model.fingerprint, size: 100)
                    .background(Circle().fill(Ink.base).padding(-4))
            }
            SettingsGroup("Name", footer: "Only people you chat with see your name, picture and banner.") {
                TextField("", text: $name, prompt: Text("Your name").foregroundStyle(Ink.faint))
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.text)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    .onChange(of: name) { model.updateProfile { $0.name = name.trimmingCharacters(in: .whitespaces) } }
            }
            SettingsGroup("Public profile",
                          footer: listed ? "Anyone can find you by your @handle and send a chat request."
                                         : "Turn this on to claim a @handle. Otherwise only people you give an invite code can reach you.") {
                SettingRow("Discoverable") {
                    Toggle("", isOn: Binding(get: { listed }, set: { on in
                        if on { claim() } else { Task { await model.unpublishProfile() } }
                    }))
                    .toggleStyle(GlowToggleStyle())
                    .disabled(claiming)
                }
                RowDivider()
                HStack(spacing: 4) {
                    Text("@").font(.system(size: 15)).foregroundStyle(Ink.faint)
                    TextField("", text: $handle, prompt: Text("handle").foregroundStyle(Ink.faint))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.text)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .onSubmit(claim)
                    if claiming { ProgressView().controlSize(.small) }
                    if listed && handle == model.activeProfile.handle {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(theme.accent)
                    } else {
                        Button("Claim", action: claim)
                            .font(.system(size: 14, weight: .semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(handle.isEmpty ? Ink.faint : theme.accent)
                            .disabled(handle.isEmpty || claiming)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                if let handleProblem {
                    Text(handleProblem)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
                if listed, let mine = model.activeProfile.handle, let me = model.me(model.activePersona) {
                    RowDivider()
                    // Carries a check of your key, so it can never open someone else's profile.
                    ActionRow(title: "Copy profile link") {
                        copyToClipboard(DirectoryProfile.link(mine, key: me.card.signing))
                    }
                }
                RowDivider()
                NavigationLink(value: SettingsPage.handles) {
                    SettingRow("Your handles") {
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.faint)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                RowDivider()
                TextField("", text: $bio, prompt: Text("Bio").foregroundStyle(Ink.faint), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.text)
                    .lineLimit(1...4)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
                    .onChange(of: bio) { model.updateProfile { $0.bio = String(bio.prefix(160)) } }
            }
            ProfileLinksEditor()
            ProfileNotesEditor()
            SettingsGroup("Signature colour", footer: "How your messages glow on other people's screens.") {
                HStack(spacing: 0) {
                    ForEach(Signature.colors.indices, id: \.self) { i in
                        let on = model.signature("me") == Signature.colors[i]
                        Button { withAnimation(.snappy) { model.updateProfile { $0.color = i } } } label: {
                            Circle().fill(Signature.colors[i])
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Ink.text, lineWidth: on ? 2 : 0).padding(-4))
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Signature colour \(i + 1)")
                    }
                }
                .padding(.horizontal, 8)
            }
            if let id = model.activePersona {
                SettingsGroup(footer: "Burning this persona deletes it for good. Your main identity and other personas aren't touched.") {
                    ActionRow(title: "Burn persona", destructive: true) { burningPersona = true }
                }
                .sheet(isPresented: $burningPersona) { PersonaBurnSheet(persona: id) }
            }
        }
        .onChange(of: model.activePersona, initial: true) {
            name = model.activeProfile.name
            handle = model.activeProfile.handle ?? ""
            bio = model.activeProfile.bio ?? ""
        }
    }

    private func claim() {
        guard !handle.isEmpty, !claiming else { return }
        claiming = true
        handleProblem = nil
        Task {
            do {
                try await model.publishProfile(handle: handle)
                handle = model.activeProfile.handle ?? handle
            } catch AppModel.DirectoryError.taken {
                handleProblem = "@\(handle.lowercased()) is taken"
            } catch AppModel.DirectoryError.reserved {
                handleProblem = "@\(handle.lowercased()) is reserved"
            } catch AppModel.DirectoryError.held {
                handleProblem = "@\(handle.lowercased()) was let go of recently, so nobody can claim it yet. It frees up within 3 months"
            } catch AppModel.DirectoryError.full {
                handleProblem = "You've used your 3 handles. One you let go of frees up 3 months later"
            } catch AppModel.DirectoryError.invalidHandle {
                handleProblem = "Use 3–24 letters, numbers or _"
            } catch AppModel.DirectoryError.unreachable {
                handleProblem = "Can't reach the relay"
            } catch {
                handleProblem = "Couldn't claim it"
            }
            claiming = false
        }
    }
}

// MARK: - Handles

/// Every handle tied to this identity's key: the one in use, and the ones it stopped using that are kept for
/// it for three months. A kept one can be used again, or let go of early to make room for another.
private struct HandleSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var held: [AppModel.HeldHandle] = []
    @State private var loading = true
    @State private var working: String?
    @State private var problem: String?
    @State private var lettingGo: AppModel.HeldHandle?

    private var current: String? { model.activeProfile.handle }
    private var used: Int { held.count + (current == nil ? 0 : 1) }

    var body: some View {
        SettingsScreen(title: "Your handles", back: "Profile") {
            SettingsGroup("In use") {
                SettingRow(current.map { "@\($0)" } ?? "No public handle") {
                    if current != nil {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(theme.accent)
                    }
                }
            }
            SettingsGroup("Kept for you",
                          footer: "You can have \(AppModel.maxHandles) handles, counting the ones kept for you. A handle you stop using stays yours for 3 months, so nobody else can take it. Let it go to make room for another.") {
                if loading {
                    SettingRow("Checking with the relay…") { ProgressView().controlSize(.small) }
                } else if held.isEmpty {
                    SettingRow("None") { EmptyView() }
                } else {
                    ForEach(Array(held.enumerated()), id: \.element.id) { i, kept in
                        if i > 0 { RowDivider() }
                        keptRow(kept)
                    }
                }
            }
            HStack {
                Text("\(used) of \(AppModel.maxHandles) used").font(.system(size: 13)).foregroundStyle(Ink.faint)
                Spacer()
                if let problem { Text(problem).font(.system(size: 12, weight: .medium)).foregroundStyle(.orange) }
            }
            .padding(.horizontal, 14)
        }
        .task(id: model.activePersona) { await load() }
        .confirmationDialog(lettingGo.map { "Let go of @\($0.handle)?" } ?? "", isPresented: Binding(get: { lettingGo != nil }, set: { if !$0 { lettingGo = nil } }),
                            titleVisibility: .visible, presenting: lettingGo) { kept in
            Button("Let go", role: .destructive) { letGo(kept) }
        } message: { _ in
            Text("It frees a spot for another handle. Nobody can claim it for 30 days, you included; after that anyone can. Links you shared won't open their profile.")
        }
    }

    private func keptRow(_ kept: AppModel.HeldHandle) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("@\(kept.handle)").font(.system(size: 15)).foregroundStyle(Ink.text)
                Text("Yours until \(kept.until.formatted(date: .long, time: .omitted))")
                    .font(.system(size: 12)).foregroundStyle(Ink.faint)
            }
            Spacer(minLength: 8)
            if working == kept.handle {
                ProgressView().controlSize(.small)
            } else {
                Button("Use") { use(kept) }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
                Button("Let go") { lettingGo = kept }
                    .font(.system(size: 14)).foregroundStyle(.red)
            }
        }
        .buttonStyle(.plain)
        .disabled(working != nil)
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
    }

    private func load() async {
        loading = true
        do {
            held = try await model.heldHandles()
            problem = nil
        } catch {
            problem = "Can't reach the relay"
        }
        loading = false
    }

    /// Back in use: the one in use now is kept for you in its place.
    private func use(_ kept: AppModel.HeldHandle) {
        working = kept.handle
        Task {
            do {
                try await model.publishProfile(handle: kept.handle)
                problem = nil
            } catch AppModel.DirectoryError.unreachable {
                problem = "Can't reach the relay"
            } catch {
                problem = "Couldn't use @\(kept.handle)"
            }
            await load()
            working = nil
        }
    }

    private func letGo(_ kept: AppModel.HeldHandle) {
        working = kept.handle
        Task {
            do {
                try await model.letGo(of: kept.handle)
                withAnimation(.snappy) { held.removeAll { $0 == kept } }
                problem = nil
            } catch {
                problem = "Can't reach the relay"
            }
            working = nil
        }
    }
}

// MARK: - Privacy & Security

private struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @State private var biometrics = false
    @State private var settingUp: DisguiseKind?
    @State private var confirmRemove: DisguiseKind?

    var body: some View {
        SettingsScreen(title: "Privacy & Security") {
            SettingsGroup("Lock", footer: model.biometricsBlocked
                          ? "\(Vault.biometryName) is off while a decoy or panic passcode is set: it would open your account without asking which."
                          : nil) {
                if Vault.biometricsAvailable {
                    SettingRow("Unlock with \(Vault.biometryName)") {
                        Toggle("", isOn: Binding(get: { biometrics }, set: { on in
                            model.setBiometrics(on)
                            withAnimation(.snappy) { biometrics = model.biometricsOn }
                        }))
                        .toggleStyle(GlowToggleStyle())
                        .disabled(model.biometricsBlocked)
                    }
                    RowDivider()
                }
                SecurityToggle(title: Platform.isPhone ? "Hide in app switcher" : "Blur when in background", key: \.blurWhenInactive)
                RowDivider()
                SecurityToggle(title: "Block screenshots & recording", key: \.blockCapture)
            }
            SettingsGroup("Auto-lock", footer: "Locks PULSHADE after this long without use.") {
                ChoiceRows(values: [1, 5, 15, 0], selected: model.data.security.autoLockMinutes,
                           label: { $0 == 0 ? "Never" : $0 == 1 ? "After 1 minute" : "After \($0) minutes" }) { m in
                    model.updateSecurity { $0.autoLockMinutes = m }
                }
            }
            SettingsGroup("Messages",
                          footer: "To make a link preview, your device visits the website over Tor, on a circuit of its own, so the website never sees your IP address (with Tor off, it does). People receiving it never contact the website. Receipts are sent a little later, together, so their timing gives nothing away. With read receipts or story views off you won't see other people's either, and one-time chats never send them. Online status shows a green dot while you have PULSHADE open. It goes only to contacts you've accepted who have it on too, never from a burner, and you see theirs only if you show yours. The relay can't read it, but it can see when it goes out and to whom, and switching persona shows it that two personas share a device, so it's off until you turn it on.") {
                SecurityToggle(title: "Link previews", key: \.linkPreviews)
                RowDivider()
                SecurityToggle(title: "Delivery receipts", key: \.deliveryReceipts)
                RowDivider()
                SecurityToggle(title: "Read receipts", key: \.readReceipts)
                RowDivider()
                SecurityToggle(title: "Typing indicators", key: \.typingIndicators)
                RowDivider()
                SecurityToggle(title: "Online status", key: \.onlineStatus)
                RowDivider()
                SecurityToggle(title: "Story views", key: \.storyViews)
            }
            SettingsGroup("Blocked",
                          footer: "Anything blocked people send is dropped without telling them. Unblocking lets them send you a new request; your old chat doesn't come back.") {
                if model.data.blocked.isEmpty {
                    SettingRow("Nobody") { EmptyView() }
                } else {
                    ForEach(Array(model.data.blocked.enumerated()), id: \.element) { i, fp in
                        if i > 0 { RowDivider() }
                        SettingRow(model.data.blockedNames[fp] ?? "Unknown · \(fp.prefix(8))") {
                            Button("Unblock") { model.unblock(fp) }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(model.theme.accent)
                        }
                    }
                }
            }
            SettingsGroup("Disguise",
                          footer: "A decoy passcode opens an empty PULSHADE. A panic passcode silently erases everything, then does the same.") {
                disguiseRow(.decoy, title: "Decoy passcode", isSet: model.hasDecoy)
                RowDivider()
                disguiseRow(.panic, title: "Panic passcode", isSet: model.hasPanic)
            }
        }
        .onAppear { biometrics = model.biometricsOn }
        .sheet(item: $settingUp) { kind in DisguiseSetup(kind: kind) }
        .confirmationDialog(confirmRemove == .decoy ? "Remove the decoy?" : "Remove the panic passcode?",
                            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if confirmRemove == .decoy { model.removeDecoy() } else { model.removePanic() }
                confirmRemove = nil
            }
        }
    }

    private func disguiseRow(_ kind: DisguiseKind, title: String, isSet: Bool) -> some View {
        SettingRow(title) {
            Button(isSet ? "Remove" : "Set up") {
                if isSet { confirmRemove = kind } else { settingUp = kind }
            }
            .font(.system(size: 14, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(isSet ? Ink.dim : Color.accentColor)
        }
    }
}

// MARK: - Notifications

private struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    @State private var loginItem = false

    var body: some View {
        let on = model.data.security.notifications
        SettingsScreen(title: "Notifications") {
            SettingsGroup {
                SecurityToggle(title: "Notifications", key: \.notifications)
                if on {
                    RowDivider()
                    SecurityToggle(title: "Sound", key: \.notificationSound)
                }
            }
            if on && model.data.security.notificationSound {
                SettingsGroup("Message tone", footer: "The sound a new message makes, on a locked iPhone too.") {
                    ChoiceRows(values: MessageTone.allCases, selected: model.data.security.messageTone, label: \.label) { tone in
                        model.updateSecurity { $0.messageTone = tone }
                        tone.play()
                    }
                }
            }
            if on {
                SettingsGroup("Show in notifications",
                              footer: model.data.security.notificationContent == .hidden
                                  ? "Notifications only say \"New message\"."
                                  : "The system saves notification text in its own database, outside PULSHADE's encryption, and may keep it after PULSHADE clears the notification.") {
                    ChoiceRows(values: NotificationContent.allCases, selected: model.data.security.notificationContent,
                               label: \.label) { option in
                        model.updateSecurity { $0.notificationContent = option }
                    }
                }
            }
            #if os(iOS)
            if on {
                SettingsGroup("When locked",
                              footer: "Lets the relay wake this iPhone through Apple when mail arrives, so you hear about it while the phone is locked. The wake-up only says \"New message\". Apple learns that your iPhone was woken, and when, and the relay keeps its push token. Turned off, you only hear about messages while PULSHADE is open. Only your main identity is covered.") {
                    SecurityToggle(title: "Wake when locked", key: \.pushWake)
                }
            }
            #endif
            #if os(macOS)
            SettingsGroup("Mac", footer: "Keeps PULSHADE, and its menu bar icon, running from when you log in.") {
                SecurityToggle(title: "Menu bar icon", key: \.menuBarIcon)
                RowDivider()
                SettingRow("Open at login") {
                    Toggle("", isOn: Binding(get: { loginItem }, set: { on in
                        LoginItem.set(on)
                        loginItem = LoginItem.enabled
                    }))
                    .toggleStyle(GlowToggleStyle())
                }
            }
            #endif
        }
        #if os(macOS)
        .onAppear { loginItem = LoginItem.enabled }
        #endif
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsScreen(title: "Appearance") {
            SettingsGroup("Theme", footer: "Light, Sand, Dark and Midnight are clean and quiet. Pulse is deep violet glass with a slow glow behind it.") {
                let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Theme.all) { t in
                        ThemeCard(theme: t, selected: t.id == model.theme.id) { model.setTheme(t) }
                    }
                }
                .padding(14)
            }
        }
    }
}

// MARK: - Devices

private struct DevicesSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsScreen(title: "Devices") {
            SettingsGroup("Account",
                          footer: "Every device here is this one account: the same profile, @handle, contacts, chats and requests. "
                              + "To use a different account on a device, erase it in Account & Recovery and create a new one.") {
                HStack(spacing: 12) {
                    Avatar(image: model.data.profile.avatar, seed: model.fingerprint, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.data.profile.displayName).font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.text)
                        Text(model.data.profile.handle.map { "@\($0)" } ?? "Private profile")
                            .font(.system(size: 13))
                            .foregroundStyle(model.data.profile.handle == nil ? Ink.faint : theme.accent)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            LinkedDevicesCard()
        }
    }
}

// MARK: - Network

private struct NetworkSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmTorOff = false
    @State private var bridges = Bridges.current
    @State private var editingBridges = false
    /// Set when a change of bridges only applies from the next start.
    @State private var bridgesPending = false

    private var relayURL: URL? { URL(string: model.data.relay) }
    private var onion: Bool { relayURL.map(Tor.isOnion) ?? false }
    /// Only Tor reaches an onion relay, so the switch stays on until the relay has a direct address too.
    private var torLocked: Bool { onion && AppData.directRelay == nil }
    private var localRelay: Bool { relayURL?.host().map(Invite.isLocal) ?? false }

    var body: some View {
        SettingsScreen(title: "Network") {
            SettingsGroup("Connection", footer: connectionFooter) {
                SettingRow("Status") { LinkBadge() }
                RowDivider()
                SettingRow("Route") { Text(routeText).font(.system(size: 14)).foregroundStyle(Ink.dim) }
                if torLocked || model.data.security.tor {
                    RowDivider()
                    SettingRow("Tor") { TorProgress() }
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 0) {
                        RowDivider()
                        SettingRow("Relay answered") { Self.dim(Self.ago(model.lastRelayReached)) }
                        RowDivider()
                        SettingRow("Mail received") { Self.dim(Self.ago(model.lastMailReceived)) }
                        RowDivider()
                        SettingRow("Waiting to send") { Self.dim(waitingText) }
                    }
                }
                RowDivider()
                ActionRow(title: model.retryingRelay ? "Checking…" : "Check connection") { Task { await model.retryRelay() } }
            }
            SettingsGroup("Relay", footer: "The server that passes on your encrypted messages. It can't read them.") {
                SettingRow("Server") {
                    // The built-in relay's address isn't shown; a development build may be pointed at another.
                    Text(branded: model.data.relay == AppData.defaultRelay ? "PULSHADE" : relayURL?.host() ?? model.data.relay)
                        .font(.system(size: 14, design: .monospaced)).foregroundStyle(Ink.dim)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            SettingsGroup("Tor", footer: torFooter) {
                SettingRow("Connect over Tor") {
                    Toggle("", isOn: Binding(get: { torLocked || model.data.security.tor },
                                             set: { v in
                                                 // Switching it off asks first: it's a step down that can't be undone for what the relay sees.
                                                 if !v && model.data.security.tor { confirmTorOff = true; return }
                                                 withAnimation(.snappy) { model.updateSecurity { $0.tor = v } }
                                             }))
                        .toggleStyle(GlowToggleStyle())
                        .disabled(torLocked)
                }
            }
            if torLocked || model.data.security.tor {
                SettingsGroup("Bridges", footer: bridgesFooter) {
                    ChoiceRows(values: Bridges.choices, selected: bridges, label: \.title) { choice in
                        if choice == .custom { editingBridges = true; return }
                        bridges = choice
                        bridgesPending = !Bridges.choose(choice)
                    }
                    if bridges == .custom {
                        RowDivider()
                        Button { editingBridges = true } label: {
                            SettingRow("Edit bridges") {
                                Text("\(Bridges.usable(Bridges.customLines))").foregroundStyle(Ink.dim)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            SettingsGroup(footer: "The route your messages took to the relay, hop by hop, and what the relay can and can't see.") {
                MenuRow(page: .anonymity, symbol: "eye.slash.fill", color: .hex(0x64D2FF), title: "Anonymity Report",
                        value: nil)
            }
        }
        .sheet(isPresented: $editingBridges) {
            BridgeLinesSheet { lines in
                bridges = .custom
                bridgesPending = !Bridges.choose(.custom, custom: lines)
            }
        }
        .alert("Turn off Tor?", isPresented: $confirmTorOff) {
            Button("Turn off Tor", role: .destructive) { withAnimation(.snappy) { model.updateSecurity { $0.tor = false } } }
            Button("Keep Tor on", role: .cancel) {}
        } message: {
            Text(branded: torOffWarning)
        }
    }

    private var torOffWarning: String {
        let security = model.data.security
        let since = security.torFromStart ? "Since you created your account, PULSHADE has"
            : security.torSince.map { "Since \($0.formatted(date: .long, time: .omitted)), PULSHADE has" } ?? "PULSHADE has"
        return "Faster, but less private:\n\n"
            + "• The server sees your IP address and roughly where you are, and can tie your personas together by it. "
            + "It's built not to keep your address, but you'd be trusting the server and its host with it.\n"
            + "• Your internet provider sees you use PULSHADE.\n"
            + "• People you talk to never see your address, either way.\n\n"
            + "A VPN hides both, but the VPN company then sees them instead.\n\n"
            + since + " only reached the server over Tor. Once the server sees your address, that can't be undone. "
            + "Messages stay end-to-end encrypted either way."
    }

    private var bridgesFooter: String {
        let what: String
        switch bridges {
        case .auto: what = "Connects to Tor directly. If that doesn't get through within about 40 seconds, PULSHADE switches to Snowflake by itself and remembers it for next time."
            + (Bridges.autoUsesSnowflake ? " Using Snowflake now." : "")
        case .off: what = "For networks that block Tor or watch for it. PULSHADE connects to Tor directly when they're off."
        case .snowflake: what = "Snowflake disguises Tor as a video call, through volunteers. Works on most networks."
        case .custom: what = "Your own bridges, for example from bridges.torproject.org. Private bridges are the hardest for a network to block."
        }
        return bridgesPending ? what + " PULSHADE will use them from the next time it opens." : what
    }

    private var routeText: String {
        guard torLocked || model.data.security.tor else { return "Direct" }
        switch bridges {
        case .off: return "Tor"
        case .auto: return Bridges.autoUsesSnowflake ? "Tor via Snowflake" : "Tor"
        case .snowflake: return "Tor via Snowflake"
        case .custom: return "Tor via your bridges"
        }
    }

    private var connectionFooter: String {
        if model.link == .online { return "Everything is reaching the relay." }
        if !(torLocked || model.data.security.tor) { return "The relay isn't answering. Messages wait on this device and go out when it does." }
        return "Tor can take a minute or two to connect on a slow or restricted network, longer through a bridge. Messages wait on this device and go out as soon as it does."
    }

    private var waitingText: String {
        let (count, oldest) = model.waitingToSend
        guard count > 0 else { return "Nothing" }
        let age = oldest.map { " · oldest \(Self.ago($0, suffix: ""))" } ?? ""
        return "\(count)" + age
    }

    private static func dim(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(Ink.dim).monospacedDigit()
    }

    private static func ago(_ date: Date?, suffix: String = " ago") -> String {
        guard let date else { return "Not yet" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "Just now" }
        if seconds < 60 { return "\(seconds) s" + suffix }
        if seconds < 3600 { return "\(seconds / 60) min" + suffix }
        return "\(seconds / 3600) h" + suffix
    }

    private var torFooter: String {
        if torLocked { return "PULSHADE's server is only reachable over Tor, so Tor is always on." }
        if model.data.security.tor && localRelay {
            return "Tor can't reach a relay on your own network, so PULSHADE can't connect. Turn Tor off, or use the relay's onion address."
        }
        if !model.data.security.tor {
            return "Off: faster, but the server sees your IP address (or your VPN's) and can tie your personas together by it."
        }
        return "Hides your IP address from PULSHADE's server. Each persona, inbox and call goes over its own Tor circuit, so they can't be linked by address. Slower than a direct connection."
    }
}

/// Pasting bridge lines someone gave you.
private struct BridgeLinesSheet: View {
    @Environment(\.dismiss) private var dismiss
    var use: (String) -> Void
    @State private var lines = Bridges.customLines

    var body: some View {
        SheetBody(width: 520) {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeader(symbol: "point.3.connected.trianglepath.dotted", title: "Your bridges")
                Text("Paste bridge lines, one per line: webtunnel or Snowflake. Get them from bridges.torproject.org, or from someone who runs one.")
                    .font(.system(size: 14)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $lines)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 140)
                    .background(Ink.line.opacity(0.4), in: .rect(cornerRadius: 10))
                let usable = Bridges.usable(lines)
                Text(usable == 0 ? "No usable bridges yet" : usable == 1 ? "1 usable bridge" : "\(usable) usable bridges")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(usable == 0 ? .orange : Ink.dim)
                Button("Use these bridges") {
                    use(lines)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(usable == 0)
            }
        }
    }
}

/// How far Tor has got connecting.
private struct TorProgress: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let progress = Tor.progress
            Text(progress < 0 ? "Couldn't start" : progress >= 100 ? "Connected" : "Connecting… \(progress)%")
                .font(.system(size: 14)).foregroundStyle(progress < 0 ? Color.orange : Ink.dim)
                .monospacedDigit()
        }
    }
}

// MARK: - Account & Recovery

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var revealCode = false
    @State private var copiedKey = false

    var body: some View {
        SettingsScreen(title: "Account & Recovery") {
            SettingsGroup("Safety number", footer: "Compare it in person with someone to be sure no one is impersonating you.") {
                Text(model.fingerprint.prefix(32).uppercased().chunked(4).joined(separator: " "))
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(Ink.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                RowDivider()
                ActionRow(title: copiedKey ? "Copied" : "Copy public key") {
                    copyToClipboard(model.publicKey)
                    withAnimation(.snappy) { copiedKey = true }
                }
            }
            SettingsGroup("Recovery code",
                          footer: "Your recovery code is the only way back into this account. Keep it somewhere safe and offline.") {
                ActionRow(title: revealCode ? "Hide recovery code" : "Show recovery code") {
                    withAnimation(.snappy) { revealCode.toggle() }
                }
                if revealCode {
                    RowDivider()
                    RecoveryCodeGrid(code: model.recoveryCode)
                        .padding(16)
                        .transition(.opacity)
                }
            }
        }
    }
}

#if os(macOS)
/// The Mac app's version, and its updates from the relay.
private struct UpdateSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    private var updater: Updater { Updater.shared }

    var body: some View {
        SettingsScreen(title: "Updates") {
            SettingsGroup(footer: footer) {
                SettingRow("Version") {
                    Text("\(Updater.version) (\(String(Updater.build)))").font(.system(size: 14)).foregroundStyle(Ink.faint)
                }
                RowDivider()
                SettingRow("Status") {
                    Text(status).font(.system(size: 14)).foregroundStyle(updater.ready ? theme.accent : Ink.faint)
                }
                if case .downloading = updater.phase {
                    RowDivider()
                    ProgressView().progressViewStyle(.linear).tint(theme.accent).padding(16)
                }
            }
            if case .available(let release) = updater.phase {
                SettingsGroup("What's new in \(release.version)") {
                    Text(release.notes.isEmpty ? "Fixes and improvements." : release.notes)
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    RowDivider()
                    ActionRow(title: "Install and Restart") {
                        guard let client = model.client(nil, lane: "update") else { return }
                        Task { await updater.install(client) }
                    }
                }
            }
            SettingsGroup {
                ActionRow(title: "Check for Updates") {
                    guard let client = model.client(nil, lane: "update") else { return }
                    Task { await updater.check(client) }
                }
                .disabled(busy)
            }
        }
    }

    private var busy: Bool {
        switch updater.phase {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    private var status: String {
        switch updater.phase {
        case .idle: "Not checked yet"
        case .checking: "Checking…"
        case .upToDate: "Up to date"
        case .available(let r): "Version \(r.version) is ready"
        case .downloading: "Downloading…"
        case .installing: "Installing…"
        case .failed: "Couldn't update"
        }
    }

    private var footer: String {
        if case .failed(let why) = updater.phase { return why }
        let checked = updater.lastChecked.map { "Last checked \($0.formatted(date: .omitted, time: .shortened)). " } ?? ""
        return checked + "Updates come from your relay over the same private connection as your messages, "
            + "and are only installed if they're signed by PULSHADE."
    }
}
#endif

/// A small picture of a theme: its background, a message each way and its accent, drawn in its own colours.
private struct ThemeCard: View {
    var theme: Theme
    var selected: Bool
    var action: () -> Void
    @Environment(\.theme) private var current
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                preview
                    .frame(height: 118)
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(selected ? AnyShapeStyle(current.accent) : AnyShapeStyle(Ink.line), lineWidth: selected ? 2 : 1))
                    .shadow(color: selected ? current.accent.opacity(0.3) : .clear, radius: 10)
                    .scaleEffect(hover ? 1.02 : 1)
                HStack(spacing: 5) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? AnyShapeStyle(current.accent) : AnyShapeStyle(Ink.faint))
                    Text(theme.name).font(.system(size: 13, weight: .medium)).foregroundStyle(selected ? Ink.text : Ink.dim)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.25)) { hover = h } }
        .animation(.snappy, value: selected)
        .accessibilityLabel("\(theme.name) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var preview: some View {
        let ink = theme.ink
        return ZStack {
            ink.void
            if theme.glow > 0 {
                Circle().fill(theme.colors[0].opacity(0.55)).frame(width: 90).blur(radius: 30).offset(x: -34, y: -40)
                Circle().fill(theme.colors[1].opacity(0.4)).frame(width: 80).blur(radius: 30).offset(x: 40, y: 44)
            }
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(ink.text.opacity(0.7)).frame(width: 34, height: 5)
                RoundedRectangle(cornerRadius: 7).fill(ink.raised)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ink.line))
                    .frame(width: 52, height: 18)
                RoundedRectangle(cornerRadius: 7).fill(theme.gradient)
                    .frame(width: 60, height: 18)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                RoundedRectangle(cornerRadius: 7).fill(ink.raised)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ink.line))
                    .frame(width: 40, height: 18)
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 6).fill(ink.surface)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ink.line))
                    .frame(height: 14)
            }
            .padding(10)
        }
    }
}

/// A glowing pill switch that matches the theme.
struct GlowToggleStyle: ToggleStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Ink.raised))
                .overlay(Capsule().strokeBorder(configuration.isOn ? .clear : Ink.line))
                .frame(width: 46, height: 26)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 20, height: 20).padding(3)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                }
                .shadow(color: configuration.isOn ? theme.accent.opacity(0.45) : .clear, radius: 8)
                .animation(.snappy(duration: 0.3), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

enum DisguiseKind: String, Identifiable {
    case decoy, panic
    var id: String { rawValue }
}

/// Sets a decoy or panic passcode, with a plain explanation of what it does.
private struct DisguiseSetup: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let kind: DisguiseKind
    @State private var style = LockStyle.passcode
    @State private var passcode = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var problem: String?
    @State private var shake = 0

    var body: some View {
        SheetBody(width: 420) {
            VStack(spacing: 18) {
                SheetHeader(symbol: kind == .decoy ? "theatermasks.fill" : "flame.circle.fill",
                            title: kind == .decoy ? "Decoy passcode" : "Panic passcode")
                Image(systemName: kind == .decoy ? "theatermasks" : "flame")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(kind == .decoy ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Color.orange))
                    .symbolEffect(.pulse)
                Text(branded: kind == .decoy
                     ? "Opens an empty PULSHADE with your name and theme. Your real chats stay hidden."
                     : "Silently erases your real identity and chats, then opens an empty PULSHADE. This can't be undone.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.dim)
                    .multilineTextAlignment(.center)
                    .frame(width: 320)
                LockStylePicker(style: $style, options: LockStyle.forDisguise)
                    .onChange(of: style) { _, _ in passcode = ""; confirm = "" }
                if let length = style.length {
                    PinSetup(length: length, passcode: $passcode, confirm: $confirm, onDone: save)
                } else {
                    PasscodeField(placeholder: "Passcode", text: $passcode, onSubmit: save)
                    PasscodeField(placeholder: "Again", text: $confirm, onSubmit: save)
                        .modifier(Shake(trigger: shake))
                }
                if let problem {
                    Text(branded: problem).font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                }
                Button(action: save) {
                    if working { ProgressView().controlSize(.small).tint(Ink.onAccent) } else { Image(systemName: "checkmark") }
                }
                .buttonStyle(GlowButtonStyle(size: 48))
                .disabled(working)
            }
        }
    }

    private func save() {
        guard style.accepts(passcode), passcode == confirm else {
            problem = style.accepts(passcode) ? "Entries don't match" : style.problem(for: passcode)
            withAnimation(.default) { shake += 1 }
            return
        }
        working = true
        Task {
            do {
                if kind == .decoy { try await model.setDecoy(passcode: passcode) }
                else { try await model.setPanic(passcode: passcode) }
                dismiss()
            } catch AppModel.PasscodeSetupError.inUse {
                problem = "That passcode is already used"
                withAnimation(.default) { shake += 1 }
            } catch {
                problem = "Couldn't save it"
            }
            working = false
        }
    }
}

// MARK: - Log out & erase

/// Takes the account off this device. On your only device, the recovery code is asked for first.
