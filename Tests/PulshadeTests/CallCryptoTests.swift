import Testing
import Foundation
@testable import Pulshade

struct CallCryptoTests {
    @Test func packetsOpenOnlyForTheOtherSideOnceEach() throws {
        let key = Data.random(32)
        var caller = CallCrypto(key: key, caller: true)
        var callee = CallCrypto(key: key, caller: false)
        let first = caller.seal(.audio, Data("voice".utf8))
        let packet = try #require(first)
        #expect(packet.range(of: Data("voice".utf8)) == nil, "nothing readable on the wire")
        let opened = callee.open(packet)
        #expect(opened?.0 == .audio && opened?.1 == Data("voice".utf8))
        let replay = callee.open(packet)
        #expect(replay == nil, "a replayed packet is refused")

        var echo = CallCrypto(key: key, caller: true)
        let own = echo.open(packet)
        #expect(own == nil, "your own packets don't open as theirs")
        let second = caller.seal(.audio, Data("more".utf8))
        let again = try #require(second)
        var stranger = CallCrypto(key: .random(32), caller: false)
        let foreign = stranger.open(again)
        #expect(foreign == nil, "another call's key can't open it")
        var tampered = again
        tampered[tampered.count - 1] ^= 1
        let broken = callee.open(tampered)
        #expect(broken == nil)
        var relabelled = again
        relabelled[0] = CallCrypto.Kind.hello.rawValue
        let swapped = callee.open(relabelled)
        #expect(swapped == nil, "the kind is sealed in too")
        let good = callee.open(again)
        #expect(good?.1 == Data("more".utf8))
    }
}
