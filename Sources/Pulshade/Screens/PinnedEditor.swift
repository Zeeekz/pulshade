import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// What you've pinned to your profile, in one list: links, wallets and notes. A "+" at the top offers each kind,
/// so the page stays short however much is pinned. Nothing invalid is ever saved.
struct PinnedEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var linkDraft: LinkDraft?
    @State private var noteDraft: NoteDraft?
    @State private var pending: Pending?

    struct NoteDraft: Identifiable {
        var existing: ProfileNote?
        var id: String { existing?.id ?? "new" }
    }

    private static let maxCustom = 6
    private var links: [ProfileLink] { model.activeProfile.links ?? [] }
    private var notes: [ProfileNote] { model.activeProfile.notes ?? [] }
    private var used: Set<ProfileLinkKind> { Set(links.map(\.kind)) }

    private func free(wallets: Bool) -> [ProfileLinkKind] {
        (wallets ? ProfileLinkKind.wallets : ProfileLinkKind.links).filter {
            $0 == .custom ? links.filter { $0.kind == .custom }.count < Self.maxCustom : !used.contains($0)
        }
    }

    var body: some View {
        let empty = links.isEmpty && notes.isEmpty
        SettingsGroup("Pinned to your profile",
                      footer: "Links and wallets are public. Notes can be public, locked, or sent to chosen contacts.") {
            if empty {
                SettingRow("Nothing pinned yet") { EmptyView() }
                    .foregroundStyle(Ink.faint)
            }
            ForEach(Array(links.enumerated()), id: \.element.id) { i, link in
                if i > 0 { RowDivider(inset: 62) }
                linkRow(link)
            }
            ForEach(Array(notes.enumerated()), id: \.element.id) { i, note in
                if i > 0 || !links.isEmpty { RowDivider(inset: 62) }
                noteRow(note)
            }
            RowDivider(inset: 16)
            addMenu
        }
        .confirms($pending)
        .sheet(item: $linkDraft) { draft in
            AddLinkSheet(draft: draft, choices: free(wallets: draft.wallets)) { link in
                storeLinks { list in
                    if let old = draft.existing { list.removeAll { $0.id == old.id } }
                    if link.kind != .custom { list.removeAll { $0.kind == link.kind } }
                    list.removeAll { $0.id == link.id }
                    list.append(link)
                }
            }
        }
        .sheet(item: $noteDraft) { draft in
            NoteEditSheet(existing: draft.existing) { saved in
                storeNotes { list in
                    if let i = list.firstIndex(where: { $0.id == saved.id }) { list[i] = saved } else { list.append(saved) }
                }
            }
        }
    }

    private var addMenu: some View {
        Menu {
            if !free(wallets: false).isEmpty { Button("Link", systemImage: "link") { linkDraft = LinkDraft(wallets: false) } }
            if !free(wallets: true).isEmpty { Button("Wallet", systemImage: "wallet.bifold") { linkDraft = LinkDraft(wallets: true) } }
            if notes.count < ProfileNote.maxCount { Button("Note", systemImage: "doc.text") { noteDraft = NoteDraft() } }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(theme.accent)
                    .frame(width: 36, height: 36)
                    .background(theme.accent.opacity(0.14), in: .rect(cornerRadius: 10, style: .continuous))
                Text("Pin something").font(.system(size: 15, weight: .medium)).foregroundStyle(theme.accent)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 54).contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private func linkRow(_ link: ProfileLink) -> some View {
        pinRow(title: link.kind == .custom ? (link.label ?? "Link") : link.kind.title,
               subtitle: link.subtitle, mono: link.kind.isWallet,
               edit: { linkDraft = LinkDraft(wallets: link.kind.isWallet, kind: link.kind, existing: link) },
               remove: {
                   pending = Pending(title: "Remove this \(link.kind.isWallet ? "wallet" : "link") from your profile?", confirm: "Remove") {
                       storeLinks { list in list.removeAll { $0.id == link.id } }
                   }
               }) {
            BrandTile(kind: link.kind, size: 36)
        }
    }

    private func noteRow(_ note: ProfileNote) -> some View {
        pinRow(title: note.title, subtitle: note.subtitle, mono: false,
               edit: { noteDraft = NoteDraft(existing: note) },
               remove: {
                   pending = Pending(title: "Delete the note “\(note.title)”?", message: "It's removed from your profile and can't be brought back.",
                                     confirm: "Delete") {
                       storeNotes { list in list.removeAll { $0.id == note.id } }
                   }
               }) {
            Image(systemName: note.isLocked ? "lock.fill" : note.isRestricted ? "person.2.fill" : "doc.text.fill")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
                .frame(width: 36, height: 36)
                .background(Ink.base, in: .rect(cornerRadius: 10, style: .continuous))
        }
    }

    private func pinRow<Icon: View>(title: String, subtitle: String, mono: Bool, edit: @escaping () -> Void,
                                    remove: @escaping () -> Void, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 14) {
            Button(action: edit) {
                HStack(spacing: 14) {
                    icon()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.text).lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 12.5, design: mono ? .monospaced : .default))
                            .foregroundStyle(Ink.faint).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button(action: remove) {
                Image(systemName: "trash").font(.system(size: 14)).foregroundStyle(Ink.faint).frame(width: 40, height: 40).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(title)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 54)
    }

    private func storeLinks(_ change: (inout [ProfileLink]) -> Void) {
        model.updateProfile { profile in
            var list = ProfileLink.cleaned(profile.links)
            change(&list)
            let order = Dictionary(uniqueKeysWithValues: ProfileLinkKind.allCases.enumerated().map { ($1, $0) })
            list.sort { (order[$0.kind] ?? 0, $0.label ?? "") < (order[$1.kind] ?? 0, $1.label ?? "") }
            profile.links = list.isEmpty ? nil : list
        }
    }

    private func storeNotes(_ change: (inout [ProfileNote]) -> Void) {
        model.updateProfile { profile in
            var list = ProfileNote.cleaned(profile.notes, keepAudience: true)
            change(&list)
            profile.notes = list.isEmpty ? nil : list
        }
    }
}
