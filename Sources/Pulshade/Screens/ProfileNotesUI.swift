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
                        Image(systemName: Self.symbol(note))
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

    private static func symbol(_ note: ProfileNote) -> String {
        note.isLocked ? "lock.fill" : note.isRestricted ? "person.fill.checkmark" : "doc.text.fill"
    }

    private func row(_ note: ProfileNote) -> some View {
        Button { reading = note } label: {
            HStack(spacing: 14) {
                Image(systemName: Self.symbol(note))
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
            if note.restricted == true {
                Label("Access Granted", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.green)
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
            if let problem { ProblemText(problem) }
            Button(action: tryOpen) {
                HStack(spacing: 8) {
                    if working { ProgressView().controlSize(.small) }
                    Text(working ? "Unlocking…" : "Unlock").font(.system(size: 16, weight: .semibold))
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

/// Write or change a note: a title, the words (typed, or read from a text file), and whether to lock it.
struct NoteEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var model
    var existing: ProfileNote?
    var save: (ProfileNote) -> Void
    @State private var title = ""
    @State private var text = ""
    @State private var locked = false
    /// Sent only to the contacts picked here (fingerprints), with no password.
    @State private var forContacts = false
    @State private var chosen: Set<String> = []
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
            && (!forContacts || !chosen.isEmpty)
    }

    /// Everyone the active account could send a note to.
    private var people: [Contact] {
        model.visibleContacts.filter { !$0.isSelf }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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
            if let list = existing.sharedWith { forContacts = true; chosen = Set(list) }
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
            if let problem { ProblemText(problem) }
            primary(working ? "Unlocking…" : "Unlock", enabled: !unlockPassword.isEmpty && !working, action: unlock)
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
                    VStack(spacing: 0) {
                        HStack {
                            Label("Lock with a password", systemImage: "lock.fill").font(.system(size: 15)).foregroundStyle(Ink.text)
                            Spacer()
                            Toggle("Lock with a password", isOn: Binding(get: { locked }, set: { on in
                                withAnimation(.snappy) { locked = on; if on { forContacts = false } }
                            })).toggleStyle(GlowToggleStyle())
                        }
                        .padding(.horizontal, 16).frame(minHeight: 50)
                        Divider().overlay(Ink.line)
                        HStack {
                            Label("Only some contacts", systemImage: "person.2.fill").font(.system(size: 15)).foregroundStyle(Ink.text)
                            Spacer()
                            Toggle("Only some contacts", isOn: Binding(get: { forContacts }, set: { on in
                                withAnimation(.snappy) { forContacts = on; if on { locked = false } }
                            })).toggleStyle(GlowToggleStyle())
                        }
                        .padding(.horizontal, 16).frame(minHeight: 50)
                    }
                }
                if locked { lockOptions }
                if forContacts { contactOptions }
                if let problem { ProblemText(problem) }
                primary(working ? "Saving…" : "Save", enabled: canSave, action: commit)
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
            if let passwordProblem { ProblemText(passwordProblem) }
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
                Text("Pulshade can't recover this password. Keep it safe.")
                    .font(.system(size: 12)).foregroundStyle(Ink.faint)
            }
            Text("Use a strong password. The title isn't locked.")
                .font(.system(size: 12)).foregroundStyle(Ink.faint)
        }
    }

    /// Choose who is sent the note. They read it with no password, because nobody else is ever sent it.
    private var contactOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if people.isEmpty {
                Text("You have no contacts yet. Add someone first, then choose them here.")
                    .font(.system(size: 13)).foregroundStyle(Ink.dim)
            } else {
                box {
                    VStack(spacing: 0) {
                        ForEach(Array(people.enumerated()), id: \.element.fingerprint) { i, person in
                            if i > 0 { Divider().overlay(Ink.line).padding(.leading, 16) }
                            Button {
                                if chosen.contains(person.fingerprint) { chosen.remove(person.fingerprint) } else { chosen.insert(person.fingerprint) }
                            } label: {
                                HStack(spacing: 12) {
                                    Text(person.displayName).font(.system(size: 15)).foregroundStyle(Ink.text).lineLimit(1)
                                    Spacer()
                                    Image(systemName: chosen.contains(person.fingerprint) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundStyle(chosen.contains(person.fingerprint) ? theme.accent : Ink.faint)
                                }
                                .padding(.horizontal, 16).frame(minHeight: 46).contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(person.displayName)
                            .accessibilityValue(chosen.contains(person.fingerprint) ? "Selected" : "Not selected")
                        }
                    }
                }
                Text(chosen.isEmpty ? "Pick at least one contact." : chosen.count == 1 ? "1 contact will be able to read this." : "\(chosen.count) contacts will be able to read this.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(chosen.isEmpty ? Color.orange : Ink.dim)
            }
            Text("Only the contacts you pick get this note, inside your encrypted chat. Removing someone hides it, but not what they already read.")
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
        let audience = forContacts ? Array(chosen) : nil
        Task {
            let made = await Task.detached(priority: .userInitiated) {
                if let audience { return ProfileNote.contactsNote(id: id, title: title, text: text, contacts: audience) }
                return locked ? ProfileNote.lockedNote(id: id, title: title, text: text, password: password)
                              : ProfileNote.publicNote(id: id, title: title, text: text)
            }.value
            working = false
            guard let made else { problem = "That couldn't be saved. Check the title, the text and the password."; return }
            save(made)
            dismiss()
        }
    }
}
