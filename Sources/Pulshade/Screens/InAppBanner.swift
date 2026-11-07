import SwiftUI

/// A message that arrived in another chat while Pulshade is open, shown for a few seconds at the top of the screen.
/// It says as much as your notifications do (Settings → Notifications), and a tap opens the chat.
struct InAppBanner: Identifiable, Equatable {
    let id = UUID()
    var conversation: UUID
    var title: String
    var body: String
    /// The chat's picture, left out when notifications hide who wrote.
    var avatar: Data?
    var seed: String
    var showsAvatar = true
}

extension View {
    /// Shows the model's in-app banner over this view, sliding down from the top.
    func inAppBanners() -> some View { modifier(InAppBannerHost()) }
}

private struct InAppBannerHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let banner = model.inAppBanner {
                InAppBannerView(banner: banner)
                    .id(banner.id)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .frame(maxWidth: 520)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: model.inAppBanner)
    }
}

private struct InAppBannerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var banner: InAppBanner
    @State private var lift: CGFloat = 0

    var body: some View {
        Button {
            model.dismissBanner()
            model.open(banner.conversation)
        } label: {
            HStack(spacing: 11) {
                if banner.showsAvatar {
                    Avatar(image: banner.avatar, seed: banner.seed, size: 36, showsStory: false)
                } else {
                    PulseMark(size: 20).frame(width: 36, height: 36)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(banner.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                    Text(banner.body).font(.system(size: 13)).foregroundStyle(Ink.dim).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The themes' own panel colours, on a solid base: some of them are see-through, and a banner
            // floating over chat text would show it. Same radius and hairline as the app's other cards.
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Ink.void)
                    RoundedRectangle(cornerRadius: 14).fill(Ink.surface)
                    RoundedRectangle(cornerRadius: 14).fill(theme.wash)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.line, lineWidth: 1))
            .shadow(color: .black.opacity(Ink.scheme == .dark ? 0.35 : 0.14), radius: 12, y: 5)
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .offset(y: min(lift, 0))
        // Flick it up to put it away.
        .simultaneousGesture(DragGesture(minimumDistance: 8)
            .onChanged { lift = $0.translation.height }
            .onEnded { drag in
                if drag.translation.height < -20 { model.dismissBanner() } else { withAnimation(.snappy) { lift = 0 } }
            })
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(banner.title): \(banner.body)")
        .accessibilityHint("Opens the chat")
        .accessibilityAddTraits(.isButton)
    }
}
