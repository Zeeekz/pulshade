import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// The eggs a persona holds, at the top of the Collectibles tab. An egg is started once, takes its kind's time to
/// hatch, then opens on whatever the relay rolled inside: it never says which beforehand.
struct EggsSection: View {
    @Environment(AppModel.self) private var model
    @State private var revealed: Collectible?
    @State private var viewing: RelayClient.EggInfo?

    var body: some View {
        if !model.eggs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Eggs").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(model.eggs) { egg in EggCard(egg: egg, view: { viewing = egg }) { revealed = $0 } }
                }
            }
            .sheet(item: $viewing) { egg in EggSheet(eggID: egg.id) { revealed = $0 } }
            .sheet(item: $revealed) { pet in HatchedSheet(pet: pet) }
        }
    }
}

enum EggNames {
    static func name(_ kind: String) -> String {
        switch kind {
        case "dragon": "Dragon Egg"
        default: "Egg"
        }
    }

    static func minutes(_ seconds: UInt64) -> String {
        seconds >= 3600 ? "\(seconds / 3600) hour\(seconds / 3600 == 1 ? "" : "s")" : "\(max(1, seconds / 60)) minutes"
    }
}

private struct EggCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let egg: RelayClient.EggInfo
    var view: () -> Void
    var opened: (Collectible) -> Void
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = model.secondsLeft(egg, at: context.date)
            let progress = left.map { 1 - $0 / Double(max(egg.seconds, 1)) } ?? 0
            VStack(spacing: 10) {
                Button(action: view) {
                    EggArt(progress: progress, ready: left == 0, started: left != nil)
                        .frame(width: 84, height: 100)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "view.3d").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 22, height: 22).background(.black.opacity(0.45), in: .circle)
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Look at the egg in 3D")
                VStack(spacing: 2) {
                    Text(EggNames.name(egg.kind)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text)
                    Text(status(left)).font(.system(size: 12, weight: .medium)).foregroundStyle(left == 0 ? theme.accent : Ink.faint)
                        .monospacedDigit()
                }
                if left == nil {
                    action("Start hatching") { try await model.startEgg(egg.id) }
                } else if left == 0 {
                    action("Open") { opened(try await model.hatchEgg(egg.id)) }
                }
                if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(.orange) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14).padding(.horizontal, 10)
            .background(Ink.raised, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(left == 0 ? theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
        }
    }

    private func status(_ left: TimeInterval?) -> String {
        guard let left else { return "Takes \(EggNames.minutes(egg.seconds))" }
        if left == 0 { return "Ready to open" }
        let s = Int(left.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func action(_ title: String, _ run: @escaping () async throws -> Void) -> some View {
        Button {
            working = true
            problem = nil
            Task {
                do { try await run() } catch RelayClient.HatchError.notReady {
                    problem = "Not quite ready yet"
                } catch RelayClient.HatchError.soldOut {
                    problem = "Nothing left to hatch from this egg"
                } catch {
                    problem = "Couldn't reach the server"
                }
                working = false
            }
        } label: {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accent)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(theme.accent.opacity(0.14), in: .capsule)
                .opacity(working ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(working)
    }
}

/// An egg that cracks as its time runs out, and wobbles when it's ready.
private struct EggArt: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var progress: Double
    var ready: Bool
    var started: Bool
    @State private var wobble = false

    var body: some View {
        ZStack {
            EggShape()
                .fill(LinearGradient(colors: [theme.accent.opacity(0.95), Color(red: 0.16, green: 0.12, blue: 0.4)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            EggShape().strokeBorder(.white.opacity(0.25), lineWidth: 1.5)
            // Spots.
            GeometryReader { geo in
                ForEach(0..<5, id: \.self) { i in
                    Circle().fill(.white.opacity(0.18))
                        .frame(width: geo.size.width * [0.16, 0.1, 0.13, 0.08, 0.11][i])
                        .position(x: geo.size.width * [0.3, 0.62, 0.45, 0.7, 0.25][i], y: geo.size.height * [0.35, 0.3, 0.62, 0.7, 0.7][i])
                }
            }
            .clipShape(EggShape())
            if started { Cracks(amount: ready ? 1 : max(0, min(progress, 1)) * 0.85).stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)) }
        }
        .shadow(color: theme.accent.opacity(ready ? 0.7 : 0.25), radius: ready ? 14 : 6)
        .rotationEffect(.degrees(ready && wobble ? 5 : ready ? -5 : 0), anchor: .bottom)
        .onAppear {
            guard ready, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.28).repeatForever(autoreverses: true)) { wobble = true }
        }
        .onChange(of: ready) { _, now in
            guard now, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.28).repeatForever(autoreverses: true)) { wobble = true }
        }
    }
}

