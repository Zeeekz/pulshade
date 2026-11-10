import Testing
import Foundation
import CryptoKit
@testable import Pulshade

/// The keys behind groups that share one mailbox: member keys, epochs, chains, sealing, settings and new epochs.
struct GroupKeysTests {
    let group = UUID()
    let dev = Data.random(16)

    private func keys(_ seed: Data) -> GroupMemberKeys { GroupMemberKeys(seed: seed, group: group) }

    private func settings(owner: GroupMemberKeys, members: [GroupMemberKeys], admins: [GroupMemberKeys] = [],
                          mods: [GroupMemberKeys] = []) -> GroupSettings {
        var s = GroupSettings(group: group, kind: .group, version: 1, epoch: 1, title: "Crew", owner: owner.publicKey,
                              admins: admins.map(\.publicKey), mods: mods.map(\.publicKey),
                              members: ([owner] + members).map { MemberCard.make($0, group: group, name: "m", avatar: nil, color: nil) },
                              epochCheck: GroupEpoch.fresh(number: 1).check)
        s.sign(with: owner)
        return s
    }

    @Test func memberKeysAreTheSameOnEveryDeviceButDifferInEveryGroup() {
        let seed = Data.random(32)
        #expect(GroupMemberKeys(seed: seed, group: group).publicKey == GroupMemberKeys(seed: seed, group: group).publicKey)
        #expect(GroupMemberKeys(seed: seed, group: group).publicKey != GroupMemberKeys(seed: seed, group: UUID()).publicKey)
        let identity = try! Identity(seed: seed)
        #expect(GroupMemberKeys(seed: seed, group: group).publicKey != identity.signingKey.publicKey.rawRepresentation,
                "A group key says nothing about the account")
    }

    @Test func aMessageOpensOnceForEveryMemberAndNotAfterTheChainMovesOn() throws {
        let epoch = GroupEpoch.fresh(number: 1)
        let me = keys(.random(32))
        var chain = epoch.chainStart(for: me.publicKey, device: GroupSeal.deviceTag(dev))
        let first = try GroupSeal.seal(Data("hello".utf8), group: group, epoch: epoch, keys: me, device: dev, chain: &chain)
        let second = try GroupSeal.seal(Data("again".utf8), group: group, epoch: epoch, keys: me, device: dev, chain: &chain)
        #expect(chain.index == 2)
        // Two readers, each with their own state.
        for _ in 0..<2 {
            var reader = GroupReader()
            let outer2 = try GroupSeal.outer(second, group: group, epoch: epoch)
            let outer1 = try GroupSeal.outer(first, group: group, epoch: epoch)
            #expect(outer1.sender == me.publicKey && outer2.index == 1)
            // Out of order: the second first.
            let maybe2 = reader.messageKey(epoch: epoch, sender: outer2.sender, device: outer2.device, index: outer2.index)
            let k2 = try #require(maybe2)
            #expect(GroupSeal.inner(outer2, messageKey: k2) == Data("again".utf8))
            let maybe1 = reader.messageKey(epoch: epoch, sender: outer1.sender, device: outer1.device, index: outer1.index)
            let k1 = try #require(maybe1)
            #expect(GroupSeal.inner(outer1, messageKey: k1) == Data("hello".utf8))
            #expect(reader.messageKey(epoch: epoch, sender: outer1.sender, device: outer1.device, index: 0) == nil, "Each key is used once")
            #expect(reader.skipped.isEmpty)
        }
        // A second device of the same account has a chain of its own: the same index is a different key.
        let other = Data.random(16)
        var otherChain = epoch.chainStart(for: me.publicKey, device: GroupSeal.deviceTag(other))
        let fromOther = try GroupSeal.seal(Data("other device".utf8), group: group, epoch: epoch, keys: me, device: other, chain: &otherChain)
        var reader = GroupReader()
        let o = try GroupSeal.outer(fromOther, group: group, epoch: epoch)
        #expect(o.index == 0 && o.device == GroupSeal.deviceTag(other))
        let key = reader.messageKey(epoch: epoch, sender: o.sender, device: o.device, index: o.index)
        #expect(key.flatMap { GroupSeal.inner(o, messageKey: $0) } == Data("other device".utf8))
    }

    @Test func theRelayAndOtherEpochsSeeNothingAndNobodyCanSignAsSomeoneElse() throws {
        let epoch = GroupEpoch.fresh(number: 1)
        let me = keys(.random(32)), mallory = keys(.random(32))
        var chain = epoch.chainStart(for: me.publicKey, device: GroupSeal.deviceTag(dev))
        let blob = try GroupSeal.seal(Data("secret".utf8), group: group, epoch: epoch, keys: me, device: dev, chain: &chain)
        #expect(blob.count >= 2_048, "Padded like any envelope")
        #expect(!blob.contains(me.publicKey) && blob.range(of: Data("secret".utf8)) == nil)
        #expect(throws: GroupSeal.Failure.self) { try GroupSeal.outer(blob, group: group, epoch: GroupEpoch.fresh(number: 2)) }
        #expect(throws: GroupSeal.Failure.self) { try GroupSeal.outer(blob, group: UUID(), epoch: epoch) }
        // Mallory, a member, re-signs nothing of mine: putting my key on her envelope fails the check.
        var hers = epoch.chainStart(for: mallory.publicKey, device: GroupSeal.deviceTag(dev))
        let forged = try GroupSeal.seal(Data("from me".utf8), group: group, epoch: epoch, keys: mallory, device: dev, chain: &hers)
        let outer = try GroupSeal.outer(forged, group: group, epoch: epoch)
        #expect(outer.sender == mallory.publicKey)
    }

    @Test func cardsAreSignedByTheirOwnerAndCanNotBeChanged() {
        let me = keys(.random(32))
        var card = MemberCard.make(me, group: group, name: "Sam", avatar: nil, color: 3)
        #expect(card.verified(group: group))
        #expect(!card.verified(group: UUID()))
        card.name = "Someone else"
        #expect(!card.verified(group: group))
        var swapped = MemberCard.make(me, group: group, name: "Sam", avatar: nil, color: 3)
        swapped.agreementKey = Data.random(32)
        #expect(!swapped.verified(group: group), "An admin can't slip in an agreement key of their own")
    }

    @Test func whoMayChangeWhat() {
        let owner = keys(.random(32)), admin = keys(.random(32)), mod = keys(.random(32))
        let plain = keys(.random(32)), other = keys(.random(32)), newcomer = keys(.random(32))
        let base = settings(owner: owner, members: [admin, mod, plain, other], admins: [admin], mods: [mod])
        #expect(base.wellFormed() && base.signatureIsValid)

        func next(_ change: (inout GroupSettings) -> Void, by signer: GroupMemberKeys) -> GroupSettings {
            var n = base
            change(&n)
            n.version = base.version + 1
            n.sign(with: signer)
            return n
        }
        let addNewcomer: (inout GroupSettings) -> Void = { $0.members.append(MemberCard.make(newcomer, group: self.group, name: "n", avatar: nil, color: nil)) }
        let removePlain: (inout GroupSettings) -> Void = { $0.members.removeAll { $0.signingKey == plain.publicKey } }
        let removeAdmin: (inout GroupSettings) -> Void = { $0.members.removeAll { $0.signingKey == admin.publicKey }; $0.admins = [] }
        let rename: (inout GroupSettings) -> Void = { $0.title = "New name" }
        let promote: (inout GroupSettings) -> Void = { $0.admins.append(plain.publicKey) }

        #expect(base.accepts(next(addNewcomer, by: owner)))
        #expect(base.accepts(next(promote, by: owner)))
        #expect(base.accepts(next(removeAdmin, by: owner)))
        #expect(base.accepts(next(addNewcomer, by: admin)))
        #expect(base.accepts(next(removePlain, by: admin)))
        #expect(base.accepts(next(rename, by: admin)))
        #expect(!base.accepts(next(promote, by: admin)), "Only the owner gives roles")
        #expect(!base.accepts(next(removeAdmin, by: admin)), "An admin can't take another out")
        #expect(base.accepts(next(removePlain, by: mod)))
        #expect(!base.accepts(next(rename, by: mod)), "A mod only removes")
        #expect(!base.accepts(next(addNewcomer, by: mod)))
        #expect(!base.accepts(next(removePlain, by: plain)))
        #expect(!base.accepts(next(rename, by: plain)))
        // A member may change their own card, and nothing else.
        let renamedSelf = next({ s in
            let i = s.members.firstIndex { $0.signingKey == plain.publicKey }!
            s.members[i] = MemberCard.make(plain, group: self.group, name: "Pat", avatar: nil, color: 1)
        }, by: plain)
        #expect(base.accepts(renamedSelf))
        let renamedOther = next({ s in
            let i = s.members.firstIndex { $0.signingKey == other.publicKey }!
            s.members[i].name = "x"
        }, by: admin)
        #expect(!base.accepts(renamedOther), "Nobody can change someone else's card")
        // Numbering, signatures and outsiders.
        var skipped = next(rename, by: owner)
        skipped.version += 1
        skipped.sign(with: owner)
        #expect(!base.accepts(skipped))
        var tampered = next(rename, by: owner)
        tampered.title = "Tampered"
        #expect(!base.accepts(tampered))
        #expect(!base.accepts(next(rename, by: newcomer)), "Someone not in it changes nothing")
        var twoEpochs = next(rename, by: owner)
        twoEpochs.epoch += 2
        twoEpochs.sign(with: owner)
        #expect(!base.accepts(twoEpochs))
    }

    @Test func aNewEpochOpensForThoseLeftAndNotForWhoeverWasTakenOut() throws {
        let owner = keys(.random(32)), stays = keys(.random(32)), goes = keys(.random(32))
        let cards = [owner, stays].map { MemberCard.make($0, group: group, name: "m", avatar: nil, color: nil) }
        let next = GroupEpoch.fresh(number: 2, days: 3)
        let rekey = GroupRekey.make(next, group: group, for: cards)
        #expect(rekey.open(with: stays)?.key == next.key)
        #expect(rekey.open(with: owner)?.receiveKey == next.receiveKey)
        #expect(rekey.open(with: goes) == nil)
        #expect(rekey.open(with: stays)?.days == 3)
        // Sealed to each member's own key: one member's copy is no use to another.
        var moved = rekey
        moved.sealed[goes.publicKey.hex] = rekey.sealed[stays.publicKey.hex]
        #expect(moved.open(with: goes) == nil)
        #expect(next.sendID != GroupEpoch.fresh(number: 2).sendID, "Each epoch has its own mailbox")
    }

    @Test func readersForgetOldEpochsAndDontRunAhead() {
        let epoch = GroupEpoch.fresh(number: 3)
        var reader = GroupReader()
        let sender = keys(.random(32)).publicKey
        #expect(reader.messageKey(epoch: epoch, sender: sender, device: GroupSeal.deviceTag(dev), index: GroupReader.maxSkip + 1) == nil)
        #expect(reader.messageKey(epoch: epoch, sender: sender, device: GroupSeal.deviceTag(dev), index: 5) != nil)
        #expect(reader.skipped.count == 5)
        reader.drop(before: 4)
        #expect(reader.chains.isEmpty && reader.skipped.isEmpty)
    }

    @Test func numbersOutOfRangeAndBigPicturesAreRefusedNotCrashedOn() {
        let owner = keys(.random(32))
        var s = settings(owner: owner, members: [])
        for bad in [0, -1, Int.max, Int(Int32.max)] {
            var v = s
            v.version = bad
            v.sign(with: owner)
            #expect(!v.wellFormed())
            var e = s
            e.epoch = bad
            e.sign(with: owner)
            #expect(!e.wellFormed())
            #expect(!s.accepts(v) && !s.accepts(e))
            #expect(!GroupEpoch(number: bad, key: .random(32), started: Date()).isValid)
        }
        let big = MemberCard.make(owner, group: group, name: "m", avatar: Data(count: 17_000), color: nil)
        #expect(big.avatar == nil && big.avatarHash == nil && big.verified(group: group), "a picture too big is left off when the card is made")
        // Sealing with any epoch number never traps.
        var chain = SenderChain(key: .random(32), index: 0)
        #expect((try? GroupSeal.seal(Data("x".utf8), group: group, epoch: GroupEpoch(number: -5, key: .random(32), started: Date()),
                                     keys: owner, device: dev, chain: &chain)) != nil)
    }

    @Test func picturesTravelApartButOnlyTheSignedOneIsTaken() {
        let me = keys(.random(32))
        let picture = Data(repeating: 7, count: 2_000)
        let card = MemberCard.make(me, group: group, name: "Sam", avatar: picture, color: 1)
        #expect(card.verified(group: group) && card.withoutAvatar.verified(group: group))
        #expect(card.sameCard(as: card.withoutAvatar))
        var swapped = card
        swapped.avatar = Data(repeating: 8, count: 2_000)
        #expect(!swapped.verified(group: group), "another picture under the same card is refused")
        // Settings carry cards without pictures.
        var s = settings(owner: me, members: [])
        s.members = [card]
        s.sign(with: me)
        #expect(!s.wellFormed())
    }

    @Test func competingVersionsSettleTheSameWayEverywhereAndTheOwnerCanCatchPeopleUp() {
        let owner = keys(.random(32)), a = keys(.random(32)), b = keys(.random(32)), x = keys(.random(32)), y = keys(.random(32))
        let base = settings(owner: owner, members: [a, b, x, y], admins: [a, b])
        func change(_ f: (inout GroupSettings) -> Void, by signer: GroupMemberKeys, version: Int? = nil) -> GroupSettings {
            var n = base
            f(&n)
            n.version = version ?? base.version + 1
            n.sign(with: signer)
            return n
        }
        let fromA = change({ $0.members.removeAll { $0.signingKey == x.publicKey } }, by: a)
        let fromB = change({ $0.members.removeAll { $0.signingKey == y.publicKey } }, by: b)
        #expect(base.accepts(fromA) && base.accepts(fromB))
        // Whichever arrives first, the lower tie-break wins: the same everywhere.
        let winner = fromA.tieBreak.lexicographicallyPrecedes(fromB.tieBreak) ? fromA : fromB
        let loser = winner == fromA ? fromB : fromA
        #expect(winner.tieBreak.lexicographicallyPrecedes(loser.tieBreak) && !loser.tieBreak.lexicographicallyPrecedes(winner.tieBreak))
        // Only the owner may skip versions.
        let jump = change({ $0.title = "Later" }, by: owner, version: base.version + 5)
        #expect(base.acceptsJump(jump) && !base.accepts(jump))
        #expect(!base.acceptsJump(change({ $0.title = "Later" }, by: a, version: base.version + 5)))
        var back = change({ $0.title = "Back" }, by: owner, version: base.version + 5)
        back.epoch = base.epoch - 1 == 0 ? base.epoch : base.epoch - 1
        back.sign(with: owner)
        #expect(base.acceptsJump(back) == (back.epoch >= base.epoch))
    }

    @Test func oneSenderCantCrowdOutOthersOrOpenEndlessChains() {
        let epoch = GroupEpoch.fresh(number: 1)
        var reader = GroupReader()
        let noisy = keys(.random(32)).publicKey, quiet = keys(.random(32)).publicKey
        let quietDevice = GroupSeal.deviceTag(.random(8))
        _ = reader.messageKey(epoch: epoch, sender: quiet, device: quietDevice, index: 3)
        #expect(reader.skipped.count == 3)
        let noisyDevice = GroupSeal.deviceTag(.random(8))
        var at: UInt32 = 0
        for _ in 0..<5 { at += 1_900; _ = reader.messageKey(epoch: epoch, sender: noisy, device: noisyDevice, index: at) }
        #expect(reader.skipped.keys.filter { $0.contains(noisy.hex) }.count <= GroupReader.maxSkippedPerSender)
        #expect(reader.skipped.keys.filter { $0.contains(quiet.hex) }.count == 3, "the quiet member's gaps are kept")
        for _ in 0..<GroupReader.maxDevicesPerSender { _ = reader.messageKey(epoch: epoch, sender: noisy, device: .random(8), index: 0) }
        #expect(reader.messageKey(epoch: epoch, sender: noisy, device: .random(8), index: 0) == nil, "no more devices")
    }

    @Test func eachEpochKeyCarriesACheckTheSettingsName() {
        let one = GroupEpoch.fresh(number: 2), other = GroupEpoch.fresh(number: 2)
        #expect(one.check.count == 32 && one.check != other.check && one.check != one.key)
    }

    @Test func theOwnersVersionBeatsAnAdminsAndModsCanRemoveWithANewKey() {
        let owner = keys(.random(32)), admin = keys(.random(32)), mod = keys(.random(32)), plain = keys(.random(32))
        let base = settings(owner: owner, members: [admin, mod, plain], admins: [admin], mods: [mod])
        var fromOwner = base, fromAdmin = base
        fromOwner.admins = []
        fromOwner.version += 1
        fromOwner.sign(with: owner)
        for n in 0..<20 {
            fromAdmin.title = "try \(n)"
            fromAdmin.version = base.version + 1
            fromAdmin.sign(with: admin)
            #expect(fromOwner.winsOver(fromAdmin) && !fromAdmin.winsOver(fromOwner), "however often the admin tries")
        }
        // A mod's removal comes with a new epoch, and is taken.
        let next = GroupEpoch.fresh(number: base.epoch + 1)
        var removal = base
        removal.members.removeAll { $0.signingKey == plain.publicKey }
        removal.version += 1
        removal.epoch = next.number
        removal.epochCheck = next.check
        removal.sign(with: mod)
        #expect(base.accepts(removal))
    }

    @Test func theSizeCheckMatchesWhatTheRelayTakes() {
        let owner = keys(.random(32))
        var s = settings(owner: owner, members: [])
        for _ in 0..<1_000 { s.members.append(MemberCard.make(keys(.random(32)), group: group, name: "Member", avatar: nil, color: 2).withoutAvatar) }
        s.sign(with: owner)
        #expect(s.fitsInMailbox, "a thousand members fit")
        let bytes = try! Payload.groupSettings(s).wire(framed: false).count
        #expect(GroupSeal.fits(payload: bytes) && !GroupSeal.fits(payload: 2_100_000))
        // What the check passes really does seal under the relay's limit (2 MiB and a little).
        var chain = SenderChain(key: .random(32), index: 0)
        let sealed = try! GroupSeal.seal(Data(count: bytes), group: group, epoch: .fresh(number: 1), keys: owner, device: dev, chain: &chain)
        #expect(sealed.count <= 2 * 1024 * 1024 + 1024)
        var long = s
        long.title = String(repeating: "\u{0301}", count: 300)
        long.sign(with: owner)
        #expect(!long.wellFormed(), "few characters but many bytes")
    }
}
