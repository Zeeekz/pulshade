import Foundation
import CryptoKit

// Public names for groups and channels (`PublicNameCard`), in the same directory, and so the same pool of names, as
// people's @handles. A group's owner names it, and the name opens a join link made for it; a channel's admin names
// it, and the name opens the channel's code. Each name's directory traffic goes on a lane of its own, so the relay
// can't tie it to the account's other lookups.

extension AppModel {
    enum PublicNameError: Error { case notAllowed, invalidHandle, reserved, taken, held, unreachable, failed }

    /// The public name this device claimed for a conversation, if any.
    func publicName(_ id: Conversation.ID) -> PublicName? { data.publicNames.first { $0.conversation == id } }

    /// Whether this account can name the conversation: a group's owner, or a channel's admin.
    func canNamePublicly(_ id: Conversation.ID) -> Bool { anchor(for: id) != nil }

    /// The key that vouches for a conversation's name, and the kind of name.
    private func anchor(for id: Conversation.ID) -> (key: Curve25519.Signing.PrivateKey, kind: PublicNameCard.Kind)? {
        guard let c = conversation(id), let shared = c.shared, !shared.gone, !shared.joining else { return nil }
        switch c.kind {
        case .group:
            guard let keys = memberKeys(c.persona, group: c.wireID), shared.settings.owner == keys.publicKey else { return nil }
            return (keys.signing, .group)
        case .channel:
            guard c.amAdmin, let me = me(c.persona) else { return nil }
            return (me.signingKey, .channel)
        default:
            return nil
        }
    }

    private func nameLane(_ id: Conversation.ID) -> String { "name|" + id.uuidString }

    /// What the name's web page shows for a conversation now.
    func shownForName(_ id: Conversation.ID) -> PublicNameCard.Shown {
        guard let c = conversation(id) else { return .init() }
        let about = c.about?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PublicNameCard.Shown(title: c.title, about: about?.isEmpty == false ? about : nil,
                                    picture: Self.thumbnail(c.avatar, side: 320),
                                    members: c.kind == .group ? c.members.count + 1 : nil).trimmed
    }

    /// What the name opens now: the code of the group's link for it (made on the way, if it has none yet), or the
    /// channel's code.
    private func nameCode(for id: Conversation.ID, kind: PublicNameCard.Kind, approval: Bool) -> (code: String, link: UUID?)? {
        switch kind {
        case .channel:
            let code = makeInviteCode(channel: id)
            return code.isEmpty ? nil : (code, nil)
        case .group:
            if let held = publicName(id)?.link, let link = joinLinks(id)?.link(held), let code = linkCode(link, in: id) {
                return (code.text, link.id)
            }
            guard let link = makeJoinLink(in: id, label: "Public name", approval: approval),
                  let code = linkCode(link, in: id) else { return nil }
            return (code.text, link.id)
        }
    }

    /// Claims `raw` as the conversation's public name, letting go of the one it had. For a group, `approval` says whether
    /// people who join through the name wait for an admin's yes.
    func setPublicName(_ raw: String, for id: Conversation.ID, approval: Bool = true) async throws {
        guard let handle = DirectoryProfile.validHandle(raw) else { throw PublicNameError.invalidHandle }
        guard !DirectoryProfile.isReserved(handle) else { throw PublicNameError.reserved }
        guard let (anchor, kind) = anchor(for: id) else { throw PublicNameError.notAllowed }
        let old = publicName(id)
        guard let (code, link) = nameCode(for: id, kind: kind, approval: approval) else { throw PublicNameError.failed }
        let shown = shownForName(id)
        let key = try await publish(handle, code: code, kind: kind, anchor: anchor, conversation: id, shown: shown)
        data.publicNames.removeAll { $0.conversation == id }
        data.publicNames.append(PublicName(conversation: id, handle: handle, link: link, key: key.rawRepresentation, shown: shown.digest))
        // The old name is let go of, and tried again until the relay has let it go.
        if let old, old.handle != handle { queueRelease(old) }
        save()
        await releasePendingNames()
    }

    /// Lets go of the conversation's public name. The group's link for it goes too. Until the relay has let it go, it's
    /// tried again (`releasePendingNames`), even once the conversation is gone.
    func removePublicName(for id: Conversation.ID) async {
        guard let name = publicName(id) else { return }
        queueRelease(name)
        if let link = name.link, joinLinks(id)?.link(link) != nil { deleteJoinLink(link, in: id) }
        save()
        await releasePendingNames()
    }

    /// Takes a name off the conversation and into the names waiting to be let go of.
    private func queueRelease(_ name: PublicName) {
        data.publicNames.removeAll { $0.conversation == name.conversation && $0.handle == name.handle }
        guard let key = name.key, !data.namesToRelease.contains(where: { $0.handle == name.handle && $0.key == key }) else { return }
        data.namesToRelease.append(NameRelease(handle: name.handle, key: key))
    }

