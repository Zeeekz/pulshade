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

**Checking who you are talking to** (the "pulse check", *code: `SafetyCode.swift`*), made the way Signal makes safety
numbers: each person has a **fingerprint of their own**, worked out from their keys alone, and the code is the two side
by side.

- A person's fingerprint is SHA-512 iterated **5,200 times**: the first round over the format version (2 bytes, `4`)
  and the person's key block, each later round over the round before and the key block again; the first 32 bytes are
  kept. The key block is the label `pulshade.safety.v4` followed by, each with a 4-byte length in front: the account's
  fingerprint (the hex above), the Ed25519 signing key, the X25519 agreement key, and SHA-512 over
  `pulshade.safety.pq`, the ML-KEM-768 key and the ML-DSA-65 key (empty while those keys aren't known).
- **Shown:** 60 digits in 12 groups of five: 30 from each fingerprint (six groups, each five bytes read as a number,
  mod 100,000), the lower half first so both screens show the same order. Swapping a key changes only that person's
  half, so someone in the middle has to find keys whose fingerprint matches the real person's 30 digits (about 2^99
  tries, each 5,200 rounds), not two codes that match each other.
- **QR code:** `pshv4:`, the showing phone's own fingerprint, then the fingerprint it holds for the other person (32
  bytes each, in hex). A scan matches only if the other phone's fingerprint for itself is the one this phone holds for
  it, and its fingerprint for this phone is this phone's own.
- **Verified** only by a QR scan that matches or by confirming all 60 digits, and only once the contact's post-quantum
  keys are known. The 10 emoji and two colours come from both fingerprints together (60 bits of emoji) and are a quick
  look only: they never mark anyone verified.
- **Older apps.** Version 4 replaced a single code made from both identities (versions 1 to 3, `pshv1:` to `pshv3:` in
  the QR). Their codes never match these. A scanned QR from one says "<name> needs to update Pulshade first", and the
  screen says that someone whose code shows 30 digits needs to update. A contact already marked verified stays so.

Nothing is verified for you automatically: the first time you meet a key you trust it, the way most messengers do, and
the code is how you catch someone sitting in the middle. There is no key transparency log.

One account can be several **personas** (separate identities), on one phone. See
[section 6](#6-devices-and-personas).

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
   keys, the ML-KEM public key, the ciphertext, and the pins of both devices' own keys), with the label
   `pulshade.handshake.v1`. A different transcript gives a different root.
5. Each half is also signed by the sending **device's own keys** ([section 6](#6-devices-and-personas)), Ed25519 and
   ML-DSA-65, and carries that device's card (its public keys, signed by the account with both of its signing keys for
   that device id). The signature covers both accounts, the device id, the device's pin, the throwaway key and a hash of
   the ML-KEM key; the answer's also covers the asking device's pin, the ask it answers and the ciphertext. A half
   without a card and signature that verify is dropped.

What this gives:

- **Who:** the two long-term DH steps mean only the real holders of both identity keys can compute the root, and the
  device signatures mean only the device whose keys are pinned can open a session in its name
  ([section 6](#6-devices-and-personas)).
- **Forward secrecy:** the third DH uses two throwaway keys that are deleted once they are no longer needed; stealing
  identity keys later does not reveal the root. "No longer needed" is not immediate in every case. To finish a
  handshake whose answer arrives late, a device keeps the secret half of its current ask and of up to **3 earlier
  unanswered asks** to each friend's device, each for at most **8 days** from when it was made (`AppModel.askLifetime`).
  An ask for a **friend request** waits up to **32 days** for an answer (`requestAskLifetime`). Since build 23 a
  request that arrives on an @handle's mailbox is answered by the receiving phone at once (unless it takes requests from
  contacts only): the sender becomes a hidden contact and the chat waits under Message requests, with no read receipts
  or typing, until the receiver replies or adds them; at most 100 such chats per persona, the oldest unanswered going. When a session opens
  from an answer, that ask and every earlier one are deleted at once; only an ask made after it (whose answer may still
  come) stays. A spare key's secret half is kept while the spare is up (**5 to 10 days**, longer only while the app
  doesn't run to replace it) and for **10 days** after it is replaced (`spareGrace`, [section 5](#5-spare-keys)). These
  limits are applied when the app unlocks and every few seconds while it runs (`pruneHandshakeSecrets`). An answer that
  comes after its ask's secret is gone can't be opened: the other side's messages on that session can't be read, and
  the chat asks for new keys again, as for any keys out of step. A device that logs back in also keeps up to **4
  sessions it replaced**, in memory only, until the app locks. All of the above sits in the encrypted vault. The sealed
  backup ([section 8](#8-sealed-backups)) holds only the asks to people who haven't accepted yet; spares and sessions
  never go in it.
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
- **Out of order:** up to 1,000 missed messages can be skipped over, and up to 2,000 keys for skipped messages are kept to
  open late arrivals, only for the other side's **5 newest chains** (a late message on an older chain can't be read), and
  each for at most **30 days** from when it was kept (`Ratchet.skippedLifetime`; dropped whenever the session sends or
  reads, and by the app's upkeep for a session that does neither). A message held back longer than that can't be opened
  with a device seized later. A message that fails to open never changes the saved state (it is tried on a copy).
- **Sparse post-quantum ratchet:** the handshake gives quantum resistance at the start; after that a second, slower
  exchange keeps adding fresh ML-KEM-768 secrets, spread over many small messages so that no message is bigger.
  *Code: `Ratchet.swift` (the exchange), `ChunkCode.swift` (the erasure code).*
  - Each side keeps making fresh ML-KEM-768 keys and *offers* them. The other side *answers* with a ciphertext. Two such
    exchanges run at once, one offered by each side.
  - A key (1,184 bytes) and a ciphertext (1,088) are each followed by a SHA-256 digest, cut into 96-byte pieces and
    erasure coded: pieces are combinations of the data blocks over GF(2^8) with a Cauchy matrix, so **any 13 different
    pieces of a key (12 of a ciphertext) rebuild it**, in any order, whichever messages were lost. A rebuilt key or
    ciphertext that does not match its digest is thrown away and collected again.
  - **Every message carries at least one piece** in its header (`pq`, 102 bytes each: kind, epoch, piece number,
    bytes), and when there is nothing to send, one piece of random filler. Envelopes are padded to fixed buckets anyway,
    so a message carries **as many more pieces as fit in the padding it already has** (`Ratchet.encrypt(_:fit:)`,
    `Envelope.ratchetFit`): about seven more for a short text, more for a receipt or typing note, none for a message
    already near the edge of its bucket. The sender works out the envelope's bucket with one piece, then adds pieces
    only while the envelope stays in that same bucket, so no envelope is ever bigger because of them and sizes say
    nothing about when an exchange runs. Each exchange sends fresh piece numbers, taking turns, at most as many in one
    message as it takes to rebuild it. Not while the envelope still carries the sender's post-quantum card.
  - When the offerer has rebuilt the ciphertext and decapsulated, both sides hold the secret (the answerer made it). The
    offerer mixes it into the **root key** of its next new sending chain, next to that chain's X25519 output, and says so
    in every message of that chain (`pm`, the epoch). A sending chain is derived when the first message goes on it, not at
    the step, so a secret that arrived in between goes into the very next message. The answerer, stepping to that chain,
    mixes in the secret it kept, and both start the next epoch. The side that needs the secret to read is always the
    one that made it, so no message ever waits on a piece and no acknowledgement round is needed; lost, late and
    repeated messages are handled by the ordinary skipped-key logic and at worst delay the next exchange.
  - The secret goes in as `HKDF-SHA256(secret, salt = SHA-256(key ‖ ciphertext), info = "pulshade.pqr.mix" ‖ epoch)`,
    next to the X25519 output, so it is bound to the exact key and ciphertext. Piece digests use the label
    `pulshade.pqr.digest`. The pieces and `pm` are part of what each message's AEAD authenticates (label
    `pulshade.ratchet.bound.v4`), so a changed piece or flag fails on the spot.
  - **How often:** with short messages, a back-and-forth chat completes a new secret roughly every 6 to 10 messages in
    total (before build 17: every 35 to 40). Messages with no spare padding carry one piece and go at about the old
    pace. Any message from the other side moves the exchange on, delivery receipts and typing notes included, so a chat
    that is mostly one way refreshes with every few of those. A peer that sends nothing at all cannot refresh the
    sender's direction: the secret has to come from it, as the X25519 ratchet's does.
  - Limits kept: at most 1,000 skipped messages per jump and 2,000 kept keys for them; at most 240 piece numbers per epoch
    and one epoch of each exchange in memory (under about 3 KB). A message that fails to open, for any reason, changes
    nothing in the saved state (it is tried on a copy).
  - **Stalls.** Each session counts the messages it has sent since a post-quantum secret last went into its root (at
    the handshake, or either side's mix). If that reaches **200**, or **20** with the newest sent **7 days** or more
    after the last secret went in, the post-quantum ratchet counts as stalled (`Ratchet.postQuantumStalled`) and the app
    asks that device for new keys (`AppModel.refreshStalledPostQuantum`): the fresh handshake's root has a new ML-KEM
    secret in it, as SPQR starts over when its epochs stop moving. At most once a day per device, not while an ask is
    already waiting, and not for a device that is held, needs to update, or has gone quiet. Chat goes on on the old
    keys until the answer comes. A chat that is only quiet never counts as stalled.
  - **Old builds.** Every message has to be in this form (header version 4, bit 7 of the `caps` byte). A message from a
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
- a **friend request and its optional note** (up to 280 characters), since there is no session yet. The note is not
  covered by the request's ML-DSA signature ([section 4](#4-sealed-sender-envelopes-and-padding-buckets));
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
- **A friend request's note is not signed.** A request with a note travels as a frame: the request (card and ask) as
  JSON with an empty note, then the note's UTF-8 bytes. The inner header says how many bytes at the end the signature
  leaves out (`ut`), and the signature is then over the same transcript as above under a label of its own
  (`pulshade.envelope.v3.sig.part`), with the hash of the payload without those bytes. The count isn't signed, so the
  signature says nothing about the note, not even its length (the signed part is a frame that says its own length, so
  a count that moved its end would leave a hash the signature doesn't match). The receiver takes this only for a request, and only if what
  was left out is exactly its note; anything else is refused. So the signature binds the card and the ask (all that key
  setup needs), while the note is authenticated only by the inner seal, like a chat message: the recipient can't show it
  to anyone as signed by the sender. The trade: someone who could both break X25519 and seal to the recipient could
  change a note in transit without breaking ML-DSA. The name, picture and mailbox on the card stay signed. A request
  sealed in a classical introduction (to someone whose post-quantum keys aren't known yet) carries no ML-DSA signature
  at all, as before. Apps before build 22 can't read a request with a note sent this way.
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
  signature above). What those signatures do show a third party is that the sender's account set up keys with the
  recipient (and, for a request, its card: name, picture and mailbox), never what was said: a request's note is left
  out of its signature. (Public directory entries, @handles and announcements *are*
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
- every spare is padded to **one size (16 KB)**, whatever is inside (it carries the device's signed card);
- each slot is read and written on its own connection at random times, so one person's spares are hard to tie together;
- each device leaves each friend up to **three** spares, each in its own slot (the slot number is mixed into the HKDF
  context; the first slot is derived exactly as before, so older apps still find it): two are **used once**: the relay
  hands one out and erases it in the same step (`POST /v1/backup/{key}/take`, signed `pulshade.backup.take.v1`), so two
  of a friend's devices asking at once can't both get it, as with Signal's one-time prekeys (a relay without the route
  answers 404 and the app reads the spare and erases it afterwards, as before; builds before 22 always do that); the
  third is a **last resort**, taken only when both of the others are gone, and only read, never erased. "Used once"
  rests on the relay being honest, as with Signal's server and its one-time prekeys: a relay that wanted to could answer
  404 to make the app read and erase instead (two devices asking at once could then both get it), or hand the same
  spare out twice. Then the once-only guarantee (and what it adds against a first message being replayed) doesn't hold,
  but the relay still can't open anything, since it never has a spare's secret half;
- an unused spare, and the last-resort one whether used or not, is replaced every **5 to 10 days**; removing a friend
  erases yours for them; one nobody updates is erased by the relay after **180 days**.
- Spares are only made for friends whose app says it takes them.
- A spare's secret half is kept while it is up, and for **10 days** after it is replaced (`AppModel.spareGrace`); an
  answer to one that arrives later can't be opened, and the chat asks for new keys instead. A friend's device takes no
  spare made more than **20 days** before (`spareMaxAge`: the longest one is up plus that), and the maker finishes no
  answer to a last-resort spare older than that.
- An answer to a spare this device doesn't have (used already, gone past its time, or never made) is checked against
  nothing, so it adds no device and moves none to another mailbox: only a device already known by that same id is
  asked for new keys, at the mailbox it already has. From a device id not known, it is dropped.

The relay can still see *that* a spare was written, read or erased, and when, and (in Fast mode) the IP address that did
it. It cannot see who the friends are. Each spare is signed by the device's own keys. Its secret half lives in your
encrypted vault, and **not** in the sealed backup: a copy of the backup must not be able to finish a spare in your
device's name. A friend who takes a spare the device no longer has is asked for new keys instead.

**Why three, and the trade.** Spares now also mend chats whose keys fell out of step in everyday use, not only after a
recovery, so a friend may need several in a row, or two of their phones may both need one at once, while your app
stays closed. Two one-time spares cover most of that; the last-resort one (like Signal's signed prekey) means there is
always something to start from, so a chat only waits for a friend who hasn't opened Pulshade for weeks. The cost: the
last-resort spare's secret half is kept until it is replaced rather than thrown away when first used, so the first
messages of a session started on it are only as safe as that secret for those few days; the keys move on with the
first reply, as always. Each answer to it is remembered (its ephemeral key, the last 64), so the same answer sent again
can't put a chat back on keys it has moved on from, and the maker finishes none older than a friend would take. A
device fills or replaces **one slot per run** of its upkeep, minutes apart, so it writes new backup keys no faster than
before; the last-resort slot is filled before the second and is never left waiting behind refills, so its secret half
doesn't outlive its 5 to 10 days. A friend reads the slots one at a time, a few random seconds apart: the first; if
that's gone, the last-resort one (always up where a device leaves more than one, so if it isn't, there's nothing else
to look for); then the second, which is preferred to it. That keeps a recovery at about one read per friend, inside the
relay's hourly allowance. If the device's own keys change (its data opened on another device, say), every spare they
signed is erased and new ones are made; an answer to one signed by keys the device no longer has is refused.

**When both friends log back in at once.** Each may take the other's spare, so for a moment there are two new
sessions. Both sides settle on the same one, the spare made by the "lower" side by a fixed comparison both make, as
for crossed handshakes. The rule is dropped as soon as anything opens on the other keys, and a small receipt makes
sure that happens, so a friend who recovers later is still answered. Hellos sent before a spare was answered are
ignored.

## 6. Devices and personas

*Code: `AppModel.deviceID(for:)`, `AppModel.endLinkedDevices`.*

**Devices.** Since build 22 an account lives on **one device**: there is no way to link another. Builds before 22 could
link several, sharing the identity keys, and contacts can still be on those builds, so the protocol still treats a
contact as a list of devices. Each device has:

- its own random **device id**;
- its own long-term **device keys**, Ed25519 and ML-DSA-65 (`DeviceKeys.swift`), made on the device from 32 random
  bytes that never leave it: they sit in the encrypted data file, sealed again with a key in this device's Keychain only
  (never synced or backed up), and are left out of the sealed backup. The account signs the
  device's public keys for its id (the device's *card*), and the device signs every handshake it takes part in
  ([section 2](#2-the-handshake)). Each persona gets its own pair from the same bytes;
- its own mailboxes. Each has a secret receive key; senders write to a hash of it, so knowing where to *send* does not
  let anyone *collect*. A fetch does hand the relay the receive keys themselves, and one fetch asks for all of a
  persona's mailboxes together, so the relay can tell roughly how many mailboxes (and so contacts) a persona has;
- its own ratchet session with **every device of every contact**, so no message key is ever used twice.

People send a copy to each device a contact has. Nothing is synced between devices of one account any more: a `sync`
payload is read and dropped, whoever sends it.

**Ending old links.** A device whose data still lists other devices of the account (`Contact.isSelf`, left by an older
build) ends that once the relay is in reach after an unlock (`endLinkedDevices`). The keeper is the device with the
lowest id among those heard from in the last 30 days; one silent longer, never heard from, or known only by its mailbox
never makes another give way. The keeper sends the others `accountDetached` and, once that has left for each of them,
tells every contact `devicesUnlinked` for all the account's other devices, forgets them and makes a new group secret
(`renewGroupSecret`). Until it has left, the keeper keeps them listed and tries again at the next unlock. Every other
device does nothing on its own: it wipes only when `accountDetached` arrives from a device of the account, after telling
its contacts `deviceRemoved`, without erasing files on the relay. Of all `sync` events only that one and `accountErased`
(a Burn on an older build) are still taken, and only from a device of the account. So a stale list can't wipe the last
phone in use; at worst two devices both keep the account.

**Pinned device keys.** Contacts pin each device's keys (a hash of both public keys) the first time a handshake proves
them. A device whose keys later differ from the pinned ones, under the same id
or a new one, is a **new device**: the chat says "<name>'s account added a new device", and with "Ask before a friend's
new device gets my messages" on, nothing is sent to it and nothing it sends is read until you allow it. So someone who has a copy of a friend's account keys (their recovery
code) still can't stand in for one of that friend's devices unannounced. Restoring an account from its recovery code
makes new device keys, so friends see the restored device as new. A data file copied to another device can't open its
device keys there and makes new ones too. Handshakes without device keys (builds before 17) are not taken.

**After an unlink.** Unlinking a device (on builds before 22, or when ending old links) tells every contact (`devicesUnlinked`, from a device still linked, over its own
session, with the list of the account's devices that device still has). Contacts drop the unlinked device for good, hold
any other device of that account they know that isn't on the list, and from then on hold every new device of that
account until it is allowed, unless a device of theirs they still trust vouches for it: the device that approves a new
one signs its id and key pin with its own device keys (`DeviceVouch`), and the new device shows that vouch with each
hello to its main persona's contacts. An unlinked device still holds the account's keys, so it can make a new device of
its own, but not a vouch from a device the contact still trusts. Limits: a new device's other personas carry no vouch
(the approving device doesn't know their keys), nor does a friend request, so after an unlink those are held until
allowed; and a device a taken phone adds before it is unlinked is trusted until the unlink arrives.

**Linking a new device** was removed in build 22. The steps it took (a QR code from the new device, eight digits to
compare, the account sent sealed to a one-time key) are in this document's history.

**Personas.** A persona is a separate identity: its own seed, keys, mailboxes, contacts, chats and settings. Its
device id is an HMAC of the persona's own id, keyed with the device id, so a friend who knows two of your personas
cannot match them by device id. Over Tor each persona uses its own **lane**: its own circuits and so its own exit.
Personas are not linked to each other anywhere on the relay, unless you use Fast mode, where they come from the same
IP address (see [Tor and Fast](#tor-and-fast)).

**Lanes.** The app keeps separate network "lanes": each persona, each public inbox, sending, linking, reports,
each call. Each lane signs in to Tor under its own name, so each gets its own circuits and none can be tied to another by
address. Each lane's fetches also run on their own timers. *Code: `Lanes.swift`, `AppModel.currentLanes`, `flush`.*
Over Tor, from build 22:

- **Fetching.** A persona's one-to-one mailboxes are spread over three lanes. Which lane a mailbox goes on is worked out
  from the account's seed and the mailbox, so every device of the account (and the account restored) puts it on the same
  one, and it never moves while the mailbox lasts: a mailbox seen beside different others on different circuits would tie
  those lanes together. They are reshuffled as mailboxes move (below): a new mailbox lands on a lane of its own choosing.
  No single fetch names every contact a persona has. Each shared group is read on a lane of its own, never beside
  one-to-one mailboxes (past 16 groups, the rest share 16 lanes among groups only). The switch is for all of a device's
  groups at once: when its count of groups goes past 16 (or back to 16 or fewer), every group moves between its own lane
  (`group|<id>`) and the shared one its id falls in (`groups/<bucket>`), so the relay sees the device's group reads
  change circuits together at that moment. *Code: `AppModel.groupLane`.*
- **Moving mailboxes.** Each device moves to a fresh mailbox for each friend once a week (each friend's week starting at its
  own random moment), and tells each of their devices inside its session with it (`Payload.mailbox`), so only that device
  can say so. The old mailbox is still read until every device of theirs has written to the new one, then for 30 days (as
  long as mail waits). An app before build 22 ignores the move and keeps writing to the old mailbox, which is then read for
  as long as it does, and no further move is made until it has followed. A device
  not heard on the new mailbox three days after the move is told again (every three days until it is); one silent for a
  month while another of theirs talks, which is left out of sending and so never told, isn't waited for. A move doesn't by
  itself send the account's backup up again: it goes with the next upload that happens anyway, or the weekly one, so the
  backup's timing on the relay doesn't follow the moves. Before it moves, the device asks the relay
  (`POST /v1/move`, both receive keys, on the lane the old mailbox is read on) to give the fresh mailbox the old one's
  standing, and only tells the friend once the relay has: otherwise the fresh mailbox would count as one nobody has
  collected from, whose mail waits two days, not 30, and a phone off for a few days after a move would lose what was
  sent. A mailbox can pass its standing on once, so moves never make more mailboxes that can move; they have a rate
  limit of their own, apart from new mailboxes'. The relay learns that the two mailboxes belong together, which it
  would see anyway once both are read on the same lane, and forgets one moved from after six weeks unused (not twelve).
  A relay without the route (before build 22) says no, and the device stays on its mailbox.
  *Code: `AppModel.tendMailboxes`, `tendMailboxMoves`, `backupChangeDigest`, relay `Store::pass_on`.*
- **Sending.** A persona's sending lane, and each shared group's posting lane, keeps its circuit for one burst of sending:
  after 90 seconds quiet, or 5 minutes in use, the next send goes on a fresh circuit. Nothing is sent just to keep a
  sending lane open (builds before sent a health check on it every 45 seconds, which tied everything it carried
  together).
- **Used once.** Each delivery or read receipt, each file upload or download, each token spent, each file erased, each
  part of a wake-up registration and each part of a Burn goes on a lane of its own that is let go of afterwards.
- **Reconnecting.** Coming back to the front, a refresh, an unlock or a new network: the main lane checks in at once, the
  main persona's other lanes within 10 seconds, and every other lane at its own random moment within a minute, so the
  relay doesn't see all of one phone's lanes arrive in the same second. After a wake-up push the spread is a few seconds.

Over a direct connection (Fast) all lanes come from one address, so the app doesn't spread fetches, groups or wake-up
registrations: it would buy nothing and use up the relay's allowances for that address (waiting fetches; 60 wake-up
requests an hour). Mailboxes still move.

**What the relay can still infer.** Lanes hide which mailboxes one request names together, not timing. The relay sees
when mail lands in a mailbox and which circuit is waiting on it, so mail landing in one of your mailboxes followed by your
phone's delivery receipt landing in the sender's mailbox 5 to 20 seconds later still pairs the two mailboxes statistically
if it watches long enough (as with any relay that sees both ends); moving mailboxes weekly limits how long one pairing
stays useful, and while an old and a new mailbox are both read they are fetched on the same phone's lanes, which can tie
them together. A phone's lanes also start and stop together across unlocks and wake-ups, which a patient relay can line
up. Wake-up registrations share one Apple token across everything they cover (see `docs/push-notifications.md`).

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
  sealed on disk for the epoch's life (7 days from build 16, 3 in builds 14 and 15; 1 to 7 allowed) and does not let it go when it is read, because it must not learn
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
  (two admins at once) are settled everywhere alike by who signed them: the owner, then the admins in the order the
  owner listed them, then mods, then members in card order, so nobody can win by signing again. Only two versions from
  one key (two of one account's devices) are settled by the lower hash. The owner's device signs every change made by
  someone else over again, and an owner-signed version may skip numbers, so a member who missed some catches up.
- **Posts that must not get lost.** The relay keeps group mail for 7 days (new epochs from build 16; 1 to 7 is allowed). A device
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
- **An unlinked device.** Its account's devices move the account's place in each group to keys made with a new group
  secret it doesn't have. It still holds the old keys, so it could move the place to keys of its own: a move to new keys
  beats any other change the old key signs at the same number, and two moves of one place to different keys (even one
  arriving after the group moved on) are a dispute. Then neither is taken, nothing from those keys is read, an admin's
  phone takes the place out with a new epoch, and the member has to be added again over a 1:1 chat. If the place is the
  owner's, the group is closed on every device. A device that sees its own account's place moved to keys it can't make,
  and doesn't get the group secret that makes them within ten minutes, moves the same place to a throwaway key so the
  members see the dispute, and leaves. See `docs/groups-design.md` section 23.

What it changes, honestly:

- **Healing.** A 1:1 chat heals at the next reply after a key is stolen. In a group, a stolen epoch key reads everything
  in that epoch (every member's chain starts from it), so epochs are short: a removal, a newcomer after the group has
  talked, or 7 days / 1,000 posts. Within an epoch each sender's chain still only moves forward, so a member's
  device holds no key of a message it has already read from a sender it has heard; but it can work out the chain of any
  sender it has not, from the epoch key, so **there is no per-message forward secrecy against someone who steals an
  epoch key** (see `docs/groups-design.md`, "Forward secrecy inside an epoch").
- **Receipts.** A group message shows "sent" once it is on the relay; members do not confirm it one by one.
- **The relay** sees one mailbox that many devices read, and can count how often it is read. It can tell the readers
  apart: each member device keeps its own waiting fetch on the mailbox and reads from its own place (its cursor), so the
  relay can count the member devices that read, see how far each has read and when, and see which device posted (posts
  go on the poster's circuit). Over Tor (from build 22) each group is read on a lane of its own, starting at its own
  random moment, and posted to on another, so a device's groups and its one-to-one mailboxes aren't named in the same
  request; but it can still count readers and line up their timing. In Fast mode it also sees their addresses.
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
  no names; at most 500). It is posted in a second, staff-only mailbox (an "epoch 0") that opens with a 32-byte staff
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
  once every ten minutes. A channel's code lets in at most 60 new followers an hour (repeat hellos from one identity count once); the rest wait, earliest first, and the list drops the newest when it is full (500). Nothing is
  posted in any mailbox. With no answer (an older app, an absent phone, or a follower already taken out) the follower is just
  told that none came.
- **Who can invite.** A channel invite carries the sending staff member's signature, with their group key in the
  channel, over the channel and the sending account's key (`StaffVouch`). A channel the phone doesn't follow yet is taken
  only from an invite whose signature is from the owner or an admin and names the account that sent it, so nobody can
  forward an invite they got and become the account the channel is followed through. Invites from staff on apps from
  before carry none and are refused, with a note to a friend's chat that their app is too old.
- **Channel codes name their channel.** A channel code carries a 16-byte hash of the channel's id under its signature
  (kind byte 3; apps from before can't read such a code). After following a code, the channel's invite is taken without
  asking only if it carries that code's tag and is for the channel the code names; otherwise, and after following a code
  from an older app, it waits for a yes.
- **Earlier posts for a newcomer.** Once a follower's card comes back, the staff member who let them in sends the
  channel's newest 100 posts over their 1:1 chat (`channelHistory`: group id and up to 20 posts each, every post a
  `WireMessage` plus its staff author's group key). The follower takes them only from the staff member it follows the
  channel through, only for staff authors, quietly and in date order. Big media follows as `clipBlob`, which a follower
  takes for a channel post from that same staff member. Apps from before ignore it.
- **Chains from the inviter.** Staff chains a follower gets from the staff member who invited it are kept only once a
  post from that staff device opens with them; one that doesn't is dropped and asked for again, so they can't be
  replaced with made-up ones for good.
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
  It keeps a record of everyone the keys have been sealed to since the last reset, and when two versions are made at once
  the one whose signer ranks higher wins (the owner first, then admins in the owner's order), so a change made at the
  same moment can't undo the reset and no admin can win by signing again.

What this means: anyone who has a link can read the preview, so they learn the group's name, picture, description, size
and the member keys of its owner and admins (keys used only in this group); they can also overwrite or delete the
preview (the owner's phone puts it back within a day, or at once on any change; a reset gives the link new
secrets). A preview is taken for 14 days after it was made and names the link secret it was made for (a tag signed with
a second signature that older apps ignore), so an old copy put back by someone who once held the link stops working,
and one can't be moved into another link's slot. A preview without the tag (from an owner on an older app) is taken
only for four days after it was made, and not at all from 1 January 2027, so taking the tag off doesn't get round it.
Openers read at most 256 KB from the slot. Only admins can see who asked through a link that needs approval. The relay sees a small backup-sized slot
read now and then, and envelopes going into and out of two ordinary mailboxes. If the owner's phone is away when an
admin is removed, that admin can still read requests until it's back; previews aren't refreshed while it's away. Two admins changing the links at the same moment
can let a use limit be passed by one or two; a ban or use count lost that way is put back by the phone that holds it.

## 8. Sealed backups

*Code: `AppModel.sealedBackup`, `Identity.backupKey`.*

So that Detach can be instant, the app keeps **one backup** of your account on the relay.

- **What is in it:** your profile, @handles, contacts, groups, personas and settings. **Not** in it: chat history,
  stories, requests, messages still waiting to be sent, any decoy or panic identity, **and (since build 13) any
  session keys**, nor (since build 17) the device's own keys or its spare keys. A recovered account opens new sessions with every contact (on their spare keys where they left
  one), so mail sent to you while you were detached can't be opened. The one exception is a contact who hasn't
  accepted yet, whose waiting ask has to stay.
- **How it is sealed:** AES-256-GCM, with a key made from your seed (so only the recovery code can open it). The seed
  is 256 bits of randomness, so there is nothing to guess.
- **Padding:** to a power of two, at least 64 KB, behind a length marker. The relay learns a rough size class, not how
  many contacts you have.
- **Count and date:** inside the seal, every backup carries a stamp (`BackupStamp`): a count one higher than the last
  this device made or restored (or the time in seconds, if that is more, so an account's devices count up roughly in
  order), and when it was made. Restoring shows "Backup from <date>" and waits for a yes. A device that still has the
  account's data refuses a backup whose count is lower than the newest it made or restored ("the relay gave an older
  backup"). A device with none of the account's data (a fresh install, or after a Detach) has nothing to compare
  with: the date is its only defence against a relay that serves an older copy. A backup from before build 22 has no
  stamp; it is restored, and the screen says its date isn't known.
- **Where it is filed:** under a public Ed25519 key that is also derived from the recovery code, and from nothing else.
  The relay cannot tie it to your account or to anything you send. Every read, write and removal must carry a fresh
  signature from that key (a signed label, the key, the time and, for a write, the hash of the body).
- **When it is saved:** a random 1.5 to 10 minutes after something in it changes, over Tor if Tor is on, and once a
  week regardless. Only the main identity does this, never a decoy or panic account. You can switch it off in Settings,
  which erases it at once. Burn erases it too. If you set a panic passcode, each save also gives the relay the hash of
  a delete-only token, so entering the panic passcode can erase the backup without the recovery code's key. The relay
  keeps that hash (and the backup's other side files: when it was first stored, and its size to grow from) sealed with
  its storage key, and answers a forget with the token the same way whether a token was filed, the token was wrong or
  the backup was erased, so asking doesn't tell anyone whether a panic passcode is set.
- **How long:** until you switch it off, Burn, or **180 days** after the last save. After a Detach nothing refreshes
  it, so the 180-day clock runs from the last save.

Honest limits:

- The backup no longer holds session keys, so a leaked recovery code with a stored copy shows no chat key that was ever
  used. It does show your contacts, groups and settings, and the recovery code on its own is still your whole identity
  (someone holding it can take over the account and be sent new sessions, though every friend sees those come from a new
  device). Copies of old versions may linger on the relay's disk or in storage snapshots, sealed.
- The relay can see *when* a backup was saved, its rough size, and (in Fast mode) the IP that saved it.
- The relay can hand back an older copy it kept instead of the newest. It can't change the date or count inside it;
  see "Count and date" above for what is caught.

## 9. The blob store (big files)

*Code: `Sources/Pulshade/Core/Blob.swift`.*

Files up to **100 MB**, chat videos, and story videos are not sent inside a message. Neither are photos, voice notes
and photo stories bigger than about 48 KB, when every device of the person they go to says its app takes them that way
(bit 5 of the `caps` byte): the message or story then carries only a tiny preview of the photo, or a voice note's length
and waveform, and the rest follows as a pointer. Older apps still get them inside the message. Instead:

1. The sender's app makes a fresh random **256-bit file key** and seals the file in **1 MiB pieces** with
   ChaCha20-Poly1305. Each piece's nonce is its position, and its authenticated data is the file id, the position and
   a "last piece" flag, so pieces cannot be swapped, reordered or cut short. While reading the file the first time, the
   app keeps a SHA-256 of each piece; a piece is sealed only if it still has that hash, so a file changed on disk before
   an upload is tried again or resumed never puts different bytes under the same key and nonce (the upload stops and
   says the file changed).
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
   after **30 days at most** (7 in groups). Burn sends the same erase for everything the account uploaded.

The phone never writes a received file to disk unless you tap **Save a copy**. The relay can see that a file of about
that size was uploaded, when, and when it was collected (and your IP in Fast mode). It cannot see what the file is, its
name, its type or who it is for.

### 9a. Calls

*Code: `Sources/Pulshade/Core/Call.swift`, and the relay's call handling.*

The caller makes a random room id and a random 256-bit call key and sends both inside an ordinary end-to-end encrypted
message (`CallInvite`). Both phones join the room on the relay over a WebSocket; the relay passes packets between the
two devices in it and lets no third one in, and never sees the key.

- **Keys:** each **connection** picks a random 16-byte salt. Its sending key is HKDF-SHA256 over the call key, salted
  with that salt, with the label `pulshade.call.caller.v2` or `pulshade.call.callee.v2` for its side. Every packet carries
  its sender's salt, so the other side derives the matching key (it remembers the last 4 salts it heard from).
- **Packets:** `kind (1) | salt (16) | number (8) | ChaCha20-Poly1305 ciphertext and tag`, with the header as the
  authenticated data and the number (counted from 1 per connection) as the nonce. Every body is padded to 256 bytes, so
  sizes don't show who is talking. A number seen before, or more than 100 behind the newest, is refused.
- **Why the salt:** if two of the callee's devices answer the same call at once, both count from 1 under the call key.
  With a salt each, they never seal under the same key and nonce, even if a relay passed both on.
- Apps before build 22 sent packets without the salt, under keys without it; they can't call or be called by this one.

## 10. Delivery receipts, and receipts from a locked phone

*Code: `Sources/Pulshade/Core/LockedDelivery.swift`, `HelperStore.swift`.*

From build 16, delivery receipts are always sent (there is no switch; a saved "off" from an older build is ignored);
read receipts remain a choice. A message without a receipt is sent again: soon at first, then less often, up to once a
day, for as long as the relay keeps mail (30 days). Each copy carries a relay replace tag (`x-pulshade-collapse`, from
`AppModel.resendTag`: a hash of the mailbox, the sending device, the message id and a three-day window), so the newest
copy replaces the one before while it waits. Within a three-day window the relay can see that deposits are copies of one
thing and come from one sender device; across windows the tag changes. When new keys are set up with a device, what it
hasn't confirmed goes to it again at once, at most once every ten minutes and at most the newest 50 messages.
Collecting mail while locked (below) is switched off in build 16.

Ordinary receipts are ratchet messages like any other. A receipt waits a random 5 to 20 seconds (from build 22; 1 to 5
before) and goes out batched with others for the same person, on a Tor circuit used for nothing else, so it pairs "a
message arrived" with "a message was sent" less tightly in time and not by circuit. A phone woken by a push in the
background has about half a minute in all, so there the wait is cut to what is left of that (as little as half a
second); a receipt still waiting when iOS suspends the app goes when Pulshade next runs. A message that arrives again
(sent twice) is answered with a receipt at most once a day, and at most 20 times an hour for each contact, so sending
the same message over and over doesn't tell a contact when each of your devices is running. *Code: `queueReceipt`,
`Lanes.receiptWait`.* This blurs the timing; it doesn't remove it (see "What the relay can still infer" in section 6).

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
- It needs notifications on (they bring wake-ups with them). It covers the main identity only (not personas), and Burn and Detach remove
  everything the helper holds. If a decoy or panic passcode is set, it is off for the whole device, not only for those
  accounts.
- **Waking a locked iPhone is always on while notifications are on** (iOS asks first for notification permission;
  there is no separate switch from build 19). It covers new messages and friend requests. Apple learns that your phone
  was woken and when, never who wrote or what. The relay holds your push token, tied to your mailboxes and your
  @handle's request mailbox. People who need the strongest anonymity should turn notifications off.

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

## What the relay stores, and for how long

The relay does not keep accounts. Everything it holds is either sealed by your phone, sealed again by the relay with its
storage key (kept in its memory, not on its disk: see below), or public because someone chose to publish it.

| What | Where | How long |
| --- | --- | --- |
| Waiting envelopes (messages, receipts, call set-up) | Disk, in segment files with every record sealed under a key of the segment's own (keys only in an index sealed by the storage key); recent ones also cached in memory. Written before the 202 | Until the recipient collects them, or **30 days** (when the mail share is over 90% full, mail that has waited over a week makes way, oldest first, down to 80%). Collected envelopes are dead at once: a segment with none alive has its key forgotten, its file overwritten and deleted; one kept alive by a slow reader is rewritten without them once at least half of it is dead. A full share of the disk answers **507** and drops nothing |
| Group mail (groups and channels that share one mailbox) | Disk, sealed on the phones and again by the relay | The life the epoch was made with, **7 days** for every epoch made from build 16 (3 in builds 14 and 15). **Not erased when read**, so the relay can't learn who reads or how many do |
| Typing and "online" signals | From build 22 they wait like any envelope (they no longer say they're short-lived, which marked them out); a newer one from the same device replaces the older (the collapse tag below). From older apps: memory only | Until collected, or 30 days; the receiving app ignores typing that reached the relay more than 20 seconds before |
| Big files, chat videos, story videos | Disk, sealed twice, in pieces. From build 22 padded with random bytes to a size step (quarters up to 1 MiB, from 8 KiB; whole MiB above), so the relay sees the step, not the size. With each file, its **reader list**: a hash of each reader token and how many uses it has left, and when each use is spent. From build 22 the list has a fixed shape (at least four entries, all with the same number of uses; the sender spends the uses nobody else will, at random moments within six hours, each on its own connection), so it no longer says how many people or devices a file went to | Erased when collected (every use spent) or deleted, **30 days at most**, 7 in groups (an unfinished upload: 1 hour; one announced that sends no piece: 2 minutes, and unsent uploads together may hold at most a quarter of the store). When the store is full, finished files older than a week make way, oldest first, only for room really taken (not for uploads announced and not sent), no more than a quarter of the store an hour. Someone who keeps the store full of fresh files can still crowd out new ones; nothing younger than a week ever goes |
| Sealed backups and spare keys | Disk, in the backup store | Until switched off or Burn; **180 days** after the last save. Spares: also erased when used |
| Wake-up registrations (Apple push tokens) | Memory, and a sealed file | While the setting is on; dropped after 7 days without renewal. Each mailbox keeps the tokens of the phones that read it (up to 64; a group's mailbox one per member), each with only what the push needs and when it runs out, to the hour. Whoever has the server's memory, or the file and the storage key, can see which mailboxes share a token and which tokens read one group |
| Mailboxes collected from (so new mailboxes can be kept to a small share) | Memory, and a sealed file | A mailbox id with roughly how much has been collected from it (a power of two), the day it was first collected from for its first week only, and the week it was last used. Forgotten after 12 weeks without a fetch or collection |
| Public @handles and profiles, announcements | Disk | Public by choice. A let-go handle is held for its owner 90 days, then free (a 30-day cool-off if the owner gives up the hold early) |
| Rate-limit counters, and who left mail on probation | Memory | An hour (a day for daily limits); probation tags 12 to 24 hours. A keyed hash of the address, never the address itself: pseudonymised, and reversible (by trying every address) by whoever holds the server's memory while its key lives |
| Mailboxes closed by a Burn | Memory | 30 days (as long as mail can wait) |

The relay's disk files (mail segments, directory, backups, blobs, keys) are sealed with a **storage key that is kept in
the server's memory** (a memory-only folder, and the operator's Mac), not on the server's disk. A new server's install
writes the key to its disk until the operator moves it into memory, which shreds that copy; a flash disk can keep old
blocks all the same, so the operator then re-keys (with the relay's re-key command): every file sealed with the storage key is
sealed again with a new key that was never on the disk. A re-key doesn't change the per-segment and per-blob keys inside
the indexes, so mail and files from before it stay as open to the old key as they were, until they expire (30 days at
most). In the relay the key sits in a memory page of its own, locked so it is never swapped and zeroed when let go; keys
read from files and the plain text of the indexes are wiped once used; on Linux the relay won't start while the server
swaps to a disk; and a crash writes no memory to disk. What this does **not** stop: someone who controls the *running*
server can read the key from memory. That is why anything personal is sealed on your phone first.

What the relay **sees**: that a sealed envelope arrived at a random mailbox, when, and its size class; which mailboxes
one fetch asks for, and which fetch is waiting on a mailbox when mail lands in it; when a backup, spare or file is
written, read or erased and its size step; how many readers a group mailbox has and how far each has read; when the
uses on a file's reader list are spent; which mailboxes one wake-up token covers; and (in Fast mode, including the
locked-phone helper) an IP address while it is connected. See "What the relay can still infer" under Lanes above.

Each deposit also carries a few plain headers the relay acts on:

- **Wake:** whether to wake the recipient's phone, and whether it is a call ringing. So the relay can tell a message
  from a background signal from a call.
- **Life and collapse:** a deposit may say how long it is worth keeping (at most an hour); from build 22 the app no
  longer uses this for typing and "online", so they don't stand out from messages (apps before build 22 still send it
  on them). Some signals, key requests and resends carry a tag so a newer copy replaces the older one. The tag is a hash of the kind of signal,
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
| Which mailboxes share a push token (your @handle's request mailbox among them), while notifications are on | Anything that ties your personas together, apart from Fast-mode IP or a shared push token (main identity only) |
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

While notifications are on: that your device got a push, and when. Never who wrote, or what ("New message" only). The
App Store knows you downloaded the app. Your phone may also keep its own records of notifications and app use,
which Pulshade cannot control. By default notification text is only
"New message".

### A seized phone, locked

| What the attacker faces | |
| --- | --- |
| The vault | Sealed with the passcode (Argon2id, 64 MiB, then AES-GCM), **mixed with the answer that phone's Secure Enclave gives for that passcode**, so every guess needs the phone's chip. A copy taken off the phone cannot be guessed at elsewhere, and answers once taken from the chip don't help with other passcodes. On iPhone the files are also unreadable while locked. Ten wrong guesses in a row wipe a new account's device (a setting, sealed in the lock file). |
| The Keychain | Only if notifications and **Collect messages when locked** are both on. Collecting is **off by default**; it is a choice made by hand, with a warning. Then the notification helper keeps in the Keychain ("after first unlock": readable once the phone has been unlocked since it started) this account's raw **signing and agreement keys**, this device's id, and each friend's agreement key and mailbox key, plus short sealed envelopes waiting in its inbox. An attacker who can extract Keychain items from such a phone can **impersonate the account** (sign as you, and open new sessions with your friends), open the envelope wrappers sent to you, and so **read what is sent to you from then on**. They cannot read **past** messages: the chat keys (ratchet state) are in the vault, behind your passcode and the Secure Enclave. Turning the setting off removes the bundle. |
| Decoy / panic passcodes | A decoy opens an empty identity; the panic passcode shreds the real one. The lock file always has three equal slots and four data files, so the disk does not show which are real. |
| Old copies | The whole lock file is sealed again with a Keychain key that changes every time Pulshade locks, so an old copy recovered from flash storage no longer opens (unless the attacker also recovers that key's old Keychain entry and knows the old passcode). |

A **short passcode can be guessed** only on the device itself (because of the Secure Enclave mix), one Argon2id run
and one Secure Enclave answer per guess, by someone who can run code on the unlocked device (the app's own wait and
wipe count don't bind them). A 6-digit PIN would likely fall to that within hours to days (an estimate, not measured); a long passcode doesn't. A long passcode is
the strongest protection you control.

### A seized phone, unlocked (or malware as you)

Everything on it that the app can read: chats, contacts, keys, the lock file's contents once opened. We cannot protect
against this beyond **Burn**, the **panic passcode** and **auto-lock**. An automatic lock keeps the keys in memory so
messages still arrive, unless **Close everything when it locks** is on; a lock you press always clears them. Screenshots are blanked where the system allows
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
| Message content | **Still safe.** The handshake mixes ML-KEM-768, and the sparse post-quantum ratchet adds a fresh ML-KEM-768 secret about every 6 to 10 short messages of a back-and-forth chat. |
| The sealed-sender layer (version 3 envelopes) | **Still safe.** ML-KEM-768 is mixed into both layers. Exceptions: the first, introducing envelope each way (hello, request or introduction), and group-member envelopes, which are classical. |
| Any TLS/Tor layers (X25519-based) | **Could be opened** (outside what Pulshade controls). That would reveal the mailbox read keys sent in requests and timing, not message content or, for version 3 envelopes, the sender. |
| Identity authentication | **Hybrid.** Control messages need an Ed25519 and an ML-DSA-65 signature, and a pinned contact can't be downgraded. Pinning is trust on first use; the pulse code covers both signing keys and both agreement keys (Ed25519 and X25519), not the post-quantum keys, and public directory entries and admin signatures are still Ed25519 only. |
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
  like), and Tor's own state and caches (iOS file protection, not our key). The Tor
  switch and the bridge choice are sealed with a Keychain key (build 13). Video you pick from your photo
  library may be copied by the system to a temporary file before Pulshade reads it into memory; Pulshade deletes
  leftovers at launch, but we do not control that system copy. We are not aware of any other temporary files written
  by Apple's video code (AVFoundation) in Pulshade's paths, and this is one of the questions we ask auditors to check.
- **Keychain items after first unlock** (section 10) when locked-phone collection is on.
- **One operator.** The official app sends your messages and account traffic only to Pulshade's own servers. It also contacts Apple's push
  service (while notifications are on, the default), the sites behind link previews you turn on (over Tor if Tor is on),
  and, if you pick the Snowflake bridge, its CDN front and public STUN servers; links you tap open in the browser. A modified app
  could point at other servers; the rate limits and the terms of use, not the code, hold that back.
- **Disappearing messages** and **deleted stories** depend on the other person's app.
- **Groups** cap at 300 members and trust their admins for the roster.
