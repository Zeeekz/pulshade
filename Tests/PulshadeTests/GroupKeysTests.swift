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

    @Test func theRelayAndOtherEpochsSeeNothingAndNobodyCanSignAsSomeoneElse() throws {
        let epoch = GroupEpoch.fresh(number: 1)
        let me = keys(.random(32)), mallory = keys(.random(32))
        var chain = SenderChain.fresh()
        let blob = try GroupSeal.seal(Data("secret".utf8), group: group, epoch: epoch, keys: me, device: dev, chain: &chain)
        #expect(blob.count >= 2_048, "Padded like any envelope")
        #expect(!blob.contains(me.publicKey) && blob.range(of: Data("secret".utf8)) == nil)
        #expect(throws: GroupSeal.Failure.self) { try GroupSeal.outer(blob, group: group, epoch: GroupEpoch.fresh(number: 2)) }
        #expect(throws: GroupSeal.Failure.self) { try GroupSeal.outer(blob, group: UUID(), epoch: epoch) }
        // Mallory, a member, re-signs nothing of mine: putting my key on her envelope fails the check.
        var hers = SenderChain.fresh()
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
        // Whichever arrives first, the admin the owner listed first wins: the same everywhere, and B can't change that by
        // signing again until a hash comes out lower.
        #expect(fromA.contest(fromB, base: base) == .wins && fromB.contest(fromA, base: base) == .loses)
        for n in 0..<20 {
            let retry = change({ $0.members.removeAll { $0.signingKey == y.publicKey }; $0.title = "try \(n)" }, by: b)
            #expect(retry.contest(fromA, base: base) == .loses && fromA.contest(retry, base: base) == .wins, "however often B tries")
        }
        // Only the owner may skip versions.
        let jump = change({ $0.title = "Later" }, by: owner, version: base.version + 5)
        #expect(base.acceptsJump(jump) && !base.accepts(jump))
        #expect(!base.acceptsJump(change({ $0.title = "Later" }, by: a, version: base.version + 5)))
        var back = change({ $0.title = "Back" }, by: owner, version: base.version + 5)
        back.epoch = base.epoch - 1 == 0 ? base.epoch : base.epoch - 1
        back.sign(with: owner)
        #expect(base.acceptsJump(back) == (back.epoch >= base.epoch))
    }

    /// A member's move to new keys (their account unlinked a device), made from `base` by whoever holds `old`.
    private func move(_ base: GroupSettings, from old: GroupMemberKeys, to new: GroupMemberKeys, version: Int? = nil) -> GroupSettings {
        let epoch = GroupEpoch.fresh(number: base.epoch + 1)
        func swap(_ key: Data) -> Data { key == old.publicKey ? new.publicKey : key }
        var next = base
        next.members = base.members.map { $0.signingKey == old.publicKey ? MemberCard.make(new, group: group, name: "m", avatar: nil, color: nil).withoutAvatar : $0 }
        next.owner = swap(base.owner)
        next.admins = base.admins.map(swap)
        next.mods = base.mods.map(swap)
        next.epoch = epoch.number
        next.epochCheck = epoch.check
        next.version = version ?? base.version + 1
        next.sign(with: old)
        return next
    }

    @Test func anUnlinkedDeviceCantWinTheMoveToNewKeysByTryingAgain() {
        // The owner's account unlinked a device. Its real devices move the owner's place to keys made with the new group
        // secret; the unlinked device still holds the old keys and moves the place to keys of its own, as often as it likes.
        let owner = keys(.random(32)), admin = keys(.random(32)), plain = keys(.random(32))
        let base = settings(owner: owner, members: [admin, plain], admins: [admin])
        let real = move(base, from: owner, to: keys(.random(32)))
        #expect(base.accepts(real) && base.renewal(to: real) != nil)
        for _ in 0..<20 {
            let stolen = move(base, from: owner, to: keys(.random(32)))
            #expect(base.accepts(stolen), "on its own it looks like any move")
            // Two moves of one place to different keys: neither wins, whichever is held.
            guard case let .dispute(old, keys) = stolen.contest(real, base: base), case .dispute = real.contest(stolen, base: base) else {
                Issue.record("a second move of the same place must be a dispute")
                return
            }
            #expect(old == owner.publicKey && Set(keys) == [owner.publicKey, real.owner, stolen.owner])
        }
        // Any other change the old keys sign at the same number loses to the move, however it's tried.
        for n in 0..<20 {
            var other = base
            other.title = "mine \(n)"
            other.admins = []
            other.version += 1
            other.sign(with: owner)
            #expect(real.contest(other, base: base) == .wins && other.contest(real, base: base) == .loses)
        }
        // Two of the account's own devices moving to the same new key (each with its own epoch) agree either way.
        let new = keys(.random(32))
        let one = move(base, from: owner, to: new), two = move(base, from: owner, to: new)
        #expect(one.contest(two, base: base) != two.contest(one, base: base))
        #expect([GroupSettings.Contest.wins, .loses].contains(one.contest(two, base: base)), "no dispute")
        // A plain member's move loses to an admin's change made at the same moment: seniority, not a hash.
        let plainMove = move(base, from: plain, to: keys(.random(32)))
        var byAdmin = base
        byAdmin.title = "Renamed"
        byAdmin.version += 1
        byAdmin.sign(with: admin)
        #expect(base.accepts(byAdmin) && byAdmin.contest(plainMove, base: base) == .wins && plainMove.contest(byAdmin, base: base) == .loses)
    }

    @Test func aLateSecondMoveOfAPlaceIsSeenAfterTheGroupMovedOn() {
        let owner = keys(.random(32)), member = keys(.random(32))
        let base = settings(owner: owner, members: [member])
        let first = move(base, from: member, to: keys(.random(32)))
        // The group moves on past the move.
        var later = first
        later.title = "Later"
        later.version += 1
        later.sign(with: owner)
        let mark = RenewalMark(old: member.publicKey, new: first.card(first.members[1].signingKey)!.signingKey, version: first.version)
        let second = move(base, from: member, to: keys(.random(32)))
        let taker = second.movesPlace(of: mark.old, at: mark.version, otherThan: mark.new, from: later)
        #expect(taker == second.members[1].signingKey)
        // The same move again (the relay handing it out twice) is no dispute.
        #expect(first.movesPlace(of: mark.old, at: mark.version, otherThan: mark.new, from: later) == nil)
        // Signed by anyone else, or for another number, it says nothing.
        var forged = second
        forged.sign(with: owner)
        #expect(forged.movesPlace(of: mark.old, at: mark.version, otherThan: mark.new, from: later) == nil)
        #expect(move(base, from: member, to: keys(.random(32)), version: base.version + 2)
            .movesPlace(of: mark.old, at: mark.version, otherThan: mark.new, from: later) == nil)
    }

    /// A claimed admin key adds a member, moves on to another key, and adds again; the member it added moves to new keys
    /// of their own. A dispute over the claimed key reaches all of it, and nobody the owner or the real admin brought in.
    @Test func aDisputeReachesEverythingTheClaimedKeysBroughtIn() {
        let owner = keys(.random(32)), admin = keys(.random(32)), plain = keys(.random(32))
        let base = settings(owner: owner, members: [admin, plain], admins: [admin])
        var shared = SharedGroup(settings: base, epochs: [])
        func take(_ next: GroupSettings) {
            #expect(shared.settings.accepts(next), "every step is one members take")
            if let (old, new) = shared.settings.renewal(to: next) {
                shared.renewals = (shared.renewals ?? []) + [RenewalMark(old: old, new: new, version: next.version)]
            }
            shared.noteAdded(from: shared.settings, to: next)
            shared.settings = next
        }
        func add(_ who: GroupMemberKeys, by signer: GroupMemberKeys) -> GroupSettings {
            var next = shared.settings
            next.members.append(MemberCard.make(who, group: group, name: "m", avatar: nil, color: nil).withoutAvatar)
            next.version += 1
            next.sign(with: signer)
            return next
        }
        let claimed = keys(.random(32)), later = keys(.random(32)), m = keys(.random(32)), m2 = keys(.random(32))
        let n = keys(.random(32)), q = keys(.random(32))
        take(move(shared.settings, from: admin, to: claimed))
        take(add(m, by: claimed))
        take(move(shared.settings, from: claimed, to: later))
        take(add(n, by: later))
        take(move(shared.settings, from: m, to: m2))
        take(add(q, by: owner))
        #expect(shared.addedBy?[m2.publicKey.hex] == claimed.publicKey, "a move to new keys keeps who brought the member in")
        let decoy = keys(.random(32)).publicKey
        let reached = shared.broughtIn(under: [claimed.publicKey, decoy])
        // (The member's key from before their move is no longer listed, so there's nothing of it left to hold back.)
        #expect(reached == [claimed.publicKey, decoy, later.publicKey, m2.publicKey, n.publicKey])
        #expect(!reached.contains(owner.publicKey) && !reached.contains(plain.publicKey) && !reached.contains(q.publicKey))
        #expect(shared.holder(of: admin.publicKey) == later.publicKey && shared.holder(of: claimed.publicKey) == later.publicKey)
        #expect(shared.holder(of: plain.publicKey) == plain.publicKey)
        // Only those still listed are remembered.
        let remembered = Set((shared.addedBy ?? [:]).keys)
        #expect(remembered.isSubset(of: Set(shared.settings.members.map(\.signingKey.hex))))
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
            #expect(fromOwner.contest(fromAdmin, base: base) == .wins && fromAdmin.contest(fromOwner, base: base) == .loses,
                    "however often the admin tries")
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
        for _ in 0..<400 { s.members.append(MemberCard.make(keys(.random(32)), group: group, name: "Member", avatar: nil, color: 2).withoutAvatar) }
        s.sign(with: owner)
        #expect(s.fitsInMailbox, "four hundred members fit")
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

    @Test func aChannelRekeyDoesntListItsReadersAndHidesHowManyThereAre() throws {
        let owner = keys(.random(32))
        let followers = (0..<5).map { _ in keys(.random(32)) }
        let outsider = keys(.random(32))
        let cards = ([owner] + followers).map { MemberCard.make($0, group: group, name: "", avatar: nil, color: nil) }
        let next = GroupEpoch.fresh(number: 2)
        let rekey = GroupRekey.make(next, group: group, for: cards, tagged: true)
        for who in [owner] + followers { #expect(rekey.open(with: who)?.key == next.key) }
        #expect(rekey.open(with: outsider) == nil)
        #expect(rekey.tagged == true)
        for who in [owner] + followers { #expect(rekey.sealed[who.publicKey.hex] == nil, "no reader's key is named") }
        #expect(rekey.sealed.count == 8, "padded up to eight")
        let more = (0..<12).map { _ in MemberCard.make(keys(.random(32)), group: group, name: "", avatar: nil, color: nil) }
        #expect(GroupRekey.make(next, group: group, for: cards + more, tagged: true).sealed.count == 32, "then to a power of two")
        // A copy filed under someone else's tag opens nothing for them.
        var swapped = rekey
        let mine = rekey.sealed.first { (name, _) in followers[1].publicKey.hex != name }!
        swapped.sealed = [mine.key: mine.value]
        #expect(swapped.open(with: outsider) == nil)
    }

    @Test func aChannelsFollowerListOpensOnlyForStaffAndMergesWithoutLosingAnyone() throws {
        let owner = keys(.random(32)), admin = keys(.random(32)), follower = keys(.random(32)), other = keys(.random(32))
        let staff = [owner, admin].map { MemberCard.make($0, group: group, name: "s", avatar: nil, color: nil) }
        let a = MemberCard.make(follower, group: group, name: "", avatar: nil, color: nil)
        let b = MemberCard.make(other, group: group, name: "", avatar: nil, color: nil)
        // Whole seconds: dates are written to the millisecond, so a finer one wouldn't come back equal.
        let t0 = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let one = GroupRoster.Body(entries: [.init(card: a, added: t0)], removed: [])
        let two = GroupRoster.Body(entries: [.init(card: b, added: t0.addingTimeInterval(1))], removed: [])
        let roster = try #require(GroupRoster.make(one, group: group, epoch: 1, staff: staff, keys: owner))
        #expect(roster.signatureIsValid)
        #expect(roster.open(with: owner) == one && roster.open(with: admin) == one)
        #expect(roster.open(with: follower) == nil && roster.open(with: other) == nil, "a follower can't read it")
        var forged = roster
        forged.box = Data(forged.box.reversed())
        #expect(!forged.signatureIsValid)
        // Two admins add at once: both stay.
        #expect(Set(one.merged(with: two, group: group).live.map(\.signingKey)) == Set([a.signingKey, b.signingKey]))
        // A removal beats the entry it names, but a later add beats the removal.
        let removed = GroupRoster.Body(entries: [], removed: [.init(key: a.signingKey, at: t0.addingTimeInterval(5))])
        #expect(one.merged(with: removed, group: group).live.isEmpty)
        let again = GroupRoster.Body(entries: [.init(card: a, added: t0.addingTimeInterval(9))], removed: [])
        #expect(one.merged(with: removed, group: group).merged(with: again, group: group).live.map(\.signingKey) == [a.signingKey])
        // A card that isn't genuine for this group is left out.
        var fake = b
        fake.signature = Data(repeating: 1, count: 64)
        #expect(one.merged(with: .init(entries: [.init(card: fake, added: t0)], removed: []), group: group).live.count == 1)
        // The size doesn't give the number away to within a power of two: the sealed list is always a power of two long
        // (plus the seal's nonce and tag), and lists of three and four, close in size, look the same.
        func boxSize(_ n: Int) -> Int {
            let body = GroupRoster.Body(entries: (0..<n).map { _ in .init(card: a, added: t0) }, removed: [])
            return GroupRoster.make(body, group: group, epoch: 1, staff: staff, keys: owner)!.box.count
        }
        for n in [1, 3, 4, 9] {
            let padded = boxSize(n) - 28
            #expect(padded >= 1_024 && padded & (padded - 1) == 0, "\(n) entries seal to a power of two")
        }
        #expect(boxSize(3) == boxSize(4))
    }

    @Test func aRosterCantBeMadeUnbeatableOrFilledWithTheDead() throws {
        let one = keys(.random(32)), two = keys(.random(32))
        let a = MemberCard.make(one, group: group, name: "", avatar: nil, color: nil)
        let b = MemberCard.make(two, group: group, name: "", avatar: nil, color: nil)
        let now = Date()
        let empty = GroupRoster.Body(entries: [], removed: [])
        // A removal dated far ahead is only as good as a few minutes ahead: someone added after that gets back in.
        let forever = GroupRoster.Body(entries: [], removed: [.init(key: a.signingKey, at: now.addingTimeInterval(86_400 * 3_650))])
        let later = GroupRoster.Body(entries: [.init(card: a, added: now.addingTimeInterval(900))], removed: [])
        #expect(empty.merged(with: forever, group: group).merged(with: later, group: group).live.map(\.signingKey) == [a.signingKey])
        // An entry dated far ahead can't make someone impossible to remove: a removal now beats it.
        let pinned = GroupRoster.Body(entries: [.init(card: a, added: now.addingTimeInterval(86_400 * 3_650))], removed: [])
        let out = GroupRoster.Body(entries: [], removed: [.init(key: a.signingKey, at: now.addingTimeInterval(600))])
        #expect(pinned.merged(with: out, group: group).live.isEmpty)
        // Someone taken out isn't kept as an entry, so the cap counts only people who are in.
        let merged = GroupRoster.Body(entries: [.init(card: a, added: now), .init(card: b, added: now)], removed: [])
            .merged(with: .init(entries: [], removed: [.init(key: a.signingKey, at: now.addingTimeInterval(1))]), group: group)
        #expect(merged.entries.map(\.card.signingKey) == [b.signingKey])
        #expect(merged.removed.map(\.key) == [a.signingKey], "but the removal is kept against older copies")
    }
}
