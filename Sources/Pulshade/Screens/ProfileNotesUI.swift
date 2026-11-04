import SwiftUI
import UniformTypeIdentifiers
#if canImport(PulshadeShared)
import PulshadeShared
#endif

// MARK: - Reading someone's notes

/// A profile's notes, in a section that stays shut until tapped: each is a row with its title; tap one to read it.
/// A locked note asks for its password first, and opens on this device only.
struct ProfileNoteList: View {
    var notes: [ProfileNote]
    var tint: Color
    @State private var reading: ProfileNote?

    var body: some View {
        let shown = ProfileNote.cleaned(notes)
        if !shown.isEmpty {
            ExpandableCard(title: "Notes", symbol: "doc.text", count: shown.count) {
                HStack(spacing: 6) {
                    ForEach(shown.prefix(3)) { note in
                        Image(systemName: note.isLocked ? "lock.fill" : "doc.text.fill")
                            .font(.system(size: 12)).foregroundStyle(Ink.dim)
                    }
                }
            } content: {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, note in
                        if i > 0 { Divider().overlay(Ink.line).padding(.leading, 56) }
                        row(note)
                    }
                }
            }
            .frame(maxWidth: 340)
            .sheet(item: $reading) { note in NoteReaderSheet(note: note, tint: tint) }
        }
    }

    private func row(_ note: ProfileNote) -> some View {
        Button { reading = note } label: {
            HStack(spacing: 14) {
                Image(systemName: note.isLocked ? "lock.fill" : "doc.text.fill")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(Ink.raised, in: .rect(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                    Text(note.subtitle).font(.system(size: 12.5)).foregroundStyle(Ink.dim).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.faint)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(note.title), \(note.subtitle)")
    }
}

/// Reads one note. A locked one shows only a password field until the right password is typed; the words exist on
/// screen only while it is open, and are dropped when it closes.
struct NoteReaderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    var note: ProfileNote
    var tint: Color
    @State private var password = ""
    @State private var words: String?
    @State private var working = false
    @State private var failures = 0
    @State private var waitUntil = Date.distantPast
    @State private var problem: String?

    private var text: String? { note.isLocked ? words : note.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: note.isLocked ? (words == nil ? "lock.fill" : "lock.open.fill") : "doc.text.fill").foregroundStyle(tint)
                Text(note.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(2)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.plain).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent)
            }
            if let text {
                ScrollView {
                    Text(text)
                        .font(.system(size: 15)).foregroundStyle(Ink.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .background(Ink.raised, in: .rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
                if note.isLocked {
                    Button { words = nil; password = "" } label: { Label("Lock again", systemImage: "lock.fill") }
                        .buttonStyle(ProfileActionStyle())
                }
            } else {
                unlock
                Spacer(minLength: 0)
            }
        }
        .padding(24)
        .frame(minWidth: 340, maxWidth: 520, minHeight: 360)
        .presentationDetents([.large])
        .onDisappear { words = nil; password = "" }
    }

    private var unlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This note is locked. Type its password to read it. The password never leaves this device.")
                .font(.system(size: 13)).foregroundStyle(Ink.dim)
            SecureField("", text: $password, prompt: Text("Password").foregroundStyle(Ink.faint))
                .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(Ink.text)
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
                .padding(.horizontal, 16).frame(minHeight: 50)
                .background(Ink.surface, in: .rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
                .onSubmit(tryOpen)
            if let problem { Text(problem).font(.system(size: 12, weight: .medium)).foregroundStyle(.orange) }
            Button(action: tryOpen) {
                HStack(spacing: 8) {
                    if working { ProgressView().controlSize(.small) }
                    Text(working ? "Unlocking..." : "Unlock").font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(Ink.onAccent).frame(maxWidth: .infinity, minHeight: 48)
                .background(theme.gradient, in: .capsule)
                .opacity(password.isEmpty || working ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(password.isEmpty || working)
        }
    }

    /// Opening is deliberately slow (it makes guessing slow), so it runs off the main thread. After a few wrong
    /// tries this screen makes you wait; that slows a person down, and the slow key derivation is what slows a program.
    private func tryOpen() {
        guard !password.isEmpty, !working else { return }
        guard Date() >= waitUntil else {
            problem = "Wait a few seconds before trying again."
            return
        }
        working = true
        problem = nil
        let attempt = password, note = note
        Task {
            let opened = await Task.detached(priority: .userInitiated) { note.open(password: attempt) }.value
            working = false
            if let opened {
                words = opened; failures = 0
            } else {
                failures += 1
                if failures >= 3 { waitUntil = Date().addingTimeInterval(Double(min(30, failures * 3))) }
                problem = "That password didn't open it."
            }
        }
    }
}

// MARK: - Writing your own

/// Your notes in Settings: what you've written, with a lock on the ones that have a password, and a way to add more.
struct ProfileNotesEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var editing: Draft?

    struct Draft: Identifiable {
        var existing: ProfileNote?
        var id: String { existing?.id ?? "new" }
    }

    private var notes: [ProfileNote] { model.activeProfile.notes ?? [] }

    var body: some View {
        SettingsGroup("Notes", footer: "Text people can read by tapping it on your profile. Add a password and it's encrypted on this device: nobody else can read it, not even Pulshade, and if you forget the password it can't be recovered. Titles are always visible.") {
            ForEach(Array(notes.enumerated()), id: \.element.id) { i, note in
                if i > 0 { RowDivider(inset: 58) }
                row(note)
            }
            if notes.count < ProfileNote.maxCount {
                if !notes.isEmpty { RowDivider(inset: 58) }
                Button { editing = Draft() } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(theme.accent)
                            .frame(width: 36, height: 36)
                            .background(theme.accent.opacity(0.14), in: .rect(cornerRadius: 10, style: .continuous))
                        Text("Add a note").font(.system(size: 15, weight: .medium)).foregroundStyle(theme.accent)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 54).contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: $editing) { draft in
            NoteEditSheet(existing: draft.existing) { saved in
                store { list in
                    if let i = list.firstIndex(where: { $0.id == saved.id }) { list[i] = saved } else { list.append(saved) }
                }
            }
        }
    }

    private func row(_ note: ProfileNote) -> some View {
        HStack(spacing: 14) {
            Button { editing = Draft(existing: note) } label: {
                HStack(spacing: 14) {
                    Image(systemName: note.isLocked ? "lock.fill" : "doc.text.fill")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
                        .frame(width: 36, height: 36)
                        .background(Ink.base, in: .rect(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.text).lineLimit(1)
                        Text(note.subtitle).font(.system(size: 12.5)).foregroundStyle(Ink.faint).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button { store { list in list.removeAll { $0.id == note.id } } } label: {
                Image(systemName: "trash").font(.system(size: 14)).foregroundStyle(Ink.faint).frame(width: 30, height: 30).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(note.title)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 54)
    }

    private func store(_ change: (inout [ProfileNote]) -> Void) {
        model.updateProfile { profile in
            var list = ProfileNote.cleaned(profile.notes)
            change(&list)
            profile.notes = list.isEmpty ? nil : list
        }
    }
}

/// Write or change a note: a title, the words (typed, or read from a text file), and whether to lock it.
struct NoteEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    var existing: ProfileNote?
    var save: (ProfileNote) -> Void
    @State private var title = ""
    @State private var text = ""
    @State private var locked = false
    @State private var password = ""
    @State private var generated: String?
    /// Changing a locked note starts by proving you know its password.
    @State private var needsUnlock = false
    @State private var unlockPassword = ""
    @State private var working = false
    @State private var problem: String?
    @State private var importing = false

    private var passwordProblem: String? { locked && !password.isEmpty ? NoteSeal.passwordProblem(password) : nil }
    private var canSave: Bool {
        !working && ProfileNote.cleanTitle(title) != nil && ProfileNote.cleanText(text) != nil
            && (!locked || NoteSeal.passwordProblem(password) == nil)
    }

    var body: some View {
        Group {
            if needsUnlock { unlockStep } else { form }
        }
        .padding(24)
        .frame(minWidth: 360, maxWidth: 560, minHeight: 420)
        .presentationDetents([.large])
        .onAppear {
            guard let existing else { return }
            title = existing.title
            if existing.isLocked { needsUnlock = true; locked = true } else { text = existing.text ?? "" }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count <= 200_000, let read = String(data: data, encoding: .utf8) else {
                problem = "That isn't a plain text file (or it's too big)."
                return
            }
            text = String(read.prefix(ProfileNote.maxText))
            if title.isEmpty { title = String(url.deletingPathExtension().lastPathComponent.prefix(ProfileNote.maxTitle)) }
            problem = read.count > ProfileNote.maxText ? "Only the first \(ProfileNote.maxText) characters fit in a note." : nil
        }
    }

    private var unlockStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Unlock to change")
            Text("Type this note's password to change it. Nobody can recover it if it's lost.").font(.system(size: 13)).foregroundStyle(Ink.dim)
            SecureField("", text: $unlockPassword, prompt: Text("Password").foregroundStyle(Ink.faint))
                .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(Ink.text)
                .padding(.horizontal, 16).frame(minHeight: 50)
                .background(Ink.surface, in: .rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
                .onSubmit(unlock)
            if let problem { Text(problem).font(.system(size: 12, weight: .medium)).foregroundStyle(.orange) }
            primary(working ? "Unlocking..." : "Unlock", enabled: !unlockPassword.isEmpty && !working, action: unlock)
            Spacer(minLength: 0)
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(existing == nil ? "New note" : "Edit note")
                box { field("Title (always visible)", $title) }
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $text)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 15)).foregroundStyle(Ink.text)
                        .frame(minHeight: 180)
                        .padding(10)
                        .background(Ink.surface, in: .rect(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
                    HStack {
                        Button { importing = true } label: { Label("Use a text file", systemImage: "doc.badge.plus") }
                            .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.accent)
                        Spacer()
                        Text("\(text.count) / \(ProfileNote.maxText)").font(.system(size: 12)).foregroundStyle(text.count > ProfileNote.maxText ? .orange : Ink.faint)
                    }
                }
                box {
                    HStack {
                        Label("Lock with a password", systemImage: "lock.fill").font(.system(size: 15)).foregroundStyle(Ink.text)
                        Spacer()
                        Toggle("", isOn: $locked.animation(.snappy)).toggleStyle(GlowToggleStyle())
                    }
                    .padding(.horizontal, 16).frame(minHeight: 50)
                }
                if locked { lockOptions }
                if let problem { Text(problem).font(.system(size: 12, weight: .medium)).foregroundStyle(.orange) }
                primary(working ? "Saving..." : "Save", enabled: canSave, action: commit)
            }
        }
        .scrollIndicators(.never)
    }

    private var lockOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            box {
                SecureField("", text: $password, prompt: Text("Password (12 or more characters)").foregroundStyle(Ink.faint))
                    .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(Ink.text)
                    .padding(.horizontal, 16).frame(minHeight: 50)
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
            }
            if let passwordProblem { Text(passwordProblem).font(.system(size: 12, weight: .medium)).foregroundStyle(.orange) }
            HStack {
                Button {
                    let made = NoteSeal.generatePassword()
                    password = made; generated = made
                } label: { Label("Make a strong one", systemImage: "wand.and.stars") }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.accent)
                Spacer()
            }
            if let generated, generated == password {
                HStack {
                    Text(generated).font(.system(size: 14, design: .monospaced)).foregroundStyle(Ink.text).textSelection(.enabled)
                    Spacer()
                    Button { copyToClipboard(generated, clearAfter: 60) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).foregroundStyle(theme.accent).accessibilityLabel("Copy password")
                }
                .padding(12).background(Ink.raised, in: .rect(cornerRadius: 12, style: .continuous))
                Text("Save it somewhere safe, and give it to whoever should read the note. Pulshade can't recover it.")
                    .font(.system(size: 12)).foregroundStyle(Ink.faint)
            }
            Text("Anyone who opens your profile can copy a locked note and try passwords on their own computer, which is why a strong password is required. The title is not locked.")
                .font(.system(size: 12)).foregroundStyle(Ink.faint)
        }
    }

    // MARK: Pieces

    private func header(_ title: String) -> some View {
        HStack {
            Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Ink.text)
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(Ink.dim)
        }
    }

    private func box<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .background(Ink.surface, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
    }

    private func field(_ prompt: String, _ binding: Binding<String>) -> some View {
        TextField("", text: binding, prompt: Text(prompt).foregroundStyle(Ink.faint))
            .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(Ink.text)
            .padding(.horizontal, 16).frame(minHeight: 50)
    }

    private func primary(_ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if working { ProgressView().controlSize(.small) }
                Text(label).font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Ink.onAccent).frame(maxWidth: .infinity, minHeight: 48)
            .background(theme.gradient, in: .capsule)
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Actions

    private func unlock() {
        guard let existing, !unlockPassword.isEmpty, !working else { return }
        working = true; problem = nil
        let attempt = unlockPassword
        Task {
            let words = await Task.detached(priority: .userInitiated) { existing.open(password: attempt) }.value
            working = false
            if let words { text = words; password = attempt; needsUnlock = false; unlockPassword = "" }
            else { problem = "That password didn't open it." }
        }
    }

    /// Sealing is slow on purpose, so it runs off the main thread.
    private func commit() {
        guard canSave else { return }
        working = true; problem = nil
        let (title, text, password, locked, id) = (title, text, password, locked, existing?.id ?? ProfileNote.newID())
        Task {
            let made = await Task.detached(priority: .userInitiated) {
                locked ? ProfileNote.lockedNote(id: id, title: title, text: text, password: password)
                       : ProfileNote.publicNote(id: id, title: title, text: text)
            }.value
            working = false
            guard let made else { problem = "That couldn't be saved. Check the title, the text and the password."; return }
            save(made)
            dismiss()
        }
    }
}