    /// A conversation going (deleted, left, its persona or the account burned): its name goes with it.
    func dropPublicName(of id: Conversation.ID) {
        if let name = publicName(id) { queueRelease(name) }
    }

    /// Names this device can no longer stand behind (the group passed to a new owner, you're no longer the channel's
    /// admin) are let go of; then every name waiting is tried. Called from housekeeping, now and then.
    func tendPublicNames() async {
        for name in data.publicNames where conversation(name.conversation).map({ $0.shared?.joining != true && anchor(for: $0.id) == nil }) ?? true {
            queueRelease(name)
        }
        await releasePendingNames()
        // The group's title, description, picture or size changed: the name's page shows the new ones.
        for name in data.publicNames where name.shown != shownForName(name.conversation).digest {
            await refreshPublicName(for: name.conversation)
        }
    }

    /// From housekeeping, which runs every couple of seconds: names are looked after every ten minutes or so.
    func tendPublicNamesNow() {
        guard !data.publicNames.isEmpty || !data.namesToRelease.isEmpty || !data.shortLinks.isEmpty, !tendingNames,
              Date().timeIntervalSince(namesTended) > 600 else { return }
        tendingNames = true
        namesTended = Date()
        Task { [weak self] in
            await self?.tendPublicNames()
            await self?.tendShortLinks()
            self?.tendingNames = false
        }
    }

    /// Asks the relay to let go of every name waiting. One stays waiting until the relay no longer lists it under its key.
    func releasePendingNames() async {
        let waiting = data.namesToRelease
        guard !waiting.isEmpty else { return }
        var done: [NameRelease] = []
        for name in waiting where await release(name) { done.append(name) }
        guard !done.isEmpty else { return }
        data.namesToRelease.removeAll { done.contains($0) }
        save()
    }

    private func release(_ name: NameRelease) async -> Bool {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: name.key) else { return true }
        guard let client = client(nil, lane: "name|" + name.handle) else { return false }
        let ts = UInt64(RelayClock.now.timeIntervalSince1970)
        let message = Data("pulshade.dir.del.v1".utf8) + Data(name.handle.utf8) + withUnsafeBytes(of: ts.bigEndian) { Data($0) }
        guard let sig = try? key.signature(for: message) else { return false }
        if (try? await client.release(name.handle, sig: sig.base64EncodedString(), ts: ts)) != nil { return true }
        // Refused: done if the relay doesn't list it under this key any more (released already, or someone else's now).
        let listed: RelayClient.DirectoryEntry?
        do { listed = try await client.lookup(name.handle) } catch { return false }
        guard let listed else { return true }
        return Data(base64Encoded: listed.key) != key.publicKey.rawRepresentation
    }

    /// Lists the name again with what it opens now: after its group link was reset, say.
    func refreshPublicName(for id: Conversation.ID) async {
        guard let name = publicName(id), let (anchor, kind) = anchor(for: id),
              let (code, link) = nameCode(for: id, kind: kind, approval: true) else { return }
        let shown = shownForName(id)
        guard (try? await publish(name.handle, code: code, kind: kind, anchor: anchor, conversation: id, shown: shown)) != nil,
              let i = data.publicNames.firstIndex(where: { $0.conversation == id }) else { return }
        data.publicNames[i].link = link
        data.publicNames[i].shown = shown.digest
        save()
    }

    private func publish(_ handle: String, code: String, kind: PublicNameCard.Kind, anchor: Curve25519.Signing.PrivateKey,
                         conversation id: Conversation.ID, shown: PublicNameCard.Shown) async throws -> Curve25519.Signing.PrivateKey {
        guard let client = client(nil, lane: nameLane(id)) else { throw PublicNameError.unreachable }
        let (card, key) = try PublicNameCard.make(kind, handle: handle, code: code, anchor: anchor,
                                                  conversation: conversation(id)?.wireID ?? id, shown: shown)
        let entry = try card.entry(signedWith: key, updated: directoryStamp(handle))
        do {
            try await client.claim(handle, entry)
            return key
        } catch RelayClient.DirectoryError.taken { throw PublicNameError.taken
        } catch RelayClient.DirectoryError.reserved { throw PublicNameError.reserved
        } catch RelayClient.DirectoryError.held { throw PublicNameError.held
        } catch RelayClient.DirectoryError.unreachable { throw PublicNameError.unreachable
        } catch { throw PublicNameError.failed }
    }

    /// Opens what a group's or channel's name found by `findProfile` is for: its join screen, or the channel's code
    /// (which still waits for a yes). Only for someone who searched for the name. False if it wasn't one.
    @discardableResult
    func openFoundPublicName(_ handle: String) -> Bool {
        guard let card = foundPublicNames.removeValue(forKey: handle) else { return false }
        switch card.kind {
        case .group:
            guard let code = GroupLinkCode(text: card.code) else { return false }
            openedGroupLink = OpenedGroupLink(code: code)
        case .channel:
            openedCode = card.code
        }
        return true
    }
}
