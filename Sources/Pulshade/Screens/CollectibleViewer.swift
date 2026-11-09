import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// A collectible opened up to look at: Pulze The Dragon turns all the way round under your finger, and zaps
/// when you tap it. Wearing it after your name is done from here too.
struct CollectibleViewerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let item: Collectible
    /// Someone else's: look, but no button to wear it.
    var readOnly = false

    private var wearing: Bool { model.activeProfile.badge == item }
    @State private var gifting = false
    @State private var letting = false
    @State private var problem: String?

    private func otherButton(_ title: String, symbol: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint ?? Ink.text)
                .frame(maxWidth: .infinity).frame(height: 40)
                .background(Ink.raised, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent)
            }
            VStack(spacing: 4) {
                Text(item.kind?.name ?? item.item).font(.system(size: 22, weight: .bold)).foregroundStyle(Ink.text)
                RarityTag(item: item)
                if let kind = item.kind {
                    Text(branded: kind.blurb).font(.system(size: 13)).foregroundStyle(Ink.faint)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)

            Group {
                if item.kind == .pulze || item.kind == .goldPulze {
                    DragonViewer(golden: item.kind == .goldPulze)
                } else if item.kind == .bitcoin {
                    BitcoinViewer()
                } else if let kind = item.kind {
                    ObjectViewer3D(kind: kind)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300)
            .frame(maxHeight: 440)
            .background(
                RadialGradient(colors: [Color(red: 0.07, green: 0.11, blue: 0.26), Color(red: 0.03, green: 0.04, blue: 0.09)], center: .bottom, startRadius: 0, endRadius: 460),
                in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Ink.line))
            .clipShape(.rect(cornerRadius: 18))

            if !readOnly {
            Button { withAnimation(.snappy) { model.wear(wearing ? nil : item) } } label: {
                Text(wearing ? "Showing after your name" : "Show after your name")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(wearing ? Ink.onAccent : theme.accent)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(wearing ? theme.accent : theme.accent.opacity(0.12), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            HStack(spacing: 10) {
                if item.kind?.transferable ?? true {
                    otherButton("Gift", symbol: "gift") { gifting = true }
                }
                otherButton("Let go", symbol: "xmark.bin", tint: .red) { letting = true }
            }
            if let problem { ProblemText(problem) }
            }
        }
        .sheet(isPresented: $gifting) { GiftSheet(item: item) { dismiss() } }
        .confirmationDialog("Let \(item.kind?.name ?? "it") #\(item.serial) go?", isPresented: $letting, titleVisibility: .visible) {
            Button("Let it go", role: .destructive) {
                Task {
                    do { try await model.release(item); dismiss() }
                    catch { problem = "Couldn't reach the server. Nothing was changed." }
                }
            }
        } message: {
            Text("It goes back into circulation, so someone else can hatch this one. You won't get it back.")
        }
        .padding(20)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Ink.surface)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 640)
        #endif
    }
}
