import Testing
import Foundation
@testable import Pulshade

/// Fixed vectors for the parts that turn one seed into an account. They catch a change to a derivation label,
/// an HKDF salt, the Crockford alphabet or the frame header, which a round-trip test alone would miss.
@Suite struct ProtocolVectorsTests {
    private let seed = Data(0..<32)

    @Test func identityDerivationsAreStable() throws {
        let id = try Identity(seed: seed)
        #expect(id.fingerprint == "4205f2b25de6f610c02c0bf927cede91")
        #expect(id.signingKey.rawRepresentation.hex == "50399d743f67befff00e75432e4f28e40f80f310f19384e24b90586d0376b14c")
        #expect(id.agreementKey.rawRepresentation.hex == "6f7607823d91208cd2757b0dc7930d9818a35ed77dfbb143d3c7b9b09782afc9")
        #expect(id.storageKey.withUnsafeBytes { Data($0).hex } == "a53b612c4d8cf5a976e89dd15a999453f80de09fa32d87022c71c5918afa7a7c")
        #expect(id.pq.kemSeed.hex == "06336a93770749bb9c51cc765a6cc05b29e608b2adf8d8c97ae415bd3526f729414245c8d1b9d2ebf33bf3ce47594c43dd3ddb9b7fec5b45515fcc0e6efef017")
        #expect(id.pq.sigSeed.hex == "fcecdf4a3969a7a080ca9a8734eb73702b42a7899922ed62c01e5707d23a1eb1")
    }

    @Test func base32AndHexAreStable() throws {
        #expect(Base32.encode(seed) == "000G40R40M30E209185GR38E1W8124GK2GAHC5RR34D1P70X3RFG")
        #expect(Base32.decode("000G40R40M30E209185GR38E1W8124GK2GAHC5RR34D1P70X3RFG") == seed)
        #expect(seed.hex == "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        #expect(Data(hexString: seed.hex) == seed)
    }

    @Test func theFrameHeaderIsStable() throws {
        let header = Data([1, 2, 3]), tail = Data([9, 8])
        let framed = Frame.join(header, tail)
        #expect(framed == Data([0, 0, 0, 0, 3, 1, 2, 3, 9, 8]))
        let parts = try #require(Frame.split(framed))
        #expect(parts.header == header && parts.tail == tail)
        // A length that runs past the buffer, and a wrong marker, are refused.
        #expect(Frame.split(Data([0, 0, 0, 0, 9, 1])) == nil)
        #expect(Frame.split(Data([1, 0, 0, 0, 0])) == nil)
    }
}
