import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// Everyone you know, in one place: search them, find new people by @handle, and answer requests.
struct ContactsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var openChat: (Conversation.ID) -> Void

    @State private var query = ""
    @State private var searching = false
    @State private var found: DirectoryProfile?
    @State private var notFound = false
    @State private var problem: String?
    @State private var note = ""
    @State private var sent = false
    @State private var reporting: ReportSubject?
    @State private var reportingSomeone = false
    @State private var removing: Contact?
    /// Searching @abuse, @report or @safety shows the Pulshade Safety contact instead of a lookup.
    @State private var safety = false
    /// A profile link filled in the search: look it up once the field has taken it.
    @State private var lookUpWhenFilled = false
    /// From a profile link: the handle and the key check its profile has to match.
    @State private var linkCheck: (handle: String, keyCheck: String)?

    /// What's typed, as a handle: "@Nova" and "nova" both look up "nova".
    private var handle: String? { DirectoryProfile.validHandle(query) }

    private var contacts: [Contact] {
        let all = model.visibleContacts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let text = query.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !text.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(text) || $0.name.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 8) {
                    Text("Contacts").font(.system(size: 20, weight: .bold)).foregroundStyle(Ink.text)
                    if !model.requests.isEmpty {
                        Text("\(model.requests.count)")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(Ink.onAccent)
                            .padding(.horizontal, 8).frame(height: 20).background(theme.accent, in: .capsule)
                    }
                    Spacer()
                }
                searchField
                if safety { safetyCard }
                if found != nil || notFound || problem != nil { lookupResult }
                if !model.requests.isEmpty && query.isEmpty { requestsSection }
                if !model.sentRequests.isEmpty && query.isEmpty { waitingSection }
                contactsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, Platform.isPhone ? 12 : 40)
            .padding(.bottom, 24)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .sheet(item: $reporting) { ReportSheet(subject: $0) }
        .sheet(isPresented: $reportingSomeone) { ReportSheet(subject: nil) }
        .animation(.snappy, value: found)
        .animation(.snappy, value: notFound)
        .animation(.snappy, value: model.requests.count)
        .onChange(of: model.openedHandle, initial: true) { _, opened in
            guard let opened else { return }
            model.openedHandle = nil
            linkCheck = model.openedKeyCheck.map { (opened, $0) }
            model.openedKeyCheck = nil
            if query == "@" + opened { search() } else { lookUpWhenFilled = true; query = "@" + opened }
        }
    }

    // MARK: Search

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Ink.faint)
                TextField("", text: $query, prompt: Text("Search contacts or find @handle").foregroundStyle(Ink.faint))
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.text)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .onSubmit(search)
                    .onChange(of: query) {
                        found = nil; notFound = false; problem = nil; sent = false; safety = false
                        if lookUpWhenFilled { lookUpWhenFilled = false; search() }
                    }
                if searching { ProgressView().controlSize(.small) }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.faint) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Ink.surface, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line))
            if let handle, found == nil, !notFound, problem == nil, !safety {
                Button(action: search) {
                    HStack(spacing: 10) {
                        Image(systemName: "at").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(theme.accent.opacity(0.85), in: .rect(cornerRadius: 8))
                        Text("Find @\(handle)").font(.system(size: 15)).foregroundStyle(Ink.text)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.faint)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 50)
                    .background(Ink.surface, in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(searching)
            }
        }
    }

    @ViewBuilder private var lookupResult: some View {
        if let found {
            VStack(spacing: 14) {
                ProfileCard(profile: found)
                if let earlier = model.earlierOwner(of: found) {
                    Label("@\(found.handle) used to be \(earlier.displayName). This is a different account.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.isMine(found.fingerprint) {
                    Label("That's you", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Ink.dim)
                } else if let known = model.visibleContacts.first(where: { $0.fingerprint == found.fingerprint }) {
                    Button { message(known) } label: { Label("Message", systemImage: "bubble.left.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                } else if sent || model.sentRequests.contains(where: { $0.fingerprint == found.fingerprint }) {
                    Label("Request sent", systemImage: "paperplane.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.accent)
                    // A request can go missing (a relay restart), or they may still think you're friends:
                    // sending it again gets it there, and an existing friend reconnects straight away.
                    if !sent {
                        Button("Send again", action: request)
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Ink.dim)
                    }
                } else {
                    TextField("", text: $note, prompt: Text("Add a note (optional)").foregroundStyle(Ink.faint))
                        .textFieldStyle(LargeFieldStyle())
                        .onSubmit(request)
                    Button(action: request) { Label("Send request", systemImage: "person.crop.circle.badge.plus") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                if !model.isMine(found.fingerprint) {
                    Button("Report @\(found.handle)") {
                        reporting = ReportSubject(key: found.signingKey, handle: found.handle, name: found.name)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Ink.faint)
                }
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        } else if notFound {
            Text("No one has @\(handle ?? query). Handles are exact, so check the spelling.")
                .font(.system(size: 13)).foregroundStyle(Ink.dim)
        } else if let problem {
            Text(branded: problem).font(.system(size: 13, weight: .medium)).foregroundStyle(.orange)
        }
    }

    /// Pulshade's own safety contact: the way to report someone.
    private var safetyCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                PulseMark(size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(branded: "PULSHADE Safety").font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.text)
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 13)).foregroundStyle(theme.accent)
                    }
                    Text("@\(handle ?? "abuse")").font(.system(size: 13)).foregroundStyle(theme.accent)
                    Text("Report spam, harassment, impersonation or anything else that breaks the rules.")
                        .font(.system(size: 13)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Button { reportingSomeone = true } label: { Label("Report someone", systemImage: "flag.fill") }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(16)
        .background(Ink.surface, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.line))
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private func search() {
        guard let handle, !searching else { return }
        if DirectoryProfile.reportHandles.contains(handle) {
            withAnimation(.snappy) { safety = true }
            return
        }
        searching = true
        Task {
            do {
                found = try await model.findProfile(query)
                notFound = found == nil
                problem = nil
                if let check = linkCheck, check.handle == handle, let profile = found, !profile.matches(keyCheck: check.keyCheck) {
                    // The name is listed by an account other than the one the link was made for.
                    found = nil
                    problem = "This link was for a different account than the one using @\(handle) now"
                }
            } catch AppModel.DirectoryError.invalidHandle {
                problem = "Handles are letters, numbers or _"
            } catch AppModel.DirectoryError.unreachable {
                problem = "Can't reach the relay"
            } catch {
                problem = "That profile didn't check out"
            }
            searching = false
        }
    }

    private func request() {
        guard let found, model.sendRequest(to: found, note: note) != nil else { return }
        note = ""
        withAnimation(.snappy) { sent = true }
    }

    // MARK: Lists

    private var requestsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Requests")
            ForEach(model.requests) { r in
                RequestRow(request: r,
                           accept: { if let c = model.acceptRequest(r.id) { openChat(c.id) } },
                           decline: { model.declineRequest(r.id) },
                           block: { model.blockRequest(r.id) },
                           report: { reporting = ReportSubject(key: r.card.signingKey, handle: nil, name: r.card.name) })
                    .transition(.asymmetric(insertion: .scale.combined(with: .opacity),
                                            removal: .move(edge: .trailing).combined(with: .opacity)))
            }
        }
    }

    private var waitingSection: some View {
        SettingsGroup("Waiting for them to accept") {
            ForEach(Array(model.sentRequests.enumerated()), id: \.element.id) { i, c in
                if i > 0 { RowDivider(inset: 66) }
                ContactRow(contact: c, detail: "Request sent")
                    .opacity(0.75)
            }
        }
    }

    @ViewBuilder private var contactsSection: some View {
        if contacts.isEmpty {
            VStack(spacing: 10) {
                Constellation(symbol: "person.2", text: query.isEmpty ? "No contacts yet" : "No contacts match")
                if query.isEmpty {
                    Text("Find people by their @handle above, or share your invite code from the Invite tab.")
                        .font(.system(size: 12)).foregroundStyle(Ink.faint)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 30)
        } else {
            SettingsGroup(query.isEmpty ? "\(contacts.count) contacts" : "Matching contacts") {
                ForEach(Array(contacts.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { RowDivider(inset: 66) }
                    Button { message(c) } label: { ContactRow(contact: c, detail: nil) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Message", systemImage: "bubble.left") { message(c) }
                            Button("Remove contact", systemImage: "person.badge.minus", role: .destructive) { removing = c }
                        }
                }
            }
            .confirmationDialog(removing.map(RemoveContact.title) ?? "", isPresented: Binding(get: { removing != nil },
                                                                                          set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { c in
                Button("Remove", role: .destructive) { model.removeContact(c.fingerprint, persona: c.persona) }
            } message: { _ in
                Text(RemoveContact.detail)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium))
            .tracking(0.4)
            .foregroundStyle(Ink.faint)
            .padding(.leading, 14)
    }

    /// Opens your chat with them, starting one if there isn't one yet.
    private func message(_ contact: Contact) {
        let convo = model.startConversation(kind: .direct, title: contact.displayName, members: [contact.fingerprint])
        openChat(convo.id)
    }
}

/// What removing a contact does, in plain words.
enum RemoveContact {
    static func title(_ contact: Contact) -> String { "Remove \(contact.displayName)?" }
    static let detail = "They're taken out of your contacts on all your devices, and your chat is deleted for both of you. "
        + "They can only reach you again with a new invite or request."
}

/// A person in your contacts: picture, name, and a verified tick once you've compared safety numbers.
private struct ContactRow: View {
    @Environment(\.theme) private var theme
    var contact: Contact
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Avatar(image: contact.avatar, seed: contact.fingerprint, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(contact.displayName).font(.system(size: 15)).foregroundStyle(Ink.text).lineLimit(1)
                    BadgeMark(badge: contact.badge, size: 15)
                    if contact.verified {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(theme.accent)
                    }
                }
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Ink.faint)
                } else if !contact.nickname.isEmpty, contact.nickname != contact.name, !contact.name.isEmpty {
                    Text(contact.name).font(.system(size: 12)).foregroundStyle(Ink.faint)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
        .contentShape(.rect)
    }
}

/// Someone's public profile: art, name, bio and handle.
private struct ProfileCard: View {
    @Environment(\.theme) private var theme
    var profile: DirectoryProfile

    var body: some View {
        let tint = Signature.color(profile.color, seed: profile.fingerprint)
        VStack(spacing: 12) {
            VStack(spacing: -48) {
                Banner(image: profile.banner, seed: profile.fingerprint, height: 110)
                Avatar(image: profile.avatar, seed: profile.fingerprint, size: 96)
                    .overlay(Circle().strokeBorder(tint, lineWidth: 3).padding(-5))
                    .shadow(color: tint.opacity(0.6), radius: 24)
            }
            HStack(spacing: 6) {
                Text(profile.name.isEmpty ? "Anonymous" : profile.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Ink.text)
                BadgeMark(badge: profile.badge, size: 20)
            }
            HStack(spacing: 6) {
                Text("@\(profile.handle)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
                if profile.isCreator {
                    Label("Creator", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Ink.onAccent.opacity(0.85))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(theme.gradient, in: .capsule)
                        .help("This handle can only belong to PULSHADE's creator")
                }
            }
            if !profile.bio.isEmpty {
                Text(LinkPreviews.linked(profile.bio))
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.dim)
                    .tint(tint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            ProfileLinkList(links: profile.links ?? [], tint: tint)
            ProfileNoteList(notes: profile.notes ?? [], tint: tint)
        }
        .padding(24)
        .frame(maxWidth: Platform.isPhone ? .infinity : 340)
        .glass(14)
    }
}

private struct RequestRow: View {
    @Environment(\.theme) private var theme
    var request: FriendRequest
    var accept: () -> Void
    var decline: () -> Void
    var block: () -> Void
    var report: () -> Void

    var body: some View {
        let tint = Signature.color(request.card.color, seed: request.fingerprint)
        HStack(alignment: .top, spacing: 14) {
            Avatar(image: request.card.avatar, seed: request.fingerprint, size: 48)
                .overlay(Circle().strokeBorder(tint, lineWidth: 2).padding(-3))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(request.card.name.isEmpty ? "Anonymous" : request.card.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Ink.text)
                    Spacer()
                    Text(request.receivedAt.chatStamp).font(.system(size: 11)).foregroundStyle(Ink.faint)
                }
                if !request.note.isEmpty {
                    Text(request.note)
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.dim)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Ink.raised.opacity(0.7), in: .rect(cornerRadius: 12))
                }
                HStack(spacing: 8) {
                    Button(action: accept) {
                        Label("Accept", systemImage: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Ink.onAccent.opacity(0.85))
                            .padding(.horizontal, 14).frame(height: 30)
                            .background(theme.gradient, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    Button(action: decline) { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 30))
                        .help("Decline")
                        .accessibilityLabel("Decline")
                    Button(action: block) { Image(systemName: "hand.raised.fill") }
                        .buttonStyle(IconButtonStyle(size: 30))
                        .help("Block: their requests vanish silently")
                        .accessibilityLabel("Block")
                    Button(action: report) { Image(systemName: "flag.fill") }
                        .buttonStyle(IconButtonStyle(size: 30))
                        .help("Report to the PULSHADE team")
                        .accessibilityLabel("Report")
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .glass(14)
    }
}
