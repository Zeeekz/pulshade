import SwiftUI

/// The Burn tab: Lock, Detach and Burn in one place, each saying what it does before it's chosen. Detach and
/// Burn open their own sheets, which ask again before anything happens.
struct LeaveView: View {
    @Environment(AppModel.self) private var model
    @State private var detaching = false
    @State private var burning = false
    @State private var burningPersona = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Burn").font(.system(size: 20, weight: .bold)).foregroundStyle(Ink.text)
                VStack(spacing: 10) {
                    LeaveOption(symbol: "lock.fill", color: Ink.dim, title: "Lock",
                                detail: "Close PULSHADE now. Your passcode opens it again.") { model.lock() }
                    LeaveOption(symbol: "person.crop.circle.badge.minus", color: .orange, title: "Detach",
                                detail: "Log out of this device, or every device. Your recovery code brings the account back.") { detaching = true }
                    if model.activePersona != nil {
                        LeaveOption(symbol: "flame", color: .red, title: "Burn persona",
                                    detail: "Delete \(model.activeProfile.displayName) for good. Your main identity and other personas aren't touched.") { burningPersona = true }
                    }
                    LeaveOption(symbol: "flame.fill", color: .red, title: "Burn",
                                detail: "Delete your account everywhere, as if it never existed. It can't be undone.") { burning = true }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, Platform.isPhone ? 12 : 40)
            .padding(.bottom, 24)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .sheet(isPresented: $detaching) { DetachSheet() }
        .sheet(isPresented: $burning) { BurnSheet() }
        .sheet(isPresented: $burningPersona) {
            if let id = model.activePersona { PersonaBurnSheet(persona: id) }
        }
    }
}

private struct LeaveOption: View {
    var symbol: String
    var color: Color
    var title: String
    var detail: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 40, height: 40)
                    .background(color.opacity(0.14), in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.text)
                    Text(branded: detail).font(.system(size: 13)).foregroundStyle(Ink.dim)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.faint)
            }
            .padding(14)
            .background(Ink.raised, in: .rect(cornerRadius: 14))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

/// Detach: the account leaves this device (or every device), keeping everything but the chats.
struct DetachSheet: View {
    @Environment(AppModel.self) private var model
    @State private var scope = AppModel.DetachScope.thisDevice
    @State private var code = ""
    @State private var working = false
    @State private var problem: String?

    private var needsCode: Bool { !model.hasOtherDevices || scope == .everyDevice }

    var body: some View {
        SheetBody(width: 460) {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeader(symbol: "person.crop.circle.badge.minus", title: "Detach")
                if model.hasOtherDevices {
                    VStack(spacing: 8) {
                        LeaveChoice(title: "Only this device", detail: "Your other devices keep the account and every chat. Log back in here with a QR code from one of them.",
                                    chosen: scope == .thisDevice) { scope = .thisDevice }
                        LeaveChoice(title: "Every device", detail: "Every device is logged out and every chat is deleted. Your recovery code brings back the rest.",
                                    chosen: scope == .everyDevice) { scope = .everyDevice }
                    }
                }
                if needsCode {
                    Text("Your profile, @handles, contacts, groups and settings are sealed and kept on the relay for your recovery code, for up to 180 days. Every chat, story and request is deleted for good. Enter the code to make sure you have it.")
                        .font(.system(size: 14)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    RecoveryCodeField(code: $code)
                }
                if let problem {
                    Text(branded: problem).font(.system(size: 13, weight: .medium)).foregroundStyle(.orange)
                }
                Button(action: detach) { WorkingLabel(title: "Detach", working: working) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(working || (needsCode && code.isEmpty))
            }
        }
    }

    private func detach() {
        working = true
        problem = nil
        Task {
            do {
                try await model.detach(scope, recoveryCode: needsCode ? code : nil)
            } catch AppModel.LeaveError.wrongRecoveryCode {
                problem = "That isn't this account's recovery code"
            } catch {
                problem = "Can't reach the relay. Check your connection and try again."
            }
            working = false
        }
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
                Text("This deletes your account everywhere, as if it never existed. It can't be undone, and the recovery code won't bring it back.")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                BurnPoints()
                if !(model.activeProfile.collectibles ?? []).isEmpty {
                    Label("Your collectibles can come back in a new account with your backup code. Write it down from Collectibles before you burn.", systemImage: "key.horizontal")
                        .font(.system(size: 13)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                BurnConfirmField(confirm: $confirm)
                if let problem {
                    Text(branded: problem).font(.system(size: 13, weight: .medium)).foregroundStyle(.orange)
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
                try await model.burn()
            } catch {
                problem = "Can't reach the relay, so nothing was burned yet. Check your connection and try again."
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
    private var hasCollectibles: Bool { !(model.activeProfile.collectibles ?? []).isEmpty }

    var body: some View {
        SheetBody(width: 460) {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeader(symbol: "flame.fill", title: "Burn \(name)")
                Text("This deletes the persona \(name) everywhere, as if it never existed. It can't be undone. Your main identity and your other personas aren't touched.")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    BurnPoint(symbol: "bubble.left.and.bubble.right", text: "Its chats are deleted for both sides. Groups it owns are deleted for everyone; it leaves the rest.")
                    BurnPoint(symbol: "person.crop.circle.badge.xmark", text: "Its contacts forget it, along with its messages, stories and requests.")
                    BurnPoint(symbol: "at", text: "Its @handles can't be claimed for 3 months, and the relay forgets they were its.")
                    BurnPoint(symbol: "laptopcomputer.and.iphone", text: "It's removed from every device on your account.")
                    if hasCollectibles {
                        BurnPoint(symbol: "key.horizontal", text: "Its collectibles can come back in another persona or account with its backup code. Write it down from Collectibles first.")
                    }
                }
                BurnConfirmField(confirm: $confirm)
                if let problem {
                    Text(branded: problem).font(.system(size: 13, weight: .medium)).foregroundStyle(.orange)
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
                    LeaveChoice(title: "Detach", detail: "This device lets go of the account. Your profile, @handles, contacts and groups wait up to 180 days for your recovery code; this device's chats are deleted.",
                                chosen: !burning) { burning = false }
                    LeaveChoice(title: "Burn", detail: "The account is deleted everywhere, as if it never existed.",
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
                    Text(branded: problem).font(.system(size: 13, weight: .medium)).foregroundStyle(.orange)
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
            BurnPoint(symbol: "at", text: "Your @handles can't be claimed for 3 months, and the relay forgets they were yours.")
            BurnPoint(symbol: "server.rack", text: "The relay keeps nothing: no backup, no waiting messages.")
            BurnPoint(symbol: "laptopcomputer.and.iphone", text: "Every device on the account is wiped, and this one keeps no trace of it.")
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
