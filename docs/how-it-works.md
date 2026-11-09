# How Pulshade works

The design in full, for anyone checking Pulshade's claims. The short version is in the [README](../README.md).

## Your account

**Identity.** 32 random bytes made on your device; every key is derived from them. Your passcode seals them in
`identity.lock` (PBKDF2-SHA256, 600,000 rounds, AES-GCM), with the key also mixed with a secret only this device's
Secure Enclave can produce, so a copied lock file can't be guessed at on another computer. The whole file is
sealed again with a key kept in the Keychain and replaced every time Pulshade locks, so an old copy left in the
SSD's spare blocks no longer opens, even on this device, once its key has been replaced (`identity.bio`, for Touch
ID, works the same way).

**Storage.** Chats live in `data-*.vault`, sealed with a key derived from the identity and padded to 64 KB, 128 KB
and so on. The folder is kept out of backups, and on iPhone the files can't be read while the phone is locked. If
the passcode is right but the data won't open, Pulshade stays locked and changes nothing, rather than opening an
empty account that would save over it. The recovery code is the only way back in.

**Lock, Detach and Burn.** The only three ways to leave, on the Burn tab. Detach on an account's only device
first tells the people you chat with to clear their one-to-one chat with you (they keep you as a contact), waiting
four seconds at most; offline, or if that can't be sent in time, it wipes anyway and they are told when the account
is next recovered.
- *Lock* closes the vault. Everything stays on the device, encrypted; the passcode (or Touch ID) opens it again.
- *Detach* wipes this device at once, with no questions and no waiting on the network: everything on it is
  overwritten and the app starts fresh. Nothing is sent, so your other linked devices keep the account (and every
  chat; a QR code from one of them logs you back in). Your profile, @handles, contacts, groups, personas and
  settings come back with the recovery code from the sealed backup (below), but every chat, story and request on
  this device is gone for good. From the lock screen the flame can also do a Detach that first seals the account
  with the recovery code and tells your other devices and contacts; every device is then wiped.
- *Burn* deletes the account as if it never existed: every chat for both sides, every contact forgets you, every
  @handle is retired (unclaimable for three months, and tied to no one), the server's backup and waiting messages are gone, every device is wiped, and this one keeps
  nothing (not even a revoked Keychain key). The recovery code can't bring it back.

The flame on the lock screen does Detach (this device) or Burn without the passcode, using the recovery code instead.

**Files.** A file (up to 100 MB) is not sent inside a message. The app seals it on the device in pieces of 1 MiB with
ChaCha20-Poly1305 and a fresh random 256-bit key, binding each piece to its place so pieces can't be swapped, reordered
or cut short, and uploads the sealed pieces once to the relay under a random id. The key, the id, the file's name and
type and an erase secret travel only inside the ordinary end-to-end encrypted message. The relay seals each file a
second time with its own random key for that file, keeps the pieces on its disk and the key in a sealed index, and
can't open either layer. The receiving app fetches the pieces into memory, opens and checks them there, and shows the
file; it never writes it to disk unless the person taps "Save a copy". Deleting the message sends the erase secret
(whose hash is all the relay holds) and the relay overwrites the pieces, removes them and destroys the file's key; an
erase that can't be sent is remembered and tried again. Anything left is erased after 7 days. The relay can see that a
file of about that size was uploaded and collected, and when.

**The sealed backup.** So that Detach can be instant, the app keeps one backup of your profile, @handles, contacts,
groups, personas and settings (never chats, stories or requests, nor a message still waiting to be sent, nor
a decoy or panic identity) on the relay. It is sealed on the device with a key
only the recovery code makes, filed under a throwaway public key derived from the recovery code and from nothing
else, so the relay can't read it or tie it to your account. It is padded to a power of two (at least 64 KB), so its
size says little. A few minutes after something in it changes (a random 1.5 to 10 minutes, so an upload can't be
lined up with an edit) the app saves it again, over Tor if Tor is on; it is also saved once a week, which restarts
the relay's 180-day clock. Only the main identity does this, never a decoy or panic account. Settings has a switch:
off erases the copy at once. Burn erases it too. Restoring with the recovery code brings it back, and it stays on the
relay, saved over as things change.

**Decoy and panic passcodes.** `identity.lock` always holds three equal-sized slots and there are always four data
files, real or random, padded to the same sizes and rewritten together whenever Pulshade locks, so the disk doesn't
show what's set up. The decoy passcode opens a separate, empty identity wearing your name, theme and settings, and
its Settings look exactly like the real ones (setting a decoy or panic passcode there only pretends). Touch ID and
Face ID turn off while a decoy or panic passcode is set, since they'd open an account without asking which. The
panic passcode shreds the real identity, the decoy and Touch ID under a fresh Secure Enclave key, then opens an
empty account that becomes an ordinary one.

