import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// The pages Settings opens, each from a row on the main list.
enum SettingsPage: String, Hashable {
    case profile, invite, handles, pinned, collectibles, pets, privacy, privacyLock, privacyMessages, privacyPasscodes, privacyBackup, blocked, notifications, appearance, devices, network, networkWaiting, anonymity, account, updates
}

/// Settings, laid out like a phone's own: your profile on top, then a short list of rows,
/// each opening its own page.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var path: [SettingsPage] = []
    /// The @handle at the top says "Copied" for a moment after it's tapped.
    @State private var copiedHandle = false
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
                            MenuRow(page: .invite, symbol: "qrcode", color: .hex(0x30D158), title: "Invite",
                                    value: "QR code or link")
                            RowDivider(inset: 54)
                            MenuRow(page: .collectibles, symbol: "crown.fill", color: .hex(0xE5383B), title: "Collectibles",
                                    value: model.activeProfile.badge?.kind?.name)
                            RowDivider(inset: 54)
                            MenuRow(page: .pets, symbol: "pawprint.fill", color: .hex(0xFF9F0A), title: "Pets")
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
                    case .invite: PeopleView(openChat: { model.requestedConversation = $0 }, inSettings: true)
                    case .handles: HandleSettings()
                    case .pinned: PinnedSettings()
                    case .collectibles: CollectiblesView(inSettings: true, pets: false)
                    case .pets: CollectiblesView(inSettings: true, pets: true)
                    case .privacy: PrivacySettings()
                    case .privacyLock: LockSettings()
                    case .privacyMessages: MessagePrivacySettings()
                    case .privacyPasscodes: PasscodeSettings()
                    case .privacyBackup: BackupSettings()
                    case .blocked: BlockedSettings()
                    case .notifications: NotificationSettings()
                    case .appearance: AppearanceSettings()
                    case .devices: DevicesSettings()
                    case .network: NetworkSettings()
                    case .networkWaiting: WaitingToSendView()
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
        if Tor.isOnion(relay) && AppData.directRelay == nil { return "Tor" }
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
            // Tap the @handle to copy it.
            Button {
                guard let handle = model.activeProfile.handle else { return }
                copyToClipboard("@\(handle)")
                Haptics.tick()
                withAnimation(.snappy) { copiedHandle = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.snappy) { copiedHandle = false }
                }
            } label: {
                Text(copiedHandle ? "Copied" : (model.activeProfile.handle.map { "@\($0)" } ?? "Private profile"))
                    .font(.system(size: 14))
                    .foregroundStyle(model.activeProfile.handle == nil ? Ink.dim : theme.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.activeProfile.handle == nil)
            .accessibilityLabel(model.activeProfile.handle.map { "@\($0)" } ?? "Private profile")
            .accessibilityHint(model.activeProfile.handle == nil ? "" : "Copies your username")
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
            Toggle(title, isOn: Binding(get: { model.data.security[keyPath: key] },
                                     set: { v in withAnimation(.snappy) { model.updateSecurity { $0[keyPath: key] = v } } }))
                .toggleStyle(GlowToggleStyle())
        }
    }
}

/// A whole-row button, red when it destroys something.
struct ActionRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    var title: String
    var destructive = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(destructive ? Color.red : theme.accent)
                .opacity(enabled ? 1 : 0.4)
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

/// A row that opens a small menu of choices, so a short list takes one line instead of one row per choice.
private struct MenuChoiceRow<Value: Hashable>: View {
    var title: String
    var values: [Value]
    var selected: Value
    var label: (Value) -> String
    var choose: (Value) -> Void

    var body: some View {
        SettingRow(title) {
            Menu {
                ForEach(values, id: \.self) { v in
                    Button { withAnimation(.snappy) { choose(v) } } label: {
                        if v == selected { Label(label(v), systemImage: "checkmark") } else { Text(label(v)) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(label(selected)).font(.system(size: 14)).foregroundStyle(Ink.dim)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.faint)
                }
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        }
    }
}

/// Long explanations stay out of the way: a small line that opens the full text when tapped.
private struct LearnMore: View {
    var title = "How this works"
    var text: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle").font(.system(size: 12))
                    Text(title).font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
                }
                .foregroundStyle(Ink.dim)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open {
                Text(branded: text)
                    .font(.system(size: 12)).foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, -14)
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
                VStack(spacing: 20) { content }
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
    @State private var bio = ""
    @State private var burningPersona = false

    private var pinnedCount: Int { (model.activeProfile.links ?? []).count + (model.activeProfile.notes ?? []).count }
    private static let bioLimit = 120

    private func hint(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
    }

    /// A labelled row: the label on the left, the field filling the rest.
    private func fieldRow<Field: View>(_ label: String, top: Bool = false, @ViewBuilder field: () -> Field) -> some View {
        HStack(alignment: top ? .top : .center, spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ink.faint)
                .frame(width: 70, alignment: .leading)
                .padding(.top, top ? 3 : 0)
            field()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, top ? 14 : 0)
        .frame(minHeight: 50)
    }

