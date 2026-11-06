import Testing
import Foundation
import CryptoKit
import PulshadeShared
@testable import Pulshade

/// The phone hashes a typed giveaway code the way the admin app does (which keeps its own copy of these same cases),
/// or nobody could enter one.
struct GiveawayCodeTests {
    @Test func aTypedCodeHashesTheSameWayAsInTheAdminApp() {
        let cases = [("remember remember", "REMEMBERREMEMBER"), ("REMEMBER-REMEMBER", "REMEMBERREMEMBER"), ("Rememb3r, Rememb3r!", "REMEMB3RREMEMB3R"),
                     ("BONFIRE 5", "B0NF1RE5"), ("oil lamp 0", "0111AMP0")]
        for (typed, normalised) in cases {
            #expect(Collectible.codeHash(typed) == Data(SHA256.hash(data: Data(normalised.utf8))), "\(typed)")
        }
    }
}
