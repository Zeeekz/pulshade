import SwiftUI

/// Links in chat leave Pulshade (and Tor), so every one of them is confirmed first, with the host it really goes to
/// shown, the same as links on a profile.
extension View {
    /// Asks before opening `url`. Set it to a link to ask; it is cleared when answered.
    func confirmsExternalLink(_ url: Binding<URL?>) -> some View {
        confirmationDialog(LinkPreviews.openable(url.wrappedValue) == nil ? "Link not opened" : "Leave Pulshade?",
                           isPresented: Binding(get: { url.wrappedValue != nil }, set: { if !$0 { url.wrappedValue = nil } }),
                           presenting: url.wrappedValue) { link in
            if let safe = LinkPreviews.openable(link) {
                Button("Open \(safe.host() ?? "link")") { Platform.open(safe) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { link in
            if let safe = LinkPreviews.openable(link) {
                Text("This goes to \(safe.host() ?? "a website"). Pulshade can't protect you there.\n\(String(safe.absoluteString.prefix(120)))")
            } else {
                Text("This isn't a plain web address, so Pulshade won't open it.")
            }
        }
    }

    /// Taps on links inside text (rather than on a button) go through the same question.
    func confirmsLinkTaps() -> some View { modifier(LinkTapGate()) }
}

private struct LinkTapGate: ViewModifier {
    @State private var asking: URL?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                asking = url
                return .handled
            })
            .confirmsExternalLink($asking)
    }
}
