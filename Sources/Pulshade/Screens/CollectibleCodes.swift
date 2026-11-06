import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// The backup code for all of this persona's collectibles, to write down. Like the recovery code it's never offered
/// for copying, so it can't end up on the clipboard or in another device's.
struct BackupCodeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    /// Set when this is the alert for something the code just started covering, rather than opened from Collectibles.
    var alert: AppModel.CodeAlert?
    @State private var working = false
    @State private var problem: String?
    @State private var confirmReplace = false

    private var items: [Collectible] { alert?.items ?? model.activeProfile.collectibles ?? [] }
    private var names: String { items.map { "\($0.kind?.name ?? $0.item) #\($0.serial)" }.formatted(.list(type: .and)) }

    private var title: String {
        guard let alert else { return "Backup code" }
        return alert.newCode ? "Back up your collectibles" : "Your backup code covers it"
    }

    var body: some View {
        SheetBody(width: 440) {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeader(symbol: "key.horizontal.fill", title: title)
                if !items.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(items.prefix(6)) { item in
                            VStack(spacing: 4) {
                                if let kind = item.kind { CollectibleIcon(item: kind, size: 52) }
                                Text("#\(item.serial)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.faint)
                            }
                        }
                        if items.count > 6 {
                            Text("+\(items.count - 6)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim)
                        }
                    }
                }
                if let code = model.collectionCode {
                    Text(code)
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(Ink.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Ink.raised, in: .rect(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.accent.opacity(0.4)))
                        .accessibilityLabel(code.map { String($0) }.joined(separator: " "))
                    Text(explanation)
                        .font(.system(size: 13)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Your backup code was made on another of your devices and hasn't reached this one yet. You can see it there, or make a new one here: the old one then stops working.")
                        .font(.system(size: 13)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let problem {
                    Text(problem).font(.system(size: 13, weight: .medium)).foregroundStyle(.orange)
                }
                Button(alert?.newCode == true ? "I've written it down" : "Done") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                if !(model.activeProfile.collectibles ?? []).isEmpty {
                    Button(working ? "Making a new code…" : "Make a new code") {
                        if model.collectionCode == nil { replace() } else { confirmReplace = true }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.dim)
                    .frame(maxWidth: .infinity)
                    .disabled(working)
                    .confirmationDialog("Make a new code?", isPresented: $confirmReplace, titleVisibility: .visible) {
                        Button("Make a new code", role: .destructive, action: replace)
                    } message: {
                        Text("The code you have now stops working for all your collectibles. Use this if someone else may have seen it.")
                    }
                }
            }
        }
    }

    private var explanation: String {
        if let alert, !alert.newCode {
            return "\(names) is now covered by your backup code, the same one as before. Nothing new to write down."
        }
        return "One code for all your collectibles: \(names), and any you get later. Write it down and keep it somewhere safe. If this account is ever burned or lost, enter the code in a new account to get them all back, with the same numbers. Anyone with the code can take them, so keep it to yourself."
    }

    private func replace() {
        working = true
        problem = nil
        Task {
            do { try await model.makeNewCollectionCode() } catch { problem = "Can't reach the relay, so some collectibles may still use the old code. Try again." }
            working = false
        }
    }
}

/// Bringing collectibles back into this account with backup codes from another one.
struct ClaimCodeCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var code = ""
    @State private var working = false
    @State private var result: (text: String, failed: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Redeem a code").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim)
            HStack(spacing: 8) {
                TextField("", text: $code, prompt: Text("Enter a code").foregroundStyle(Ink.faint))
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Ink.text)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .onSubmit(claim)
                Button(working ? "Checking…" : "Enter", action: claim)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ready ? theme.accent : Ink.faint)
                    .disabled(!ready || working)
            }
            .padding(.horizontal, 12).frame(height: 44)
            .background(Ink.raised, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line))
            if let result {
                Text(branded: result.text).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(result.failed ? .orange : theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Collectibles and pets can be redeemed here.")
                    .font(.system(size: 12)).foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var ready: Bool { Collectible.normalisedCode(code).count >= 4 }

    private func claim() {
        guard ready, !working else { return }
        working = true
        result = nil
        Task {
            do {
                switch try await model.enterCollectibleCode(code) {
                case let .restored(found):
                    let names = found.map { "\(Collectible.Kind(rawValue: $0.item)?.name ?? $0.item) #\($0.serial)" }
                        .formatted(.list(type: .and))
                    result = ("\(names) will show up here once PULSHADE has signed \(found.count == 1 ? "it" : "them") over to you.", false)
                case let .giveaway(item, place):
                    let name = Collectible.Kind(rawValue: item)?.name ?? item
                    result = ("You're in: number \(place) in line for \(name). It shows up here once PULSHADE has signed it over to you, usually within a few minutes.", false)
                }
                code = ""
            } catch RelayClient.ClaimError.unknownCode, RelayClient.GiveawayError.unknownCode {
                result = ("That code doesn't match anything. It may have been used already, replaced, or the giveaway isn't open.", true)
            } catch RelayClient.GiveawayError.full {
                result = ("That giveaway has run out. Every one has been claimed.", true)
            } catch {
                result = ("Can't reach the relay. Try again in a moment.", true)
            }
            working = false
        }
    }
}
