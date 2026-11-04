import Testing
import Foundation
@testable import PulshadeShared

struct ProfileNotesTests {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    @Test func scryptMatchesTheStandardsTestVectors() {
        // RFC 7914, section 12.
        #expect(hex(Scrypt.derive(password: [], salt: [], n: 16, r: 1, p: 1, length: 64)!)
                == "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906")
        #expect(hex(Scrypt.derive(password: Array("password".utf8), salt: Array("NaCl".utf8), n: 1024, r: 8, p: 16, length: 64)!)
                == "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640")
    }

    @Test func aLockedNoteOpensOnlyWithItsPassword() throws {
        let pw = "correct horse battery"
        let note = try #require(ProfileNote.lockedNote(title: "Recipe", text: "Two eggs.\nA pinch of salt.", password: pw, logN: 14))
        #expect(note.isLocked && note.text == nil)
        #expect(note.open(password: pw) == "Two eggs.\nA pinch of salt.")
        #expect(note.open(password: "correct horse batterY") == nil)
        #expect(note.open(password: "") == nil)
        // The words are nowhere in what gets sent.
        #expect(note.sealed?.range(of: Data("Two eggs".utf8)) == nil)
    }

    @Test func aSealedNoteCantBeMovedOrChanged() throws {
        let pw = "a long enough password"
        let note = try #require(ProfileNote.lockedNote(title: "Mine", text: "secret", password: pw, logN: 14))
        // Another title or id: it won't open.
        var retitled = note; retitled.title = "Someone else's"
        #expect(retitled.open(password: pw) == nil)
        var moved = note; moved.id = ProfileNote.newID()
        #expect(moved.open(password: pw) == nil)
        // One changed byte anywhere: it won't open.
        var bytes = try #require(note.sealed)
        bytes[bytes.count - 5] ^= 1
        var changed = note; changed.sealed = bytes
        #expect(changed.open(password: pw) == nil)
    }

    @Test func sizesAreHiddenInBuckets() throws {
        let a = try #require(ProfileNote.lockedNote(id: "0000000000000001", title: "T", text: "hi", password: "twelve chars!", logN: 14))
        let b = try #require(ProfileNote.lockedNote(id: "0000000000000001", title: "T", text: String(repeating: "x", count: 400), password: "twelve chars!", logN: 14))
        #expect(a.sealed?.count == b.sealed?.count)
    }

    @Test func weakPasswordsAreRefused() {
        #expect(NoteSeal.passwordProblem("short") != nil)
        #expect(NoteSeal.passwordProblem("aaaaaaaaaaaaaaaa") != nil)
        #expect(NoteSeal.passwordProblem("password1234") != nil)
        #expect(NoteSeal.passwordProblem("a decent passphrase") == nil)
        #expect(ProfileNote.lockedNote(title: "T", text: "x", password: "weak") == nil)
        for _ in 0..<20 { #expect(NoteSeal.passwordProblem(NoteSeal.generatePassword()) == nil) }
        #expect(NoteSeal.generatePassword() != NoteSeal.generatePassword())
    }

    @Test func receivedNotesAreCheckedAndCapped() throws {
        let sealed = try #require(ProfileNote.lockedNote(title: "L", text: "x", password: "twelve chars!", logN: 14)?.sealed)
        let good = ProfileNote(id: ProfileNote.newID(), title: "Hello", text: "Some words")
        let list = ProfileNote.cleaned([
            good,
            ProfileNote(id: "short", title: "Bad id", text: "x"),                              // wrong id
            ProfileNote(id: ProfileNote.newID(), title: "", text: "no title"),                // no title
            ProfileNote(id: ProfileNote.newID(), title: "Both", text: "x", sealed: sealed),   // text and sealed together
            ProfileNote(id: ProfileNote.newID(), title: "Junk", sealed: Data(repeating: 1, count: 600)), // not a sealed note
            ProfileNote(id: ProfileNote.newID(), title: "Bidi\u{202E}", text: "x"),           // hidden characters in the title
            ProfileNote(id: good.id, title: "Same id", text: "x"),                             // duplicate id
        ])
        #expect(list.map(\.title) == ["Hello"])
        let many = (0..<30).map { ProfileNote(id: ProfileNote.newID(), title: "N\($0)", text: "x") }
        #expect(ProfileNote.cleaned(many).count == ProfileNote.maxCount)
        // Text is cleaned, not trusted: hidden marks go, new lines stay.
        #expect(ProfileNote.cleanText("a\u{202E}b\u{200B}c\nd") == "abc\nd")
        #expect(ProfileNote.cleanText(String(repeating: "a", count: ProfileNote.maxText + 1)) == nil)
    }

    @Test func costSettingsFromOutsideAreLimited() throws {
        let pw = "a long enough password"
        var bytes = try #require(NoteSeal.seal("x", password: pw, aad: Data("a".utf8), logN: 14))
        #expect(NoteSeal.open(bytes, password: pw, aad: Data("a".utf8)) == "x")
        bytes[1] = 30   // a note asking for 2^30 blocks of memory
        #expect(!NoteSeal.looksSealed(bytes))
        #expect(NoteSeal.open(bytes, password: pw, aad: Data("a".utf8)) == nil)
    }
}
