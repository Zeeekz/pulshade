import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Pulshade

/// Pictures are re-encoded before they leave the device. That must drop EXIF and GPS, not just resize.
@Suite struct MediaMetadataTests {
    @Test func cleanedPicturesCarryNoLocationOrExif() throws {
        let width = 16, height = 16
        let pixels = Data(repeating: 200, count: width * height * 4)
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))

        // A JPEG carrying a location and a comment.
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLongitude: -0.12]
        let exif: [CFString: Any] = [kCGImagePropertyExifUserComment: "private"]
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyGPSDictionary: gps,
            kCGImagePropertyExifDictionary: exif,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let original = encoded as Data

        // It really did travel with the metadata.
        let source = try #require(CGImageSourceCreateWithData(original as CFData, nil))
        let before = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(before[kCGImagePropertyGPSDictionary] != nil)
        #expect(before[kCGImagePropertyExifDictionary] != nil)

        // What the app sends has neither.
        let cleaned = try #require(cleanJPEG(PlatformImage.from(cgImage: image), maxSide: 32))
        let cleanedSource = try #require(CGImageSourceCreateWithData(cleaned as CFData, nil))
        let after = (CGImageSourceCopyPropertiesAtIndex(cleanedSource, 0, nil) as? [CFString: Any]) ?? [:]
        #expect(after[kCGImagePropertyGPSDictionary] == nil, "no location")
        let exifAfter = (after[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        #expect(exifAfter[kCGImagePropertyExifUserComment] == nil, "no comment")
        #expect(exifAfter[kCGImagePropertyExifDateTimeOriginal] == nil, "no capture time")
        #expect(exifAfter[kCGImagePropertyExifLensModel] == nil, "no lens")
        #expect(exifAfter[kCGImagePropertyExifBodySerialNumber] == nil, "no camera serial")
    }
}
