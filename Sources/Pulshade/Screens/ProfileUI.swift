import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// The top of a profile: the banner runs edge to edge and fades into the page, the picture sits half over it in a
/// ring of the person's colour, then the name, @handle and bio.
struct ProfileHero: View {
    @Environment(\.theme) private var theme
    var banner: Data?
    var avatar: Data?
    var seed: String
    var tint: Color
    var name: String
    var badge: Collectible?
    var handle: String?
    var bio: String?
    var verified = false
    var bannerHeight: CGFloat = 150
    @State private var arrived = false

    var body: some View {
        VStack(spacing: 0) {
            Banner(image: banner, seed: seed, height: bannerHeight)
                .overlay {
                    ZStack {
                        RadialGradient(colors: [tint.opacity(0.45), .clear], center: .bottom, startRadius: 0, endRadius: 220)
                        LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: Ink.base.opacity(0.7), location: 0.8),
                                               .init(color: Ink.base, location: 1)], startPoint: .top, endPoint: .bottom)
                    }
                }
                .clipped()
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Avatar(image: avatar, seed: seed, size: 100, showsStory: false)
                    .padding(5)
                    .background(Ink.base, in: .circle)
                    .overlay {
                        Circle().strokeBorder(AngularGradient(colors: [tint, tint.opacity(0.35), tint], center: .center), lineWidth: 3)
                    }
                    .shadow(color: tint.opacity(0.45), radius: 22, y: 4)
                    .scaleEffect(arrived ? 1 : 0.85)
                HStack(spacing: 7) {
                    Text(name)
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(Ink.text)
                        .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.7)
                    BadgeMark(badge: badge, size: 24)
                    if verified {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 16)).foregroundStyle(theme.accent)
                            .accessibilityLabel("Verified in person")
                    }
                }
                if let handle {
                    HStack(spacing: 6) {
                        Text("@\(handle)").font(.system(size: 13, weight: .bold)).foregroundStyle(tint)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(tint.opacity(0.14), in: .capsule)
                            .overlay(Capsule().strokeBorder(tint.opacity(0.3)))
                        if DirectoryProfile.isReserved(handle) {
                            Label("Creator", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Ink.onAccent.opacity(0.85))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(theme.gradient, in: .capsule)
                                .help("This handle can only belong to PULSHADE's creator")
                        }
                    }
                }
                if badge.isModerator { ModeratorTag() }
                if let bio, !bio.isEmpty {
                    Text(LinkPreviews.linked(bio))
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.dim)
                        .tint(tint)
                        .lineSpacing(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 330)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 16)
            .offset(y: -54)
            .padding(.bottom, -54)
        }
        .frame(maxWidth: .infinity)
        .onAppear { withAnimation(.spring(duration: 0.5, bounce: 0.35)) { arrived = true } }
    }
}

/// Someone found by @handle: their whole profile, with one button to add them. A note is optional and tucked away.
struct FoundProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var profile: DirectoryProfile
    var openChat: (Conversation.ID) -> Void

    @State private var addingNote = false
    @State private var note = ""
    @State private var justSent = false
    @State private var reporting: ReportSubject?

    private var tint: Color { Signature.color(profile.color, seed: profile.fingerprint) }
    private var known: Contact? { model.visibleContacts.first { $0.fingerprint == profile.fingerprint } }
    private var requested: Bool { justSent || model.sentRequests.contains { $0.fingerprint == profile.fingerprint } }

    var body: some View {
        VStack(spacing: 18) {
            ProfileHero(banner: profile.banner, avatar: profile.avatar, seed: profile.fingerprint, tint: tint,
                        name: profile.name.isEmpty ? "Anonymous" : profile.name, badge: profile.badge,
                        handle: profile.handle, bio: profile.bio)
            VStack(spacing: 16) {
                if let earlier = model.earlierOwner(of: profile) {
                    Label("@\(profile.handle) used to be \(earlier.displayName). This is a different account.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
                VStack(spacing: 10) {
                    ProfileLinkList(links: profile.links ?? [], tint: tint)
                    ProfileNoteList(notes: profile.notes ?? [], tint: tint)
                }
                if !model.isMine(profile.fingerprint) {
                    Button("Report @\(profile.handle)") {
                        reporting = ReportSubject(key: profile.signingKey, handle: profile.handle, name: profile.name)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Ink.faint)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: 360)
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .sheet(item: $reporting) { ReportSheet(subject: $0) }
        .animation(.snappy, value: requested)
        .animation(.snappy, value: addingNote)
    }

    @ViewBuilder private var actions: some View {
        if model.isMine(profile.fingerprint) {
            Label("That's you", systemImage: "person.crop.circle.badge.checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ink.dim)
        } else if let known {
            wideButton("Message", "bubble.left.fill") {
                let convo = model.startConversation(kind: .direct, title: known.displayName, members: [known.fingerprint])
                openChat(convo.id)
            }
        } else if requested {
            VStack(spacing: 10) {
                Label("Request sent", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(tint.opacity(0.12), in: .capsule)
                    .overlay(Capsule().strokeBorder(tint.opacity(0.3)))
                Text("Once they accept, you're connected and your chat opens. Nothing else to do.")
                    .font(.system(size: 12.5)).foregroundStyle(Ink.faint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 18) {
                    // A request can go missing (a relay restart): sending again gets it there.
                    if !justSent { Button("Send again", action: add) }
                    Button("Cancel request") {
                        model.cancelRequest(to: profile.fingerprint)
                        justSent = false
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ink.dim)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
            VStack(spacing: 10) {
                wideButton("Add friend", "person.crop.circle.badge.plus", action: add)
                if addingNote {
                    TextField("", text: $note, prompt: Text("A note with your request").foregroundStyle(Ink.faint), axis: .vertical)
                        .textFieldStyle(LargeFieldStyle())
                        .lineLimit(1...3)
                        .onSubmit(add)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Button("Add a note") { addingNote = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Ink.dim)
                }
            }
        }
    }

    private func wideButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Ink.onAccent)
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(tint.gradient, in: .capsule)
                .shadow(color: tint.opacity(0.35), radius: 12, y: 4)
                .contentShape(.capsule)
        }
        .buttonStyle(PressScale())
    }

    private func add() {
        guard model.sendRequest(to: profile, note: note) != nil else { return }
        Haptics.tick()
        note = ""
        addingNote = false
        justSent = true
    }
}

/// Opens a found profile on its own page, from the chat list's search.
struct FoundProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    var profile: DirectoryProfile
    var openChat: (Conversation.ID) -> Void

    var body: some View {
        ScrollView {
            FoundProfileView(profile: profile) { id in
                dismiss()
                openChat(id)
            }
            .padding(.bottom, 28)
        }
        .scrollIndicators(.never)
        .background(Ink.base)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 34))
                .padding(14)
                .accessibilityLabel("Close")
        }
        #if os(macOS)
        .frame(width: 440, height: 640)
        #else
        .presentationDragIndicator(.visible)
        #endif
    }
}

extension DirectoryProfile: Identifiable {
    var id: String { handle }
}
