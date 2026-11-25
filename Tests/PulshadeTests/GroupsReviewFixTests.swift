import Testing
import Foundation
import CryptoKit
@testable import Pulshade

/// The pieces behind the fixes to groups, channels, linked devices and codes from the review of 24 November 2026, checked
/// without a relay.
struct GroupsReviewFixTests {
    let group = UUID()

    /// A channel code names its channel under the signature, a code from before names none, and a code whose channel was
    /// swapped isn't read at all.
    @Test func aChannelCodeNamesItsChannel() throws {
        let me = Identity.generate()
        let sendID = Data.random(32)
        let named = try Invite(kind: .channel, identity: me, sendID: sendID, channel: group)
        let parsed = try #require(Invite(code: named.code))
        #expect(parsed.kind == .channel && parsed.channel == Invite.channelCommit(group) && parsed.sendID == sendID)
        #expect(parsed.channel != Invite.channelCommit(UUID()))
        #expect(!named.code.contains(group.uuidString.lowercased()), "the id itself isn't in the code")

        let old = try Invite(kind: .channel, identity: me, sendID: sendID)
        #expect(Invite(code: old.code)?.channel == nil && Invite(code: old.code)?.kind == .channel)
        // With a relay after it, both still read.
        let relayed = try Invite(kind: .channel, identity: me, sendID: sendID, relay: AppData.defaultRelay, channel: group)
        #expect(Invite(code: relayed.code)?.relay == AppData.defaultRelay && Invite(code: relayed.code)?.channel == Invite.channelCommit(group))
        // A contact code never names a channel.
        #expect(try Invite(kind: .contact, identity: me, sendID: sendID, channel: group).channel == nil)

        // Another channel's commitment put in place of this one's: the signature no longer holds.
        let swapped = Invite(kind: .channel, signingKey: named.signingKey, agreementKey: named.agreementKey, bind: named.bind,
                             pqHash: named.pqHash, sendID: sendID, channel: Invite.channelCommit(UUID()))
        #expect(Invite(code: swapped.code) == nil)
        // Nor can the name be taken off to pass as a code from before.
        let stripped = Invite(kind: .channel, signingKey: named.signingKey, agreementKey: named.agreementKey, bind: named.bind,
                              pqHash: named.pqHash, sendID: sendID)
        #expect(Invite(code: stripped.code) == nil)
    }

    /// Only someone the settings name as staff can vouch, only for the account named, and only in that channel.
    @Test func onlyStaffCanVouchForTheAccountSendingAChannelInvite() throws {
        let owner = GroupMemberKeys(seed: .random(32), group: group)
        let follower = GroupMemberKeys(seed: .random(32), group: group)
        let settings = GroupSettings(group: group, kind: .channel, version: 1, epoch: 1, title: "Drops", owner: owner.publicKey,
                                     members: [MemberCard.make(owner, group: group, name: "o", avatar: nil, color: nil).withoutAvatar])
        let staffAccount = Data.random(32), forwarder = Data.random(32)
        let vouch = try #require(StaffVouch.make(owner, group: group, account: staffAccount))
        #expect(vouch.checks(settings, account: staffAccount))
        #expect(!vouch.checks(settings, account: forwarder), "forwarded by someone else, it names the wrong account")
        let own = try #require(StaffVouch.make(follower, group: group, account: forwarder))
        #expect(!own.checks(settings, account: forwarder), "a follower isn't staff")
        var other = settings
        other.group = UUID()
        #expect(!vouch.checks(other, account: staffAccount), "another channel")
    }

    /// A device's vouch holds only for the device and keys it names, made by keys the account signed for the voucher.
    @Test func aDeviceVouchNamesTheDeviceAndItsKeys() throws {
        let account = Identity.generate()
        let voucherID = Data.random(16), newID = Data.random(16)
        let voucher = try DeviceKey(seed: .random(32), persona: nil)
        let card = try voucher.card(account: account, device: voucherID)
        let newPin = try DeviceKey(seed: .random(32), persona: nil).pin
        let vouch = try DeviceVouch.make(key: voucher, card: card, account: account.card.signing, by: voucherID, device: newID, pin: newPin)
        let pq = account.pq.pin
        #expect(vouch.checks(account: account.card.signing, accountPQ: pq, device: newID, pin: newPin))
        #expect(!vouch.checks(account: account.card.signing, accountPQ: pq, device: newID, pin: Data.random(32)), "other keys")
        #expect(!vouch.checks(account: account.card.signing, accountPQ: pq, device: Data.random(16), pin: newPin), "another device")
        #expect(!vouch.checks(account: account.card.signing, accountPQ: pq, device: voucherID, pin: newPin), "not for itself")
        let stranger = Identity.generate()
        #expect(!vouch.checks(account: stranger.card.signing, accountPQ: stranger.pq.pin, device: newID, pin: newPin), "another account")
        // A device the account never signed for can't vouch, even with the account's own name on it.
        let rogue = try DeviceKey(seed: .random(32), persona: nil)
        var forged = vouch
        forged.sig = try rogue.sign(DeviceVouch.message(account: account.card.signing, by: voucherID, device: newID, pin: newPin))
        #expect(!forged.checks(account: account.card.signing, accountPQ: pq, device: newID, pin: newPin))
    }

    /// A chain passed on by someone else that doesn't open its device's own post is dropped (so the real one can come);
    /// one that does is kept for good.
    @Test func aPassedOnChainStandsOnlyOnceItsDevicesPostOpens() {
        var reader = GroupReader()
        let sender = Data.random(32), device = Data.random(8)
        let real = SenderChain.fresh(), planted = SenderChain.fresh()
        let r1 = reader.start(epoch: 2, sender: sender, device: device, chain: planted, proven: false)
        #expect(r1)
        // Another passed-on chain doesn't replace one held, proved or not.
        let r2 = reader.start(epoch: 2, sender: sender, device: device, chain: real, proven: false)
        #expect(!r2)
        // The device's post doesn't open with it: it goes.
        let r3 = reader.dropUnproven(epoch: 2, sender: sender, device: device)
        #expect(r3)
        #expect(!reader.follows(epoch: 2, sender: sender, device: device))
        let r4 = reader.start(epoch: 2, sender: sender, device: device, chain: real, proven: false)
        #expect(r4)
        reader.proved(epoch: 2, sender: sender, device: device)
        let kept = reader.dropUnproven(epoch: 2, sender: sender, device: device)
        #expect(!kept, "proved: kept")
        #expect(reader.unproven == nil)
        // From its own device, a chain replaces a passed-on one nothing proved.
        let other = Data.random(8)
        let r5 = reader.start(epoch: 2, sender: sender, device: other, chain: planted, proven: false)
        #expect(r5)
        let r6 = reader.start(epoch: 2, sender: sender, device: other, chain: real)
        #expect(r6)
        #expect(reader.chains[GroupReader.id(epoch: 2, sender: sender, device: other)] == real && reader.unproven == nil)
    }

    /// Untagged previews (owners on builds 19 and 20) stop being taken at the start of 2027.
    @Test func untaggedPreviewsEndWithTheYear() {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: GroupPreview.untaggedUntil)
        #expect(parts.year == 2027 && parts.month == 1 && parts.day == 1 && parts.hour == 0)
    }
}
