import Foundation
import CryptoKit

// Short web links: `https://<domain>/i/<24 letters>` in place of an invite's whole code, which carries keys and runs to
// some 300 characters (too long for WhatsApp and others to link in full).
//
// The 24 letters are 120 random bits, too many to search for even by whoever holds the whole directory. From them come a
// name in the relay's handle directory (`_` and a hash, so the directory never holds the letters) and a key that seals
// what the link opens (the long code). The letters do reach the links' web server when a browser opens the page, which
// keeps no logs. The relay keeps the sealed code under
// that name like any listing: the first key to list a name owns it, so only the phone that made the link can change it.
// Anyone with the link can read it, nobody else can find it (lookups are by exact name, with no listing), and the
// directory alone can't open it. A link is put up only when Copy or Share is tapped, never because a screen opened. A link that stops being good (its group link reset, its invite used, its chat over) is overwritten with
// a note saying so, never released, so its name can't later pass to someone else who has the letters.

struct ShortCode: Equatable, Hashable {
    static let length = 24
    let text: String
    let raw: Data

    static func make() -> ShortCode { ShortCode(raw: .random(15)) }

    private init(raw: Data) {
        self.raw = raw
        text = Base32.encode(raw).lowercased()
    }

    init?(_ string: String) {
        let text = string.lowercased()
        guard text.count == Self.length, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              let raw = Base32.decode(text.uppercased()), raw.count == 15, Base32.encode(raw).lowercased() == text else { return nil }
        self.text = text
        self.raw = raw
    }

    private func derive(_ label: String, _ count: Int = 32) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw), salt: Data("pulshade.short.v2".utf8),
                               info: Data(label.utf8), outputByteCount: count).withUnsafeBytes { Data($0) }
    }

    /// The directory name it's listed under: `_` and 23 letters of a hash, which a handle can't be mistaken for (handles
    /// people pick start with a letter or a digit) and which says nothing of the link's own letters.
    var listing: String { "_" + String(Base32.encode(derive("listing")).lowercased().prefix(23)) }

    private var sealing: SymmetricKey { SymmetricKey(data: derive("sealing")) }

    /// What a short link opens: the long code, or a note that it no longer works. Padded to one size.
    struct Payload: Codable, Equatable {
        var target: String?
        var revoked: Bool?
    }

    static let paddedSize = 1024

    func seal(_ payload: Payload) -> Data? {
        guard let plain = try? JSONEncoder().encode(payload), plain.count + 3 <= Self.paddedSize else { return nil }
        var padded = Data([0x01])
        withUnsafeBytes(of: UInt16(plain.count).bigEndian) { padded.append(contentsOf: $0) }
        padded.append(plain)
        padded.append(Data(count: Self.paddedSize - padded.count))
        return try? AES.GCM.seal(padded, using: sealing, authenticating: Data(listing.utf8)).combined
    }

    func open(_ blob: Data) -> Payload? {
        guard blob.count <= Self.paddedSize + 64, let box = try? AES.GCM.SealedBox(combined: blob),
              let plain = try? AES.GCM.open(box, using: sealing, authenticating: Data(listing.utf8)),
              plain.first == 0x01, plain.count >= 3 else { return nil }
        let length = Int(plain[plain.startIndex + 1]) << 8 | Int(plain[plain.startIndex + 2])
        guard 3 + length <= plain.count else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: plain.subdata(in: (plain.startIndex + 3)..<(plain.startIndex + 3 + length)))
    }

    /// The directory entry, signed by the link's own key.
    func entry(_ payload: Payload, key: Curve25519.Signing.PrivateKey, updated: UInt64) -> RelayClient.DirectoryEntry? {
        guard let blob = seal(payload), let sig = try? key.signature(for: PublicNameCard.listed(listing, updated, blob)) else { return nil }
        return .init(key: key.publicKey.rawRepresentation.base64EncodedString(), blob: blob.base64EncodedString(),
                     sig: sig.base64EncodedString(), updated: updated)
    }

    /// What a directory entry for this link says, if it's really signed by the key it names and opens with these letters.
    func read(_ entry: RelayClient.DirectoryEntry) -> Payload? {
        guard let blob = Data(base64Encoded: entry.blob), let sig = Data(base64Encoded: entry.sig),
              let keyData = Data(base64Encoded: entry.key), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(sig, for: PublicNameCard.listed(listing, entry.updated, blob)) else { return nil }
        return open(blob)
    }
}

/// A short link this device made, kept to keep it listed and to mark it no longer good.
struct ShortLinkRecord: Codable, Equatable {
    var code: String
    /// The long code it opens.
    var target: String
    /// The private half of the key its listing is signed with.
    var key: Data
    var made: Date
    /// On the relay.
    var published: Bool = false
    /// No longer good: waiting for the note saying so to reach the relay.
    var revoked: Bool = false
}