    /// Your profile as people you chat with see it, changing as you edit, with the colour picker built in.
    private var hero: some View {
        let tint = model.signature("me")
        return VStack(spacing: 8) {
            VStack(spacing: -48) {
                BannerPicker(image: Binding(get: { model.activeProfile.banner },
                                            set: { v in model.updateProfile { $0.banner = v } }),
                             seed: model.fingerprint)
                AvatarPicker(image: Binding(get: { model.activeProfile.avatar },
                                            set: { v in model.updateProfile { $0.avatar = v } }),
                             seed: model.fingerprint, size: 96, ring: tint, ringGap: Ink.base)
            }
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(Signature.colors.indices, id: \.self) { i in
                        let on = tint == Signature.colors[i]
                        Button { withAnimation(.snappy) { model.updateProfile { $0.color = i } } } label: {
                            Circle().fill(Signature.colors[i])
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Ink.text, lineWidth: on ? 2 : 0).padding(-4))
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Signature colour \(i + 1)")
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .glass(14)
    }

    /// Which persona this page is editing, with a tap to switch: every persona has its own profile, handles and pins.
    private var personaBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                personaChip(nil, name: model.data.profile.displayName, avatar: model.data.profile.avatar,
                            seed: model.identity?.fingerprint ?? "me", caption: "Main")
                ForEach(model.personas) { persona in
                    personaChip(persona.id, name: persona.profile.displayName, avatar: persona.profile.avatar,
                                seed: persona.id.uuidString, caption: "Persona")
                }
            }
            .padding(.horizontal, 2).padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }

    private func personaChip(_ id: UUID?, name: String, avatar: Data?, seed: String, caption: String) -> some View {
        let on = model.activePersona == id
        return Button { model.switchPersona(id) } label: {
            HStack(spacing: 8) {
                Avatar(image: avatar, seed: seed, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(on ? Ink.text : Ink.dim).lineLimit(1)
                    Text(caption).font(.system(size: 10, weight: .medium)).foregroundStyle(Ink.faint)
                }
            }
            .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
            .background(on ? theme.accent.opacity(0.16) : Ink.surface, in: .capsule)
            .overlay(Capsule().strokeBorder(on ? theme.accent.opacity(0.6) : Ink.line))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(caption): \(name)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func sectionNote(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Ink.faint)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
    }

    var body: some View {
        SettingsScreen(title: "Profile") {
            if !model.personas.isEmpty {
                personaBar
            }
            VStack(spacing: 6) {
                hero
                sectionNote("Tap your picture or banner to change it.")
            }
            SettingsGroup("About you", footer: "Only people you chat with see these.") {
                fieldRow("Name") {
                    TextField("", text: $name, prompt: Text("Your name").foregroundStyle(Ink.faint))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.text)
                        .onChange(of: name) { model.updateProfile { $0.name = name.trimmingCharacters(in: .whitespaces) } }
                }
                RowDivider()
                fieldRow("Bio", top: true) {
                    VStack(alignment: .trailing, spacing: 2) {
                        TextField("", text: $bio, prompt: Text("A line about you").foregroundStyle(Ink.faint), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
                            .foregroundStyle(Ink.text)
                            .lineLimit(1...3)
                            .onChange(of: bio) {
                                if bio.count > Self.bioLimit { bio = String(bio.prefix(Self.bioLimit)) }
                                model.updateProfile { $0.bio = bio }
                            }
                        Text("\(bio.count) / \(Self.bioLimit)")
                            .font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(bio.count >= Self.bioLimit ? Color.orange : Ink.faint)
                    }
                }
            }
            SettingsGroup {
                MenuRow(page: .handles, symbol: "at", color: .hex(0x3D8BFF), title: "Handles",
                        value: model.activeProfile.handle.map { "@\($0)" } ?? "Private")
                RowDivider(inset: 54)
                MenuRow(page: .pinned, symbol: "pin.fill", color: .hex(0xFF9F0A), title: "Pinned",
                        value: pinnedCount == 0 ? nil : "\(pinnedCount)")
            }
            if let id = model.activePersona {
                SettingsGroup(footer: "Burning this persona deletes it for good.") {
                    ActionRow(title: "Burn persona", destructive: true) { burningPersona = true }
                }
                .sheet(isPresented: $burningPersona) { PersonaBurnSheet(persona: id) }
            }
        }
        .onChange(of: model.activePersona, initial: true) {
            name = model.activeProfile.name
            bio = String((model.activeProfile.bio ?? "").prefix(Self.bioLimit))
        }
    }

}

