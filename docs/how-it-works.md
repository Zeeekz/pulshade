# How Pulshade works

The design in full, for anyone checking Pulshade's claims. The short version is in the [README](../README.md).

## Your account

**Identity.** 32 random bytes made on your device; every key is derived from them. Your passcode seals them in
`identity.lock` (AES-GCM). The passcode is first stretched with Argon2id (64 MiB of memory, 3 passes, one run per
try), then each slot's key also mixes in the answer this device's Secure Enclave gives for that passcode: the chip
multiplies a point on the curve made from the stretched passcode by a key that never leaves it. An answer for one
passcode says nothing about another, so every single guess needs this device's chip: a copied lock file can't be
guessed at on another computer, and neither can answers someone once got out of the chip. What's left is guessing on
the device itself (or with code running on it), at the chip's speed and the Argon2id cost per guess: a 6-digit PIN
would likely fall to that within hours to days (an estimate, not measured), a long passcode doesn't. Where there is no Secure Enclave (the Simulator)
only Argon2id stands in the way. The whole file is sealed again with a key kept in the Keychain and
replaced every time Pulshade locks, so an old copy left in the SSD's spare blocks no longer opens, even on this
device, once its key has been replaced (`identity.bio`, for Face ID or Touch ID, works the same way). Lock files from before
build 22 used PBKDF2 and a Secure Enclave secret that didn't depend on the passcode; the real passcode's slot is
upgraded at its next unlock, and a decoy or panic passcode set before stays in the old form until it is set again.
The lock file also holds the lock screen's own settings (which keypad, and the wipe after wrong guesses), so no
other app or preference editor can read or change them.

**Storage.** Chats live in `data-*.vault`, sealed with a key derived from the identity and padded to 64 KB, 128 KB
and so on. The folder is kept out of backups, and the files can't be read while the phone is locked. If
the passcode is right but the data won't open, Pulshade stays locked and changes nothing, rather than opening an
empty account that would save over it. The recovery code is the only way back in.

**Lock, Detach and Burn.** The only three ways to leave, on the Burn tab. Detach on an account's only device
first tells the people you chat with to clear their one-to-one chat with you (they keep you as a contact), waiting
four seconds at most; offline, or if that can't be sent in time, it wipes anyway and they are told when the account
is next recovered.
- *Lock* closes the vault. Everything stays on the device, encrypted; the passcode (or Face ID or Touch ID) opens it again.
  Auto-lock (Immediately, 1, 5 or 15 minutes, or never) also locks when the iPhone locks, unless it's set to
  never; Immediately locks the moment you leave Pulshade. An automatic lock hides everything behind the passcode but
  keeps receiving, so friends still get delivery ticks; the keys stay in memory until you press Lock. Turn on *Close
  everything when it locks* and an automatic lock closes the vault like Lock does: keys and chats leave memory, and
  nothing comes in until you unlock. Either way it behaves the same with or without a decoy or panic passcode: typing
  one at a hidden account closes it and opens that one. New accounts wipe this device after 10 wrong guesses in a row
  (5, 10, 20 or off in Settings). A 4-digit PIN from an older build has to be changed before anything else, and a
  decoy or panic passcode set up then is chosen again in the same step, so it can still be typed on the new keypad.
  The keypad's length is only a hint: its Enter key takes a PIN of any length.
- *Detach* wipes this device at once, with no questions and no waiting on the network: everything on it is
  overwritten and the app starts fresh. Your profile, @handles, contacts, groups, personas and settings come back
  with the recovery code from the sealed backup (below), but every chat, story and request on this device is gone
  for good. From the lock screen the flame can also do a Detach that first seals the account with the recovery code
  and tells your contacts; the device is then wiped.
- *Burn* deletes the account as if it never existed: every chat for both sides, every contact forgets you, every
  @handle is retired (unclaimable for three months, and tied to no one), the server's backup and waiting messages are gone, and this device keeps
  nothing (not even a revoked Keychain key). The recovery code can't bring it back.

The flame on the lock screen does Detach (this device) or Burn without the passcode, using the recovery code instead.

