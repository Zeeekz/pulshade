import SwiftUI
import ImageIO
import Observation

/// The collectibles list this app has checked, and the pictures it names, held in memory for every view to draw from.
/// The app fills it from its sealed copy at unlock and whenever the relay has a newer list; Pulshade Admin fills it
/// with the list it is editing, to preview. Empty, only the built-in collectibles have pictures.
@MainActor @Observable
public final class CollectibleLibrary {
    public static let shared = CollectibleLibrary()

    public private(set) var catalog: CollectibleCatalog?
    /// Pictures by SHA-256 hex, each already checked against the list.
    @ObservationIgnored private var art: [String: Data] = [:]
    /// Who put the list here, so only it takes it away again (tests run several accounts in one process).
    @ObservationIgnored private var installedBy: ObjectIdentifier?

    public init() {}

    /// Takes a list and its pictures. Pictures that don't match it are left out (their items show the placeholder).
    public func install(_ catalog: CollectibleCatalog, art: [String: Data], by owner: AnyObject? = nil) {
        var kept: [String: Data] = [:]
        for item in catalog.items where kept[item.art.sha256] == nil {
            if let data = art[item.art.sha256], (try? CollectibleCatalog.checkArt(data, against: item.art)) != nil {
                kept[item.art.sha256] = data
            }
        }
        self.art = kept
        self.catalog = catalog
        installedBy = owner.map(ObjectIdentifier.init)
        CatalogFrames.shared.removeAll()
    }

    /// Forgets the list, on Burn, Detach or when an account locks. With `owner`, only if it was the one that put it here.
    public func clear(by owner: AnyObject? = nil) {
        if let owner, let installedBy, installedBy != ObjectIdentifier(owner) { return }
        installedBy = nil
        art = [:]
        catalog = nil
        CatalogFrames.shared.removeAll()
    }

    public func item(_ id: String) -> CollectibleCatalog.Item? { catalog?.item(id) }

    public func artData(_ item: CollectibleCatalog.Item) -> Data? { art[item.art.sha256] }

    /// Whether every picture the list names is here.
    public var hasAllArt: Bool { catalog?.items.allSatisfy { art[$0.art.sha256] != nil } ?? true }

    /// Everything a screen needs to show `item`, whether this build draws it, the list has it, or neither (yet).
    public func info(_ item: String) -> CollectibleInfo {
        if let kind = Collectible.Kind(rawValue: item) {
            return CollectibleInfo(item: item, name: kind.name, blurb: kind.blurb, category: kind.category,
                                   transferable: kind.transferable, kind: kind, listed: nil)
        }
        if let listed = self.item(item) {
            return CollectibleInfo(item: item, name: listed.name, blurb: listed.blurb, category: listed.category.kindCategory,
                                   transferable: listed.transferable, kind: nil, listed: listed)
        }
        return CollectibleInfo(item: item, name: CollectibleInfo.unknownName, blurb: CollectibleInfo.unknownBlurb,
                               category: .items, transferable: false, kind: nil, listed: nil)
    }
}

/// A collectible as a screen shows it.
public struct CollectibleInfo: Equatable {
    public var item: String
    public var name: String
    public var blurb: String
    public var category: Collectible.Kind.Category
    public var transferable: Bool
    /// Set when this build draws it itself.
    public var kind: Collectible.Kind?
    /// Set when it comes from the collectibles list.
    public var listed: CollectibleCatalog.Item?

    /// Neither drawn by this build nor in the list it has: shown with a placeholder until the list arrives.
    public var known: Bool { kind != nil || listed != nil }

    public static let unknownName = "New collectible"
    public static let unknownBlurb = "Its picture hasn't arrived yet. It shows once Pulshade has fetched the latest collectibles."
}

extension Collectible {
    /// Name, words and picture, from this build or the collectibles list.
    @MainActor public var info: CollectibleInfo { CollectibleLibrary.shared.info(item) }
}

/// Any collectible's picture: drawn by this build, played from the list's animated PNG, or a plain placeholder.
public struct CollectibleArtwork: View {
    var item: String
    var size: CGFloat

    public init(item: String, size: CGFloat) {
        self.item = item
        self.size = size
    }

    public var body: some View {
        if let kind = Collectible.Kind(rawValue: item) {
            CollectibleIcon(item: kind, size: size)
        } else if let listed = CollectibleLibrary.shared.item(item), let data = CollectibleLibrary.shared.artData(listed) {
            CatalogArt(art: listed.art, data: data, size: size)
                .accessibilityLabel(listed.name)
        } else {
            CollectiblePlaceholder(size: size)
        }
    }
}

/// What stands in for a collectible whose picture this app doesn't have yet.
public struct CollectiblePlaceholder: View {
    var size: CGFloat

    public init(size: CGFloat) { self.size = size }

    public var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .frame(width: size, height: size)
        .accessibilityLabel(CollectibleInfo.unknownName)
    }
}

/// A list picture, played round every `art.loop` seconds at the display's rate, or still on its first frame when the
/// system asks for less motion.
public struct CatalogArt: View {
    var art: CollectibleCatalog.Art
    var data: Data
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var scale

    public init(art: CollectibleCatalog.Art, data: Data, size: CGFloat) {
        self.art = art
        self.data = data
        self.size = size
    }

    public var body: some View {
        Group {
            if art.frames == 1 || reduceMotion {
                frame(0)
            } else {
                TimelineView(.animation) { context in
                    frame(CatalogFrames.index(at: context.date, art: art))
                }
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private func frame(_ index: Int) -> some View {
        if let image = CatalogFrames.shared.frame(art: art, data: data, index: index, pixels: Int(size * scale)) {
            Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            CollectiblePlaceholder(size: size)
        }
    }
}

/// Decoded frames of list pictures, made at the size they're drawn and kept within a memory budget: a picture of 72
/// frames at full size would be 75 MB if every frame were kept, so frames are decoded as they're needed and the
/// least used ones go first.
public final class CatalogFrames: @unchecked Sendable {
    public static let shared = CatalogFrames()

    private let cache = NSCache<NSString, CGImage>()
    private let lock = NSLock()
    private var sources: [String: CGImageSource] = [:]

    public init() {
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    /// The frame to show at `date`: the same moment of the loop on every screen.
    public static func index(at date: Date, art: CollectibleCatalog.Art) -> Int {
        guard art.frames > 1, art.loop > 0 else { return 0 }
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: art.loop) / art.loop
        return min(art.frames - 1, max(0, Int(t * Double(art.frames))))
    }

    /// Frame `index` no bigger than `pixels` across (sizes are rounded up to a few steps, so nearby sizes share frames).
    public func frame(art: CollectibleCatalog.Art, data: Data, index: Int, pixels: Int) -> CGImage? {
        let side = max(art.width, art.height)
        let step = [64, 128, 256, 512].first { $0 >= pixels } ?? 512
        let target = min(side, step)
        let key = "\(art.sha256)/\(index)/\(target)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        lock.lock()
        let source: CGImageSource? = sources[art.sha256] ?? {
            let made = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
            sources[art.sha256] = made
            return made
        }()
        lock.unlock()
        guard let source, index < CGImageSourceGetCount(source) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    public func removeAll() {
        cache.removeAllObjects()
        lock.lock()
        sources = [:]
        lock.unlock()
    }
}
