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
| Storage key | Seals the local database on the device. Never leaves it |
| Backup signing key and backup sealing key | For the sealed backup. Unrelated to the keys above on the wire |
| Public-inbox key, one per @handle | The mailbox behind a public handle |

The **recovery code** is the seed written as 52 characters of Crockford base32 plus a 4-character checksum, in 14
groups of four. It is the only way back in if the device is lost. Anyone who has it *is* you: it is the whole identity.

The **fingerprint** is the first 16 bytes (32 hex characters) of SHA-256 of the signing public key. It names an account
inside the app and seeds the artwork you see for it.

**Checking who you are talking to** (the "pulse check"): both phones work out the same code from both fingerprints,
sorted so the order does not matter. It is shown as 10 emoji (60 bits), 30 digits, two colours, and a QR code that
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
  message cannot be moved into another pair's session or have its header altered.
- **Out of order:** up to 1,000 missed messages can be skipped over, and up to 2,000 spare keys are kept to open late
  arrivals. A message that fails to open never changes the saved state (it is tried on a copy).
- **Post-quantum refresh:** the handshake gives quantum resistance at the start. After **50 messages or 24 hours** a side
  offers a new ML-KEM-768 key inside its messages; the other side answers on its next new chain with a ciphertext, and
  that secret goes into the root alongside the X25519 step. So someone who breaks X25519 later is locked out again at
  the next refresh. Messages that carry a refresh are bigger (about 8 KB instead of 2 KB), so someone who can see sizes
  could tell roughly when one happens. This is like Apple's PQ3, not Signal's "triple ratchet". A chat with someone on
  an old version never refreshes.

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

A ratchet message is sealed again before it goes to the relay, so the relay does not learn who sent it.

- **Outer seal.** A fresh X25519 key per envelope; its DH with the recipient's long-term agreement key gives a
  ChaCha20-Poly1305 key. Inside: the sender's agreement key, then the inner seal. The recipient's key is the only
  thing needed to *send*, so anyone can write to a mailbox they know; what the relay sees is one random-looking blob.
- **Inner seal.** A second key mixes two DH results: ephemeral-to-recipient *and* sender's long-term key to the
  recipient's long-term key. Inside it: the sender's signing key, a signature by that key over the sender's agreement
  key ("these two keys are the same person"), the device id, the time in whole seconds, a byte saying what the sender's
  app can read, and the payload.