private struct EggShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        var p = Path()
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + h * 0.62),
                   control1: CGPoint(x: r.midX + w * 0.42, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + h * 0.36))
        p.addCurve(to: CGPoint(x: r.midX, y: r.maxY),
                   control1: CGPoint(x: r.maxX, y: r.minY + h * 0.86), control2: CGPoint(x: r.midX + w * 0.3, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX, y: r.minY + h * 0.62),
                   control1: CGPoint(x: r.midX - w * 0.3, y: r.maxY), control2: CGPoint(x: r.minX, y: r.minY + h * 0.86))
        p.addCurve(to: CGPoint(x: r.midX, y: r.minY),
                   control1: CGPoint(x: r.minX, y: r.minY + h * 0.36), control2: CGPoint(x: r.midX - w * 0.42, y: r.minY))
        return p
    }

    func inset(by amount: CGFloat) -> EggShape { EggShape(inset: inset + amount) }
}

/// A zig-zag crack across the middle, longer as `amount` grows.
private struct Cracks: Shape {
    var amount: Double

    func path(in rect: CGRect) -> Path {
        let points: [CGPoint] = [(0.12, 0.5), (0.26, 0.42), (0.38, 0.56), (0.5, 0.44), (0.62, 0.58), (0.74, 0.45), (0.88, 0.55)]
            .map { CGPoint(x: rect.minX + rect.width * $0.0, y: rect.minY + rect.height * $0.1) }
        var p = Path()
        p.move(to: points[0])
        let upTo = Double(points.count - 1) * amount
        for i in 1..<points.count {
            let t = min(max(upTo - Double(i - 1), 0), 1)
            guard t > 0 else { break }
            let a = points[i - 1], b = points[i]
            p.addLine(to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return p
    }
}

/// What came out of the egg.
struct HatchedSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let pet: Collectible

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Text("It hatched!").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim)
            if let kind = pet.kind { CollectibleIcon(item: kind, size: 200) }
            VStack(spacing: 4) {
                Text(pet.kind?.name ?? pet.item).font(.system(size: 24, weight: .bold)).foregroundStyle(Ink.text)
                RarityTag(item: pet)
                if let kind = pet.kind {
                    Text(branded: kind.blurb).font(.system(size: 13)).foregroundStyle(Ink.faint)
                        .multilineTextAlignment(.center).padding(.top, 4)
                }
            }
            Text("It's yours now. If you already have one, you can gift it to someone, or let it go to go back into circulation, from its page.")
                .font(.system(size: 12)).foregroundStyle(Ink.faint).multilineTextAlignment(.center)
            Spacer(minLength: 0)
            Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.surface)
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 560)
        #endif
    }
}

// MARK: - Gifting and letting go

/// Choose who gets a collectible, then hand it over. They see it the next time their app checks.
struct GiftSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: Collectible
    var done: () -> Void
    @State private var confirming: Contact?
    @State private var working = false
    @State private var problem: String?

    private var contacts: [Contact] {
        model.visibleContacts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        SheetBody(width: 420) {
            VStack(alignment: .leading, spacing: 20) {
                SheetHeader(symbol: "gift.fill", title: "Gift \(item.kind?.name ?? "collectible") #\(item.serial)")
                SettingsGroup(footer: "It moves to them with its number. It leaves your collection, and you can't take it back.") {
                    if contacts.isEmpty { SettingRow("No contacts yet") { EmptyView() } }
                    ForEach(Array(contacts.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { RowDivider(inset: 62) }
                        Button { confirming = c } label: {
                            HStack(spacing: 12) {
                                Avatar(image: c.avatar, seed: c.fingerprint, size: 34)
                                Text(c.displayName).font(.system(size: 15)).foregroundStyle(Ink.text).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.faint)
                            }
                            .padding(.horizontal, 14).frame(minHeight: 52).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(working)
                    }
                }
                if let problem { Text(problem).font(.system(size: 12, weight: .medium)).foregroundStyle(.orange) }
            }
        }
        .confirmationDialog("Give it to \(confirming?.displayName ?? "them")?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            Button("Gift it") {
                guard let c = confirming else { return }
                working = true
                Task {
                    do { try await model.gift(item, to: c); dismiss(); done() }
                    catch { problem = "Couldn't reach the server. Nothing was changed." }
                    working = false
                }
            }
        } message: {
            Text("\(item.kind?.name ?? "It") #\(item.serial) leaves your collection.")
        }
    }
}
