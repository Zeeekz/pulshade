import Testing
import Foundation
@testable import Pulshade

@Suite(.serialized) struct LockStyleTests {
    @Test func pinsNeedExactlyTheirDigits() {
        #expect(LockStyle.pin4.accepts("1234"))
        #expect(!LockStyle.pin4.accepts("123"))
        #expect(!LockStyle.pin4.accepts("12345"))
        #expect(LockStyle.pin6.accepts("123456"))
        #expect(!LockStyle.pin6.accepts("1234"))
        #expect(!LockStyle.pin6.accepts("12345a"))
        #expect(!LockStyle.pin6.accepts("١٢٣٤٥٦"), "only ASCII digits")
    }

    @Test func passcodeKeepsItsSixCharacterMinimum() {
        #expect(LockStyle.passcode.accepts("abcdef"))
        #expect(!LockStyle.passcode.accepts("abcde"))
        #expect(LockStyle.passcode.accepts("123456"))
    }

    @Test func typingIsFilteredForPINs() {
        #expect(LockStyle.pin4.filtered("12a34567") == "1234")
        #expect(LockStyle.pin6.filtered("1 2-3") == "123")
        #expect(LockStyle.passcode.filtered("Ab 1!") == "Ab 1!")
    }

    @Test func disguiseSecretsAreNeverShorterThanSix() {
        #expect(!LockStyle.forDisguise.contains(.pin4))
    }

    @Test func aPINOpensTheVaultLikeAnyPasscode() throws {
        let vault = Vault(directory: testDirectory("pulshade-lockstyle"))
        let identity = Identity.generate()
        try vault.create(identity, passcode: "4821")
        guard case let .identity(opened, _) = try vault.unlock(passcode: "4821") else {
            Issue.record("wrong role"); return
        }
        #expect(opened.seed == identity.seed)
        #expect(throws: VaultError.self) { try vault.unlock(passcode: "4822") }
    }
}
