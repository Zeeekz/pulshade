import SwiftUI

/// What an empty chat list shows: the two things a new account needs to know. How to add a friend, and that a
/// username is optional. It goes away with the first chat.
struct GettingStartedCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var addFriend: () -> Void
    var chooseUsername: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("No chats yet")
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(Ink.text)
                Text(branded: "PULSHADE needs no phone number or email. You choose who can reach you.")
                    .font(.system(size: 14)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                row(symbol: "person.badge.plus", title: "Add a friend",
                    detail: "Show your code, scan theirs, or find their @username.", action: addFriend)
                RowDivider(inset: 58)
                if let handle = model.activeProfile.handle {
                    row(symbol: "at", title: "You're @\(handle)",
                        detail: "Anyone who knows it can send you a request. You decide whether to accept.",
                        action: chooseUsername)
                } else {
                    row(symbol: "at", title: "Choose a username",
                        detail: "Optional. With one, people can find you by @name. Without one, only people you give your code or link to can reach you.",
                        action: chooseUsername)
                }
            }
            .background(Ink.surface, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.line))
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                Text("Everything you send is end-to-end encrypted.")
            }
            .font(.system(size: 12)).foregroundStyle(Ink.faint)
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
    }

    private func row(symbol: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Ink.onAccent)
                    .frame(width: 32, height: 32)
                    .background(theme.accent.opacity(0.9), in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text)
                    Text(detail).font(.system(size: 13)).foregroundStyle(Ink.dim)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.faint)
                    .padding(.top, 9)
            }
            .padding(12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Usernames on their own, as a sheet: claim one, turn one off, or stay without.
struct UsernameSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SheetBody(width: 460) {
            VStack(spacing: 18) {
                SheetHeader(symbol: "at", title: "Username")
                Text("A username is optional. With one, anyone who knows it can find your profile and send you a request, which you accept or decline. Without one, people add you with your code or link from Add a friend.")
                    .font(.system(size: 13)).foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HandlesEditor()
            }
        }
    }
}