**Files.** A file (up to 100 MB) is not sent inside a message. The app seals it on the device in pieces of 1 MiB with
ChaCha20-Poly1305 and a fresh random 256-bit key, binding each piece to its place so pieces can't be swapped, reordered
or cut short, and uploads the sealed pieces once to the relay under a random id. Each piece is sealed only with the
bytes it had when the file was first read, so a file changed before an upload is retried never reuses a nonce. The key, the id, the file's name and
type and an erase secret travel only inside the ordinary end-to-end encrypted message. The relay seals each file a
second time with its own random key for that file, keeps the pieces on its disk and the key in a sealed index, and
can't open either layer. The receiving app fetches the pieces into memory, opens and checks them there, and shows the
file; it never writes it to disk unless the person taps "Save a copy". Deleting the message sends the erase secret
(whose hash is all the relay holds) and the relay overwrites the pieces, removes them and destroys the file's key; an
erase that can't be sent is remembered and tried again. Anything left is erased after 30 days (7 in groups). The relay can see that a
file of about that size was uploaded and collected, and when.

**Calls.** The caller sends a random room and call key inside an ordinary end-to-end encrypted message. The audio goes
through that room on the relay, which passes packets between the two devices in it and can't open them: each packet is
sealed with ChaCha20-Poly1305, padded to one size, numbered so a replay is refused, under a key made from the call key
and a random salt each connection picks for itself. So two of your devices answering the same call at once never seal
under the same key and nonce.

**The sealed backup.** So that Detach can be instant, the app keeps one backup of your profile, @handles, contacts,
groups, personas and settings (never chats, stories or requests, nor a message still waiting to be sent, nor
a decoy or panic identity) on the relay. It holds no chat keys: after a restore the app opens new ones with each
contact, so mail sent to you while you were detached can't be opened. It is sealed on the device with a key
only the recovery code makes, filed under a throwaway public key derived from the recovery code and from nothing
else, so the relay can't read it or tie it to your account. It is padded to a power of two (at least 64 KB), so its
size says little. A few minutes after something in it changes (a random 1.5 to 10 minutes, so an upload can't be
lined up with an edit) the app saves it again, over Tor if Tor is on; it is also saved once a week, which restarts
the relay's 180-day clock. Only the main identity does this, never a decoy or panic account. Settings has a switch:
off erases the copy at once. Burn erases it too. Restoring with the recovery code brings it back, and it stays on the
relay, saved over as things change. Each backup carries a count and the date it was made inside its seal. Restoring
shows "Backup from <date>" and asks first; a device that still has the account's data refuses a copy older than the
newest it made or restored. A freshly installed or detached device can't tell, so the date is what shows an old copy.

**Decoy and panic passcodes.** `identity.lock` always holds three equal-sized slots and there are always four data
files, real or random, padded to the same sizes and rewritten together whenever Pulshade locks, so the disk doesn't
show what's set up. The decoy passcode opens a separate, empty identity wearing your name, theme and settings, and
its Settings look exactly like the real ones (setting a decoy or panic passcode there only pretends). Touch ID and
Face ID turn off while a decoy or panic passcode is set, since they'd open an account without asking which. The
panic passcode shreds the real identity, the decoy and the Face ID or Touch ID copy under a fresh Secure Enclave key, then opens an
empty account that becomes an ordinary one. Their keys go at once; the files themselves (and the media pool) are
moved into the vault's `work` folder, which is always there, under random names and overwritten in the background,
and anything left there is finished at the next launch. Every unlock answers at the same moment after the passcode
is checked (0.4 s), whether it opened the real account, a decoy or the panic one, and the panic seals its new
account with the stretch the check already did, so it takes no longer.

**On your device.** Face ID and Touch ID use a key that lives inside the Secure Enclave and only works after a face or
fingerprint match; it unlocks a second sealed copy of your identity. Voice notes are recorded and played from memory, never a
file. iOS has no way to block screenshots, so Pulshade draws itself in the layer iOS keeps out of them (the one
behind password fields): they come out blank, and it covers itself while the screen is recorded, mirrored or shared.
You can turn this off. The message box
has autocorrect off, so the keyboard doesn't learn what you type. Copies stay on the device they were made on (no
Universal Clipboard), and the recovery code is never offered for copying. Saving a picture from a chat adds it to Photos, which the app can only add to, never read. Notifications say only "New message"
unless you choose otherwise, because the system stores notification text in its own database, outside Pulshade's
encryption, and may keep it after Pulshade clears them, which it does whenever it locks.