**On your device.** Touch ID uses a key that lives inside the Secure Enclave and only works after a fingerprint
match; it unlocks a second sealed copy of your identity. Voice notes are recorded and played from memory, never a
file. Screenshots and screen recordings of the Mac window come out blank unless you turn that off. On iPhone, which
has no way to block screenshots, Pulshade draws itself in the layer iOS keeps out of them (the one behind password
fields), so they come out blank too, and it covers itself while the screen is recorded, mirrored or shared. The message box
has autocorrect off, so the keyboard doesn't learn what you type. Copies stay on the device they were made on (no
Universal Clipboard), and the recovery code is never offered for copying. Saving a picture from a chat adds it to Photos, which the app can only add to, never read. Notifications say only "New message"
unless you choose otherwise, because the system stores notification text in its own database, outside Pulshade's
encryption, and may keep it after Pulshade clears them, which it does whenever it locks.

**What's on the disk outside the vault.** A few things have to be readable before the passcode, and nothing in them
is about your account: the theme, the menu bar icon and the screen-protection switches (so the lock screen looks
right) and the Tor switch, in the system's preferences file; the bridge choice, in `bridges.sealed`, sealed with a
Keychain key of its own because private bridge lines are worth hiding; and Tor's own state and cache of relay lists,
in `Application Support/Pulshade/tor` and `Caches/Pulshade/tor`, so later launches connect faster and keep the same
guard. Detach keeps the network ones, since the device still has to reach the server. Burn removes all of them, the
Keychain items included. When Pulshade deletes a file it overwrites it first, but on an SSD that only helps a
little: the drive writes the new bytes somewhere else and erases the old blocks when it chooses. What makes a deleted
file unreadable is that its key is gone.

## Messages

