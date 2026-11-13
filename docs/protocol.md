# The Pulshade protocol and threat model

**DRAFT.** For people who want to check Pulshade's claims, and for anyone reviewing it from outside. It says what the
app does with your keys and messages, what the server does and keeps, and who can learn what. The friendlier tour is
[How Pulshade works](how-it-works.md); what we keep and for how long is in the [privacy policy](privacy-policy.md).

Pulshade has **not had an independent audit yet**. The cryptography here is our own code following published designs
(Signal's Double Ratchet, X3DH-style key agreement, ML-KEM-768). Treat every claim below as "what we built and tested",
not "what an expert has confirmed". Where something is a weakness, this document says so.

The app is open source. The server (the "relay") is a private program. This document describes what the relay does,
because the app's design depends on it, but does not publish its code, addresses, keys or admin tools. Everything the
relay is trusted with is listed under [What the relay stores](#what-the-relay-stores-and-for-how-long), and the design
aims to make that trust small: the relay only ever handles sealed bytes.

## The ideas in short

- No accounts. You have a key pair made on your device. No phone number, email or name is needed.
- Every message is end-to-end encrypted with its own key, used once.
- The relay is a post box. It holds sealed envelopes until the other phone collects them, then forgets them. It cannot
  read an envelope and does not learn who sent it.
- Over Tor the relay cannot see your IP address. In Fast mode it can (see [Tor and Fast](#tor-and-fast)).
- Anything the relay keeps beyond waiting mail is sealed on your phone first, with keys the relay never has.

## 1. Identity keys and fingerprints

*Code: `Sources/Pulshade/Core/Identity.swift`.*

An identity is **32 random bytes** (the *seed*), made on the device from the system's secure random generator. Every
other key is derived from it with HKDF-SHA256, each with its own label:

| Key | Use |
| --- | --- |
| Signing key (Ed25519) | Vouches for the agreement key, signs directory entries (public @handles) |
| Agreement key (X25519) | The long-term key people seal envelopes to; used in the handshake |
| Envelope key (ML-KEM-768) | The post-quantum half of what envelopes are sealed to. Seed (64 bytes) from HKDF label `pulshade.pq.envelope.kem.v1` |
| Post-quantum signing key (ML-DSA-65) | Signs, next to the Ed25519 key, everything that is not a ratchet message. Seed (32 bytes) from label `pulshade.pq.signing.v1` |
| Storage key | Seals the local database on the device. Never leaves it |
| Backup signing key and backup sealing key | For the sealed backup. Unrelated to the keys above on the wire |
| Public-inbox key, one per @handle | The mailbox behind a public handle |

The **recovery code** is the seed written as 52 characters of Crockford base32 plus a 4-character checksum, in 14
groups of four. It is the only way back in if the device is lost. Anyone who has it *is* you: it is the whole identity.

The **fingerprint** is the first 16 bytes (32 hex characters) of SHA-256 of the signing public key. It names an account
inside the app and seeds the artwork you see for it.

**Checking who you are talking to** (the "pulse check"): both phones work out the same code from both identities (each a
signing-key fingerprint together with its agreement key and a commitment to its post-quantum keys, `pulshade.safety.v3`), sorted so the order does not matter. It is shown as 10 emoji (60 bits), 30 digits, two colours, and a QR code that
carries 160 bits. Comparing in person, or scanning the other phone's QR, marks the contact verified. Nothing is
verified for you automatically: the first time you meet a key you trust it, the way most messengers do, and the code
is how you catch someone sitting in the middle. There is no key transparency log.

One account can be several **personas** (separate identities) and several **devices** (the same identity on more than
one phone or Mac). See [section 6](#6-multi-device-and-personas).

## 2. The handshake

*Code: `Sources/Pulshade/Core/Handshake.swift`.*

Two people start a conversation by setting up a shared secret, the *session root*. It is a hybrid: it is safe if
**either** X25519 **or** ML-KEM-768 holds.

1. The one who starts (the *initiator*) makes a fresh X25519 key and a fresh ML-KEM-768 key pair and sends the two
   public halves (`SessionInit`).
2. The other side (the *responder*) makes its own fresh X25519 key, and "encapsulates" to the initiator's ML-KEM key,
   which gives a secret plus a ciphertext. It sends back its public X25519 key and the ciphertext (`SessionAccept`).
3. Both sides now have the same four secrets and join them:
   - DH(initiator's throwaway key, responder's long-term agreement key)
   - DH(initiator's long-term agreement key, responder's throwaway key)
   - DH(initiator's throwaway key, responder's throwaway key)
   - the ML-KEM shared secret
4. The session root is HKDF-SHA256 over those four, salted with a hash of the whole public transcript (both throwaway
   keys, the ML-KEM public key, the ciphertext), with the label `pulshade.handshake.v1`. A different transcript gives
   a different root.

What this gives:

- **Who:** the two long-term DH steps mean only the real holders of both identity keys can compute the root. There is
  no separate signature on the handshake.
- **Forward secrecy:** the third DH uses two throwaway keys that are deleted once they are no longer needed; stealing
  identity keys later does not reveal the root. "No longer needed" is not immediate in every case. To finish a
  handshake whose answer arrives late, a device keeps the secret halves of up to its **3 latest unanswered asks** to
  each friend's device for up to **8 days**, keeps up to **4 sessions it replaced** after logging back in, and keeps a
  retired spare key's secret half for about **10 days** ([section 5](#5-spare-keys)). All of these sit in the encrypted
  vault, and so in the sealed backup ([section 8](#8-sealed-backups)).
- **Quantum resistance:** an attacker who records the handshake and later breaks X25519 still lacks the ML-KEM secret.
- The **responder speaks first**, and uses the initiator's throwaway key as its first ratchet key.
- Crossed handshakes (both sides starting at once) are settled by comparing (fingerprint, device id): the lower one wins.
- Every handshake message travels inside a sealed-sender envelope ([section 4](#4-sealed-sender-envelopes-and-padding-buckets)),
  so it is also tied to the sender's identity there.

A "spare key" ([section 5](#5-spare-keys)) is just the first half of this handshake made ahead of time.

## 3. The double ratchet

*Code: `Sources/Pulshade/Core/Ratchet.swift`.*

After the handshake, each pair of devices talks through a Double Ratchet, as Signal specifies it. In plain words:

- Every message gets its **own key**, taken from a chain that only moves forward. The key is used once and thrown away.
  Stealing a device's current state does not open messages it already received (**forward secrecy**).
- Whenever the other side replies, a **fresh X25519 exchange** is mixed into the root. After a theft, the next round of
  replies locks the thief out again (**healing**).
- Primitives: HKDF-SHA256 for the root step, HMAC-SHA256 for the chain, ChaCha20-Poly1305 for the message. Each message
  key is stretched into a cipher key and nonce, and used for exactly one message. The session's fixed data (both
  long-term agreement keys) and the message header (ratchet public key, chain length, position) are authenticated, so a
  message cannot be moved into another pair's session or have its header altered. Once both sides are on a build that
  says so (a version number in the header), the ML-KEM offer and answer a message carries are authenticated too; until
  then they are protected only by being mixed into the root key, and a conversation with an older build stays that way.
- **Out of order:** up to 1,000 missed messages can be skipped over, and up to 2,000 spare keys are kept to open late
  arrivals. A message that fails to open never changes the saved state (it is tried on a copy).
- **Sparse post-quantum ratchet:** the handshake gives quantum resistance at the start; after that a second, slower
  exchange keeps adding fresh ML-KEM-768 secrets, spread over many small messages so that no message is bigger.
  *Code: `Ratchet.swift` (the exchange), `ChunkCode.swift` (the erasure code).*
  - Each side keeps making fresh ML-KEM-768 keys and *offers* them. The other side *answers* with a ciphertext. Two such
    exchanges run at once, one offered by each side.
  - A key (1,184 bytes) and a ciphertext (1,088) are each followed by a SHA-256 digest, cut into 96-byte pieces and
    erasure coded: pieces are combinations of the data blocks over GF(2^8) with a Cauchy matrix, so **any 13 different
    pieces of a key (12 of a ciphertext) rebuild it**, in any order, whichever messages were lost. A rebuilt key or
    ciphertext that does not match its digest is thrown away and collected again.
  - **Every message carries exactly one piece** in its header (`pq`, 102 bytes: kind, epoch, piece number, bytes), and
    when there is nothing to send, random filler of the same length. So the field is always present and always the same
    size, and message sizes say nothing about when an exchange runs. It adds about 150 bytes of JSON to a message; a
    short message still fits the 2 KiB bucket (`RatchetPQTests.aMessageStillFitsTheSmallestBucket`), and one that was
    within about 150 bytes of a bucket edge now falls into the next bucket, like any other message that grows.
  - When the offerer has rebuilt the ciphertext and decapsulated, it says so in every message (`pd`, the epoch). Only
    when the other side has seen that does it mix the secret into the **root key** at its next new chain (the same step
    that mixes in X25519), and it says so in every message of that chain (`pm`). The offerer, seeing `pm`, mixes the same
    secret in on its side of the same step, and both start the next epoch. A secret is never used before the other side
    holds it, so no message ever waits on a piece, and it adds no message keys of its own: lost, late and repeated
    messages are handled by the ordinary skipped-key logic.
  - The secret goes in as `HKDF-SHA256(secret, salt = SHA-256(key ‖ ciphertext), info = "pulshade.pqr.mix" ‖ epoch)`,
    next to the X25519 output, so it is bound to the exact key and ciphertext. Piece digests use the label
    `pulshade.pqr.digest`. The piece, `pd` and `pm` are part of what each message's AEAD authenticates (label
    `pulshade.ratchet.bound.v3`), so a changed piece or flag fails on the spot.
  - **How often:** measured in the tests (`RatchetPQTests.secretsKeepGoingIn`), a back-and-forth chat completes a new
    secret about every 35 to 40 messages in total, in both directions in turn, with no day timer. Healing therefore
    no longer depends on X25519 alone between refreshes. A chat where one side only sends does not advance (it needs
    the other side's ciphertext and a new chain), the same as the X25519 ratchet itself.
  - Limits kept: at most 1,000 skipped messages per jump and 2,000 spare keys; at most 240 piece numbers per epoch and one
    epoch of each exchange in memory (under about 3 KB). A message that fails to open, for any reason, changes nothing in
    the saved state (it is tried on a copy).
  - **Old builds.** Every message has to be in this form (header version 3, bit 7 of the `caps` byte). A message from a
    build from before is refused (`RatchetError.peerTooOld`) and the friend is marked as needing to update
    (`DeviceLink.needsUpdate`): nothing is sent to that device, the chat's composer is closed with "<name> needs to update
    Pulshade first.", and no new keys are started over it. Their next envelope with bit 7 lifts the mark. Sessions
    saved by the build before load as they are (the old refresh fields are dropped when saved again; saved-data format
    20) and start the new exchange at once. Mail from an old build that was still waiting when the app updated, and a
    refresh that was half done at that moment, are not read.

Everything people do in a chat (text, photos, reactions, typing dots, read receipts, unsends, group changes, story
views) goes through the ratchet. A few things travel only inside the sealed-sender envelope of
[section 4](#4-sealed-sender-envelopes-and-padding-buckets), without the ratchet, and so **without forward secrecy**:

- session setup (the hello, the answer to it, the answer to a spare key, and a request for new keys);
- a **friend request and its optional note** (up to 280 characters), since there is no session yet;
- "erase this account's mail" after a Burn;
- the second tick from a locked iPhone ([section 10](#10-delivery-receipts-and-receipts-from-a-locked-phone)), which only
  names envelopes by hash.

Someone who later steals your long-term agreement key, and kept copies of these envelopes, could open them. That includes
the text of friend-request notes sent to you.

## 4. Sealed-sender envelopes and padding buckets

*Code: `Sources/Pulshade/Core/EnvelopeCore.swift`, `Envelope.swift`.*

*Code also: `EnvelopePQ.swift`.*

A ratchet message is sealed again before it goes to the relay, so the relay does not learn who sent it.

**Version 3 (from build 15; the only version read, apart from introductions below).** The wire form is `3`, a fresh
X25519 key (32 bytes), an ML-KEM-768 ciphertext (1088 bytes), then the sealed content. The recipient's ML-KEM key is
encapsulated to for every envelope, and its secret is mixed into **both** layers next to the X25519 results (HKDF salt
includes the ephemeral key, the recipient's key and the ciphertext). Breaking X25519 later therefore opens nothing that
was recorded, and a forger needs both halves. The fixed padding buckets below are unchanged; every envelope is 1121 bytes
longer on the outside (`1 + 32 + 1088`), which is the whole cost of the sealing. The inner layer is a frame: a small JSON
header (signing key, the Ed25519 binding, device, time, capability bits, and optionally the sender's post-quantum card),
then raw bytes: an ML-DSA-65 signature (3309 bytes) when there is one, then the payload.

- **Hybrid signature.** Anything that is not a ratchet message (key setup, erase notices, delivery notes, introductions)
  carries an ML-DSA-65 signature over the transcript (ephemeral key, hash of the ML-KEM ciphertext, recipient, sender,
  time, device, hash of the payload), next to the Ed25519 binding. **Both must verify.** A signed control message moves
  from the 2 KiB bucket to the 8 KiB one. Ratchet messages are not signed: their session, whose root is post-quantum,
  authenticates them, and they keep their size.
- **Post-quantum card (`PQCard`).** Both public keys, with an Ed25519 signature and an ML-DSA signature over them and over
  the signing and agreement keys. It counts only if both verify. It travels inside hello and request cards, in an
  introduction (`pqIntro`), or in the header of a version 3 envelope to someone who isn't known to have ours.
- **Pinning and downgrade.** The first card that verifies for a contact is pinned in their record (trust on first use,
  like the signing key itself; the keys come from their seed, so they never change for the same account). When the
  contact came by an invite, that first card is held to the invite: a `psh3` invite carries a 16-byte commitment to the
  maker's post-quantum keys (SHA-256 over `pulshade.pq.commit.v1`, the ML-KEM key and the ML-DSA key, cut to 16 bytes),
  covered by the invite's signing-key signature (`pulshade.invite.bind.v2` over the agreement key and the commitment). The
  record keeps it (`pqCommit`) and refuses any first card whose keys don't match. Older invites (`psh1`, `psh2`) are not
  accepted. Contacts from a public handle, a group or a request have no commitment and are still trust on first use. From then on
  the signature of every non-ratchet envelope from them is checked against the pin and a different card is refused. **A
  classical (version 2) envelope is never read from anyone pinned.** For someone not yet pinned the only classical
  envelope read is the introduction itself (hello, request or `pqIntro` carrying a card that verifies): the invite and
  the public profile carry no post-quantum key to seal to, so the first envelope each way cannot be post-quantum. It
  reveals that envelope's sender and contents to a recorder who later breaks X25519, and nothing after it does.
  A contact who sends anything else classical (an app from before) is refused by name: "needs to update Pulshade", once a
  day, and nothing from them is read; nothing classical is sent to them, and messages written meanwhile wait.
- **Existing contacts.** At the first unlock after the update the app sends each contact (once) a `pqIntro`; a classical
  introduction is answered with the other side's, so both pin. Accounts, contact records, sessions and chats are not
  touched; the new keys come from the same seed, so recovery, linked devices and the sealed backup need nothing new
  (the backup carries each contact's pin). The notification helper gets the key seeds and each friend's pin; with
  neither it does nothing.
- **Not covered.** Group-member keys (per-group, per-member X25519 keys used for join links and friend invites sent through a
  group) still use the version 2 seal: they are not identity keys, but they are classical. Directory profiles and the
  request layer's signatures are Ed25519 only.

The rest of this section describes the layers; in version 3 each mixes in the ML-KEM secret as above.

- **Outer seal.** A fresh X25519 key per envelope; its DH with the recipient's long-term agreement key (and the ML-KEM secret)
  gives a ChaCha20-Poly1305 key. Inside: the sender's agreement key, then the inner seal. The recipient's keys are the only
  thing needed to *send*, so anyone can write to a mailbox they know; what the relay sees is one random-looking blob.
- **Inner seal.** A second key mixes the DH results: ephemeral-to-recipient *and* sender's long-term key to the
  recipient's long-term key, and the ML-KEM secret. Inside it: the sender's signing key, a signature by that key over the sender's agreement
  key ("these two keys are the same person"), the device id, the time in whole seconds, a byte saying what the sender's
  app can read, and the payload.
- **Deniable:** only the sender could have made the inner seal, so the recipient knows who it is from, but the
  recipient could have made it too. It proves nothing to a third party. The signature covers only the key pairing, and
  is the same every time; **no chat message is ever signed** (only key setup and control messages carry the ML-DSA
  signature above, and nothing signed can be shown to a third party as a statement about what was said). (Public directory entries, @handles and announcements *are*
  signed, because they are meant to be checked by anyone.)
- **Padding buckets.** Before the outer seal, the content is padded with zeros to a fixed size: **2 KiB, 8 KiB, 32 KiB,
  128 KiB, 512 KiB, 2 MiB**, or beyond that the next whole MiB. The relay accepts envelopes up to 4 MiB. So it sees a
  size class, not a length.
- **Replay:** the inner seal carries its time, and anything sent outside a ratchet session (introductions, erasing) is
  stamped and counted once, so an old envelope cannot be played back later.
- **Frames:** big payloads (photos, video pieces) ride inside the seals as raw bytes after a short description, not as
  base64 text, so they are not inflated by a third. An app only sends them to a device that has said it reads them.

Limits worth knowing: if your *long-term agreement key* is stolen, the thief can open envelopes addressed to you and
can write to you pretending to be anyone (this is the usual "key compromise impersonation" of any such design). It does
not open messages: those sit inside the ratchet, whose keys are separate and move forward.

## 5. Spare keys

*Code: `Sources/Pulshade/Core/SpareKeys.swift`.*

**The problem.** After you Detach (wipe a device) and log back in with your recovery code, you need new chat keys with
every friend. Normally that takes a round trip, so each chat waited until that friend next opened the app.

**The fix, as in Signal's prekeys.** Each device makes, for each friend, the first half of a handshake ahead of time and
leaves the public half on the relay where only that friend can find it. A friend whose keys are gone takes it, answers
it at once (`Handshake.accept`) and can write straight away. The answer reaches you when your app next runs, which
finishes your side (`Handshake.complete`). The cryptography is exactly the ordinary handshake's; only the first message
was made early.

**Where it is left.** In the same sealed-backup store as backups. The slot's name and signing key and its sealing key
all come from HKDF over the X25519 exchange between the two friends' identity keys, mixed with the account that made it
and its device id. So:

- the relay cannot work out the slot or open it, and cannot tell whose it is;
- every spare is padded to **one size (4 KB)**, whatever is inside;
- each slot is read and written on its own connection at random times, so one person's spares are hard to tie together;
- a spare is **used once**: whoever takes it erases it;
- an unused spare is replaced every **5 to 10 days**; removing a friend erases yours for them; one nobody updates is
  erased by the relay after **180 days**.
- Spares are only made for friends whose app says it takes them.

The relay can still see *that* a spare was written, read or erased, and when, and (in Fast mode) the IP address that did
it. It cannot see who the friends are. The secret half of each spare lives in your encrypted vault, and so also in your
sealed backup.

**When both friends log back in at once.** Each may take the other's spare, so for a moment there are two new
sessions. Both sides settle on the same one, the spare made by the "lower" side by a fixed comparison both make, as
for crossed handshakes. The rule is dropped as soon as anything opens on the other keys, and a small receipt makes
sure that happens, so a friend who recovers later is still answered. Hellos sent before a spare was answered are
ignored.

## 6. Multi-device and personas

*Code: `AppModel.deviceID(for:)`, `Linking.swift`.*

**Devices.** One account can run on several devices. They **share the identity keys**, but each device has:

- its own random **device id**;
- its own mailboxes. Each has a secret receive key; senders write to a hash of it, so knowing where to *send* does not
  let anyone *collect*. A fetch does hand the relay the receive keys themselves, and one fetch asks for all of a
  persona's mailboxes together, so the relay can tell roughly how many mailboxes (and so contacts) a persona has;
- its own ratchet session with **every device of every contact**, so no message key is ever used twice.

People send a copy to each of your devices. What you do on one (send, read, delete) is synced to the others through an
encrypted session between your own devices.

**Linking a new device.** The logged-in device shows a QR code holding a one-time secret and a mailbox. The new device
answers with a fresh key. Both screens show six digits to compare; you approve. The account (keys, contacts, groups,
personas, settings) is then sent encrypted to that key mixed with the one-time secret. Only the first device to answer a
code counts. The consequence you should know: **a linked device holds your identity keys.** Losing one is as serious as
losing the main phone for the identity (though not for past messages, since each device has its own ratchets).

**Personas.** A persona is a separate identity: its own seed, keys, mailboxes, contacts, chats and settings. Its
device id is an HMAC of the persona's own id, keyed with the device id, so a friend who knows two of your personas
cannot match them by device id. Over Tor each persona uses its own **lane**: its own circuits and so its own exit.
Personas are not linked to each other anywhere on the relay, unless you use Fast mode, where they come from the same
IP address (see [Tor and Fast](#tor-and-fast)).

**Lanes.** The app keeps separate network "lanes": each persona, each public inbox, sending, linking, reports,
each call. Each lane signs in to Tor under its own name, so each gets its own circuits and none can be tied to another by
address. Each lane's fetches also run on their own timers.

## 7. Groups

*Code: `GroupKeys.swift` and the group handling in `Wire.swift` and `AppModel.swift`.*

Groups and channels have **one format** since build 15: the shared mailbox of 7a below. Before it, a group was a
roster held on each phone and every message went as one envelope per member through each pair's ratchet (`Payload.group`
carried the roster, with introduction mailboxes, `Payload.moved`, `Payload.removed` and the per-member
`friendInvite`). Builds 13 and 14 moved those groups and channels over by themselves, and the old reading and sending
code has been removed. Those cases are no longer part of the wire format: an envelope that carries one cannot be decoded and
is dropped, and a message that names a group, arriving one to one, is ignored.

- **What stays from before.** A group or channel saved in the old format stays on the device with its past messages,
  closed: nothing is sent in it, read for it, or synced to other devices, and the chat says it is on an old format and
  can't be used (the owner starts it again). The capability bits are still sent, so other apps see what this one reads.
- **Nobody is put in the old format.** An app whose devices don't all say they take part (bit 4 for groups, bit 6 for
  channels) is refused when someone makes a group or adds them: "X needs to update Pulshade first". Nothing is kept to add
  them later.
- A group has an **owner**, optional **admins**, optional **mods**, and a **posting rule** (everyone, admins, or owner
  only). Changes carry a version number and count only when they come from someone allowed to make them. Mods can only
  remove ordinary members; everyone ignores a mod's update that does anything else.
- Members who are not your contacts are kept as hidden peers, used only inside that group. In a channel, followers learn
  who can post, not who else follows (7a-i).
- **Broadcast lists** (the old send-to-many list) still send one private copy per person. They are not groups and
  cannot be made any more.

### 7a. Groups that share one mailbox

*Code: `GroupKeys.swift`, and the "Groups that share one mailbox" section of `AppModel.swift`. Design:
`docs/groups-design.md`.*

Every group uses this format, and every member's app has to take part (bit 4 of the `caps` byte). Channels use it too
when every follower's app takes part (bit 6, see 7a-i below).

- **One mailbox per epoch.** A member seals each message **once** and posts it into the group's mailbox on the relay;
  every member reads it from there with a cursor ("everything after the last one I saw"). The relay keeps group mail
  sealed on disk for the epoch's life (3 days since build 14, 1 to 7 allowed) and does not let it go when it is read, because it must not learn
  how many members there are or who has read what.
- **Member keys made for each group.** Each account's key in a group comes from its seed and the group's id, so it is
  the same on every device of the account and is linked to nothing outside the group. Members never hold each other's
  mailboxes or identity keys: only a **member card** (name, picture, group signing and agreement keys), signed by the
  member's own group key.
- **Epoch keys and sending chains.** A random 32-byte epoch key gives the mailbox, an outer key that hides who sent
  an envelope from the relay, and the start of each member device's sending chain. Each message takes the next chain key
  (HMAC steps), so a used key is not kept. An epoch key is replaced when someone is removed, and also by an admin's
  device once the epoch is **7 days old or 1,000 chat posts long** and something was said in it (a quiet group keeps its
  epoch); two admins doing it together settle like two removals. Old epoch keys are kept only until a week after the
  next epoch began, for late mail. Each envelope is signed by the sender's group key, so one member cannot pass
  a message off as another's. Each device of an account posts on its own chain, tagged with 8 random bytes it makes for
  itself; backups and newly linked devices make their own.
- **Settings.** Name, picture, roles, posting rule, timer and the member cards are one numbered document, signed by
  whoever changed it. Every member checks each new version against the one it holds: the owner may change anything but
  who the owner is; admins add and remove ordinary members and change the details and timer; mods only remove ordinary
  members; a member may only replace their own card. Nobody can change anyone else's card.
- **Joining.** An admin invites a contact over their 1:1 chat with the settings and the current epoch's key; the
  newcomer answers with their card, and the admin posts settings that include it. If anything has been said in the
  current epoch, the admin starts a new one first, so the newcomer cannot read it.
- **Settling and catching up.** Settings carry a check of the current epoch's key; a key handed over (by an invite, a
  new epoch, or another of your devices) is used only if the settings name it. Two versions with the same number
  (two admins at once) are settled by the lower hash, everywhere alike. The owner's device signs every change made by
  someone else over again, and an owner-signed version may skip numbers, so a member who missed some catches up.
- **Posts that must not get lost.** The relay keeps group mail for 3 days (new epochs; 1 to 7 is allowed). A device
  keeps each post it makes, sealed as posted, until it reads that post back from the mailbox, which shows the relay holds
  it for every member. If it doesn't come back (the relay lost mail), after 2 minutes and then at growing gaps the same
  bytes are posted again, up to six times; readers already remember what they read, so a copy someone has is ignored.
  A post goes when its message does (unsent, or its timer ran out), and is kept at most 14 days (a day if it was
  housekeeping), up to 200 posts or 2 MB per group, in the device's own encrypted data.
- **Catching up.** A member whose device was away longer than the relay keeps mail posts `groupCatchUp(since)`, where
  `since` is only the start of a day, a day or more before the device was away, so members don't learn when it last read.
  Members' devices post again what they said since then and still hold, newest first, and only what is still shown (not
  unsent, not timed out). Only members can ask; a request that sat in the mailbox over an hour is not answered; a member
  is answered once an hour; a group's devices answer at most six requests an hour; one answer is at most 128 KB and one
  device gives at most 512 KB a day to a group, so nobody can make everyone post over and over or use up the relay's
  room for the mailbox (50 MiB a day). A request with nothing to answer uses up no allowance. Not in channels (a follower
  says nothing in one): there a follower who was away longer than the mail lives can miss posts.
- **Pictures** are not in the settings: a card signs a hash of its picture, and each member posts their card with the
  picture into the mailbox.
- **Leaving and removal.** Removing someone starts a new epoch: its key is sealed to each remaining member's group
  agreement key (X25519, a one-off key per hand-out) and posted in the old mailbox, followed by settings that move to the
  new one. The person removed can still read the old mailbox, never the new. A member who leaves says so in the mailbox
  and an admin's device takes them out the same way.

What it changes, honestly:

- **Healing.** A 1:1 chat heals at the next reply after a key is stolen. In a group, a stolen epoch key reads everything
  in that epoch (every member's chain starts from it), so epochs are short: a removal, a newcomer after the group has
  talked, or 7 days / 1,000 posts. Within an epoch each sender's chain still only moves forward, so a member's
  device holds no key of a message it has already read from a sender it has heard; but it can work out the chain of any
  sender it has not, from the epoch key, so **there is no per-message forward secrecy against someone who steals an
  epoch key** (see `docs/groups-design.md`, "Forward secrecy inside an epoch").
- **Receipts.** A group message shows "sent" once it is on the relay; members do not confirm it one by one.
- **The relay** sees one mailbox that many devices read, and can count how often it is read. Over Tor it cannot tell the
  readers apart; in Fast mode it sees their addresses and could estimate the group's size.
- **Admins** can still leave someone out of the settings (but cannot alter a card), and a hostile admin can be a
  nuisance until the owner removes them.

### 7a-i. Channels in the shared-mailbox format

*Code: `GroupKeys.swift` (`GroupRoster`, tagged rekeys) and the "A channel's followers" section of `AppModel.swift`.
Design: `docs/groups-design.md` section 17.*

A follower's app has to say it reads channels that share one mailbox (bit 6 of the `caps` byte, `Envelope.reads` is 255 with bit 7, which every current app sets).
Someone on an older app is refused until they update.

- **Followers are not in the settings.** The signed settings carry only the staff (owner and admins). A follower holds
  the epoch key and a group key of their own, with a card that has no name or picture, and posts nothing: the app
  refuses, and mail from an unlisted sender in a channel is dropped.
- **Staff roster.** The staff keep the follower list in a signed `GroupRoster` (follower keys and when they were added,
  no names; at most 1,500). It is posted in a second, staff-only mailbox (an "epoch 0") that opens with a 32-byte staff
  key the owner gives each admin with the ask to be staff. Followers never have the key, so they cannot see joins and
  leaves as they happen. The owner's phone posts the roster again every three days, since the relay keeps mail a week,
  and makes a new staff key whenever an admin is let go. Dates in the roster are clamped to a few minutes ahead, and a
  removal outranks an older entry, so nothing can be made that cannot be beaten.
- **Removal.** A follower taken out is dropped from the roster and the channel starts a new epoch whose key is sealed
  to the staff and every remaining follower. These rekeys are tagged (filed under a tag worked out from each reader's own
  key) and padded to a power of two copies, so the size reveals only roughly how many followers there are. A removed
  follower learns it only because their mailbox goes quiet.
- **Admins.** The owner can ask a follower to join the staff; they answer with a card with their name and move from the
  roster into the settings.
- **Left out.** Follower reactions are dropped (staff can still react).
- **Leaving.** A follower who leaves sends `channelLeave(group)` over their 1:1 chat with the staff member who invited
  them, then removes the channel from their devices. Nothing is posted in the channel's mailbox. That staff phone acts only
  if the chat's sender (authenticated by the session, never by the payload) is an account it admitted to this channel and
  whose roster entry is still live (hidden contacts count: a follower through a channel's code is one); it drops them from the
  roster at once and makes the new epoch once for everyone who leaves within ten minutes (retrying until it exists). A repeat,
  a late copy (older than the entry by more than ten minutes), or one from anyone else finds no live entry and changes nothing. An app from before cannot decode the payload and drops it.
- **A key that was missed.** A follower whose settings name a newer epoch whose key never came (`missedKey`) can send
  `channelKeyWanted(group, epoch)` (the newest epoch it holds) over the same chat. The inviting staff phone checks the same
  things as for a leave, and that `epoch` is older than the current one, then answers over that chat with the ordinary
  `groupInvite` (current settings and epoch key), at most once every ten minutes per follower whatever arrives. A follower's
  phone answers such an invite with its card, and takes a staff key or a new inviter from it, only from the account that invited
  it (another contact's copy only refreshes keys). A follower asks at most
  once every ten minutes. A channel's code lets in at most 60 new followers an hour (repeat hellos from one identity count once); the rest wait, earliest first, and the list drops the newest when it is full (1,500). Nothing is
  posted in any mailbox. With no answer (an older app, an absent phone, or a follower already taken out) the follower is just
  told that none came.
- **Announcements** is not a group on the wire: the relay hands every app the same admin-signed list, with no account
  attached. Its chat is a channel with no members, and it works as it always did.

### 7b. Join links

*Code: `Sources/Pulshade/Core/JoinLinks.swift`, and the "Join links" section of `AppModel.swift`.*

An admin of a group that shares one mailbox can make links that let people join without being anyone's contact.

- **The link** is `pulshade://group/` followed by 48 bytes: a random 32-byte secret and the first 16 bytes of the
  SHA-256 of the group owner's member key.
- **The preview** (name, description, picture, member count, whether admins approve, the owner and admins by their
  member keys, and where to send a request) is signed by the owner's member key, sealed with a key derived from the
  secret, padded to 32 KB and kept in the relay's sealed-backup store under another key derived from the secret, exactly
  as spare keys are. The relay cannot open it or tell what it is. The joining phone checks the signature and that the
  signer is the owner the 16 bytes in the link name. Only the owner's phone writes previews, so an admin who is removed
  cannot put out one of their own.
- **Asking** sends one sealed envelope to an ordinary mailbox named in the preview. It is sealed from the newcomer's key
  for this group alone (the same key they will be known by inside it) to a key only the group's admins hold, and holds
  their card, an optional note, and a fresh mailbox for the answer. Their account key is never used.
- **Letting in.** Through an open link, one phone adds the newcomer at once: the leading device of the admin who made
  the link. That admin's other devices step in after a minute, another admin's after two. Everyone let in at one look
  goes into one change to the settings, and a link lets in at most 30 people an hour on its own; past that, requests wait
  for an admin's yes. A request is answered once, can't be replayed later, and must be less than a day old. A new epoch starts first if anything has been said, so
  the newcomer can't read what came before. The answer carries the settings and the current epoch key, sealed to the
  newcomer's group key. Through a link that needs approval the request waits on the relay, unacknowledged, where every
  admin's phone sees it, until one of them says yes or no (at most 100 waiting per link). A banned key, an expired link
  or one that is used up gets "no".
- **Taking the answer.** The newcomer's phone takes an answer, yes or no, only from the owner or an admin the preview
  named, with settings signed by one of them that keep the same owner. A group it is already in only moves on to
  settings that follow from the ones it holds.
- **The links themselves** (their public parts, limits, how many have used each) and the group's ban list are a
  document of their own, signed by an admin and posted in the group's mailbox. The keys that read and open requests are
  sealed to each admin's group key separately; members cannot open them. When someone stops being an admin, the owner's
  phone gives every link new keys (so old copies of the links stop working) and seals them to the admins that are left.
  It keeps a record of everyone the keys have been sealed to since the last reset, and the owner's version wins when two
  are made at once, so a change made at the same moment can't undo the reset.

What this means: anyone who has a link can read the preview, so they learn the group's name, picture, description, size
and the member keys of its owner and admins (keys used only in this group); they can also overwrite or delete the
preview (the admin's phone puts it back within three days, or at once on any change; a reset gives the link new
secrets). Only admins can see who asked through a link that needs approval. The relay sees a small backup-sized slot
read now and then, and envelopes going into and out of two ordinary mailboxes. If the owner's phone is away when an
admin is removed, that admin can still read requests until it's back; previews aren't refreshed while it's away. Two admins changing the links at the same moment
can let a use limit be passed by one or two; a ban or use count lost that way is put back by the phone that holds it.

## 8. Sealed backups

*Code: `AppModel.sealedBackup`, `Identity.backupKey`.*

So that Detach can be instant, the app keeps **one backup** of your account on the relay.

- **What is in it:** your profile, @handles, contacts, groups, personas and settings. **Not** in it: chat history,
  stories, requests, messages still waiting to be sent, any decoy or panic identity, **and (since build 13) any
  session keys.** A recovered account opens new sessions with every contact (on their spare keys where they left
  one), so mail sent to you while you were detached can't be opened. The one exception is a contact who hasn't
  accepted yet, whose waiting ask has to stay.
- **How it is sealed:** AES-256-GCM, with a key made from your seed (so only the recovery code can open it). The seed
  is 256 bits of randomness, so there is nothing to guess.
- **Padding:** to a power of two, at least 64 KB, behind a length marker. The relay learns a rough size class, not how
  many contacts you have.
- **Where it is filed:** under a public Ed25519 key that is also derived from the recovery code, and from nothing else.
  The relay cannot tie it to your account or to anything you send. Every read, write and removal must carry a fresh
  signature from that key (a signed label, the key, the time and, for a write, the hash of the body).
- **When it is saved:** a random 1.5 to 10 minutes after something in it changes, over Tor if Tor is on, and once a
  week regardless. Only the main identity does this, never a decoy or panic account. You can switch it off in Settings,
  which erases it at once. Burn erases it too. If you set a panic passcode, each save also gives the relay the hash of
  a delete-only token, so entering the panic passcode can erase the backup without the recovery code's key.
- **How long:** until you switch it off, Burn, or **180 days** after the last save. After a Detach nothing refreshes
  it, so the 180-day clock runs from the last save.

Honest limits:

- The backup no longer holds session keys, so a leaked recovery code with a stored copy shows no chat key that was ever
  used. It does show your contacts, groups and settings, and the recovery code on its own is still your whole identity
  (someone holding it can take over the account and be sent new sessions). It also holds the secret halves of spare keys
  ([section 2](#2-the-handshake)), which are made ahead and carry no message. Copies of old versions may linger on the
  relay's disk or in storage snapshots, sealed.
- The relay can see *when* a backup was saved, its rough size, and (in Fast mode) the IP that saved it.

## 9. The blob store (big files)

*Code: `Sources/Pulshade/Core/Blob.swift`.*

Files up to **100 MB**, chat videos, and story videos are not sent inside a message. Neither are photos, voice notes
and photo stories bigger than about 48 KB, when every device of the person they go to says its app takes them that way
(bit 5 of the `caps` byte): the message or story then carries only a tiny preview of the photo, or a voice note's length
and waveform, and the rest follows as a pointer. Older apps still get them inside the message. Instead:

1. The sender's app makes a fresh random **256-bit file key** and seals the file in **1 MiB pieces** with
   ChaCha20-Poly1305. Each piece's nonce is its position, and its authenticated data is the file id, the position and
   a "last piece" flag, so pieces cannot be swapped, reordered or cut short.
2. It uploads the sealed pieces **once** under a random id. The relay seals each file **a second time** with a random key
   of its own, keeps the pieces on its disk and that key in its sealed index, and cannot open either layer.
3. The file key, the id, the file's name and type, a SHA-256 of the file and an **erase secret** travel only inside the
   ordinary end-to-end encrypted message (the "pointer"). The relay holds only a *hash* of the erase secret.
4. For each person the file goes to, the sender also makes a **one-time token** and tells the relay its hash. The
   receiver's phone fetches the pieces into **memory**, opens and checks them there, and then spends its token. When
   every token is spent the relay **erases the file**: overwrites the pieces with random bytes, removes them, and
   destroys the file's key (so a stray copy on a flash disk cannot be opened). Video and photo stories stay until their
   timer ends.
5. Deleting the message sends the erase secret, and the relay erases the file at once. A file nobody deletes is erased
   after **7 days at most**. Burn sends the same erase for everything the account uploaded.

The phone never writes a received file to disk unless you tap **Save a copy**. The relay can see that a file of about
that size was uploaded, when, and when it was collected (and your IP in Fast mode). It cannot see what the file is, its
name, its type or who it is for.

## 10. Delivery receipts, and receipts from a locked phone

*Code: `Sources/Pulshade/Core/LockedDelivery.swift`, `HelperStore.swift`.*

Ordinary receipts are ratchet messages like any other. A receipt waits a random few seconds and goes out batched with
others, so it does not pair "a message arrived" with "a message was sent" in time.

**The problem.** When the recipient's iPhone is locked, the app is not running, so it cannot send a receipt, and the
sender sees one tick until the recipient unlocks.

**How it is solved.**

1. A message wakes the phone with an Apple push that says only "New message". The push also asks iOS to run a small
   **notification helper** from Pulshade for a few seconds, even when the phone is locked.
2. The helper fetches new mail from the relay **without** removing it. It opens only the *outer* parts of each envelope
   ([section 4](#4-sealed-sender-envelopes-and-padding-buckets)) to see which friend and which of their devices sent it.
   It **never opens a message**: the ratchet keys stay locked in the vault until you open Pulshade.
3. For each chat message it names the envelopes it has (the first 16 bytes of the SHA-256 of the envelope) in a small
   note sealed to that friend's device. Their app turns the note into the second tick.
4. Short envelopes (up to 64 KB) are also copied into a **sealed inbox** on the iPhone so they do not sit on the
   relay; the helper only removes them from the relay after the copy is safely kept. Big ones (photos, videos) wait on
   the relay for the app.

What this costs, honestly:

- The helper needs the account's **signing and agreement private keys**, its friends' public keys and mailbox keys. These
  sit in an iOS Keychain item that is readable **after the phone's first unlock since it started**, on this device only
  (never synced or backed up). It does **not** get the seed, the recovery code, the storage key or any ratchet key, so it
  cannot read a message. But someone who can extract Keychain items from a phone that has been unlocked once since
  boot could get those two keys (see the seized-phone rows below), and the sealed envelopes copied into the inbox.
- The helper cannot run Tor, so it reaches the relay **directly**, and the relay sees your IP for that moment. It is
  therefore only available in Fast mode: turning Tor on forces locked-phone collection off, so a Tor user can never
  make those requests directly by accident.
- It needs "Wake when locked" on. It covers the main identity only (not personas), and Burn and Detach remove
  everything the helper holds. If a decoy or panic passcode is set, it is off for the whole device, not only for those
  accounts.
- **Wake when locked is on by default** (iOS asks first for notification permission). Apple learns that your phone
  was woken and when, never who wrote or what. The relay holds your push token. People who need the strongest anonymity
  should turn it off.

## 11. Tor and Fast

*Code: `Tor.swift`, `Bridges.swift`, `Relay.swift`.*

Whenever there is no account on the device (a fresh install, after a Detach or a Burn, before restoring), Pulshade
asks how to connect, and nothing connects until that is answered.

- **Private, through Tor.** Tor (the Arti program, built into the app) is started on the device. Every request goes
  through it, one lane per kind of use, each on its own circuits. The relay is reached as a Tor *onion service*: the
  relay itself hosts it, so nobody learns where the relay runs, and no exit relay sees the traffic. The relay never sees
  your IP address; it makes up one address per circuit. Nothing falls back to a direct connection. (The locked-phone
  helper is the one direct path, and it can only be on in Fast mode.) Bridges (Snowflake, webtunnel) can be turned on
  for networks that block Tor.
  Because new circuits are cheap, the relay's rate limits want a proof of work on some requests, in the header
  `X-Pulshade-Pow: 2:<seconds>:<nonce>`, SHA-256 of `pulshade.pow.v2|<what it is for>|<seconds>|<nonce>` with enough
  leading zero bits, used once. Routes ask for 21 bits (lookups, announcements, reads) or 23 (claims, backups, burns, push,
  new group mailboxes): about two or eight million hashes, a fraction of a second to about a second on one core of a phone
  (the app's solver does roughly eight million a second on a laptop core and spreads across up to four cores). A circuit that has
  made many requests lately is asked for one more bit per doubling past eight in ten minutes, everyone for up to three more
  while the relay sees hundreds to thousands of onion requests a minute, never more than 27. A proof that is too light
  counts as none, and the answer (429) carries `X-Pulshade-Pow-Bits`, which the app does once more. The first format (a
  fixed 18 bits, no version) is answered 426 with `X-Pulshade-Update: required`.
- **Fast.** The app connects straight to the relay's ordinary https address. This is much quicker and more reliable.
  The relay and your internet provider see your **IP address**, and roughly where you are. Nothing on the server keeps
  an access log, and the relay keeps no log of requests or addresses; but on Fast **you are trusting us
  not to record it**, because nothing technical prevents it. For rate limiting the relay uses a hash of the address with
  a salt that is replaced every hour, and never keeps the address. On Fast, your personas share one IP address, so a
  watcher on the relay could tie them together (we do not record that).

You can change the choice in Settings. Switching to Fast warns you, and says how long you have used only Tor, because
once the relay has seen your address that cannot be undone. Either way, **timing is not hidden**: someone who watches
both ends of the network could still line up when things happen.

## 12. Mac updates

*Code: `Sources/Pulshade/Core/Updater.swift`.*

The Mac app can update itself from the relay. A release is a small signed note (build number, version, size, SHA-256 of
the download, a hash of the release notes) signed with a **release key** whose public half is built into the app. The app
installs a download only if the signature is valid, the download's size and SHA-256 match the note, and the unpacked app
has the right bundle id and build. It also remembers the highest build it has ever been offered, so a relay cannot
freeze it on an old version by replaying an old note. A build you make yourself has no release key and never updates
itself. The release key is held by the operator and is not part of the relay.

## What the relay stores, and for how long

The relay does not keep accounts. Everything it holds is either sealed by your phone, sealed again by the relay with a
key that is never written to its disk, or public because someone chose to publish it.

| What | Where | How long |
| --- | --- | --- |
| Waiting envelopes (messages, receipts, call set-up) | Disk, in segment files with every record sealed under a key of the segment's own (keys only in an index sealed by the storage key); recent ones also cached in memory. Written before the 202 | Until the recipient collects them, or **7 days**. Collected envelopes are dead at once: a segment with none alive has its key forgotten, its file overwritten and deleted; one kept alive by a slow reader is rewritten without them once at least half of it is dead. A full share of the disk answers **507** and drops nothing |
| Group mail (groups and channels that share one mailbox) | Disk, sealed on the phones and again by the relay | The life the epoch was made with, **3 days** for every epoch made since build 14 (up to 7 for older ones). **Not erased when read**, so the relay can't learn who reads or how many do |
| Short-lived signals (typing, "online") | Memory only | A few seconds to minutes; never written to the disk |
| Big files, chat videos, story videos | Disk, sealed twice, in pieces | Erased when collected or deleted, **7 days at most** (an unfinished upload: 1 hour) |
| Sealed backups and spare keys | Disk, in the backup store | Until switched off or Burn; **180 days** after the last save. Spares: also erased when used |
| Wake-up registrations (Apple push tokens) | Memory, and a sealed file | While the setting is on; dropped after 7 days without renewal |
| Public @handles and profiles, collectibles, announcements | Disk | Public by choice. A let-go handle is held for its owner 90 days, then free (a 30-day cool-off if the owner gives up the hold early) |
| Rate-limit counters | Memory | An hour. Only a salted hash of an address, never the address |
| Mailboxes closed by a Burn | Memory | 7 days |

The relay's disk files (mail segments, directory, backups, blobs, keys) are sealed with a **storage key that is kept only in
the server's memory**, never written to the server's disk. A crash writes no memory to disk. What this does
**not** stop: someone who controls the *running* server can read the key from memory. That is why anything personal is
sealed on your phone first.

What the relay **sees**: that a sealed envelope arrived at a random mailbox, when, and its size class; which mailboxes
one fetch asks for; when a backup, spare or file is written, read or erased and roughly how big; and (in Fast mode,
including the locked-phone helper) an IP address while it is connected.

Each deposit also carries a few plain headers the relay acts on:

- **Wake:** whether to wake the recipient's phone, and whether it is a call ringing. So the relay can tell a message
  from a background signal from a call.
- **Life and collapse:** typing and "online" signals say how long they are worth keeping (at most an hour), and some
  signals and key requests carry a tag so a newer copy replaces the older one. The tag is a hash of the kind of signal,
  the sender's device id, the mailbox and a ten-minute window: it says nothing else, and it changes every ten minutes,
  so the relay can tell that repeated signals to one mailbox come from the same sender device only within a window.
- **Recall stamp:** a random number and a hash only the sender can make the matching token for. It lets a Burn take
  back the account's mail that is still waiting. When a Burn hands over those tokens, the relay learns which waiting
  envelopes came from the account that burned (not who it was).

What the relay **cannot see**: what is inside an envelope, who sent it, your contacts, your groups, file names or types,
or who you are behind Tor.

---

# Threat model

## What we are trying to protect

1. **What you say** (messages, files, calls, stories) from anyone but the people you said it to.
2. **Who you are**: nothing ties your keys to a phone number, email or name.
3. **Who talks to whom**: as far as a one-post-box design allows.
4. **What is left** after you Lock, Detach or Burn.

## What we do not claim

- Not a defence against a **global network observer** who watches everyone: timing and volume can be lined up.
- Not a defence against **malware on your device**, or a **modified or fake app**.
- Not able to stop a **contact** keeping, copying or photographing what you sent them.
- No protection if you give your **recovery code** away.
- No **key transparency**: you trust the first key you see, and check by comparing the pulse code.
- Not **audited** yet.

## Who can learn what

### The relay (and whoever runs it, or rents it the server)

| Can learn | Cannot learn |
| --- | --- |
| That an envelope was deposited to a mailbox, when, and its size class | What it says, who sent it, or the real names behind mailboxes |
| Which mailboxes a fetch asks for, and when mail is collected | Your contacts, groups, or who is in them |
| Roughly when you are online (a fetch waits up to 25 seconds) | File names, types, or what a file is |
| Fast mode: your IP address and rough location while connected | Over Tor: your IP address |
| Which mailboxes share a push token, if "Wake when locked" is on | Anything that ties your personas together, apart from Fast-mode IP or a shared push token (main identity only) |
| When a backup, spare or file is written, read or erased, and how big | A backup's or a spare's contents, or whose it is |
| A burst of equal-size envelopes landing in many mailboxes at once (a group message) | |
| Whether a deposit is a message, a signal or a call; that tagged signals to one mailbox within ten minutes come from one sender device | Which device that is, or that two windows are the same one |
| After a Burn, which waiting envelopes came from the burned account | |

A **dishonest relay** can also drop, delay or replay envelopes, refuse service, and in Fast mode record IP addresses.
It cannot forge a message (it has no keys), and a replayed one is refused by the ratchet. It could add its own traffic.
It could watch both who deposits and who collects, and so link a sender to a recipient by timing and size, especially
on Fast.

### A network observer (your internet provider, a café, a state)

| Can learn | Cannot learn |
| --- | --- |
| Fast: that you use Pulshade, and when and how much | What you say, or to whom |
| Tor, no bridges: that you use Tor, and when | That it is Pulshade (unless they can see the onion address; bridges help here) |
| Both ends watched: timing can be lined up | |

The relay's connection to Tor is encrypted by Tor; Fast uses https.

### Apple (push notifications, app store)

With "Wake when locked": that your device got a push, and when. Never who wrote, or what ("New message" only). The
App Store knows you downloaded the app; Apple also checks a Mac app when it first opens. Your phone or computer may also
keep its own records of notifications and app use, which Pulshade cannot control. By default notification text is only
"New message".

### A seized phone, locked

| What the attacker faces | |
| --- | --- |
| The vault | Sealed with the passcode (PBKDF2-SHA256, 600,000 rounds, AES-GCM), **mixed with a key only that phone's Secure Enclave can use**. A copy taken off the phone cannot be guessed at elsewhere. On iPhone the files are also unreadable while locked. |
| The Keychain | Only if **Wake when locked** and **Collect messages when locked** are both on. Collecting is **off by default**; it is a choice made by hand, with a warning. Then the notification helper keeps in the Keychain ("after first unlock": readable once the phone has been unlocked since it started) this account's raw **signing and agreement keys**, this device's id, and each friend's agreement key and mailbox key, plus short sealed envelopes waiting in its inbox. An attacker who can extract Keychain items from such a phone can **impersonate the account** (sign as you, and open new sessions with your friends), open the envelope wrappers sent to you, and so **read what is sent to you from then on**. They cannot read **past** messages: the chat keys (ratchet state) are in the vault, behind your passcode and the Secure Enclave. Turning the setting off removes the bundle. |
| Decoy / panic passcodes | A decoy opens an empty identity; the panic passcode shreds the real one. The lock file always has three equal slots and four data files, so the disk does not show which are real. |
| Old copies | The whole lock file is sealed again with a Keychain key that changes every time Pulshade locks, so an old copy recovered from flash storage no longer opens (unless the attacker also recovers that key's old Keychain entry and knows the old passcode). |

A **short passcode can be guessed** offline only on the device itself (because of the Secure Enclave mix), at the
speed of that hardware and the system's own limits. A long passcode is the strongest protection you control.

### A seized phone, unlocked (or malware as you)

Everything on it that the app can read: chats, contacts, keys, the lock file's contents once opened. We cannot protect
against this beyond **Burn**, the **panic passcode** and **auto-lock**. Screenshots are blanked where the system allows
it. The recovery code is not offered for copying. Disappearing messages and removed stories are only a promise made by
the apps.

### A malicious contact

| Can | Cannot |
| --- | --- |
| Keep, copy or screenshot what you send; ignore disappearing timers | Read other people's messages |
| Learn what you tell them (your profile, your personas they know of) | Tie your personas together, if you use separate ones |
| In a group, send different members different things; as an admin, change the roster | Open messages to a member by poisoning the roster |
| Send you malformed data (the app checks sizes and formats before it uses them) | Make you open a file or link without asking |
| Learn anything from a link preview about you: previews are off by default, built by the sender's device, and the person receiving never contacts the website | |

### A future quantum attacker

| Recorded traffic, broken later | Result |
| --- | --- |
| Message content | **Still safe.** The handshake mixes ML-KEM-768, and the sparse post-quantum ratchet adds a fresh ML-KEM-768 secret about every 35 to 40 messages of a back-and-forth chat. |
| The sealed-sender layer (version 3 envelopes) | **Still safe.** ML-KEM-768 is mixed into both layers. Exceptions: the first, introducing envelope each way (hello, request or introduction), and group-member envelopes, which are classical. |
| Any TLS/Tor layers (X25519-based) | **Could be opened** (outside what Pulshade controls). That would reveal the mailbox read keys sent in requests and timing, not message content or, for version 3 envelopes, the sender. |
| Identity authentication | **Hybrid.** Control messages need an Ed25519 and an ML-DSA-65 signature, and a pinned contact can't be downgraded. Pinning is trust on first use; the pulse code covers both signing keys and both agreement keys (Ed25519 and X25519), not the post-quantum keys, and public directory entries, collectibles and admin signatures are still Ed25519 only. |
| Files, backups, the vault | Symmetric (256-bit) and hash-based: **still safe** at current estimates. |

## Honest limits

- **Not audited.** The ratchet, the handshake and the envelopes are our own implementation.
- **Timing and volume.** Tor hides addresses, not timing. A patient observer at both ends could link a sender to a
  recipient. Group messages and file transfers are the easiest to line up.
- **Your IP address in Fast mode.** The relay sees it while you are connected. We do not record it, and nothing on the
  server keeps an access log, but that is our promise, not something the code can prove.
- **The locked-phone helper connects directly**, not over Tor, for a moment each time, when locked-phone collection is
  on. It is only possible in Fast mode: turning Tor on turns it off.
- **The 180-day backup.** A sealed backup stays on the relay until you switch it off, Burn, or 180 days without an
  update. It holds no session keys (see section 8) but does hold your contacts and settings. It is sealed with a key only your recovery code makes. If that code
  leaks and a copy of the stored backup exists, it can be opened.
- **Disk.** Deleting a file overwrites it first, but on flash storage that only helps a little; what makes old data
  unreadable is that its key is gone. Pulshade keeps plain-text files off the disk wherever it can (voice notes and chat
  clips are made and played from memory; received files are never saved unless you ask; the story camera writes into
  memory, not a file). Things that still sit on the disk in the clear: a few display settings (theme, blur and the
  like), the Mac updater's build counter, and Tor's own state and caches (iOS file protection, not our key). The Tor
  switch and the bridge choice are sealed with a Keychain key (build 13). Video you pick from your photo
  library may be copied by the system to a temporary file before Pulshade reads it into memory; Pulshade deletes
  leftovers at launch, but we do not control that system copy. We are not aware of any other temporary files written
  by Apple's video code (AVFoundation) in Pulshade's paths, and this is one of the questions we ask auditors to check.
- **Keychain items after first unlock** (section 10) when locked-phone collection is on.
- **One operator.** The official app sends your messages and account traffic only to Pulshade's own servers. It also contacts Apple's push
  service (while Wake when locked is on, the default), the sites behind link previews you turn on (over Tor if Tor is on),
  and, if you pick the Snowflake bridge, its CDN front and public STUN servers; links you tap open in the browser. A modified app
  could point at other servers; the rate limits and the terms of use, not the code, hold that back.
- **Disappearing messages** and **deleted stories** depend on the other person's app.
- **Groups** cap at 300 members and trust their admins for the roster.