**What's on the disk outside the vault.** A few things have to be readable before the passcode, and nothing in them
is about your account: the theme and the screen-protection switches (so the lock screen looks
right), in the system's preferences file; the Tor switch and the bridge choice, in `bridges.sealed`, sealed with a
Keychain key of its own because private bridge lines are worth hiding; and Tor's own state and cache of relay lists,
in `Application Support/Pulshade/tor` and `Caches/Pulshade/tor`, so later launches connect faster and keep the same
guard. Detach keeps the network ones, since the device still has to reach the server. Burn removes all of them, the
Keychain items included. When Pulshade deletes a file it overwrites it first, but on an SSD that only helps a
little: the drive writes the new bytes somewhere else and erases the old blocks when it chooses. What makes a deleted
file unreadable is that its key is gone.

## Messages

**Mailboxes.** A mailbox is a secret *receive key* and its SHA-256 hash, the *send id*. You give out the send id;
only the receive key can read. Each contact invite opens a new mailbox and works once, so the relay can't tell which
mailboxes belong to one person. Every code a persona gives out carries the same public identity key, though, so two
codes posted in different places can be matched to one persona: use a separate persona for each place you want kept
apart. Each persona's mailboxes, each public profile's request mailbox and the reports mailbox are
fetched separately, on separate connections, each on its own clock. A fetch asks the server to wait up to 25
seconds for mail, and the server answers the moment something lands, so messages arrive in about a second even
over Tor. Sending uses connections of its own too. Delivery receipts wait a random few seconds and go out together,
so a receipt doesn't pair a fetch with a send.

**Sessions.** Every pair of people talks through a Double Ratchet (the design Signal uses). It starts with a hybrid
handshake: three X25519 exchanges, two of them with throwaway keys, plus ML-KEM-768, a post-quantum key exchange.
Every message then gets its own key, used once and deleted, and every reply mixes in a fresh X25519 exchange.
- *Forward secrecy:* stealing a device's keys today doesn't open messages it already received.
- *Healing:* after a theft, the next round of replies locks the thief out again.
- *Quantum resistance:* traffic recorded now can't be opened later by breaking X25519, because the session root also
  depends on ML-KEM.
- *Sparse post-quantum ratchet:* both sides keep offering fresh ML-KEM-768 keys and answering the other's, but in small
  erasure-coded pieces, one in every message, always the same size (random filler when there is nothing to send), so no
  message is bigger and sizes show nothing. Once an answer is complete and both sides know it, the secret goes into the
  root key at the next new chain. In a back-and-forth chat of short messages that is a new post-quantum secret about
  every 6 to 10 messages, so someone who breaks X25519 later is locked out again soon, not only before the handshake
  (like Signal's triple ratchet). If one side has sent 200 messages with no new secret going in (or 20, the newest a
  week or more after the last one went in), the app asks that device for new keys, whose handshake is post-quantum
  again. An app from before it is told to update first and nothing is exchanged until it does.
- *Keys kept for messages that haven't come:* a skipped message's key is kept for at most 30 days, and only for the
  other side's five newest chains, so a message held back can't be opened with a device seized long after.
