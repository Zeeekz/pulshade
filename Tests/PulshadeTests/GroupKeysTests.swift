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
                              members: ([owner] + members).map { MemberCard.make($0, group: group, name: "m", avatar: nil, color: nil) })
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
        var big = MemberCard.make(owner, group: group, name: "m", avatar: Data(count: 17_000), color: nil)
        #expect(big.avatar == nil && big.verified(group: group), "a picture too big is left off when the card is made")
        big.avatar = Data(count: 17_000)
        #expect(!big.verified(group: group))
        // Sealing with any epoch number never traps.
        var chain = SenderChain(key: .random(32), index: 0)
        #expect((try? GroupSeal.seal(Data("x".utf8), group: group, epoch: GroupEpoch(number: -5, key: .random(32), started: Date()),
                                     keys: owner, device: dev, chain: &chain)) != nil)
    }
}
