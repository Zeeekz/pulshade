# Privacy Policy

**DRAFT. Not legal advice. Have a lawyer review this, fill in the bracketed parts and check it against the
law where you live and where the app is sold before publishing.**

Last updated: [date]

Pulshade is made by Zeekz ("we", "us"). This policy says what Pulshade does with information. It is written to match
how the app and server really work, which you can check in the open source code and in
[How Pulshade works](how-it-works.md).

## The short version

We can't read your messages, and we don't know who you are. You don't give us a phone number, email address or name
to use Pulshade, and over Tor the server never sees your IP address. We don't sell data, show ads or track you.

## What is stored on our servers

**Everything private is encrypted, on our servers and on your phone.** We take every precaution we can for your
privacy: every message has its own fresh key, sizes are padded, there are no accounts or phone numbers, the server keeps
no logs, and what is stored is sealed so we can't read it. Everything we store is either encrypted so that we can't
read it, or public because you chose to make it public.
Nothing about you or your messages is kept in readable form. Even the server's own files are sealed, with a key that
is never written to its disk. Here is every kind of thing, in plain words:

| What | Where it is kept | How long | Can we read it? |
| --- | --- | --- | --- |
| **Messages** (text, receipts, calls' set-up) | The server's memory, and a sealed journal on its disk | Until the other person's phone collects it, or 7 days (the journal is rewritten within minutes of collection and the old file overwritten) | No. Sealed on your phone with keys only you and they have. |
| **Files and chat videos you send** (files up to 100 MB; videos a few MB) | The server's disk, in pieces | Erased the moment the other person's phone has downloaded it, or when you delete the message, or after 7 days at most | No. Sealed on your phone with a key that travels only inside the encrypted message, and sealed a second time by the server with a key of its own. Its name and type are inside the encrypted message, so we don't even know those. |
| **Video stories** (a few MB) | The server's disk, one copy for everyone | Until the story's timer runs out (then overwritten and erased), or sooner if you delete the story | No. The same two layers of encryption. |
| **Sealed backup** (profile, contacts, groups, settings; never chats) | The server's disk | Until you switch it off, Burn, or 180 days without an update | No. Sealed with a key only your recovery code makes. |
| **Spare keys** (one per friend, so a friend who logs back in can write to you straight away) | The server's disk, in the sealed-backup store | Erased by your friend when they use it, or by you when you remove them; otherwise replaced every 5 to 10 days, and 180 days without an update at most | No. Only you and that friend can work out where it is or open it, and it holds no message. |
| **Public @handle and profile** (only if you choose one) | The server's disk | Until you let it go | Yes, it is public by your choice. |
| **Collectibles you own** | The server's disk | While they exist | They're not secret: the item, its number and a hash of its code. |
| **The server's own records and keys** (handle directory, held handles, moderation lists, collectible records, announcements; its push, pet-signing and onion keys) | The server's disk | While the service runs | Only the server, which needs them to work. Sealed with its storage key, which is held in memory only and never written to the disk; after a reboot the server stays locked until we unlock it. The admin password is kept only as a hash. |
| **Wake-up token** (only if you turn on "Wake when locked") | The server's memory, and a sealed file on its disk | While it's on (gone within seconds of turning it off; dropped after 7 days without a renewal) | It is a device token and nothing else. |

Photos, voice notes and text travel inside the encrypted message itself, so they wait like any message: in the server's memory and in its sealed journal on disk.

A file you are sent is erased from the server as soon as your phone has it. Your phone does not keep received files:
you open it once, from memory, and "Save a copy" is how you keep it. A chat video is kept in your chat.

Your phone keeps what you receive in memory and in its own encrypted vault. A file someone sends you is fetched into
your phone's memory when you open it and is never written to the phone's disk by Pulshade, unless you choose
"Save a copy".

When you delete something you sent (by deleting the message), it disappears from your phone straight away, your app
tells the server in the same moment, and the server erases it on the spot: the piece files are overwritten with random bytes and removed, and the key the server sealed them with is
destroyed, so even a stray copy left on a solid-state disk can't be opened. If your phone can't reach the server at
that moment, it tries again until it does. A file nobody deletes is erased after at most 7 days. Detach, the panic
passcode and Burn also erase your files from the server. All three wipe your phone at once and send the erase
requests in the same moment without waiting (on an account's only device; if your phone is offline then, the server
forgets the files within 7 days at most). Burn goes further: see below.

What the server can still see about a file, as with any message: that something of about that size was uploaded,
when it was uploaded and collected, and, if you connect without Tor, your IP address while you do. It can't see what
it is, what it's called or who it is for.

## What we collect

**Account information: none.** Pulshade has no sign-up. Your account is a set of keys made on your device. We never
see your recovery code, your passcode, your keys or your contacts.

**Messages and calls.** These are encrypted on your device before they leave it. Our server only passes on sealed
envelopes, padded to a few fixed sizes. We can't read them. Envelopes wait in the server's memory and in a journal on its disk, every record sealed with a key that is never written to the disk. They are deleted once collected (the journal is rewritten within minutes and the old file overwritten) or after 7 days, and are not logged.

**Files.** A file you send is encrypted on your device in pieces, with a fresh key that is sent only inside the
end-to-end encrypted message, and uploaded once to our server, which seals it again and keeps it on its disk until
you delete the message or 7 days pass. We can't open it. See "What is stored on our servers" above.

**Public handles and profiles (only if you choose them).** If you claim a public @handle, its name, your picture and
banner and the key it belongs to are stored on our server so anyone can look it up. This is public by your choice.
A handle you let go of is held for a while so nobody else can take it straight away; a burned account's handles are
retired and no longer tied to anyone.

**Sealed backup (on by default, switch in Settings).** So that Detaching a device can be instant, the app keeps an
encrypted copy of your profile, contacts, groups, personas and settings on the server, saved again a few minutes
after they change, so your recovery code can restore it. We can't open it, and it isn't tied to your account on the
server. It is deleted when you switch the backup off or Burn, and 180 days after it was last saved if the app never
saves it again (for instance after a Detach). Chats are never included. The server sees when it was saved and its
rough size, and, if you connect without Tor, your IP address during the upload, as with any connection.

**Spare keys.** After you log back in (Detach and your recovery code), the app needs new keys with each friend. So
that you don't have to wait for every friend to open Pulshade, each friend's app leaves a spare key for you on the
server ahead of time, and yours leaves one for each of them. It's kept in the sealed-backup store, at a place only the
two of you can work out, sealed with a key only the two of you can make, and every spare is the same size. The server
can't open it or tell whose it is. Each one is written and read on its own connection, at random times, so the server
can't easily tie the spares of one person together, but it does see when a spare is written, read or erased, and if
you connect without Tor, your IP address during that request. A spare is used once: the friend who uses it erases
it. Removing a friend erases yours for them. Otherwise each is replaced every 5 to 10 days, and one nobody updates
(after a Burn, say) is erased after 180 days; it is no use to anyone without your keys.

**Collectibles.** If you are given a collectible, the server keeps what it needs to show it and let its owner claim it
again with a backup code: the item, its number and a hash of the code.

**Reports.** If you report something, the report is sealed so that only Pulshade Admin can read it. It is sent from a
throwaway key and carries your handle only if you add it.

**Network information.** Over Tor, the server sees a made-up address for each connection, not your IP address. If you
turn Tor off in Settings, the server sees your IP address and roughly where you are, and your personas could be tied
together by it. To limit abuse, the server counts requests per sender using a hash of the address with a salt that is
replaced every hour. It never keeps the address itself: there is no request log, and the web proxy in front of the
server keeps no access log. On Fast your address is still in the server's memory while you're connected, and a server
could in principle match the address that sent a message with the one that collected it. Ours doesn't record that, but
on Fast you are trusting us not to; Tor removes the need.

**What the server can see about traffic.** It can see that a sealed envelope arrived at a random mailbox, when, and
how large (within a few set sizes). It can't see who sent it, who you are behind Tor, or what is inside.

**Your phone's address book: never.** Pulshade doesn't ask for your contacts and doesn't read them. You add friends
by scanning a code or sharing a link, so there is no phone-number matching and nothing to upload.

**Camera, microphone and photos.** The camera scans codes and takes photos and videos for chats and stories, and the
microphone records voice notes, videos and calls. Both are encrypted on your phone before they leave it, and camera
frames are never saved. Pulshade can only add pictures to your photo library when you choose "Save", and never reads it.

**Disappearing messages.** If a chat has a timer, each message disappears from every device when its timer ends. A
timer is a promise made by the apps, not by the law of physics: a friend could still screenshot or copy a message before
it goes.

## Why we handle this information

We handle only what is needed to carry your sealed messages and files, keep the backup you switch on and show the
public handles and collectibles people choose to publish, and to keep the service safe from abuse (the hourly-salted
request counts above). We have no other purpose for it, and no use for it in advertising or profiling.
[Lawyer: where the law requires a stated legal basis, this is most likely legitimate interests; confirm and
word it for each region.]

## Who may see it

- **Other Pulshade users** see what you send them and what you make public (your handle, picture and banner).
- **The people who run the server and the network it sits on** can see the same traffic facts as any server: that a
  sealed envelope arrived, when, and how large, plus your IP address if you connect without Tor.
- **Hosting.** The relay runs on a rented server. The company that rents it can see the machine's network traffic and
  could take it offline. Its disk holds nothing readable, because the key that opens the server's files is never stored
  there. Like anyone who controls a running computer, the host could in principle read its memory, which is why
  everything personal is sealed on your phone first.
- **Law enforcement and other legal requests.** We can only hand over what we hold, and what we hold is sealed or
  public, as the table above shows. We have no message content, no account identity, no phone numbers or emails, no
  contact lists and no request logs to give. If a lawful order arrives we will review it, answer it only as far as the
  law requires, and tell the person it concerns whenever we are allowed to and can reach them. [Decide whether to
  publish a transparency report.]
- **Nobody else.** We don't sell, rent or share your information with advertisers or data brokers.

## What we don't do

- We don't sell, rent or share your information.
- We don't use advertising, analytics or tracking, in the app or on the server.
- We don't build profiles of you. Over Tor we can't link your personas to each other; on Fast they connect from the same
  IP address, which we don't record.
- We don't ask for your phone number, email address, name or contacts.
- The app talks only to Pulshade's servers.

## Outside the app

- Wherever you download Pulshade from, such as the App Store or our website, sees your IP address and what you
  download. Apple also checks the app when a Mac first opens it. These services have their own policies.
- If you turn on "Wake when locked" on iPhone, notifications go through Apple's service: Apple sees your device token
  and when a notification is delivered, never message contents, and Pulshade's server keeps your token, in memory and in a sealed file on its disk, linked to your mailboxes while it's on. Pulshade recommends leaving this off if you need the strongest anonymity.
- Your phone or computer may keep its own records of notifications and app use, which we can't control. By default,
  notifications say only "New message".

## Your choices and rights

- **Lock, Detach and Burn** on the Burn tab control what stays on your device and the server. Burn deletes your account
  everywhere, and it can't be undone. It wipes your phone at once, whether or not you are connected. At the same
  time it sends the server an order, signed on your phone, to erase your sealed backup, retire your @handles, take back
  any sealed messages you sent that are still waiting for friends to collect, erase your files and empty and close your
  mailboxes. If the server can't be reached, your phone keeps that order, sealed, and tries again a minute later, then
  every hour while Pulshade is open, until the server confirms, and then deletes it; a message tells you when it is done.
  The order can erase things but can't read anything. Messages already collected by a friend's phone can't be taken
  back, though an up-to-date Pulshade on their side forgets you and everything you sent.
- Because we hold no account details about you, we usually can't tell which data is yours. For a public handle or a
  collectible, contact us at [contact address] and we'll act on what we can verify.
- **If you live in the EU, UK or a similar region**, you may have rights to access, correct and delete your data,
  to move it, to restrict or object to how it is used, and to complain to your data-protection authority. We can't
  look up what we can't link to you, and the above is what we hold. The tools that answer most of these are already in
  the app: you can see and edit your own profile, turn the backup off, and Burn erases everything we hold for you. For a
  public handle or collectible, ask us as above. [Lawyer: confirm controller details and any representative needed
  in the EU or UK.]
- **How long things are kept**, in one place: messages up to 7 days in memory; files up to 7 days; the sealed backup
  until you switch it off or Burn, or 180 days after its last update; handles and collectibles until you let them go;
  the wake-up token while the setting is on; and request counts for an hour. Nothing is kept "just in case".

## Children

Pulshade is not for children under [13 / 16 / your age rating]. We don't knowingly collect their information and, with
no accounts, can't tell who is a child. If you think a child is using Pulshade, contact us.

## Changes

If we change this policy we'll update the date above, add a line to the list below and tell people in the app's
announcements. The code and documentation show what the app does at any time.

- **Build 10:** waiting messages are now also kept in a journal on the server's disk, every record sealed with a key that
  is never written to the disk, so a restart, crash or reboot no longer loses them; collected mail is overwritten in the
  journal within minutes. They used to be in memory only, never on the disk. Wake-up tokens are kept the same way, only for people who turn on "Wake when locked". Calls and rate-limit counts
  are still memory only.
- **Build 10:** the server's own records and keys are sealed with a key that is never written to its disk; the admin
  password is kept only as a hash; what Fast means for your IP address, and that the web proxy keeps no access log;
  what the hosting company could see.
- **Build 8:** added what Pulshade never asks for (address book), what the camera, microphone and photo permissions
  are used for, disappearing messages, why we handle information, who may see it (hosting, legal requests), and a single
  list of how long everything is kept.
- **Earlier builds:** files and videos on the server's disk, the sealed backup, and Burn and Detach wiping.

## Contact

[Name or company, address if required], [contact address]
