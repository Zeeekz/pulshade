import Testing
import Foundation
import CryptoKit
@testable import Pulshade

/// The built-in relay's certificate pin on its direct, plain-HTTPS address. Serialized: every test here
/// swaps out the same shared, static pin table.
@Suite(.serialized)
struct RelayPinningTests {
    @Test func acceptsOnlyTheCertificatePinnedForThatHost() {
        let saved = RelayPinning.pins
        defer { RelayPinning.pins = saved }
        let real = Data("a certificate the relay actually serves".utf8)
        let swapped = Data("a certificate someone on the way swapped in".utf8)
        RelayPinning.pins = ["relay.example": [Data(SHA256.hash(data: real))]]

        #expect(RelayPinning.accepts(host: "relay.example", leafDER: real))
        #expect(RelayPinning.accepts(host: "RELAY.EXAMPLE", leafDER: real), "host matching ignores case")
        #expect(!RelayPinning.accepts(host: "relay.example", leafDER: swapped))
    }

    @Test func leavesAnyOtherHostToOrdinaryWebPKITrust() {
        let saved = RelayPinning.pins
        defer { RelayPinning.pins = saved }
        RelayPinning.pins = ["relay.example": [Data(SHA256.hash(data: Data("x".utf8)))]]
        // A relay with no pin of its own (a self-hosted one, say) isn't this check's business either way.
        #expect(RelayPinning.accepts(host: "someone-elses-relay.example", leafDER: Data("anything".utf8)))
    }

    @Test func publishingBothTheCurrentAndNextCertificateCoversARenewal() {
        let saved = RelayPinning.pins
        defer { RelayPinning.pins = saved }
        let current = Data("the certificate in use today".utf8)
        let next = Data("the certificate it renews to".utf8)
        RelayPinning.pins = ["relay.example": [Data(SHA256.hash(data: current)), Data(SHA256.hash(data: next))]]

        #expect(RelayPinning.accepts(host: "relay.example", leafDER: current))
        #expect(RelayPinning.accepts(host: "relay.example", leafDER: next))
    }
}