// MARK: - Handles

/// The page for a persona's handles on its own (the same editor is on the Profile page).
private struct HandleSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsScreen(title: "Handles", back: "Profile") {
            HandlesEditor()
            if model.activeProfile.handle != nil {
                SettingsGroup {
                    ActionRow(title: "Stop being discoverable", destructive: true) { Task { await model.unpublishProfile() } }
                }
            }
        }
    }
}

private struct PinnedSettings: View {
    var body: some View {
        SettingsScreen(title: "Pinned", back: "Profile") { PinnedEditor() }
    }
}

/// Every handle tied to the persona you're editing: up to three, each with a switch. A handle that's on is in the
/// directory, leads to this profile and takes chat requests, and all that are on work at once. One that's off is
/// kept for this persona for three months so nobody else can take it, and can be turned back on or let go of early.
/// The main one is the one shown on the profile. A handle belongs to the persona that claimed it.
struct HandlesEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var held: [AppModel.HeldHandle] = []
    @State private var loading = true
    @State private var working: String?
    @State private var problem: String?
    @State private var lettingGo: AppModel.HeldHandle?
    @State private var draft = ""
    @State private var copied: String?

    private var active: [String] { model.activeProfile.activeHandles }
    private var off: [AppModel.HeldHandle] { held.filter { !active.contains($0.handle) } }
    private var used: Int { active.count + off.count }

    var body: some View {
        SettingsGroup("Handles", footer: "Handles that are on take chat requests. Up to \(AppModel.maxHandles) per persona; one you turn off stays yours for 3 months.") {
            if active.isEmpty && off.isEmpty && !loading {
                SettingRow("No public handle", symbol: "at") { Text("Private").font(.system(size: 13)).foregroundStyle(Ink.faint) }
                RowDivider()
            }
            ForEach(active, id: \.self) { handle in
                activeRow(handle)
                RowDivider()
            }
            ForEach(off) { kept in
                offRow(kept)
                RowDivider()
            }
            if loading {
                SettingRow("Checking with the relay…") { ProgressView().controlSize(.small) }
            } else if used < AppModel.maxHandles {
                HStack(spacing: 4) {
                    Text("@").font(.system(size: 15)).foregroundStyle(Ink.faint)
                    TextField("", text: $draft, prompt: Text(active.isEmpty ? "username" : "add another").foregroundStyle(Ink.faint))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.text)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .onSubmit { turnOn(draft) }
                    if working == draft.lowercased(), !draft.isEmpty { ProgressView().controlSize(.small) }
                    Button("Claim") { turnOn(draft) }
                        .font(.system(size: 14, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(draft.isEmpty ? Ink.faint : theme.accent)
                        .disabled(draft.isEmpty || working != nil)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
            } else {
                SettingRow("All \(AppModel.maxHandles) handles used") { EmptyView() }
            }
            if let problem {
                Text(problem)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
        .task(id: model.activePersona) { await load() }
        .confirmationDialog(lettingGo.map { "Let go of @\($0.handle)?" } ?? "", isPresented: Binding(get: { lettingGo != nil }, set: { if !$0 { lettingGo = nil } }),
                            titleVisibility: .visible, presenting: lettingGo) { kept in
            Button("Let go", role: .destructive) { letGo(kept) }
        } message: { _ in
            Text("Frees a spot. Nobody can claim it for 30 days, you included. Shared links stop working.")
        }
    }

    /// A handle in use: its name, whether it's the main one, a copy-link button and its switch.
    private func activeRow(_ handle: String) -> some View {
        let main = handle == model.activeProfile.handle
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("@\(handle)").font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.text).lineLimit(1)
                    if main && active.count > 1 {
                        Text("Main").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.onAccent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(theme.accent, in: .capsule)
                    }
                }
                if main || active.count == 1 {
                    Text(active.count > 1 ? "Shown on your profile" : "On · anyone can find you by it")
                        .font(.system(size: 12)).foregroundStyle(Ink.faint)
                } else {
                    Button("Make main") { withAnimation(.snappy) { model.makeMainHandle(handle) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accent)
                }
            }
            Spacer(minLength: 8)
            if let me = model.me(model.activePersona) {
                // Carries a check of your key, so it can never open someone else's profile.
                Button {
                    copyToClipboard(DirectoryProfile.link(handle, key: me.card.signing))
                    withAnimation(.snappy) { copied = handle }
                } label: { Image(systemName: copied == handle ? "checkmark" : "link") }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .help("Copy profile link")
                    .accessibilityLabel(copied == handle ? "Link copied" : "Copy the link to @\(handle)")
            }
            if working == handle { ProgressView().controlSize(.small) }
            Toggle("", isOn: Binding(get: { true }, set: { on in if !on { turnOff(handle) } }))
                .labelsHidden()
                .toggleStyle(GlowToggleStyle())
                .disabled(working != nil)
                .accessibilityLabel("@\(handle) in use")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
    }

    /// A handle that's off: kept for this persona until a date, with a switch to use it again and a way to let it go.
    private func offRow(_ kept: AppModel.HeldHandle) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("@\(kept.handle)").font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.dim).lineLimit(1)
                Text("Off · yours until \(kept.until.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 12)).foregroundStyle(Ink.faint)
            }
            Spacer(minLength: 8)
            Button { lettingGo = kept } label: { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle(size: 28))
                .disabled(working != nil)
                .help("Let go of it for good")
                .accessibilityLabel("Let go of @\(kept.handle)")
            if working == kept.handle { ProgressView().controlSize(.small) }
            Toggle("", isOn: Binding(get: { false }, set: { on in if on { turnOn(kept.handle) } }))
                .labelsHidden()
                .toggleStyle(GlowToggleStyle())
                .disabled(working != nil)
                .accessibilityLabel("@\(kept.handle) in use")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
    }

    private func load() async {
        loading = true
        do { held = try await model.heldHandles(); problem = nil } catch { problem = "Can't reach the relay to check which handles are kept for you" }
        loading = false
    }

    private func turnOn(_ raw: String) {
        let handle = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !handle.isEmpty, working == nil else { return }
        working = handle
        problem = nil
        Task {
            do {
                try await model.publishProfile(handle: handle)
                draft = ""
                held.removeAll { $0.handle == handle }
            } catch AppModel.DirectoryError.taken {
                problem = "@\(handle) is taken"
            } catch AppModel.DirectoryError.reserved {
                problem = "@\(handle) is reserved"
            } catch AppModel.DirectoryError.held {
                problem = "@\(handle) was let go of recently, so nobody can claim it yet. It frees up within 3 months"
            } catch AppModel.DirectoryError.full {
                problem = "You've used your \(AppModel.maxHandles) handles. One you let go of frees up 3 months later"
            } catch AppModel.DirectoryError.invalidHandle {
                problem = "Use 3–24 letters, numbers or _"
            } catch AppModel.DirectoryError.unreachable {
                problem = "Can't reach the relay"
            } catch {
                problem = "Couldn't claim it"
            }
            working = nil
        }
    }

    private func turnOff(_ handle: String) {
        guard working == nil else { return }
        working = handle
        problem = nil
        Task {
            await model.stopUsingHandle(handle)
            await load()
            working = nil
        }
    }

    private func letGo(_ kept: AppModel.HeldHandle) {
        guard working == nil else { return }
        working = kept.handle
        Task {
            do {
                try await model.letGo(of: kept.handle)
                held.removeAll { $0.handle == kept.handle }
            } catch { problem = "Couldn't let go of @\(kept.handle). Try again when the relay is in reach" }
            working = nil
        }
    }
}

