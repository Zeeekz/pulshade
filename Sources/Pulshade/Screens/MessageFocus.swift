import SwiftUI

/// Holding a message on the phone: it lifts over the blurred chat, with a row of reactions above it and what can be
/// done with it below. The row unfolds into a panel of every emoji, like a page opening out of it.
struct MessageFocus: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Action: Identifiable {
        let id = UUID()
        var title: String
        var symbol: String
        var destructive = false
        var run: () -> Void
    }

    /// Where the message's row is on screen (global coordinates), and how far in from its leading edge the bubble starts.
    var frame: CGRect
    var lead: CGFloat
    var mine: Bool
    /// Your reaction on it now, if any.
    var current: String?
    var canReact: Bool
    var actions: [Action]
    /// The message's row, drawn again over the blur.
    var content: AnyView
    var react: (String) -> Void
    var close: () -> Void

    @State private var shown = false
    @State private var unfolded = false
    @Namespace private var tray

    static let quick = ["❤️", "😂", "🔥", "😮", "😢", "👍"]
    private let barHeight: CGFloat = 50
    private let rowHeight: CGFloat = 44
    private let gap: CGFloat = 8

    var body: some View {
        GeometryReader { outer in
            // The safe area, in global coordinates, is where everything has to fit; drawing covers the whole screen.
            let safe = outer.frame(in: .global)
            let insets = outer.safeAreaInsets
            let screenOrigin = CGPoint(x: safe.minX - insets.leading, y: safe.minY - insets.top)
            let layout = place(in: safe)
            ZStack(alignment: .topLeading) {
                backdrop
                content
                    .frame(width: frame.width, height: layout.rowHeight, alignment: .top)
                    .clipped()
                    .allowsHitTesting(false)
                    .scaleEffect(shown && !reduceMotion ? 1.02 : 1, anchor: mine ? .trailing : .leading)
                    .offset(x: frame.minX - screenOrigin.x, y: (shown ? layout.rowTop : frame.minY) - screenOrigin.y)
                if canReact {
                    reactions(width: layout.trayWidth, panelHeight: layout.panelHeight)
                        .offset(x: layout.trayX - screenOrigin.x, y: layout.trayTop - screenOrigin.y)
                }
                if !actions.isEmpty {
                    menu
                        .frame(width: layout.menuWidth)
                        .offset(x: layout.menuX - screenOrigin.x, y: layout.menuTop - screenOrigin.y)
                        .opacity(shown && !unfolded ? 1 : 0)
                        .scaleEffect(shown && !unfolded ? 1 : 0.6, anchor: mine ? .topTrailing : .topLeading)
                        .allowsHitTesting(!unfolded)
                }
            }
            .frame(width: outer.size.width + insets.leading + insets.trailing,
                   height: outer.size.height + insets.top + insets.bottom, alignment: .topLeading)
            .offset(x: -insets.leading, y: -insets.top)
        }
        .onAppear { withAnimation(.spring(duration: 0.38, bounce: 0.22)) { shown = true } }
        .accessibilityAction(.escape) { dismiss() }
    }

    // MARK: Layout

    private struct Layout {
        var rowTop: CGFloat, rowHeight: CGFloat
        var trayX: CGFloat, trayTop: CGFloat, trayWidth: CGFloat, panelHeight: CGFloat
        var menuX: CGFloat, menuTop: CGFloat, menuWidth: CGFloat
    }

    /// Keeps the message where it was when that leaves room for the reactions above and the actions below; otherwise
    /// moves it as little as it can. A message taller than the room left shows its top.
    private func place(in safe: CGRect) -> Layout {
        let bounds = safe.insetBy(dx: 8, dy: 8)
        let above = canReact ? barHeight + gap : 0
        let below = actions.isEmpty ? 0 : CGFloat(actions.count) * rowHeight + gap
        let rowHeight = max(44, min(frame.height, bounds.height - above - below))
        let rowTop = min(max(frame.minY, bounds.minY + above), bounds.maxY - below - rowHeight)

        let trayWidth = min(bounds.width, unfolded ? 360 : CGFloat(Self.quick.count + 1) * 44 + 12)
        let edge = mine ? frame.maxX - 6 : frame.minX + lead
        let trayX = min(max(mine ? edge - trayWidth : edge, bounds.minX), bounds.maxX - trayWidth)
        let panelHeight = min(340, bounds.height * 0.5)
        var trayTop = rowTop - above
        if unfolded { trayTop = min(trayTop, bounds.maxY - panelHeight) }

        let menuWidth: CGFloat = 230
        let menuX = min(max(mine ? edge - menuWidth : edge, bounds.minX), bounds.maxX - menuWidth)
        return Layout(rowTop: rowTop, rowHeight: rowHeight, trayX: trayX, trayTop: max(bounds.minY, trayTop),
                      trayWidth: trayWidth, panelHeight: panelHeight,
                      menuX: menuX, menuTop: rowTop + rowHeight + gap, menuWidth: menuWidth)
    }

    // MARK: Parts

    private var backdrop: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.25))
            .opacity(shown ? 1 : 0)
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
            .accessibilityLabel("Close")
            .accessibilityAddTraits(.isButton)
    }

    /// The row of reactions, or the panel it unfolds into. Both are drawn on one shape that grows between the two.
    @ViewBuilder private func reactions(width: CGFloat, panelHeight: CGFloat) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: unfolded ? 22 : barHeight / 2, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: unfolded ? 22 : barHeight / 2, style: .continuous).strokeBorder(Ink.line))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                .frame(width: width, height: unfolded ? panelHeight : barHeight)
            if unfolded {
                panel.frame(width: width, height: panelHeight)
                    .transition(.opacity.combined(with: .offset(y: -12)))
            } else {
                bar.frame(width: width, height: barHeight)
                    .transition(.opacity)
            }
        }
        .frame(width: width, alignment: .top)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.5, anchor: mine ? .bottomTrailing : .bottomLeading)
    }

    private var bar: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.quick.enumerated()), id: \.element) { i, e in
                emojiButton(e, size: 26, cell: 44)
                    .scaleEffect(shown || reduceMotion ? 1 : 0.3)
                    .animation(.spring(duration: 0.35, bounce: 0.45).delay(reduceMotion ? 0 : 0.04 * Double(i)), value: shown)
            }
            Button {
                Haptics.tick()
                withAnimation(.spring(duration: 0.42, bounce: 0.18)) { unfolded = true }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Ink.dim)
                    .frame(width: 32, height: 32)
                    .background(Ink.raised, in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More reactions")
        }
        .padding(.horizontal, 6)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Reactions").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim)
                Spacer()
                Button {
                    withAnimation(.spring(duration: 0.38, bounce: 0.15)) { unfolded = false }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Ink.dim)
                        .frame(width: 28, height: 28)
                        .background(Ink.raised, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fewer reactions")
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    ForEach(EmojiSet.groups, id: \.name) { group in
                        SwiftUI.Section {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 8), spacing: 2) {
                                ForEach(group.emoji, id: \.self) { e in emojiButton(e, size: 25, cell: 40) }
                            }
                        } header: {
                            Text(group.name)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Ink.faint)
                                .padding(.horizontal, 6).padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func emojiButton(_ e: String, size: CGFloat, cell: CGFloat) -> some View {
        let on = current == e
        return Button { pick(e) } label: {
            Group {
                if e == "❤️" { PulseHeart(size: size - 2) } else { Text(e).font(.system(size: size)) }
            }
            .frame(width: cell, height: cell)
            .background(on ? theme.accent.opacity(0.22) : .clear, in: .circle)
            .contentShape(Circle())
        }
        .buttonStyle(EmojiPress())
        .accessibilityLabel(on ? "\(e), your reaction" : e)
    }

    private var menu: some View {
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { i, action in
                if i > 0 { Divider().overlay(Ink.line) }
                Button {
                    dismiss(then: action.run)
                } label: {
                    HStack {
                        Text(action.title).font(.system(size: 16))
                        Spacer()
                        Image(systemName: action.symbol).font(.system(size: 15))
                    }
                    .foregroundStyle(action.destructive ? Color.red : Ink.text)
                    .padding(.horizontal, 16)
                    .frame(height: rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    // MARK: Doing

    private func pick(_ e: String) {
        Haptics.tick()
        react(e)
        dismiss()
    }

    /// Settles the message back into the chat, then goes. What was chosen runs once it's gone, so a sheet it opens
    /// doesn't fight the panel closing.
    private func dismiss(then run: (() -> Void)? = nil) {
        withAnimation(.spring(duration: 0.3, bounce: 0.1)) { shown = false; unfolded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            close()
            run?()
        }
    }
}

/// An emoji that pops a little when pressed.
private struct EmojiPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.25 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.5), value: configuration.isPressed)
    }
}