- *Handshake secrets:* the secret half of an ask for keys is kept at most 8 days (a friend request's, 32), and goes as
  soon as the session it was for opens; a spare key's, while it is up and 10 days after it is replaced. An answer that
  comes later can't be opened, and the chat asks for new keys.

**Envelopes.** Each ratchet message is then sealed twice. The outer seal uses a fresh X25519 key and
ChaCha20-Poly1305, padded to fixed sizes, and hides your agreement key. The inner seal mixes in an X25519 exchange
between your identity key and the recipient's. Both seals also mix in an ML-KEM-768 secret for the recipient's
post-quantum key (also made from the seed), so breaking X25519 later doesn't reveal who wrote to whom. Key setup and
other control messages are signed with ML-DSA as well as Ed25519, and both must check out; once a contact's
post-quantum keys are known, nothing classical is accepted from them, so it can't be downgraded. The first envelope
each way, which has to introduce the keys, is the one exception; an app from before is told to update. Only you could have made it, so the recipient knows it's from you,
but the recipient could have made it too, so it proves nothing to anyone else: nothing you say is signed. Your
signing key vouches once for your agreement key, never for a message. The ML-DSA signature on key setup covers the keys
and, on a friend request, your card, but not the request's note. Each persona writes with its own device id,
and anything sent outside a ratchet session (introductions, erasing) is stamped and counted once, so it can't be
replayed. The server sees random blobs and send ids, and none of what's inside.

Big things (photos, pieces of a video) travel inside the seals as raw bytes after a short description, a "frame",
rather than as text within text, which used to make a 1 MB piece of video take 3 MiB. Every envelope says, inside
its seal, that its sender's app reads frames; an app only sends them to a device that has said so, and anything for
an older app goes the earlier way. A video story is cut into pieces that each fill one 2 MiB message.

**Everything travels the same way.** Reactions, typing dots, unsends, story views, disappearing timers and their
changes all go through the ratchet like any other message. Disappearing messages are removed from each device when their timer
runs out.

## People

**Personas and burners.** Each persona is a separate identity with its own keys, mailboxes, contacts, chats and
device id, so a friend who knows two of your personas sees two unrelated people. With Tor on, each persona reaches
the server over its own circuit, from its own exit. A burner is a persona with a timer: when it ends (or you tap
Burn now), its keys, contacts and chats are destroyed and the other side is told to forget it. Any persona can be burned
the same way from its profile in Settings: its @handles are retired as in Burn, its chats are deleted for both sides,
its contacts forget it, and it's removed from every device on the account. The main identity and other personas are
untouched.

**Announcements.** The operator writes them in Pulshade Admin and every account gets them in a read-only chat from
@announcements. Each is signed by the admin key over its id, date and text, and every app checks that signature before
showing it, so the relay can't write one or change a word. The relay keeps the latest 50 and hands the same list to
anyone who asks, about once a minute, with no account attached, so fetching them says nothing about who you
are. The @announcements handle is reserved, so no account can pass itself off as it. One taken back disappears from the
apps the next time they check.

**One-time chats.** New chat → one-time chat makes a throwaway identity for both sides that ends after the time you
pick, and works for the first person in. Share it as a QR code, a link, or a 20-digit code to read out or type, so
nothing has to go through another app. The code's link waits on the server sealed in a mailbox only the digits lead
to (stretched like a passcode; with 10^20 possible codes, trying them all offline is out of reach), padded to a fixed size, and is deleted when
someone takes it or the chat ends.

**Public profiles and requests.** Profiles are private unless you claim a @handle (per persona). The server keeps a
small directory of signed entries: the first key to claim a handle owns it, entries can't be forged or replayed, and
a handle that's let go of stays held for that key for three months, so it can't pass straight to someone else. An
account has three handles at most, listed and held together, so nobody can use up names by claiming and letting go.
Up to three can be in use at once for one identity (the main one, shown on the profile, and two more); each leads to
the same profile and has its own request mailbox, and each has a switch: off, it leaves the directory and is held.
A handle belongs to the identity whose key claimed it, so it can't be moved from one persona to another.
A burned account's handles stay unclaimable for the three months too, but the server no longer knows whose they were.
Letting go of a held handle early frees its spot at once, but the name then cools off for 30 days, tied to nobody,
before anyone may claim it. If a handle you look up belongs to a different account than a contact who went by it, the
app says so.
A profile link copied from Settings carries a check of the owner's key (`pulshade://u/<handle>?k=…`), so it can't
open anyone else's profile, even after the name is free again. Lookups are by exact handle only (no listing or
search) and rate-limited. A request lands in Requests with an
optional note; nothing is set up until you accept, and accepting moves the two of you to a private mailbox. Blocked
people's requests are dropped silently. A request from someone who's already your friend means they've lost the
chat on their side, so it reconnects them straight away.

**Pulse check.** As with Signal's safety numbers, each person has a fingerprint of their own: SHA-512 iterated 5,200
times over their account, signing key, agreement key and post-quantum keys. Both screens show the two side by side as
60 digits (30 from each), with ten emoji, two colours and a QR code that carries both whole fingerprints. Swapping
someone's keys changes only their half, so someone in the middle would have to find keys whose fingerprint matches the
real person's, not just make two codes agree. An invite carries the signing key's signature over the agreement key, and
an invite without a valid one is refused (an app from before this is told to update). Scanning the other screen with the
camera, or confirming all 60 digits match, marks the contact verified. The emoji are a quick look only and never verify.
A code from an app before this (30 digits, or an older QR) never matches, and the screen says that person needs to
update.