extension AppModel {
    /// What a long code is for, so two codes for the same thing share one short link: an invite's mailbox (its text
    /// changes each time it's made, as its signature does), a group link's secret, or a chat link as it is.
    func shortKey(_ target: String) -> String {
        if let code = GroupLinkCode(text: target) { return "group:" + code.secret.hex }
        if target.lowercased().hasPrefix("pshchat1") { return "chat:" + target.lowercased() }
        if let invite = Invite(code: target) { return "invite:" + invite.sendID.hex }
        return "other:" + target
    }

    private func liveShort(_ target: String) -> ShortLinkRecord? {
        let key = shortKey(target)
        return data.shortLinks.first { !$0.revoked && shortKey($0.target) == key && $0.published }
            ?? data.shortLinks.first { !$0.revoked && shortKey($0.target) == key }
    }

    /// The link to share for a long code, put up on the relay now if it isn't yet: for Copy and Share.
    func linkToShare(_ target: String) async -> String {
        await prepareShortLink(target)
        return sharedLink(target) ?? WebLinks.long(target)
    }

    /// The most short links this device keeps live at once. Each takes a place in the relay's shared directory, and only
    /// a tap puts one up, so this is far past real use: past it, the long link is shared.
    static let maxShortLinks = 200

    /// The link to share for a long code: the short one once it's on the relay; the long one where there's no domain, or
    /// the short one couldn't be put up. Nil while it's being put up, a few seconds at most.
    func sharedLink(_ target: String) -> String? {
        guard WebLinks.domain != nil else { return WebLinks.long(target) }
        if let record = liveShort(target), record.published, let code = ShortCode(record.code) {
            return WebLinks.short(code)
        }
        return shortLinkFailed.contains(target) ? WebLinks.long(target) : nil
    }

    /// Puts up the short link for a long code, if it has none yet. Screens that show a link call this as they appear.
    func prepareShortLink(_ target: String) async {
        guard WebLinks.domain != nil, !target.isEmpty else { return }
        dropUnreadableShortLinks()
        if liveShort(target)?.published == true { return }
        guard !preparingShort.contains(shortKey(target)) else { return }
        preparingShort.insert(shortKey(target))
        defer { preparingShort.remove(shortKey(target)) }
        shortLinkFailed.remove(target)
        if liveShort(target) == nil {
            guard data.shortLinks.filter({ !$0.revoked }).count < Self.maxShortLinks else { shortLinkFailed.insert(target); return }
            let key = Curve25519.Signing.PrivateKey()
            data.shortLinks.append(ShortLinkRecord(code: ShortCode.make().text, target: target, key: key.rawRepresentation, made: Date()))
            save()
        }
        for _ in 0..<2 {
            guard let record = liveShort(target) else { return }
            switch await publish(record) {
            case .done: return
            case .taken:
                // Someone already has those letters (with 80 random bits, never in practice): new ones.
                if let i = data.shortLinks.firstIndex(of: record) { data.shortLinks[i].code = ShortCode.make().text; save() }
            case .failed:
                shortLinkFailed.insert(target)
                return
            }
        }
        shortLinkFailed.insert(target)
    }

    private enum ShortPublish { case done, taken, failed }