// MARK: - Privacy & Security

private struct PrivacySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsScreen(title: "Privacy & Security") {
            SettingsGroup {
                MenuRow(page: .privacyLock, symbol: "lock.fill", color: .hex(0x8E8E93), title: "Lock & screen",
                        value: model.data.security.autoLockMinutes == 0 ? "No auto-lock" : "\(model.data.security.autoLockMinutes) min")
                RowDivider(inset: 54)
                MenuRow(page: .privacyMessages, symbol: "bubble.left.and.bubble.right.fill", color: .hex(0x3D8BFF), title: "What others see")
                RowDivider(inset: 54)
                MenuRow(page: .privacyPasscodes, symbol: "theatermasks.fill", color: .hex(0xFF9F0A), title: "Decoy & panic passcodes",
                        value: model.hasDecoy || model.hasPanic ? "On" : "Off")
                RowDivider(inset: 54)
                MenuRow(page: .blocked, symbol: "hand.raised.fill", color: .hex(0xFF453A), title: "Blocked",
                        value: model.data.blocked.isEmpty ? "Nobody" : "\(model.data.blocked.count)")
            }
            SettingsGroup {
                MenuRow(page: .privacyBackup, symbol: "externaldrive.fill.badge.checkmark", color: .hex(0x30D158), title: "Backup",
                        value: model.data.security.keepBackup ? "On" : "Off")
            }
        }
    }
}