**Mailboxes.** A mailbox is a secret *receive key* and its SHA-256 hash, the *send id*. You give out the send id;
only the receive key can read. Each contact invite opens a new mailbox and works once, so two contacts can't compare
invites to link you. Each persona's mailboxes, each public profile's request mailbox and the reports mailbox are
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
- *Post-quantum refresh:* after 50 messages or a day, a side offers a fresh ML-KEM-768 key, and the other side's
  next reply answers it; that secret goes into the root alongside the reply's X25519. So someone who breaks X25519
  later is locked out again at the next refresh, not only before the handshake (like Apple's PQ3).

**Envelopes.** Each ratchet message is then sealed twice. The outer seal uses a fresh X25519 key and
ChaCha20-Poly1305, padded to fixed sizes, and hides your agreement key. The inner seal mixes in an X25519 exchange
between your identity key and the recipient's. Only you could have made it, so the recipient knows it's from you,
but the recipient could have made it too, so it proves nothing to anyone else: nothing you say is signed. Your
signing key vouches once for your agreement key, never for a message. Each persona writes with its own device id,
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
untouched, and its collectibles stay claimable with its backup code.

**Announcements.** The operator writes them in Pulshade Admin and every account gets them in a read-only chat from
@announcements. Each is signed by the admin key over its id, date and text, and every app checks that signature before
showing it, so the relay can't write one or change a word. The relay keeps the latest 50 and hands the same list to
anyone who asks, about once a minute, with no account attached, so fetching them says nothing about who you
are. The @announcements handle is reserved, so no account can pass itself off as it. One taken back disappears from the
apps the next time they check.

**Collectibles.** Numbered items (a Party Hat under falling confetti, a candle-lit Halloween Pumpkin, a Top Hat that keeps changing colour, a can of Pulse Pop that pops itself open, a Bonfire Night bonfire under fireworks a Christmas Tree with twinkling lights and snow, and Pulze The Dragon, a dark blue pet crackling with electricity, so far, all drawn in code in the same animated style; Pulze is a real 3D model built in code that you can open, turn all the way round, zoom and tap to make it zap, and pets are kept in their own group in the Collectibles tab) that the operator gives to an account
from Pulshade Admin, a separate Mac app. Each is signed by the admin key, which never leaves that Mac, over the item,
its number and the owner's key. Pulshade carries the admin key's public half, so no app can make its own and nobody can
show one given to someone else: every app checks the signature before showing it. The relay keeps them for their owner
to fetch with a fresh signature, sealed like the directory. One taken back stops showing the next time its owner's app
checks. You choose one to show after your name, to your contacts and on your public profile.

One **backup code** covers all of an account's collectibles. The app makes it with the first collectible and adds each
later one to it (an alert says so, and Collectibles shows the code any time). It stays on your own devices; the relay
keeps only its hash, beside each collectible it covers. When an account burns, the relay forgets whose its
collectibles were and keeps only the coded ones' hashes and numbers. Entering the code in another account (signed by
that account's key, limited to a few tries an hour) claims them all for it, and Pulshade Admin signs each over by
itself, same item and number; they then join that account's own code. A code works once, and making a new one stops
the old one working. Burned collectibles keep their numbers, so a number is never given out twice.

**Giveaways.** Pulshade Admin can open a giveaway: a collectible, a code, a window of time and a number to give. The
relay keeps only a hash of the code (typed any way: case, spaces and dashes don't matter), the window and the claims in
the order they came. Entering the code in the Collectibles tab sends a proof signed by the account's key, so it can only
be claimed for that account; each account gets one place, and a banned one can't enter. The admin app signs a collectible
for each claim in order, one number at a time, as for any other, and the app checks it like the rest. A burned account's
place stays used but names nobody. A **Guardian** can't be moved with a backup code (the relay refuses to code it, and a
code claim skips it): it's earned by the account that wears it. The first ten numbers of any collectible, the first
twenty-five and the last of a hundred are marked as rare in the app, from the number alone.

There are 100 of each collectible unless the operator changes it, #1 to #100; the relay refuses one past the limit. Pulshade Admin's "Amount in rotation" sets how many of each there can be, from 1 to 10,000, up or down but never below how many are already given out, and nobody's number changes; the relay tells the app the size of the run so the last number is marked "Last one". Pulshade Admin can also reset them
all: every collectible is taken back from everyone, backup codes stop working, and each item's numbering starts again
at #1. Apps drop them, and take the one shown after your name off, the next time they check.

**One-time chats.** New chat → one-time chat makes a throwaway identity for both sides that ends after the time you
pick, and works for the first person in. Share it as a QR code, a link, or a 12-digit code to read out or type, so
nothing has to go through another app. The code's link waits on the server sealed in a mailbox only the digits lead
to (stretched like a passcode, so trying them all would take years), padded to a fixed size, and is deleted when
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

**Pulse check.** Both people see the same ten emoji (60 bits), 30 digits, colours and QR code, derived from both
identities. Scanning the other screen with the camera, or confirming the emoji match, marks the contact verified.

**Removing a contact.** Removing someone takes them off every one of your devices, with their keys, mailboxes and
stories, and tells their app to forget you and your chat, the same message a burner sends when it burns, so the
chat goes on both sides. They can only reach you again with a new invite or a request. Someone you still share a
group or channel with stays only as a member there, like people you've never added.

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

**Groups, channels and broadcasts.** Groups and channels fan out one envelope per member; members who aren't your
contacts are kept as hidden peers, used only inside that group. Each has an owner, optional admins and a posting
rule (everyone, admins, or owner only). Changes carry a version number and only count when they come from an admin.
Admins add people from their contacts and remove members; only the owner appoints admins, changes the posting rule
or deletes it for everyone; anyone else who deletes it leaves. In a group the owner can also make someone a mod: a
Mod tag, posting when only admins can, and taking ordinary members out (never admins, the owner or other mods),
nothing else. Everyone else only accepts a mod's update if it removes members and changes nothing besides. Channel followers only learn who can post, not who
else follows. A broadcast is the same message sent privately to each person.

Members who don't know each other first meet through introduction mailboxes. Whoever sends out the group's details
makes one for each member's device, gives that device its key privately, and gives the other members only where to
write. Nobody is ever given the mailbox a member uses with the owner. What arrives there is sealed to the member, so
whoever made it can't read it. After the first hello, the member opens a mailbox just for that person and tells them
to write there instead. If the group was made before its owner had heard from a member's device (someone added a
moment earlier), that member is told its mailbox again once the owner knows the device.

**Linked devices.** One account, several devices, like Signal. Your identity keys are shared between your devices,
but each device has its own id, its own mailboxes and its own ratchet session with every contact device, so no
message key is ever used twice. Linking: the logged-in device shows a QR code holding a one-time secret and a
mailbox; the new device answers with a fresh key; you approve it; and the account (keys, contacts, groups, personas,
settings) is sent encrypted to that key mixed with the secret, with message history following over the new device's
session. Only the first device to answer a code counts, and both devices show six digits to compare before you
approve. The new device then introduces itself to every contact, calling itself just "Mac" or "iPhone". People send
to all your devices; what you do on one is synced to the others through an encrypted session between them.

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
friend request or linking code that names any other server is refused, and the app never connects to one, whatever
a contact once said. Every code you scan or open asks before it does anything, and a `pulshade://` link from another
app can never link a device; that only works from the camera. The code is open, so anyone can check what the app and
the server do; a build someone makes themselves uses its own server, and isn't Pulshade.