/// The emoji the reaction panel offers, by kind. Any emoji can be a reaction (the apps take whatever comes); these are
/// the ones listed.
enum EmojiSet {
    struct Shelf { var name: String; var emoji: [String] }

    static let groups: [Shelf] = [
        Shelf(name: "Smileys", emoji: Array("😀😃😄😁😆😅🤣😂🙂🙃😉😊😇🥰😍🤩😘😗😚😙😋😛😜🤪😝🤑🤗🤭🤫🤔🤐🤨😐😑😶😏😒🙄😬😮‍💨🤥😌😔😪🤤😴😷🤒🤕🤢🤮🥵🥶🥴😵🤯🤠🥳🥸😎🤓🧐😕😟🙁😮😯😲😳🥺😦😧😨😰😥😢😭😱😖😣😞😓😩😫🥱😤😡😠🤬😈👿💀☠️💩🤡👻👽🤖").map(String.init).filter { !$0.isEmpty }),
        Shelf(name: "Gestures", emoji: ["👍", "👎", "👏", "🙌", "👐", "🤝", "🙏", "✌️", "🤞", "🤟", "🤘", "👌", "🤌", "🤏", "👈", "👉", "👆", "👇", "☝️", "✋", "🤚", "🖐️", "🖖", "👋", "🤙", "💪", "🫶", "👀", "🫡", "🤷", "🤦", "🙇"]),
        Shelf(name: "Hearts", emoji: ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "❤️‍🔥", "❤️‍🩹", "💕", "💞", "💓", "💗", "💖", "💘", "💝", "💯", "💢", "💥", "💫", "💦", "💨", "🔥", "✨", "⭐", "🌟", "⚡", "🎉", "🎊"]),
        Shelf(name: "Animals and nature", emoji: ["🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🙈", "🙉", "🙊", "🐔", "🐧", "🐦", "🦄", "🐝", "🦋", "🐢", "🐍", "🐙", "🦈", "🐳", "🌸", "🌹", "🌻", "🌈", "☀️", "🌙", "❄️"]),
        Shelf(name: "Food and drink", emoji: ["🍎", "🍓", "🍑", "🍒", "🍌", "🍉", "🍇", "🥑", "🌶️", "🍕", "🍔", "🍟", "🌮", "🍣", "🍜", "🍩", "🍪", "🎂", "🍰", "🍫", "🍿", "☕", "🍵", "🍺", "🍻", "🥂", "🍷", "🥃"]),
        Shelf(name: "Activity and things", emoji: ["⚽", "🏀", "🏈", "🎾", "🎮", "🎯", "🎲", "🏆", "🥇", "🎵", "🎶", "🎧", "🎤", "🎸", "📸", "🎬", "💡", "💰", "💎", "🎁", "🔒", "🔑", "🛡️", "🚀", "✈️", "🚗", "🏠", "⏰", "📌", "📎", "✅", "❌", "❓", "❗", "⚠️", "🆗", "🆒", "🆕"]),
    ]
}
