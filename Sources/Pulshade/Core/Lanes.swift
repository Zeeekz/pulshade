import Foundation
import CryptoKit

/// Which connection (and over Tor, which circuit) each kind of traffic goes on, so that what the relay sees on one of
/// them says as little as possible about the rest. A lane's name never leaves the phone: Tor isolates circuits by it,
/// and the app keeps one set of connections for each.
///
/// - A persona's one-to-one mailboxes are read on a few lanes (`fetchSplit`), each mailbox on one of them, so no
///   single fetch names every contact a persona has.
/// - Each shared group is read on a lane of its own, apart from the one-to-one mailboxes, and posted to on another.
/// - Sending lanes are let go of after a burst of sending, or after a few minutes, and nothing is sent on them just to
///   keep them open (`SendLanes`).
/// - Delivery receipts, files, wake-up registrations and the parts of a Burn each go on a lane used once.
enum Lanes {
    /// How many lanes a persona's one-to-one mailboxes are spread over, over Tor.
    static let fetchSplit = 3
    /// Shared groups read on lanes of their own, at most. Past it they share lanes (only with other groups, never with
    /// one-to-one mail): every lane is a Tor circuit kept open and a fetch kept waiting, which a phone pays for.
    static let maxGroupLanes = 16

    /// Which of a persona's `count` fetch lanes a mailbox is read on. Fixed for this account (the salt is kept in its
    /// data), so the relay never sees a mailbox move from one lane to another: two lanes that once shared a mailbox would
    /// be known to be one person's.
    static func bucket(of key: Data, salt: Data, count: Int = fetchSplit) -> Int {
        guard count > 1 else { return 0 }
        let mac = HMAC<SHA256>.authenticationCode(for: Data("pulshade.lane.v1".utf8) + key, using: SymmetricKey(data: salt))
        let first = Data(mac).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Int(first % UInt32(count))
    }

    /// The fetch lane of a persona's mailbox. The first of a persona's lanes keeps the persona's plain name, so the main
    /// persona's first lane is still "main", the one that says whether the relay is there.
    static func fetchLane(persona: UUID?, bucket: Int) -> String {
        let base = persona?.uuidString ?? "main"
        return bucket == 0 ? base : "\(base)/\(bucket)"
    }

    /// The lane a shared group is read on: its own while there are few enough, otherwise one shared with other groups.
    /// `slot` is the group's place among this device's groups (see `AppModel.groupLanes`).
    static func groupReadLane(slot: Int) -> String { "group/\(slot)" }

    /// The lane a shared group's posts go out on, before `SendLanes` gives it its current circuit.
    static func groupSendLane(_ convo: UUID) -> String { "gsend|" + convo.uuidString }

    /// A lane used for one thing and then let go of: a delivery receipt, a file, a wake-up registration, part of a Burn.
    static func once(_ kind: String) -> String { oncePrefix + kind + "|" + Data.random(8).hex }
    static let oncePrefix = "once|"

    /// The wait before a delivery receipt goes out: long enough that it doesn't follow the fetch that brought the
    /// message closely enough to pair the two mailboxes on the relay.
    static let receiptDelay: ClosedRange<Double> = 5...20

    /// How long a receipt waits. In the background, after a wake-up push, iOS gives Pulshade about half a minute in all;
    /// the receipt must leave inside it (a fresh Tor circuit takes some seconds), so it waits only as long as what's
    /// left of that allows, `room` seconds. Nil `room` is the app in front.
    static func receiptWait(room: TimeInterval?) -> TimeInterval {
        let wanted = Double.random(in: receiptDelay)
        guard let room else { return wanted }
        return max(0.5, min(wanted, room))
    }

    /// A duplicate of a message already here is answered with a receipt (the sender may have lost the first) at most once
    /// a day for each message, and at most this many times an hour for each contact, so a contact can't send the same
    /// message over and over to find out when each of your devices is running.
    static let duplicateReceiptGap: TimeInterval = 86_400
    static let duplicateReceiptsPerHour = 20

    /// How long a lane that was just reconnected waits before it asks the relay anything, after coming back to the
    /// front, a refresh or an unlock: the main lane at once, the main persona's others soon, everything else at its own
    /// random moment within a minute. So the relay doesn't see every lane of one phone arrive in the same second.
    static func resumeDelay(lane: String, mainPersona: Bool, urgent: Bool) -> TimeInterval {
        if lane == "main" { return 0 }
        if urgent { return .random(in: 0...3) }
        return mainPersona ? .random(in: 0.5...10) : .random(in: 2...60)
    }
}

/// The circuit a sending lane is on. A lane keeps one only for a burst of sending: once it has been quiet for
/// `idle`, or has been in use for `maxAge`, the next send gets a fresh one (a new lane name, so a new Tor circuit and new
/// connections). The relay can then only link what one burst sent, not everything a persona has sent since unlock.
/// Memory only.
struct SendLanes {
    static let idle: TimeInterval = 90
    static let maxAge: TimeInterval = 300

    private struct Turn { var name: String; var started: Date; var last: Date; var busy: Int }
    private var turns: [String: Turn] = [:]

    /// The lane name to send on now for `base`, moving to a fresh circuit when the last one is due to go. Returns the
    /// lane that was let go of, if any, so its connections can be closed. Never moves while something is being sent on it.
    mutating func current(_ base: String, now: Date = Date()) -> (name: String, retired: String?) {
        guard var turn = turns[base] else {
            let fresh = Turn(name: Self.fresh(base), started: now, last: now, busy: 0)
            turns[base] = fresh
            return (fresh.name, nil)
        }
        var retired: String?
        if turn.busy == 0, now.timeIntervalSince(turn.last) > Self.idle || now.timeIntervalSince(turn.started) > Self.maxAge {
            retired = turn.name
            turn = Turn(name: Self.fresh(base), started: now, last: now, busy: 0)
        }
        turn.last = now
        turns[base] = turn
        return (turn.name, retired)
    }

    /// A send on lane `name` started (`delta` +1) or ended (-1).
    mutating func note(_ name: String, busy delta: Int, now: Date = Date()) {
        guard let base = turns.first(where: { $0.value.name == name })?.key, var turn = turns[base] else { return }
        turn.busy = max(0, turn.busy + delta)
        turn.last = now
        turns[base] = turn
    }

    /// Lanes quiet for longer than `idle`, forgotten now so their connections can go rather than wait for the next send.
    mutating func takeIdle(now: Date = Date()) -> [String] {
        let quiet = turns.filter { $0.value.busy == 0 && now.timeIntervalSince($0.value.last) > Self.idle }
        for base in quiet.keys { turns[base] = nil }
        return quiet.values.map(\.name)
    }

    mutating func reset() { turns = [:] }

    /// Every turn gets a name never used before, so Tor never hands it a circuit an earlier turn had.
    private static func fresh(_ base: String) -> String { base + "~" + Data.random(6).hex }
}