    private func publish(_ record: ShortLinkRecord) async -> ShortPublish {
        guard let code = ShortCode(record.code), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: record.key),
              let client = client(nil, lane: "short|" + code.listing) else { return .failed }
        let payload = record.revoked ? ShortCode.Payload(target: nil, revoked: true) : ShortCode.Payload(target: record.target)
        var stamp = directoryStamp(code.listing)
        for _ in 0..<2 {
            guard let entry = code.entry(payload, key: key, updated: stamp) else { return .failed }
            do {
                try await client.claim(code.listing, entry)
                return finishPublish(record)
            } catch RelayClient.DirectoryError.taken {
                // Taken, or ours with a stamp no newer than what's listed (a revoke within the same minute as the link
                // was put up, say). Only done if the relay already says exactly this, under our key; otherwise once more,
                // stamped after what's there.
                let listed: RelayClient.DirectoryEntry?
                do { listed = try await client.lookup(code.listing) } catch { return .failed }
                guard let listed else { return .failed }
                guard Data(base64Encoded: listed.key) == key.publicKey.rawRepresentation else { return record.published ? .failed : .taken }
                if code.read(listed) == payload { return finishPublish(record) }
                stamp = max(stamp, listed.updated) + 60_000
            } catch {
                return .failed
            }
        }
        return .failed
    }

    private func finishPublish(_ record: ShortLinkRecord) -> ShortPublish {
        if let i = data.shortLinks.firstIndex(where: { $0.code == record.code }) {
            if record.revoked { data.shortLinks.remove(at: i) } else { data.shortLinks[i].published = true }
            save()
        }
        return .done
    }

    /// Whether what a short link opens still works: a group link still there with the same secret and open, a chat still
    /// running, an invite this device still holds open.
    func shortTargetGood(_ target: String) -> Bool {
        if let code = GroupLinkCode(text: target) {
            return data.conversations.contains { c in
                c.shared?.links?.links.contains { $0.secret == code.secret && $0.isOpen() } == true
            }
        }
        if target.lowercased().hasPrefix("pshchat1") {
            return ChatLink(target).map { $0.endsAt > Date() } ?? false
        }
        if let invite = Invite(code: target) {
            return data.invites.contains { Mailbox.sendID(for: $0.receiveKey) == invite.sendID }
        }
        return false
    }

    /// Marks short links whose code no longer works, and puts up any change waiting. From housekeeping, now and then.
    /// Links in a format this build doesn't make (the 16-letter ones of a test build) are let go of.
    private func dropUnreadableShortLinks() {
        let before = data.shortLinks.count
        data.shortLinks.removeAll { ShortCode($0.code) == nil }
        if data.shortLinks.count != before { save() }
    }

    func tendShortLinks() async {
        dropUnreadableShortLinks()
        var changed = false
        var seen = Set<String>()
        // Newest first: of several links for the same thing (made by a build that saw a channel's code change at every
        // redraw), the newest published one stays and the rest are marked.
        let order = data.shortLinks.indices.sorted {
            (data.shortLinks[$0].published ? 1 : 0, data.shortLinks[$0].made) > (data.shortLinks[$1].published ? 1 : 0, data.shortLinks[$1].made)
        }
        for i in order where !data.shortLinks[i].revoked {
            let key = shortKey(data.shortLinks[i].target)
            if !shortTargetGood(data.shortLinks[i].target) || seen.contains(key) {
                data.shortLinks[i].revoked = true
                changed = true
            } else {
                seen.insert(key)
            }
        }
        if changed { save() }
        // Never-published links that are no longer good have nothing on the relay to overwrite.
        data.shortLinks.removeAll { $0.revoked && !$0.published }
        for record in data.shortLinks where record.revoked || !record.published {
            if record.revoked { _ = await publish(record) } else if shortTargetGood(record.target) { _ = await publish(record) }
        }
    }

    /// Every short link this device made says it no longer works: on Burn, while the keys are still here.
    func revokeAllShortLinks() async {
        for i in data.shortLinks.indices { data.shortLinks[i].revoked = true }
        data.shortLinks.removeAll { !$0.published }
        save()
        await publishRevokes(data.shortLinks)
    }

    /// Marks the short links to a persona's invites no longer good, before the persona and its invites go.
    func revokeShortLinks(ofPersona persona: UUID) async {
        let boxes = Set(data.invites.filter { $0.persona == persona }.map { "invite:" + Mailbox.sendID(for: $0.receiveKey).hex })
        for i in data.shortLinks.indices where boxes.contains(shortKey(data.shortLinks[i].target)) { data.shortLinks[i].revoked = true }
        data.shortLinks.removeAll { $0.revoked && !$0.published }
        save()
        await publishRevokes(data.shortLinks.filter(\.revoked))
    }

    /// Several at once, each on its own connection, so a Burn's few seconds reach them all.
    private func publishRevokes(_ records: [ShortLinkRecord]) async {
        await withTaskGroup(of: Void.self) { group in
            for record in records where record.revoked {
                group.addTask { @MainActor [weak self] in _ = await self?.publish(record) }
            }
        }
    }

    enum ShortLinkError: Error { case gone, unreachable, invalid }

    /// What a short link opens, looked up on the relay over a connection of its own.
    func resolveShortLink(_ code: ShortCode) async throws -> WebLinks.Target {
        guard let client = client(nil, lane: "short-read|" + UUID().uuidString) else { throw ShortLinkError.unreachable }
        let found: RelayClient.DirectoryEntry?
        do { found = try await client.lookup(code.listing) } catch { throw ShortLinkError.unreachable }
        guard let entry = found else { throw ShortLinkError.gone }
        guard let payload = code.read(entry) else { throw ShortLinkError.invalid }
        guard payload.revoked != true, let target = payload.target, let opened = WebLinks.target(forCode: target) else {
            throw ShortLinkError.gone
        }
        return opened
    }

    /// Opens a short link: looks it up, then opens what it stands for as its own link would.
    func openShortLink(_ code: ShortCode) async {
        do {
            let target = try await resolveShortLink(code)
            openTarget(target)
        } catch ShortLinkError.unreachable {
            linkProblem = "Can't reach the relay to open this link. Try again in a moment."
        } catch {
            linkProblem = "This link doesn't work any more. Ask for a new one."
        }
    }
}
