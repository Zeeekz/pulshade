# Pulshade FAQ

Short answers to common questions. For the full design, see [How Pulshade works](how-it-works.md); for what we keep,
see the [Privacy Policy](privacy-policy.md).

**Contents:** [General](#general) · [Getting started](#getting-started) · [Privacy and anonymity](#privacy-and-anonymity) ·
[Friends and chats](#friends-and-chats) · [Groups, channels and stories](#groups-channels-and-stories) ·
[Files and media](#files-and-media) · [Passcodes, Lock, Detach and Burn](#passcodes-lock-detach-and-burn) ·
[Recovery and devices](#recovery-and-devices) · [Network](#network) ·
[Notifications](#notifications) · [Handles, collectibles and extras](#handles-collectibles-and-extras) ·
[Reporting and safety](#reporting-and-safety)

## General

**What is Pulshade?**
An anonymous, end-to-end encrypted messenger for Mac and iPhone. There is no phone number, email address or username
to sign up with. The first time you open it you choose how it connects: privately through Tor, built in, or Fast.

**Who is it for?**
Anyone who wants to talk without handing over who they are. It has not had an independent security audit yet, so
please don't rely on it where your safety depends on it.

**What do I need to run it?**
macOS 26 or later, or iOS 26 or later.

**Is it free? Do you show ads?**
No ads, no analytics and no tracking, in the app or on the server. We don't sell or share your information.

**Who makes it?**
Zeekz. The apps are open source under the MIT License, so anyone can check what they do. The server is not published.

**Where do I download it?**
From the place Pulshade's website or announcements point to. Wherever you download from can see your IP address and
what you download, as with any app. See the Privacy Policy, "Outside the app".

## Getting started

**Do I need a phone number or email?**
No. Your account is a set of keys made on your device. Nothing identifies you to us.

**What is the recovery code?**
The only way back into your account if you lose the device or forget the passcode. We never see it and can't
recover it for you, so keep it somewhere safe and private. It is never offered for copying inside the app.

**What is the passcode for?**
It seals your account on the device. You can also use Touch ID, except while a decoy or panic passcode is set.

**Can I try it without committing?**
Yes. One-time chats use a throwaway identity for both sides and end after the time you choose, and personas can be
set to destroy themselves on a timer.

## Privacy and anonymity

**Can Pulshade read my messages?**
No. Messages, calls, files, profiles and backups are encrypted on your device before they leave it, and the server only
passes on sealed envelopes.

**What does the server know about me?**
That a sealed envelope arrived at a random mailbox, when, and roughly how large. It has no accounts, no names, no
contacts, no sender on envelopes and no request logs. On Tor it doesn't see your IP address either. On Fast it does,
while you're connected, but doesn't write it down.

**Does the server log my IP address?**
No. There is no request log, the web proxy in front of it keeps no access log, and rate limits keep only a hash of your
address that is thrown away every hour. On Fast your address is still in the server's memory while you're connected,
and in principle a server could match who sent a message with who collected it; ours doesn't record that, but if it
matters, use Tor.

**Is anything on the server readable?**
No. Messages, files and backups are sealed on phones before they arrive. The server's own records and keys are sealed
too, with a key that is never written to its disk, so a copy of the disk holds nothing that can be opened.

**Does it protect against quantum computers?**
Chats start with a handshake that mixes X25519 and ML-KEM-768, and new post-quantum keys are mixed in as you chat
(every 50 messages or a day).

**Can someone prove I said something?**
No. Nothing you say is signed, so a message can't be shown to a third party as coming from you.

**What are personas?**
Separate identities with their own keys, mailboxes, contacts and chats. They can't be tied to each other, and each
connects separately. Burners are personas that destroy themselves on a timer.

**What can Pulshade not protect me from?**
Honest limits: someone watching both ends of the network can still line up timing; a friend can screenshot or copy a
message; a modified app on the other side can keep what you thought had disappeared; and the app hasn't been audited.
[How Pulshade works](how-it-works.md) lists them all under "Known limits".

**Do you read my address book?**
Never. You add friends by scanning a code or sharing a link, so there is nothing to match or upload.

## Friends and chats

**How do I add a friend?**
Scan their QR code or open their link. A one-time chat can also be started with a 12-digit code you read out loud.

**How do I know I'm talking to the right person?**
Use Pulse check. Both of you see the same ten emoji, 30 digits, colours and QR code, derived from both your keys.
If they match, nobody is in the middle.

**What are disappearing messages?**
A chat can have a timer; when it ends, each message disappears from every device. It works only as far as the other
device plays fair.

**Can I unsend a message?**
Yes, by deleting it. It disappears from your phone at once, and your app tells your friend's app and the server.

**Can I send voice notes and make calls?**
Yes. Voice notes are recorded and played from memory, never a file, and calls are set up through the same encrypted
channel.

**Why are some messages "waiting"?**
Unread messages wait in the server's memory until your friend's phone collects them, or for 7 days at most. If the
server restarts, it hands them on in memory, so nothing is lost. If the whole machine reboots, a message not yet
collected is lost and your phone sends it again.

**What are link previews?**
Off by default. When on, the sender's device builds the preview and sends it inside the encrypted message.

## Groups, channels and stories

**What is the difference between a group, a channel and a broadcast?**
A group is a conversation among members. A channel is for posting to followers. A broadcast sends one message to
several people individually. All of them are sent as sealed envelopes, one per member.

**Who can see my story?**
Only the audience you choose, for the length you choose. You can edit it after posting, see who viewed it (the views
are encrypted like messages) and delete it. A story you delete or that expires is gone from every unmodified app.

## Files and media

**How big can a file be?**
Up to 100 MB. Chat videos are up to 30 seconds.

**Does the server keep my files?**
Briefly, and only sealed. A file is encrypted on your phone, uploaded, sealed again by the server, and erased the moment
the other person has it, when you delete the message, or after 7 days at most.

**Does the app save the files I receive?**
No. They open from memory. Tap "Save a copy" if you want to keep one. Saving a picture from a chat adds it to Photos;
Pulshade can only add to your library, never read it.

**Why does the camera or microphone ask for permission?**
The camera scans codes and takes photos and videos for chats and stories, and the microphone records voice notes,
videos and calls. Both are encrypted on your phone first, and camera frames are never saved.

## Passcodes, Lock, Detach and Burn

**What are Lock, Detach and Burn?**
All three are on the Burn tab.
- **Lock** closes the vault. Everything stays on the device, encrypted.
- **Detach** wipes this device at once. Your other devices keep the account, and your profile, contacts and groups come
  back with the recovery code. Chats on this device are gone for good.
- **Burn** deletes the account everywhere, as if it had never existed. It can't be undone.

**What are decoy and panic passcodes?**
The decoy passcode opens a separate, harmless, empty account. The panic passcode quietly destroys the real account and
opens an empty one. The disk doesn't show whether either is set up.

**What if I'm offline when I Burn?**
Your phone is wiped at once regardless. It keeps a signed order and sends it again until the server confirms, then
tells you.

## Recovery and devices

**I lost my phone. What now?**
Install Pulshade on a new device and use your recovery code. Your profile, handles, contacts, groups, personas and
settings come back from the sealed backup. Chats don't: they never leave your devices.

**What is the sealed backup?**
A copy of your profile, contacts, groups, personas and settings (never the messages or any chat keys), encrypted
with a key only your recovery code makes. After you log back in the app opens new chat keys with each contact, so mail
sent while you were logged out can't be opened. We can't open it or link it to you. It is on by default and erased when you switch it off in Settings, Burn,
or 180 days after its last save.

**Can I use Pulshade on several devices?**
Yes, linked devices share one account. A QR code from a linked device logs a new one in.

**What happens to my chats if I Detach the only device?**
The people you chat with are told to clear their one-to-one chat with you (they keep you as a contact). If you are
offline, they are told when the account is next recovered.

**Can I message everyone straight away after I log back in?**
Your contacts and groups are there at once, but each chat starts with fresh keys. A friend's Pulshade has to be open
once to answer before your messages reach them; until then the chat says it is setting up new keys.

## Network

**How does Pulshade connect?**
The first time you open the app you choose Tor or Fast. Tor is built in, with nothing to install, and hides your IP
address from the server. Fast skips it and is quicker, but the server then sees your IP address (it doesn't log it).

**Can I change it later?**
Yes, in Settings → Network. Turning Tor off is for speed, and the app explains first: the server then sees your IP address and your personas
could be tied together by it.

**My network blocks Tor.**
Turn on bridges in Settings → Network → Bridges. Without bridges, your network can see you use Tor, though not that it
is Pulshade.

**How can I see what the server sees?**
Settings → Anonymity Report shows the address the server sees for you.

## Notifications

**Why don't I get messages when the app is closed?**
On iPhone, messages arrive while the app is open. Turn on **Wake when locked** in Settings → Notifications to let the
server wake your phone through Apple. Apple then learns your phone was woken, and when, though never what was said.
Leave it off if you need the strongest anonymity.

**What do notifications show?**
Only "New message" unless you choose otherwise, because the system stores notification text outside Pulshade's
encryption.

## Handles, collectibles and extras

**What is a @handle?**
An optional public name you can claim per persona, so people can look you up. Its name, picture and banner are public by
your choice. A handle you let go of is held for a while so nobody takes it straight away.

**What are collectibles and pets?**
Numbered items, drawn in code, that the operator gives to an account. You can gift them or let them go; pets have their
own group in the Collectibles tab. They aren't secret: the item, its number and a hash of its code are kept so the
owner can claim it again with a backup code.

**What are announcements?**
Notes from the operator, delivered to a read-only chat from Pulshade. Nobody can reply to them.

## Reporting and safety

**How do I report something?**
Use the report option on the thing you want to report. The report is sealed so only Pulshade Admin can read it, and it
is sent from a throwaway key. It carries your handle only if you add it.

**Can you read or moderate private chats?**
No, and we can't. We can act on what is public, such as handles and public profiles.

**I found a security problem.**
Please report it privately, not in a public issue. See [SECURITY.md](../SECURITY.md).

**Something here is wrong or missing.**
This page is written to match the app and the code; if it doesn't, the code and
[How Pulshade works](how-it-works.md) are what count. Tell us at zeekz@zeekz.world.
