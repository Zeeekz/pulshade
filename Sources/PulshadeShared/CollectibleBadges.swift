import SwiftUI

/// The collectible someone shows after their name, sized to the text beside it.
public struct BadgeMark: View {
    var badge: Collectible?
    var size: CGFloat

    public init(badge: Collectible?, size: CGFloat = 15) {
        self.badge = badge
        self.size = size
    }

    public var body: some View {
        if let badge {
            let name = CollectibleLibrary.shared.info(badge.item).name
            CollectibleArtwork(item: badge.item, size: size)
                .help("\(name) #\(badge.serial)")
                .accessibilityLabel("\(name) number \(badge.serial)")
        }
    }
}

/// A collectible's number, with a flourish for the wanted ones: gold for #1 to #10, violet for numbers with a pattern,
/// silver to #25, and the end of the run.
public struct RarityTag: View {
    var item: Collectible

    public init(item: Collectible) { self.item = item }

    public var body: some View {
        let rarity = item.rarity
        let tint: Color = switch rarity {
        case .first, .topTen: Color(red: 0.98, green: 0.78, blue: 0.30)
        case .special: Color(red: 0.55, green: 0.85, blue: 1)
        case .topTwentyFive: Color(red: 0.72, green: 0.78, blue: 0.90)
        case .last: Color(red: 0.74, green: 0.55, blue: 1)
        case .common: Color.white.opacity(0.42)
        }
        HStack(spacing: 4) {
            if rarity == .first { Image(systemName: "crown.fill").font(.system(size: 9)) }
            else if rarity == .topTen { Image(systemName: "star.fill").font(.system(size: 9)) }
            else if case .special = rarity { Image(systemName: "sparkle").font(.system(size: 9)) }
            Text("#\(item.serial)").font(.system(size: 12, weight: rarity == .common ? .regular : .semibold, design: .monospaced))
            if let name = rarity.name { Text("· \(name)").font(.system(size: 11, weight: .medium)) }
        }
        .foregroundStyle(tint)
        .accessibilityLabel("Number \(item.serial)\(rarity.name.map { ", \($0)" } ?? "")")
    }
}
