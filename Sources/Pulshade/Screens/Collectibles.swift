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
    /// Which half to show. Nil shows both with a switch on top, as on the Mac's tab.
    var pets: Bool?
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
                SettingsScreen(title: pets == true ? "Pets" : pets == false ? "Collectibles" : "Collectibles & Pets") { content }
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

    private enum Tab: String, CaseIterable { case collectibles = "Collectibles", pets = "Pets" }
    @State private var tab = Tab.collectibles
    private var showPets: Bool { pets ?? (tab == .pets) }

    private func isPet(_ item: Collectible) -> Bool { item.kind?.category == .pets }
    private var collectibleCount: Int { owned.filter { !isPet($0) }.count }
    private var petCount: Int { owned.filter(isPet).count }

    private var content: some View {
        let pets = showPets
        let mine = owned.filter { isPet($0) == pets }
        let notYet = missing.filter { ($0.category == .pets) == pets }
        return VStack(alignment: .leading, spacing: 20) {
            preview
            if self.pets == nil {
                Picker("", selection: $tab.animation(.snappy)) {
                    Text("Collectibles · \(collectibleCount)").tag(Tab.collectibles)
                    Text("Pets · \(petCount)").tag(Tab.pets)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if pets { EggsSection() }
            if !pets && collectibleCount > 0 { codeRow }
            if !mine.isEmpty {
                grid(title: "\(mine.count) \(pets ? (mine.count == 1 ? "pet" : "pets") : (mine.count == 1 ? "collectible" : "collectibles"))") {
                    ForEach(mine) { item in ownedCard(item) }
                }
            } else if !(pets && !model.eggs.isEmpty) {
                Text(pets ? "No pets yet. Eggs hatch into them." : "No collectibles yet.")
                    .font(.system(size: 13)).foregroundStyle(Ink.faint)
            }
            if !notYet.isEmpty {
                DisclosureGroup {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(notYet) { kind in missingCard(kind) }
                    }
                    .padding(.top, 10)
                } label: {
                    Text(pets ? "Pets to find · \(notYet.count)" : "Not collected · \(notYet.count)")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim)
                }
                .tint(Ink.dim)
            }
            ClaimCodeCard()
            Text(branded: pets
                 ? "Each pet is numbered and belongs to this persona. A backup code restores them."
                 : "Each one is numbered and belongs to this persona. The one you pick shows after your name. A backup code restores them.")
                .font(.system(size: 12)).foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                ProblemText(problem)
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