private struct LockSettings: View {
    @Environment(AppModel.self) private var model
    @State private var biometrics = false

    var body: some View {
        SettingsScreen(title: "Lock & screen", back: "Privacy") {
            SettingsGroup("Lock", footer: model.biometricsBlocked
                          ? "\(Vault.biometryName) is off while a decoy or panic passcode is set."
                          : "Locks PULSHADE when you leave it, so a borrowed or stolen phone shows nothing.") {
                if Vault.biometricsAvailable {
                    SettingRow("Unlock with \(Vault.biometryName)") {
                        Toggle("Unlock with \(Vault.biometryName)", isOn: Binding(get: { biometrics }, set: { on in
                            model.setBiometrics(on)
                            withAnimation(.snappy) { biometrics = model.biometricsOn }
                        }))
                        .toggleStyle(GlowToggleStyle())
                        .disabled(model.biometricsBlocked)
                    }
                    RowDivider()
                }
                MenuChoiceRow(title: "Auto-lock", values: [1, 5, 15, 0], selected: model.data.security.autoLockMinutes,
                              label: { $0 == 0 ? "Never" : $0 == 1 ? "1 minute" : "\($0) minutes" }) { m in
                    model.updateSecurity { $0.autoLockMinutes = m }
                }
            }
            SettingsGroup("While locked", footer: model.biometricsBlocked
                          ? "Not available while a decoy or panic passcode is set."
                          : "Auto-lock keeps PULSHADE running so messages still arrive. Off closes everything until you unlock. Pressing Lock always closes everything.") {
                SecurityToggle(title: "Keep receiving while locked", key: \.keepReceivingLocked)
                    .disabled(model.biometricsBlocked)
            }
            SettingsGroup("Screen", footer: "Keeps chats out of screenshots, screen recordings and the app switcher.") {
                SecurityToggle(title: Platform.isPhone ? "Hide in app switcher" : "Blur when in background", key: \.blurWhenInactive)
                RowDivider()
                SecurityToggle(title: "Block screenshots & recording", key: \.blockCapture)
            }
        }
        .onAppear { biometrics = model.biometricsOn }
    }
}

private struct MessagePrivacySettings: View {
    var body: some View {
        SettingsScreen(title: "What others see", back: "Privacy") {
            SettingsGroup("Messages", footer: "Turn one off and you stop seeing theirs too.") {
                SecurityToggle(title: "Link previews", key: \.linkPreviews)
                RowDivider()
                SecurityToggle(title: "Delivery receipts", key: \.deliveryReceipts)
                RowDivider()
                SecurityToggle(title: "Read receipts", key: \.readReceipts)
                RowDivider()
                SecurityToggle(title: "Typing indicators", key: \.typingIndicators)
            }
            SettingsGroup("Presence", footer: "Off by default. Only contacts who show theirs see yours.") {
                SecurityToggle(title: "Online status", key: \.onlineStatus)
            }
            SettingsGroup("Forwarding", footer: "Off, people can't forward or copy what you send from now on. Forwarded messages never say who wrote them. Nothing can stop a screenshot.") {
                SecurityToggle(title: "Let people forward my messages", key: \.allowForwarding)
            }
            LearnMore(title: "Link previews",
                      text: "Fetched over Tor, so the site never sees your IP (with Tor off, it does).")
        }
    }
}