- **Deniable:** only the sender could have made the inner seal, so the recipient knows who it is from, but the
  recipient could have made it too. It proves nothing to a third party. The signature covers only the key pairing, and
  is the same every time; **no message is ever signed.** (Public directory entries, @handles and announcements *are*
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

*Code: `GroupInfo` and the group handling in `Wire.swift` and `AppModel.swift`.*

Groups, channels and broadcasts are made **between phones. The relay knows nothing about them.**

- A group is a list (the *roster*) of members' public keys and mailboxes, held on each member's phone. It travels as a
  normal message through each pair's ratchet. The relay sees an ordinary envelope.
- Every group message is sent as **one envelope per member device**, each through that pair's own ratchet. There is no
  shared group key. The cap is 300 members, because of this fan-out.
- A group has an **owner**, optional **admins**, optional **mods**, and a **posting rule** (everyone, admins, or owner
  only). Changes carry a version number and count only when they come from someone allowed to make them. Mods can only
  remove ordinary members; everyone ignores a mod's update that does anything else.
- Members who are not your contacts are kept as hidden peers, used only inside that group. Members who do not know
  each other first meet through **introduction mailboxes**, made by whoever sends the group's details. Nobody is given
  the mailbox another member uses with the owner. After the first hello each pair moves to a mailbox of its own.
- In a channel, followers learn who can post, not who else follows.

Honest limits:

- A roster is only as trustworthy as the admins who sent it. A poisoned roster **cannot** let anyone read your messages
  to a member (a session only opens on an answer signed by that member's own identity), but it can stop you reaching
  that member. Checking the pulse code settles it. A later version may have members sign their own cards.
- Because each member gets their own copy, a malicious member can send different members different things. There is no
  group-wide transcript check.
- The relay sees a burst of envelopes of the same size land in many mailboxes at the same moment. Over Tor it cannot tell
  whose they are; in Fast mode it sees one IP address depositing all of them.

## 8. Sealed backups

*Code: `AppModel.sealedBackup`, `Identity.backupKey`.*

So that Detach can be instant, the app keeps **one backup** of your account on the relay.

- **What is in it:** your profile, @handles, contacts, groups, personas and settings, **and the session keys** for each
  contact device, so mail sent to you while you were detached can still be opened after you log back in. **Not** in it:
  chat history, stories, requests, messages still waiting to be sent, and any decoy or panic identity.
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

- Because session keys are in the backup, **forward secrecy is weaker against one specific attacker**: someone who gets
  *both* your recovery code *and* a stored copy of your backup can read what that snapshot's keys cover (messages that
  were in flight, and the ones sent in the same chain until the other side's next reply). They would not need much
  else, since the recovery code on its own is your whole identity. The backup is overwritten on each save, but copies
  of old versions may linger on the relay's disk or in storage snapshots, sealed. The same goes for the handshake
  secrets kept to finish late answers ([section 2](#2-the-handshake)) and spare keys' secret halves.
- The relay can see *when* a backup was saved, its rough size, and (in Fast mode) the IP that saved it.

## 9. The blob store (big files)

*Code: `Sources/Pulshade/Core/Blob.swift`.*

Files up to **100 MB**, chat videos, and story videos are not sent inside a message. Instead:

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
   destroys the file's key (so a stray copy on a flash disk cannot be opened). Video stories stay until their timer ends.
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
- The helper cannot run Tor, so it reaches the relay **directly**, and the relay sees your IP for that moment. That is
  why locked-phone collection is **on by default only in Fast mode and off by default on Tor**; turning it on with Tor
  says so.
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
  your IP address; it makes up one address per circuit. Nothing falls back to a direct connection, apart from the
  locked-phone helper above, if you turn it on. Bridges (Snowflake, webtunnel) can be turned on for networks that block Tor.
  Because new circuits are cheap, the relay's rate limits want a small proof of work (a fraction of a second of
  hashing) on some requests.
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
| Waiting envelopes (messages, receipts, call set-up) | Memory, and a journal on disk with every record sealed. Each envelope is added to the journal as it arrives | Until the recipient collects them, or **7 days**. After collection the journal is rewritten within minutes and the old file overwritten |
| Short-lived signals (typing, "online") | Memory only | A few seconds to minutes; never journaled |
| Big files, chat videos, story videos | Disk, sealed twice, in pieces | Erased when collected or deleted, **7 days at most** (an unfinished upload: 1 hour) |
| Sealed backups and spare keys | Disk, in the backup store | Until switched off or Burn; **180 days** after the last save. Spares: also erased when used |
| Wake-up registrations (Apple push tokens) | Memory, and a sealed file | While the setting is on; dropped after 7 days without renewal |
| Public @handles and profiles, collectibles, announcements | Disk | Public by choice. A let-go handle is held for its owner 90 days, then free (a 30-day cool-off if the owner gives up the hold early) |
| Rate-limit counters | Memory | An hour. Only a salted hash of an address, never the address |
| Mailboxes closed by a Burn | Memory | 7 days |

The relay's disk files (journal, directory, backups, blobs, keys) are sealed with a **storage key that is kept only in
the server's memory**, never written to the server's disk. A crash writes no memory to disk. What this does
**not** stop: someone who controls the *running* server can read the key from memory. That is why anything personal is
sealed on your phone first.

What the relay **sees**: that a sealed envelope arrived at a random mailbox, when, and its size class; which mailboxes
one fetch asks for; when a backup, spare or file is written, read or erased and roughly how big; and (Fast mode,
and the locked-phone helper) an IP address while it is connected.

Each deposit also carries a few plain headers the relay acts on:

- **Wake:** whether to wake the recipient's phone, and whether it is a call ringing. So the relay can tell a message
  from a background signal from a call.
- **Life and collapse:** typing and "online" signals say how long they are worth keeping (at most an hour), and some
  signals and key requests carry a tag so a newer copy replaces the older one. The tag is a hash of the kind of signal,
  the sender's device id and the mailbox: it says nothing else, but it is the same each time, so the relay can tell
  that repeated signals to one mailbox come from the same sender device.
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
| Whether a deposit is a message, a signal or a call; that repeated tagged signals to one mailbox come from one sender device | Which device that is |
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
| The Keychain | If the phone has been **unlocked once since it started** ("after first unlock" state), and the attacker has a way to extract Keychain items, they may get: the two envelope keys, friends' public keys and mailbox keys, and short sealed envelopes waiting in the helper's inbox — **only if Wake when locked and locked-phone collection are on**. That lets them open envelope *wrappers* to this account and write to it as anyone. It does **not** open messages (the ratchet keys are in the vault). |
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
| Message content | **Still safe.** The handshake mixes ML-KEM-768, and the ratchet refreshes it every 50 messages or a day. |
| The sealed-sender layer and any TLS/Tor layers (X25519-based) | **Could be opened.** That would reveal sender key, device id and timing for recorded envelopes, and the mailbox read keys sent in requests; not message content. |
| Identity authentication (Ed25519, X25519) | Not post-quantum. A quantum attacker could impersonate in *new* conversations once such a machine exists. Existing verified contacts and the pulse code are not protected by ML-KEM. |
| Files, backups, the vault | Symmetric (256-bit) and hash-based: **still safe** at current estimates. |

## Honest limits

- **Not audited.** The ratchet, the handshake and the envelopes are our own implementation.
- **Timing and volume.** Tor hides addresses, not timing. A patient observer at both ends could link a sender to a
  recipient. Group messages and file transfers are the easiest to line up.
- **Your IP address in Fast mode.** The relay sees it while you are connected. We do not record it, and nothing on the
  server keeps an access log, but that is our promise, not something the code can prove.
- **The locked-phone helper connects directly**, not over Tor, for a moment each time, when locked-phone collection is
  on (the default in Fast mode, not on Tor).
- **The 180-day backup.** A sealed backup stays on the relay until you switch it off, Burn, or 180 days without an
  update. It holds session keys (see section 8). It is sealed with a key only your recovery code makes. If that code
  leaks and a copy of the stored backup exists, it can be opened.
- **Disk.** Deleting a file overwrites it first, but on flash storage that only helps a little; what makes old data
  unreadable is that its key is gone. Pulshade keeps plain-text files off the disk wherever it can (voice notes and chat
  clips are made and played from memory; received files are never saved unless you ask; the story camera writes into
  memory, not a file). Things that still sit on the disk in the clear: a few display settings, the Tor/bridge
  choice's inputs (the bridge list itself is sealed), and Tor's own state and caches. Video you pick from your photo
  library may be copied by the system to a temporary file before Pulshade reads it into memory; Pulshade deletes
  leftovers at launch, but we do not control that system copy. We are not aware of any other temporary files written
  by Apple's video code (AVFoundation) in Pulshade's paths, and this is one of the questions we ask auditors to check.
- **Keychain items after first unlock** (section 10) when locked-phone collection is on.
- **One operator.** The official app talks only to Pulshade's own servers. A modified app could point at others; the
  rate limits and the terms of use, not the code, hold that back.
- **Disappearing messages** and **deleted stories** depend on the other person's app.
- **Groups** cap at 300 members and trust their admins for the roster.
