import Testing
import Foundation
@testable import Pulshade
@testable import PulshadeShared

/// Links and wallets travelling from one account to a contact through a real relay (see RelayFlowTests for how to start one).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct ProfileDeliveryTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-test")
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        return model
    }

    private func settle(_ models: AppModel..., seconds: Int = 5) async {
        for _ in 0..<seconds {
            for m in models { await m.syncOnceFully() }
            try? await Task.sleep(for: .seconds(1))
        }
        for m in models { await m.syncOnceFully() }
    }

    @Test func linksAndWalletsReachContactsAndGoWhenRemoved() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, seconds: 2)
        let aliceFP = alice.fingerprint

        let btc = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        alice.updateProfile { $0.links = [ProfileLink.make(.github, from: "octocat")!, ProfileLink.make(.bitcoin, from: btc)!] }
        await settle(alice, bob)
        #expect(bob.contact(aliceFP)?.links?.map(\.kind) == [.github, .bitcoin])
        #expect(bob.contact(aliceFP)?.links?.last?.value == btc)

        // A changed wallet is noticed; removing everything clears it.
        let other = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
        alice.updateProfile { $0.links = [ProfileLink.make(.github, from: "octocat")!, ProfileLink.make(.bitcoin, from: other)!] }
        await settle(alice, bob)
        #expect(bob.contact(aliceFP)?.walletChangedAt != nil)
        alice.updateProfile { $0.links = nil }
        await settle(alice, bob)
        #expect(bob.contact(aliceFP)?.links == nil)
    }

    /// A wallet taken down and later replaced still warns: the last address of each kind is remembered.
    @Test func aWalletReplacedAfterAGapStillWarns() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, seconds: 2)
        let aliceFP = alice.fingerprint
        alice.updateProfile { $0.links = [ProfileLink.make(.bitcoin, from: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")!] }
        await settle(alice, bob)
        #expect(bob.contact(aliceFP)?.walletChangedAt == nil)
        alice.updateProfile { $0.links = nil }
        await settle(alice, bob)
        // The warning from the removal has run out by the time a new one goes up.
        if let i = bob.data.contacts.firstIndex(where: { $0.fingerprint == aliceFP }) { bob.data.contacts[i].walletChangedAt = nil }
        alice.updateProfile { $0.links = [ProfileLink.make(.bitcoin, from: "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")!] }
        await settle(alice, bob)
        #expect(bob.contact(aliceFP)?.walletChangedAt != nil)
    }

    /// A profile older than the newest one taken is ignored, so a late copy can't bring back what was taken down.
    @Test func anOlderProfileArrivingLateIsIgnored() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, seconds: 2)
        let aliceFP = alice.fingerprint
        alice.updateProfile { $0.bio = "First" }
        await settle(alice, bob)
        #expect(bob.contact(aliceFP)?.bio == "First")
        // As if a newer profile had already been taken.
        if let i = bob.data.contacts.firstIndex(where: { $0.fingerprint == aliceFP }) { bob.data.contacts[i].profileStamp = .max - 1 }
        alice.updateProfile { $0.bio = "Second" }
        await settle(alice, bob)
        #expect(bob.contact(aliceFP)?.bio == "First")
    }

    @Test func notesReachContactsAndLockedOnesOpenOnlyWithTheirPassword() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, seconds: 2)
        let aliceFP = alice.fingerprint

        let open = try #require(ProfileNote.publicNote(title: "About me", text: "Hello there.\nSecond line."))
        let locked = try #require(ProfileNote.lockedNote(title: "Private", text: "The secret words.", password: "twelve chars!", logN: 14))
        alice.updateProfile { $0.notes = [open, locked] }
        await settle(alice, bob)

        let seen = try #require(bob.contact(aliceFP)?.notes)
        #expect(seen.map(\.title) == ["About me", "Private"])
        #expect(seen[0].text == "Hello there.\nSecond line.")
        // What Bob received of the locked note has no readable words in it, and opens only with the password.
        #expect(seen[1].text == nil && seen[1].isLocked)
        #expect(seen[1].sealed?.range(of: Data("secret".utf8)) == nil)
        #expect(seen[1].open(password: "twelve chars!") == "The secret words.")
        #expect(seen[1].open(password: "wrong password!") == nil)

        alice.updateProfile { $0.notes = nil }
        await settle(alice, bob)
        #expect(bob.contact(aliceFP)?.notes == nil)
    }

    /// A note goes into a chat as a card with no words in it. The other side finds the note on the sender's profile,
    /// where the password or the access they were given decides if it opens.
    @Test func aNoteCardCarriesOnlyItsTitleAndOpensFromTheProfile() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob)
        let bobFP = try #require(alice.visibleContacts.first).fingerprint
        let open = try #require(ProfileNote.publicNote(title: "Wifi", text: "the password is swordfish"))
        let mine = try #require(ProfileNote.contactsNote(title: "Just for Bob", text: "a secret plan", contacts: [bobFP]))
        alice.updateProfile { $0.notes = [open, mine] }
        await settle(alice, bob, seconds: 6)
        let chat = try #require(alice.data.conversations.first { $0.kind == .direct })
        alice.send(NoteCard(mine).fallbackText, note: NoteCard(mine), in: chat.id)
        await settle(alice, bob)

        let theirs = try #require(bob.data.conversations.first { $0.kind == .direct }?.messages.last)
        let card = try #require(theirs.note, "it arrives as a card")
        #expect(card.title == "Just for Bob" && card.restricted && !card.locked)
        #expect(!theirs.text.contains("secret plan"), "the words never travel in the chat")
        let found = try #require(bob.contact(alice.fingerprint)?.notes?.first { $0.id == card.id }, "his copy of the note comes with her profile")
        #expect(found.restricted == true && found.text == "a secret plan", "made for him: access granted")
        #expect(NoteCard.cleaned(NoteCard(id: "", title: "x", locked: false, restricted: false)) == nil, "a card with no id is dropped")
    }

    @Test func aNoteCardOpensWhenTheChatBelongsToAnotherPersona() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        // Bob knows Alice only through a persona, then goes back to his main profile.
        let shadow = try #require(bob.createPersona(name: "Shadow"))
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: "", persona: .some(shadow.id)))
        await settle(alice, bob)
        bob.switchPersona(nil)
        let note = try #require(ProfileNote.publicNote(title: "Wifi", text: "the password is swordfish"))
        alice.updateProfile { $0.notes = [note] }
        await settle(alice, bob, seconds: 6)
        let chat = try #require(alice.data.conversations.first { $0.kind == .direct })
        alice.send(NoteCard(note).fallbackText, note: NoteCard(note), in: chat.id)
        await settle(alice, bob)

        let theirs = try #require(bob.data.conversations.first { $0.kind == .direct && $0.persona == shadow.id }?.messages.last)
        let card = try #require(theirs.note)
        #expect(bob.contact(theirs.sender, in: bob.activePersona) == nil, "the open persona doesn't know her")
        let found = bob.note(for: card, sentBy: theirs.sender, mine: false)
        #expect(found?.text == "the password is swordfish", "the card still opens her note")
        #expect(alice.note(for: card, sentBy: theirs.sender, mine: true)?.id == note.id, "and her own copy opens on her side")
    }

    @Test func aNoteForChosenContactsReachesOnlyThemWithNoPassword() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let carol = try await makeUser("Carol")
        defer { for m in [alice, bob, carol] { m.lock() } }
        let bobFP = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        let carolFP = try #require(carol.addContact(code: alice.makeInviteCode(), nickname: ""))
        _ = (bobFP, carolFP)
        await settle(alice, bob, carol, seconds: 2)
        let aliceFP = alice.fingerprint
        let forBob = try #require(alice.visibleContacts.first { $0.name == "Bob" }?.fingerprint)

        let open = try #require(ProfileNote.publicNote(title: "About me", text: "Hello."))
        let private1 = try #require(ProfileNote.contactsNote(title: "My address", text: "12 Elm Street", contacts: [forBob]))
        alice.updateProfile { $0.notes = [open, private1] }
        await settle(alice, bob, carol)

        // Bob reads it with no password; Carol never receives it, and neither is told who it was for.
        let seenByBob = try #require(bob.contact(aliceFP)?.notes)
        #expect(seenByBob.map(\.title) == ["About me", "My address"])
        #expect(seenByBob[1].text == "12 Elm Street" && !seenByBob[1].isLocked && seenByBob[1].sharedWith == nil)
        #expect(carol.contact(aliceFP)?.notes?.map(\.title) == ["About me"])

        // Taking Bob off removes it from his view of the profile.
        alice.updateProfile { profile in
            profile.notes = profile.notes?.map { var n = $0; if n.sharedWith != nil { n.sharedWith = [String(repeating: "0", count: 32)] }; return n }
        }
        await settle(alice, bob, carol)
        #expect(bob.contact(aliceFP)?.notes?.map(\.title) == ["About me"])
    }
}