private struct PasscodeSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var settingUp: DisguiseKind?
    @State private var confirmRemove: DisguiseKind?

    var body: some View {
        SettingsScreen(title: "Decoy & panic", back: "Privacy") {
            SettingsGroup("Passcodes", footer: "Decoy opens an empty PULSHADE. Panic erases everything, then does the same. \(Vault.biometryName) is off while either is set.") {
                disguiseRow(.decoy, title: "Decoy passcode", isSet: model.hasDecoy)
                RowDivider()
                disguiseRow(.panic, title: "Panic passcode", isSet: model.hasPanic)
            }
        }
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
            .foregroundStyle(isSet ? Ink.dim : theme.accent)
        }
    }
}

private struct BackupSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsScreen(title: "Backup", back: "Privacy") {
            SettingsGroup("Backup", footer: "A sealed copy of your profile, contacts, groups, settings and chat keys (never messages) on the relay. Only your recovery code opens it. Off erases it.") {
                SettingRow("Keep a sealed backup") {
                    Toggle("Keep a sealed backup", isOn: Binding(get: { model.data.security.keepBackup },
                                             set: { v in withAnimation(.snappy) { model.setKeepBackup(v) } }))
                        .toggleStyle(GlowToggleStyle())
                }
                if model.data.security.keepBackup {
                    RowDivider()
                    SettingRow("Last saved") {
                        Text(model.backupStatus).font(.system(size: 14)).foregroundStyle(Ink.faint)
                    }
                }
            }
        }
    }
}

// MARK: - Blocked

private struct BlockedSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsScreen(title: "Blocked", back: "Privacy") {
            SettingsGroup(footer: "Blocked people's messages are dropped without telling them. Your old chat doesn't come back on unblock.") {
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
        }
    }
}

// MARK: - Notifications

private struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    @State private var loginItem = false

    var body: some View {
        let on = model.data.security.notifications
        let security = model.data.security
        SettingsScreen(title: "Notifications") {
            SettingsGroup(footer: on && security.notificationContent != .hidden
                          ? "The system keeps notification text outside PULSHADE's encryption." : nil) {
                SecurityToggle(title: "Notifications", key: \.notifications)
                if on {
                    RowDivider()
                    MenuChoiceRow(title: "Show in notifications", values: Array(NotificationContent.allCases),
                                  selected: security.notificationContent, label: \.label) { option in
                        model.updateSecurity { $0.notificationContent = option }
                    }
                    RowDivider()
                    SecurityToggle(title: "Sound", key: \.notificationSound)
                    if security.notificationSound {
                        RowDivider()
                        MenuChoiceRow(title: "Message tone", values: Array(MessageTone.allCases),
                                      selected: security.messageTone, label: \.label) { tone in
                            model.updateSecurity { $0.messageTone = tone }
                            tone.play()
                        }
                    }
                    #if os(iOS)
                    RowDivider()
                    SecurityToggle(title: "Wake when locked", key: \.pushWake)
                    if security.pushWake {
                        RowDivider()
                        SecurityToggle(title: "Friend request alerts when locked", key: \.pushRequests)
                        RowDivider()
                        SecurityToggle(title: "Collect messages when locked", key: \.lockedDeliveryChosen)
                    }
                    #endif
                }
            }
            #if os(iOS)
            if on, security.pushWake, !model.pushStatus.isEmpty {
                // Where it stands: registered with how many mailboxes, or why not. The count goes up by your request
                // mailboxes when friend request alerts are on.
                Text(model.pushStatus)
                    .font(.system(size: 12)).foregroundStyle(Ink.faint)
                    .padding(.horizontal, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if on, security.pushWake, security.tor {
                Text("Collecting while locked is off while Tor is on: the helper can't use Tor, so it would connect directly and the server would see this phone's address.")
                    .font(.system(size: 12)).foregroundStyle(Ink.faint)
                    .padding(.horizontal, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if on {
                LearnMore(title: "Waking a locked iPhone",
                          text: "Apple wakes your iPhone with a note that only says \"New message\". Apple learns when, and the relay keeps your push token. Off, you only hear about messages while PULSHADE is open. Collect messages when locked lets a small helper take short messages off the server into a sealed inbox on this iPhone, without opening them, so they don't wait on the server until you open PULSHADE. Photos and videos still wait there. With delivery receipts on, friends also get their second tick. It uses keys kept on this iPhone after you first unlock it.")
            }
            #endif
            #if os(macOS)
            SettingsGroup("Mac") {
                SecurityToggle(title: "Menu bar icon", key: \.menuBarIcon)
                RowDivider()
                SettingRow("Open at login") {
                    Toggle("Open at login", isOn: Binding(get: { loginItem }, set: { on in
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
            SettingsGroup("Theme", footer: "Graphite is a softer, grayer dark with a lime accent.") {
                let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Theme.all) { t in
                        ThemeCard(theme: t, selected: t.id == model.theme.id) { model.setTheme(t) }
                    }
                }
                .padding(14)
            }
            ChatBackgroundSettings()
        }
    }
}

/// The built-in chat backgrounds, the theme's own marked, and a photo of your own you can move, zoom, fade and blur.
private struct ChatBackgroundSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: EditingPhoto?
    /// The pattern size while the slider is held, saved when it's let go.
    @State private var patternSize: Double?

    private var current: ChatBackground { model.data.chatBackground }

    var body: some View {
        let theme = model.theme
        let shown = current.shown(in: theme)
        SettingsGroup("Chat background", footer: "Your photo is kept sealed on this device and isn't part of your backup.") {
            let columns = [GridItem(.adaptive(minimum: 92), spacing: 12)]
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(ChatBackground.Style.builtIn) { style in
                    BackdropTile(background: with(style), theme: theme, label: style.name,
                                 note: style == theme.backdrop ? "Default" : nil, selected: shown == style) {
                        model.setChatBackground(with(style))
                    }
                }
                ImagePickButton(maxSide: ChatBackground.photoSide, picked: { data in
                    var next = current
                    next.photo = data
                    next.zoom = 1
                    next.focusX = 0.5
                    next.focusY = 0.5
                    next.blur = 0
                    next.style = .photo
                    editing = EditingPhoto(background: next)
                }) {
                    photoTile(theme: theme, selected: shown == .photo)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            if shown == .dots || shown == .waves {
                RowDivider()
                SettingRow("Pattern size") {
                    Slider(value: Binding(get: { patternSize ?? current.patternSize }, set: { patternSize = $0 }),
                           in: ChatBackground.patternRange) { held in
                        guard !held, let size = patternSize else { return }
                        var next = current
                        next.patternSize = size
                        model.setChatBackground(next)
                        patternSize = nil
                    }
                    .tint(theme.accent)
                    .frame(maxWidth: 200)
                }
            }
            if current.photo != nil {
                RowDivider()
                ActionRow(title: shown == .photo ? "Move and scale photo" : "Use your photo") {
                    var next = current
                    next.style = .photo
                    if shown == .photo { editing = EditingPhoto(background: next) } else { model.setChatBackground(next) }
                }
                RowDivider()
                ActionRow(title: "Remove photo", destructive: true) {
                    var next = current
                    next.photo = nil
                    if next.style == .photo { next.style = .theme }
                    model.setChatBackground(next)
                }
            }
        }
        .sheet(item: $editing) { item in
            PhotoBackdropEditor(start: item.background, theme: theme) { result in
                editing = nil
                if let result { model.setChatBackground(result) }
            }
        }
    }

    /// The current settings with another look picked, for its tile and when it's chosen.
    private func with(_ style: ChatBackground.Style) -> ChatBackground {
        var next = current
        next.style = style
        if let patternSize { next.patternSize = patternSize }
        return next
    }

    private func photoTile(theme: Theme, selected: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack {
                if current.photo != nil {
                    ChatBackdrop(background: with(.photo), theme: theme)
                } else {
                    theme.ink.raised
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(theme.accent)
                }
            }
            .frame(height: 128)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Ink.line),
                              style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: current.photo == nil ? [5, 4] : [])))
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Ink.faint))
                    Text("Your photo").font(.system(size: 13, weight: .medium)).foregroundStyle(selected ? Ink.text : Ink.dim)
                }
                Text(current.photo == nil ? "Choose…" : "Change…").font(.system(size: 11)).foregroundStyle(Ink.faint)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .accessibilityLabel(current.photo == nil ? "Choose your own photo" : "Change your photo")
    }
}

/// A photo background being placed, as a sheet item.
private struct EditingPhoto: Identifiable {
    let id = UUID()
    let background: ChatBackground
}

// MARK: - Devices