**Removing a contact.** Removing someone takes them off every one of your devices, with their keys, mailboxes and
stories, and tells their app to forget you and your chat, the same message a burner sends when it burns, so the
chat goes on both sides. They can only reach you again with a new invite or a request. Someone you still share a
group or channel with stays only as a member there, like people you've never added. If your chat keys with them aren't
ready yet (an account just recovered, a friend who hasn't answered), the person goes from your screens at once, but a
hidden record is kept until that message has been sent, and dropped after two weeks if it never could be.

**Videos in chats.** A video of up to 30 seconds, recorded by holding the chat camera's button or picked from the
library, is shrunk on the device (its own shape, about 5 MB at most, no location or device metadata) and sent as a
message carrying a still from it, followed by the clip in pieces under the message's id, the way a video story's
goes. An app from before this shows the still as a photo. Replying to a photo carries a small copy of it, so the
quote shows what was answered. Something pinned to your profile (a link, a wallet, a public note) can be sent into
a chat with one tap; it goes as an ordinary message.

**Profiles and stories.** A profile has a picture and a 3:1 banner, sent to contacts like your name; a public
@handle shows them too. A story is a photo (framed to 9:16, with an optional caption) or text. Photos are redrawn
before use, which drops their location and other metadata. Each story goes to all your contacts, only the ones you
pick, or all but the ones you pick, and lasts 6, 12, 24 or 48 hours; the next story offers the same choices again.
A story can be edited after posting (its words, who sees it, how long it lasts, but not its photo): people taken
out of the audience lose it, and the rest get the new version. The first time someone views a story, their app
sends its author a view through the ratchet like any message, so the server can't see who watches what. Views
can't be switched off, except that one-time chats never send them. The author's app answers each view, and a view
that gets no answer is sent again a few times over the next hours, so one lost on the way still arrives. A story whose time has run out, or that you delete, stops being sent: copies still waiting to go are dropped.

**Groups that share one mailbox.** New groups, once everyone in them runs an app that can, post each message once into
one mailbox on the server that every member reads, instead of a copy to each person: up to 1,000 people. Each member
is known in the group by a key made for that group alone, so the group can't be tied to your profile or to your other
groups, and members never get each other's mailboxes. The group's name, roles and member list are one signed document
that only someone allowed can change, and nobody can change someone else's card. Taking someone out gives everyone
else a new key that person never gets; someone added doesn't get what was said before. The server keeps group mail
sealed for up to 7 days and can't tell who reads it over Tor. Each member's device keeps its own key chain in
each group, started from fresh random bytes and moved on with every post, and hands its starting point to the other
members' devices over private, post-quantum sessions; group keys are handed out sealed with post-quantum keys as well
as classical ones. So someone who takes a member's phone can't open the group posts it had already read. When a phone linked on an older
build is unlinked, every group you're in moves to new keys it can't work out, so it reads nothing said there from then
on, and your contacts drop it for good and hold any new device of your account until they allow it. In groups, should
an unlinked phone try to keep your place by moving it to keys of its own, the members see two moves of one place and
take neither: they hold both back, an admin takes the place out, and you are added again over a chat (a group whose owner's place is fought over is closed). When two admins change a group
at the same moment, the one higher in the owner's list wins, everywhere alike. The trade-off: group messages show "sent"
rather than ticking per member.

**Groups, channels and broadcasts.** Groups and channels share one mailbox (a channel's followers can't see who else
follows: only its staff keep that list, in a mailbox of their own). A group saved from the older format, where every
message went out as one envelope per member, stays on the device as read-only history. Members who aren't your
contacts are kept as hidden peers, used only inside that group. Each has an owner, optional admins and a posting
rule (everyone, admins, or owner only). Changes carry a version number and only count when they come from an admin.
Admins add people from their contacts and remove members; only the owner appoints admins, changes the posting rule
or deletes it for everyone; anyone else who deletes it leaves. In a group the owner can also make someone a mod: a
Mod tag, posting when only admins can, and taking ordinary members out (never admins, the owner or other mods),
nothing else. Everyone else only accepts a mod's update if it removes members and changes nothing besides. Channel followers only learn who can post, not who
else follows. A channel is followed only through its staff: an invite carries a staff member's signature naming the
account that sent it, so nobody can pass on an invite they got and become the one you follow it through, and a channel
code names its channel, so following one takes only that channel without asking. A broadcast is the same message sent
privately to each person.

**One device per account.** An account lives on one iPhone. There is no way to link a second device: moving to a new
phone is done with the recovery code, which brings back the profile, contacts, groups and personas but not the chats.
Builds before 22 could link more devices. When such a device updates, the keeper is the one with the lowest device id
among those used in the last month: it tells the others to wipe themselves, tells every contact those devices are
unlinked, and moves every group to new keys they can't work out. A device wipes only when that word from the keeper
arrives, leaving the files on the server for the keeper, so a device list gone stale can never wipe the last phone in use.
A contact on an older build can still have more than one device, and messages to them still go to each of them.

**Link previews.** Off by default. When on, the sender's device builds them while you type and sends them inside the
encrypted message, like Signal: the person receiving it never contacts the website. The sender's device fetches the
page and one picture over Tor, on a lane of its own that gets new circuits after every preview, so the website sees
a Tor exit, not you, and can't tie your previews together. Links into your own network are never fetched. With Tor
off, the device visits the website directly.

**Message times.** Messages are dated by the server's clock, not the sender's: each device learns how far its own
clock is from the server's (from the time on the server's replies) and stamps what it sends accordingly, and the
server says how long each message waited, so nothing can be dated later than it arrived. A device with a badly set
clock still shows and sends the right times.

## The servers and the network

**Pulshade's servers.** The official app talks to Pulshade's own servers and nothing else. An invite, profile,
or friend request that names any other server is refused, and the app never connects to one, whatever a contact once
said. Every code you scan or open asks before it does anything. The code is open, so anyone can check what the app and
the server do; a build someone makes themselves uses its own server, and isn't Pulshade.

**The server (relay).** A small Rust program. No accounts and no request logs (it prints only start-up and error lines, and a count when it is short of room, none naming an address or a mailbox). A waiting envelope is written to the server's disk before the sender is told it was taken, sealed, in a segment file with a key of its own (the keys are kept in an index sealed by the server's storage key), and the server keeps no copy beside it in memory (a message collected a moment after it lands is read back from the disk). It is deleted on pickup or after 30 days; their ids are random, so they don't reveal how busy it is. How much can wait is limited by the mail's share of the disk (2 GiB unless set otherwise) and, per mailbox, by a byte cap; a full share turns new mail away (the sender keeps it and tries again) and never drops mail that is already waiting. Wake-up registrations (which device token to wake for which mailbox, only for phones with notifications on) are kept the same way, in a sealed file that is rewritten within seconds of a change and drops a phone as soon as it turns notifications off. Waiting envelopes survive a restart, a crash and a reboot. When a phone has collected an envelope it is marked gone; a segment with nothing left waiting in it has its key forgotten and its file overwritten with random bytes and deleted at once (within a fraction of a second), and one kept alive by a single slow reader is rewritten without the collected mail once most of it is gone, and after a burn or a recall straight away. On a disk that writes new blocks elsewhere overwriting only helps; what makes old bytes unreadable is that they are sealed, the segment's key is forgotten, and the storage key is held only in memory. The handle directory, held handles, moderation
lists and accounts' sealed backups (no chats) are saved to disk too, the first three sealed with the same storage
key, as are the push key and the onion service's key (Arti's own keystore is kept in memory, and
the relay hands it the unsealed key at start), and so are the backups' side files. On the Linux server that key is kept off the disk once the operator moves it there (a new server's install writes
it to `/etc/pulshade` until then): it sits in a memory-only folder (ramfs, which is never swapped out) and on the
operator's Mac, and after a reboot the relay stays locked until the operator sends it back (`pulshade-admin server
unlock`). Moving it shreds the copy on the disk, but a flash disk can keep old blocks, so the relay can be re-keyed
(with the relay's re-key command): every file sealed with the storage key is sealed again with a new key that was never on the
disk. The keys inside the indexes stay as they were, so mail and files from before a re-key stay as open to the old key
as before until they expire (30 days at most). Inside the relay the storage key sits in a memory page of its own that is
locked (never swapped) and zeroed when let go, keys and index text are wiped after use, and on Linux the relay won't
start while the server swaps to a disk. So a copy of the disk, a snapshot or its backups hold nothing that opens with a
key that was never on that disk; someone who controls the running server could still read the key from memory. A
backup that hasn't been saved again for 180 days (a detached account's, once its device is gone) is erased. The server turns off core dumps, so a crash never writes its memory to disk. Rate
limits never keep an IP address, only a hash with a salt that's replaced every hour. Admin actions need the operator's token, which only root
on the server can read (the relay keeps just a hash of it); the Pulshade app has no admin in it at all. Abuse reports are sealed to
Pulshade Admin's reports key and go only to a mailbox signed by the admin key built into the app, from a throwaway key,
without your handle unless you add it, so the server can't read them. Nothing in the admin tools can read anyone's
messages.

**Onion service.** The server is reached as a Tor onion service, hosted by Arti inside the server itself, so nobody
learns where it runs and no exit relay sees the traffic. Onion connections carry no IP address, so the server makes
one up per circuit, and rate limits count each circuit as its own sender. So that building new circuits doesn't buy
new allowances, a rate-limited request (looking up or claiming a handle, backups, joining a call) carries a proof of
work: a fraction of a second's hashing, tied to that request and used once. Requests without one, from older apps,
all share a single allowance. Plain http is used for the onion address,
which Tor already encrypts end to end.

**Tor in the app.** Tor (Arti, Tor's Rust implementation) runs inside the app on the iPhone, built from
source in `tor/`; there's nothing else to install. It listens on 127.0.0.1 behind a password picked at each launch,
and every lane (each persona, each public inbox, sending, linking, reports, each call) signs in with its own name,
so each gets its own circuits and none can be linked to another by address. If a lane's circuit is slow to connect,
a fresh one races it; if a request fails, the lane gets new circuits. Fetches, deposits, the directory, backups and
call audio all go through it, and nothing falls back to a direct connection: if Tor can't start or can't reach the
server, requests fail. (The locked-phone helper can't run Tor, so collecting while locked is only offered in Fast mode
and is forced off whenever Tor is on.) A fresh install, a Detach or a Burn first asks how to connect, Fast or Tor, and nothing
connects until that is answered.

**Bridges.** For networks that block Tor or watch for it, Settings → Network → Bridges sends Tor's first hop to a
bridge instead of a public relay, disguised by a pluggable transport: Snowflake (through volunteers, looks like a
video call) or webtunnel (looks like ordinary HTTPS). The transports come from Tor Project's lyrebird, built into
the app from `tor/pt` and run inside it, since iOS doesn't let an app start programs of its own; each listens on
127.0.0.1 and Arti connects through it. Snowflake comes with the bridges Tor Browser ships; you can also paste your
own webtunnel or Snowflake bridge lines, and private bridges are the hardest to block. obfs4 isn't offered:
lyrebird's includes GPL-3 code, and Pulshade is MIT.
The choice is kept outside the vault, since Tor connects before Pulshade is unlocked, sealed with a Keychain key.

**Connecting.** After the passcode, Pulshade shows "Connecting" (with Tor's progress) and opens only once the server
has answered, so it never lets you into an account it can't reach. While the server can't be reached, a "Server
offline" screen covers the app, with a Retry button; it lifts by itself once a check gets through.

**Turning Tor off.** Settings → Network. It's for speed, and it asks first, spelling out the cost: the server sees
your IP address and roughly where you are, your personas can be tied together by it, and your internet provider can
see you use Pulshade. It also says how long Pulshade has connected only over Tor, since that can't be undone once the
server has seen your address. With Tor off, the app uses the server's ordinary https address instead of its onion
one; until the server has one, the switch stays on.

**Anonymity report.** Settings → Network → Anonymity Report shows the address the server sees for you (asked on a connection
of its own; over Tor, a made-up address per circuit), each lane's current Tor circuit with the relays' IP addresses
(the first, the guard, is the only one that sees yours), and a checklist of the settings that matter: Tor, the kind
of server, separate circuits, random timing, link previews, notification text and screen protection. Circuits are
kept in memory only.
