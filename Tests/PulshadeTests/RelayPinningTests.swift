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

    @Test func aPublicKeyPinSurvivesARenewalThatKeepsTheKey() {
        let saved = RelayPinning.pins
        defer { RelayPinning.pins = saved }
        let key = P256.Signing.PrivateKey().publicKey
        let info = key.derRepresentation
        let before = Data("certificate before renewal".utf8)
        let after = Data("certificate after renewal, same key".utf8)
        RelayPinning.pins = ["relay.example": [Data(SHA256.hash(data: info))]]

        #expect(RelayPinning.accepts(host: "relay.example", leafDER: before, leafKeyInfo: info))
        #expect(RelayPinning.accepts(host: "relay.example", leafDER: after, leafKeyInfo: info), "a new certificate on the same key is accepted")
        let other = P256.Signing.PrivateKey().publicKey.derRepresentation
        #expect(!RelayPinning.accepts(host: "relay.example", leafDER: after, leafKeyInfo: other), "another key is not")
        #expect(!RelayPinning.accepts(host: "relay.example", leafDER: after), "and without a readable key only a certificate hash can match")
    }

    @Test func theKeyInfoIsRebuiltExactlyAsOpenSSLPrintsIt() {
        let p256 = P256.Signing.PrivateKey().publicKey
        #expect(RelayPinning.keyInfo(ofPoint: p256.x963Representation) == p256.derRepresentation)
        let p384 = P384.Signing.PrivateKey().publicKey
        #expect(RelayPinning.keyInfo(ofPoint: p384.x963Representation) == p384.derRepresentation)
        #expect(RelayPinning.keyInfo(ofPoint: Data(repeating: 4, count: 33)) == nil, "other kinds are left to the certificate hash")
    }
}
