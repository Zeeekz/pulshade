import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// The Collectibles tab: what the active persona has been given, and which one shows after its name. On iPhone,
/// where the tab bar is full, it's a page in Settings instead.
struct CollectiblesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var inSettings = false
    @State private var loading = true
    @State private var problem: String?
    @State private var showingCode = false
    @State private var viewing: Collectible?

    private var owned: [Collectible] { model.activeProfile.collectibles ?? [] }
    private var worn: Collectible? { model.activeProfile.badge }
    /// Kinds this persona has none of yet, shown faded so people know what exists.
    private var missing: [Collectible.Kind] { Collectible.Kind.allCases.filter { kind in !owned.contains { $0.kind == kind } } }

    var body: some View {
        Group {
            if inSettings {
                SettingsScreen(title: "Collectibles") { content }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack {
                            Text("Collectibles").font(.system(size: 20, weight: .bold)).foregroundStyle(Ink.text)
                            Spacer()
                            if loading { ProgressView().controlSize(.small) }
                        }
                        content
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, Platform.isPhone ? 12 : 40)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never)
            }
        }
        .task(id: model.activePersona) { await refresh() }
        .sheet(isPresented: $showingCode) { BackupCodeSheet() }
        .sheet(item: $viewing) { item in CollectibleViewerSheet(item: item) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            preview
            EggsSection()
            if !owned.isEmpty { codeRow }
            // Pets are kept in their own groups, after the rest.
            ForEach(Collectible.Kind.Category.allCases, id: \.self) { category in
                let mine = owned.filter { $0.kind?.category == category }
                let notYet = missing.filter { $0.category == category }
                if !mine.isEmpty {
                    grid(title: category == .pets ? "Pets" : "Yours") {
                        ForEach(mine) { item in ownedCard(item) }
                    }
                }
                if !notYet.isEmpty {
                    grid(title: category == .pets ? "Pets to find" : (owned.isEmpty ? "None yet" : "Not collected")) {
                        ForEach(notYet) { kind in missingCard(kind) }
                    }
                }
            }
            ClaimCodeCard()
            Text(branded: "Collectibles are given out by PULSHADE. Each is numbered and belongs to this persona only. The one you choose shows after your name to your contacts and on your public profile. One backup code brings them all back if this account is ever burned or lost.")
                .font(.system(size: 12)).foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem).font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
            }
        }
    }

    /// How your name looks to others right now.
    private var preview: some View {
        HStack(spacing: 12) {
            Avatar(image: model.activeProfile.avatar, seed: model.fingerprint, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.activeProfile.displayName).font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.text)
                    BadgeMark(badge: worn, size: 18)
                }
                Text(worn.flatMap { w in w.kind.map { "Showing \($0.name) #\(w.serial)" } } ?? "Nothing after your name")
                    .font(.system(size: 12)).foregroundStyle(Ink.faint)
            }
            Spacer(minLength: 0)
            if worn != nil {
                Button("Take off") { withAnimation(.snappy) { model.wear(nil) } }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.dim)
            }
        }
        .padding(14)
        .background(Ink.raised, in: .rect(cornerRadius: 14))
    }

    /// The one backup code for everything here.
    private var codeRow: some View {
        Button { showingCode = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "key.horizontal.fill").font(.system(size: 15)).foregroundStyle(theme.accent)
                    .frame(width: 34, height: 34).background(theme.accent.opacity(0.12), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Backup code").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.text)
                    Text(owned.count == 1 ? "Covers your collectible" : "Covers all \(owned.count) collectibles")
                        .font(.system(size: 12)).foregroundStyle(Ink.faint)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.faint)
            }
            .padding(12)
            .background(Ink.raised, in: .rect(cornerRadius: 14))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func grid<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12, content: content)
        }
    }

    private func ownedCard(_ item: Collectible) -> some View {
        let wearing = worn == item
        let opens = item.kind?.has3DView == true
        return Button {
            if opens { viewing = item } else { withAnimation(.snappy) { model.wear(wearing ? nil : item) } }
        } label: {
            VStack(spacing: 10) {
                if let kind = item.kind { CollectibleIcon(item: kind, size: 84) }
                VStack(spacing: 2) {
                    Text(item.kind?.name ?? item.item).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text)
                    RarityTag(item: item)
                }
                Text(wearing ? "After your name" : (opens ? "View in 3D" : "Show after your name"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(wearing ? Ink.onAccent : theme.accent)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(wearing ? theme.accent : theme.accent.opacity(0.12), in: .capsule)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Ink.raised, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(wearing ? theme.accent : Ink.line, lineWidth: wearing ? 1.5 : 1))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func missingCard(_ kind: Collectible.Kind) -> some View {
        VStack(spacing: 10) {
            CollectibleIcon(item: kind, size: 84).saturation(0).opacity(0.3)
            VStack(spacing: 2) {
                Text(kind.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.dim)
                Text(branded: kind.blurb).font(.system(size: 12)).foregroundStyle(Ink.faint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18).padding(.horizontal, 12)
        .background(Ink.surface, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.line))
    }

    private func refresh() async {
        loading = true
        do {
            await model.refreshEggs()
            try await model.refreshCollectibles()
            problem = nil
        } catch {
            problem = "Can't reach the relay"
        }
        loading = false
    }
}
