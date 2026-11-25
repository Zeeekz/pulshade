import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a file sent through the file picker gives away besides its contents, taken out where Pulshade can: a picture's
/// hidden details (where it was taken, the camera or phone, when, the software) and the file's own name. Everything here
/// works in memory; nothing is written to disk.
enum FileScrub {
    /// What kind of file it is, as far as hidden details go.
    enum Kind: Equatable {
        /// A picture whose details Pulshade removes (JPEG, HEIC, PNG, GIF, TIFF and the like).
        case image
        /// A document, video or other file that can carry details of its own (an author, edit history, a location) that
        /// Pulshade can't remove: the person is told before it goes.
        case mayCarryDetails
        /// Plain text and the like, which have nowhere to keep any.
        case plain
    }

    static func kind(of type: UTType?) -> Kind {
        guard let type else { return .mayCarryDetails }
        if type.conforms(to: .image), canRewrite(type) { return .image }
        if type.conforms(to: .plainText) || type.conforms(to: .commaSeparatedText) { return .plain }
        return .mayCarryDetails
    }

    /// Whether ImageIO can write this kind of picture again.
    static func canRewrite(_ type: UTType) -> Bool {
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return writable.contains(type.identifier)
    }

    /// The picture's frames written again with only what's needed to show them: which way up it goes, and for an animation
    /// its timing. Location, camera, dates, software, maker notes and the rest are left behind. Nil if it can't be read.
    static func stripImage(_ data: Data, type: UTType) -> Data? {
        guard canRewrite(type), let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, count, nil) else { return nil }
        // The whole file's own details (a GIF's loop count is the one worth keeping).
        if let file = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
           let gif = file[kCGImagePropertyGIFDictionary] as? [CFString: Any], let loops = gif[kCGImagePropertyGIFLoopCount] {
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loops]] as CFDictionary)
        }
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
            let found = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            var kept: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
            if let orientation = found[kCGImagePropertyOrientation] { kept[kCGImagePropertyOrientation] = orientation }
            if let gif = found[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                var timing: [CFString: Any] = [:]
                for key in [kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime] { if let v = gif[key] { timing[key] = v } }
                if !timing.isEmpty { kept[kCGImagePropertyGIFDictionary] = timing }
            }
            if let png = found[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
                var timing: [CFString: Any] = [:]
                for key in [kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGUnclampedDelayTime] { if let v = png[key] { timing[key] = v } }
                if !timing.isEmpty { kept[kCGImagePropertyPNGDictionary] = timing }
            }
            CGImageDestinationAddImage(destination, image, kept as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// The name a file goes with when its own isn't kept: what it is, and its extension, nothing of what it was called.
    static func neutralName(for url: URL, type: UTType?) -> String {
        let ext = url.pathExtension.isEmpty ? (type?.preferredFilenameExtension ?? "") : url.pathExtension.lowercased()
        let stem: String
        if let type, type.conforms(to: .image) { stem = "photo" }
        else if let type, type.conforms(to: .movie) || type.conforms(to: .video) { stem = "video" }
        else if let type, type.conforms(to: .audio) { stem = "audio" }
        else if let type, type.conforms(to: .pdf) { stem = "document" }
        else { stem = "file" }
        // Only an extension made of plain letters and digits: never anything that could pass for more of a name.
        let safe = ext.count <= 8 && !ext.isEmpty && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return safe ? "\(stem).\(ext)" : stem
    }
}
