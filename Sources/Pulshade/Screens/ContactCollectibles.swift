import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// What someone owns, on their profile: each collectible with its name and number, and the rare ones marked.
/// Tapping one that has a 3D view opens it. Read-only: you can only wear your own.
struct ContactCollectibles: View {
    @Environment(\.theme) private var theme
    var items: [Collectible]
    var tint: Color
    @State private var viewing: Collectible?

    var body: some View {
        // One entry per number: a profile may name the same one twice.
        let shown = Collectible.unique(items)
        if !shown.isEmpty {
            ExpandableCard(title: "Collectibles", symbol: "sparkles", count: shown.count, startsOpen: true) {
                HStack(spacing: -4) {
                    ForEach(shown.prefix(4)) { item in
                        CollectibleArtwork(item: item.item, size: 26)
                    }
                }
            } content: {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                    ForEach(shown) { item in tile(item) }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity)
            .sheet(item: $viewing) { item in CollectibleViewerSheet(item: item, readOnly: true) }
        }
    }

    private func tile(_ item: Collectible) -> some View {
        let info = item.info
        let opens = info.known
        return Button { if opens { viewing = item } } label: {
            VStack(spacing: 6) {
                CollectibleArtwork(item: item.item, size: 56)
                Text(branded: info.name)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1).minimumScaleFactor(0.8)
                Text("#\(item.serial)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.faint)
                if item.rarity != .common { RarityTag(item: item) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Ink.raised, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(item.rarity == .common ? Ink.line : tint.opacity(0.6)))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(info.name), number \(item.serial)")
    }
}