**The server (relay).** A small Rust program. No accounts and no request logs (it prints only start-up and error lines, none naming an address or a mailbox). Envelopes are held in memory only and deleted on
pickup or after 7 days; their ids are random, so they don't reveal how busy it is. Waiting envelopes and wake-up
registrations (which device token to wake for which mailbox) are never written to the server's disk, so a restart or crash
empties them: a message not yet collected is lost and must be sent again. The handle directory, held handles, moderation
lists and accounts' sealed backups (no chats) are saved to disk too, the first three sealed with the same storage
key, as are the push key, the pet signing key and the onion service's key (Arti's own keystore is kept in memory, and
the relay hands it the unsealed key at start). On a Mac that key is in the Keychain. On the Linux server it is never
written to disk: it sits in a memory-only folder (ramfs, which is never swapped out) and on the operator's Mac, and
after a reboot the relay stays locked until the operator sends it back (`pulshade-admin server unlock`). So a copy of
the disk, a snapshot or its backups hold nothing that can be opened; someone who controls the running server could
still read the key from memory. A
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

**Tor in the app.** Tor (Arti, Tor's Rust implementation) runs inside the app on the Mac and the iPhone, built from
source in `tor/`; there's nothing else to install. It listens on 127.0.0.1 behind a password picked at each launch,
and every lane (each persona, each public inbox, sending, linking, reports, each call) signs in with its own name,
so each gets its own circuits and none can be linked to another by address. If a lane's circuit is slow to connect,
a fresh one races it; if a request fails, the lane gets new circuits. Fetches, deposits, the directory, backups and
call audio all go through it, and nothing falls back to a direct connection: if Tor can't start or can't reach the
server, requests fail. Tor is on from the first launch, before there's even an account.

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

**Anonymity report.** Settings → Anonymity Report shows the address the server sees for you (asked on a connection
of its own; over Tor, a made-up address per circuit), each lane's current Tor circuit with the relays' IP addresses
(the first, the guard, is the only one that sees yours), and a checklist of the settings that matter: Tor, the kind
of server, separate circuits, random timing, link previews, notification text and screen protection. Circuits are
kept in memory only.

## Known limits in full

- **Not yet audited.** The ratchet, the handshake and the envelopes are our own implementation of published designs.
  They pass our tests, but they need an independent audit before anyone relies on them.
- **Post-quantum keys refresh every 50 messages or a day, not on every reply.** Between refreshes, healing after a
  theft relies on X25519 alone. The messages carrying a refresh are larger (8 KB rather than 2 KB), so someone
  watching sizes can tell roughly when one happens. Signal's triple ratchet spreads its keys across many small
  messages to avoid that; Pulshade doesn't yet. A chat with someone on an older version never refreshes.
- **Signatures are gone from messages, not from the directory.** Public profiles, handle claims and admin actions are
  signed, because they're meant to be checked by anyone.
- **Disappearing messages and deleted stories trust the other device.** A modified app could ignore the timer or the
  removal, and anyone can photograph
  a screen. That's true of every messenger.
- **The Keychain is on the same disk.** An old `identity.lock` left in the SSD's spare blocks no longer opens once its
  Keychain key has been replaced. But the Keychain's own database is stored on that disk too, so someone who
  recovered both the old file and its old Keychain entry, and knew the old passcode, could still open it on that
  device. Only the operating system can truly erase storage.
- **Signs that Pulshade was used outlive Burn.** Burn leaves nothing that can be read, but the app itself is still
  installed, and the system's own records (notification history, which apps ran) are out of its reach.
- **Losing the Keychain item locks the vault.** If the device's Keychain is reset, `identity.lock` can't be opened and
  the recovery code is the way back in.
- **Tor hides addresses, not timing.** Someone watching both ends of the network could still line up when things
  happen.
- **Bridges are off unless you turn them on.** Until then your network can see you use Tor (not that it's Pulshade).
  The built-in bridges are public, so a determined censor can block them; your own private bridges are the strongest.
- **Outside the app, your IP address still reaches** wherever you downloaded it, and Apple when a Mac first checks the
  app is notarized. Neither learns who you are on Pulshade or who you talk to.
- **One operator.** The official app only uses Pulshade's servers, which can see when and how much traffic flows
  (never what it says, or who you are behind Tor). A modified app could still point at them; that's held back by rate
  limits and the terms of use, not by anything the code can prove.
- **iPhone:** messages arrive while the app is open, unless **Wake when locked** is on, since waking a closed app needs
  Apple's push service (see [wake-up pushes](push-notifications.md)). Blank screenshots
  rely on iOS behaviour Apple doesn't document; if an update changes it, screenshots would show the app again.
- **Groups cap out at 300 members.** Every message goes out as one envelope per member, so that's the most an owner can
  add: fine for friends and communities, not for 10,000-person channels.
