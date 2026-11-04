import Foundation
import CryptoKit
import SwiftUI

/// The code two people compare in person. Both sides derive it from both identities, sorted,
/// so it comes out identical on each screen, and differs if anyone sits in the middle.
struct SafetyCode: Equatable {
    let bytes: [UInt8]

    init(mine: String, theirs: String) {
        bytes = Array(SHA256.hash(data: Data(("pulshade.safety.v1" + [mine, theirs].sorted().joined()).utf8)))
    }

    private static let emojiSet = Array("🌙⭐️🔥🌊⚡️🍀🌸🍄🐺🦊🐙🦋🐝🦉🐬🌵🌈❄️🍒🍋🥑🎧🎲🎯🚀🛸⚓️🔮💎🗝🧲🪐🌋🗻🏝🎈🎸🥁🎺🧩🪁🛹🧊🍩🍿🌶🧀🥨🦖🐉🦄🐢🦜🐠🌻🌴🪸🕯💡📡🛰🧭⏳🔔").map(String.init)

    /// Ten emoji, easy to read out loud: six bits each, sixty in all, far too many for someone in the middle to
    /// find keys that happen to match. They come from their own hash, so they share nothing with the digits.
    var emoji: [String] {
        let source = Array(SHA256.hash(data: Data("pulshade.safety.emoji".utf8) + Data(bytes)))
        let bits = source.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (0..<10).map { Self.emojiSet[Int((bits >> UInt64($0 * 6)) & 63) % Self.emojiSet.count] }
    }

    /// 30 digits in six groups, for anyone who prefers numbers.
    var digits: [String] {
        (0..<6).map { i in
            let v = bytes[6 + i * 4..<10 + i * 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return String(format: "%05u", v % 100_000)
        }
    }

    /// Two colours for the pulse animation, so a mismatch is obvious at a glance.
    var colors: [Color] {
        [Color(hue: Double(bytes[30]) / 255, saturation: 0.75, brightness: 1),
         Color(hue: Double(bytes[31]) / 255, saturation: 0.8, brightness: 0.95)]
    }

    /// What the QR code carries.
    var scanText: String { "pshv1:" + Data(bytes.prefix(20)).hex }
}