private struct DevicesSettings: View {
    var body: some View {
        SettingsScreen(title: "Devices") {
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
                        if model.waitingToSend.count > 0 {
                            // Opens what's waiting, why, and for whom.
                            NavigationLink(value: SettingsPage.networkWaiting) {
                                SettingRow("Waiting to send") {
                                    HStack(spacing: 6) {
                                        Self.dim(waitingText)
                                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.faint)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        } else {
                            SettingRow("Waiting to send") { Self.dim(waitingText) }
                        }
                    }
                }
                RowDivider()
                ActionRow(title: model.retryingRelay ? "Checking…" : "Check connection") { Task { await model.retryRelay() } }
            }
            // Only a relay other than the built-in one is worth naming (a development build pointed elsewhere).
            if model.data.relay != AppData.defaultRelay {
                SettingsGroup("Relay", footer: "Passes on your encrypted messages. It can't read them.") {
                    SettingRow("Server") {
                        Text(relayURL?.host() ?? model.data.relay)
                            .font(.system(size: 14, design: .monospaced)).foregroundStyle(Ink.dim)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            SettingsGroup("Tor", footer: torFooter) {
                SettingRow("Connect over Tor") {
                    Toggle("Connect over Tor", isOn: Binding(get: { torLocked || model.data.security.tor },
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
            SettingsGroup(footer: "The route to the relay, hop by hop, and what it can see.") {
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
        case .auto: what = "Tries Tor directly, then switches to Snowflake by itself if it can't connect in about 40 seconds."
            + (Bridges.autoUsesSnowflake ? " Using Snowflake now." : "")
        case .off: what = "Bridges help on networks that block Tor. Off connects to Tor directly."
        case .snowflake: what = "Disguises Tor as a video call. Works on most networks."
        case .custom: what = "Your own bridges, such as from bridges.torproject.org. Hardest for a network to block."
        }
        let snowflake = bridges == .snowflake || (bridges == .auto && Bridges.autoUsesSnowflake)
        let stun = snowflake
            ? " Snowflake also contacts third-party STUN servers directly, outside Tor, so your network can tell it's in use."
            : ""
        return (bridgesPending ? what + " PULSHADE will use them from the next time it opens." : what) + stun
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
        return "Tor can take a minute or two to connect. Messages wait on this device until it does."
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
        return "Hides your IP from the server; each persona has its own circuit. Slower."
    }
}

/// What's waiting on this device to reach the relay: what it is, why it hasn't gone, and who it's for. Nothing here
/// leaves the phone; it's worked out from the outbox each time the page draws.
private struct WaitingToSendView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsScreen(title: "Waiting to send", back: "Network") {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let report = model.waitingReport
                VStack(spacing: 22) {
                    if report.kinds.isEmpty {
                        SettingsGroup(footer: "Everything has reached the relay.") {
                            SettingRow("Waiting") { Self.dim("Nothing") }
                        }
                    } else {
                        group("Why it's waiting", report.reasons,
                              footer: "From the last time each one was tried. They're tried again on their own.")
                        group("What it is", report.kinds, footer: nil)
                        group("Who it's for", report.people,
                              footer: "\(report.mailboxes) \(report.mailboxes == 1 ? "device" : "devices") in all. A friend's old phone that never collects can fill up its mailbox.")
                    }
                    SettingsGroup {
                        ActionRow(title: model.retryingRelay ? "Trying…" : "Try again now") { Task { await model.retryRelay() } }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ rows: [(String, Int)], footer: String?) -> some View {
        SettingsGroup(title, footer: footer) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                if i > 0 { RowDivider() }
                SettingRow(row.0) { Self.dim("\(row.1)") }
            }
        }
    }

    private static func dim(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(Ink.dim).monospacedDigit()
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
                Text("Paste bridge lines, one per line (webtunnel or Snowflake). Get them from bridges.torproject.org.")
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
                    ActionRow(title: "Install and restart") {
                        guard let client = model.client(nil, lane: "update") else { return }
                        Task { await updater.install(client) }
                    }
                }
            }
            SettingsGroup {
                ActionRow(title: "Check for updates") {
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

/// A glowing pill switch that matches the theme. It draws only the switch: the row beside it shows the title,
/// and the toggle's own label names it for VoiceOver.
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
        .accessibilityLabel { _ in configuration.label }
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
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
                    .symbolEffect(.pulse, isActive: !Platform.reduceMotion)
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
                    ProblemText(problem)
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
