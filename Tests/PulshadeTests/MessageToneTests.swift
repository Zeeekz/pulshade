import Testing
import Foundation
@testable import Pulshade

/// The message tones, and the call flag that makes a phone ring instead of showing a banner.
struct MessageToneTests {
    /// The names the relay accepts (relay/src/push.rs, `TONES`): the app has to offer exactly these and no others.
    private let relayTones = ["pulse", "chime", "bubble", "drop", "knock", "tick"]

    @Test func everyToneTheAppOffersIsOneTheRelayAccepts() {
        let offered = MessageTone.allCases.compactMap(\.relayName)
        #expect(Set(offered) == Set(relayTones))
        #expect(MessageTone.standard.relayName == nil && MessageTone.standard.fileName == nil, "the default is the system's own")
    }

    @Test func eachToneIsAShortDistinctSoundTheSystemCanPlay() {
        var seen = Set<Data>()
        for tone in MessageTone.allCases where tone != .standard {
            let wav = tone.wav()
            #expect(wav.prefix(4) == Data("RIFF".utf8) && wav.dropFirst(8).prefix(4) == Data("WAVE".utf8))
            let seconds = Double(tone.samples().count) / Double(MessageTone.sampleRate)
            #expect(seconds > 0.04 && seconds < 2, "\(tone) is \(seconds)s")
            #expect(tone.samples().contains { abs(Int($0)) > 8_000 }, "\(tone) is audible")
            #expect(seen.insert(wav).inserted, "\(tone) differs from the others")
            #expect(tone.wav() == wav, "the same every time")
        }
    }

    @Test func tonesAreWrittenWhereTheSystemLooksAndRewrittenIfChanged() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tones-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        MessageTone.install(into: folder)
        for tone in MessageTone.allCases {
            guard let name = tone.fileName else { continue }
            #expect(name.hasPrefix("tone-") && name.hasSuffix(".wav"))
            #expect(try Data(contentsOf: folder.appendingPathComponent(name)) == tone.wav())
        }
        let url = folder.appendingPathComponent(try #require(MessageTone.chime.fileName))
        try Data("old".utf8).write(to: url)
        MessageTone.install(into: folder)
        #expect(try Data(contentsOf: url) == MessageTone.chime.wav())
    }

    @Test func settingsFromBeforeTonesExistKeepTheDefault() throws {
        let old = try JSONEncoder().encode(SecuritySettings())
        var object = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any])
        object.removeValue(forKey: "messageTone")
        let settings = try JSONDecoder().decode(SecuritySettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(settings.messageTone == .standard)
        object["messageTone"] = "something-from-the-future"
        let odd = try JSONDecoder().decode(SecuritySettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(odd.messageTone == .standard, "an unknown tone falls back instead of failing to open the vault")
        var chosen = SecuritySettings()
        chosen.messageTone = .knock
        let back = try JSONDecoder().decode(SecuritySettings.self, from: JSONEncoder().encode(chosen))
        #expect(back.messageTone == .knock)
    }

    @Test func onlyACallOfferRingsAPhone() {
        let invite = CallInvite(id: UUID(), room: Data(count: 32), key: Data(count: 32))
        #expect(Payload.callOffer(invite).rings)
        #expect(!Payload.callEnd(id: invite.id).rings)
        #expect(!Payload.callAnswer(id: invite.id, accepted: true).rings)
        #expect(!Payload.typing(conversation: nil).rings)
    }
}
