import Testing
import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
@testable import Pulshade

/// Nothing sent from Pulshade may carry hidden information about where, when or on what it was made.
struct MetadataTests {
    /// A small photo tagged the way a phone camera tags one: location, camera, time and software.
    private func taggedJPEG() throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try #require(ctx.makeImage())
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5072, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 0.1276, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 16 Pro Max",
                                             kCGImagePropertyTIFFSoftware: "18.0", kCGImagePropertyTIFFDateTime: "2026:10:31 12:00:00"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:31 12:00:00",
                                             kCGImagePropertyExifLensModel: "Main camera"],
        ]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    @Test func photosLoseLocationCameraAndTime() throws {
        let original = try taggedJPEG()
        #expect(try properties(original)[kCGImagePropertyGPSDictionary] != nil, "The test photo starts out tagged")

        let image = try #require(PlatformImage(data: original))
        let cleaned = try #require(cleanJPEG(image, maxSide: 1600))
        let props = try properties(cleaned)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware, kCGImagePropertyTIFFDateTime] {
            #expect(tiff[key] == nil, "TIFF \(key) survived")
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        for key in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifLensModel] {
            #expect(exif[key] == nil, "Exif \(key) survived")
        }
        // The picture itself is still there.
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 64)
        let raw = String(decoding: cleaned, as: UTF8.self)
        #expect(!raw.contains("iPhone") && !raw.contains("Apple") && !raw.contains("2026"))
    }

    @Test func voiceNotesLoseTagsAndTimes() throws {
        // An AAC file written by the system, as the recorder does.
        let dir = testDirectory("voice")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("note.m4a")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                                   AVSampleRateKey: 22_050, AVNumberOfChannelsKey: 1])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050))
            buffer.frameLength = 22_050
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.05)) * 0.3 }
            try file.write(from: buffer)
        }
        let original = try Data(contentsOf: url)
        let cleaned = MP4Scrub.clean(original)
        #expect(original.range(of: Data("udta".utf8)) != nil, "The test file starts out tagged")

        #expect(cleaned.count == original.count, "Nothing is cut out, so offsets stay valid")
        for tag in ["udta", "meta", "ilst", "©too", "©day"] {
            #expect(cleaned.range(of: Data(tag.utf8)) == nil, "\(tag) survived")
        }
        // Creation and modification times in the movie header are zeroed.
        let mvhd = try #require(cleaned.range(of: Data("mvhd".utf8)))
        let version = cleaned[mvhd.upperBound]
        let width = version == 1 ? 8 : 4
        let times = cleaned[(mvhd.upperBound + 4)..<(mvhd.upperBound + 4 + width * 2)]
        #expect(times.allSatisfy { $0 == 0 })
        // It still plays.
        let player = try AVAudioPlayer(data: cleaned)
        #expect(player.duration > 0.9)
    }
}
