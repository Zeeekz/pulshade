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
Nothing about you or your messages is kept in readable form. Here is every kind of thing, in plain words:

| What | Where it is kept | How long | Can we read it? |
| --- | --- | --- | --- |
| **Messages** (text, receipts, calls' set-up) | The server's memory only, never its disk | Until the other person's phone collects it, or 7 days | No. Sealed on your phone with keys only you and they have. |
| **Files and videos you send** (files up to 100 MB; story and chat videos a few MB) | The server's disk, in pieces | Until the message is deleted, or at most 7 days | No. Sealed on your phone with a key that travels only inside the encrypted message, and sealed a second time by the server with a key of its own. Its name and type are inside the encrypted message, so we don't even know those. |
| **Sealed backup** (profile, contacts, groups, settings; never chats) | The server's disk | Until you switch it off, Burn, or 180 days without an update | No. Sealed with a key only your recovery code makes. |
| **Public @handle and profile** (only if you choose one) | The server's disk | Until you let it go | Yes, it is public by your choice. |
| **Collectibles you own** | The server's disk | While they exist | They're not secret: the item, its number and a hash of its code. |
| **Wake-up token** (only if you turn on "Wake when locked") | The server's memory only | While it's on | It is a device token and nothing else. |

Photos, voice notes and text travel inside the encrypted message itself, so they wait in the server's memory like any
message and are never on its disk.

Your phone keeps what you receive in memory and in its own encrypted vault. A file someone sends you is fetched into
your phone's memory when you open it and is never written to the phone's disk by Pulshade, unless you choose
"Save a copy".

When you delete something you sent (by deleting the message), it disappears from your phone straight away, your app
tells the server in the same moment, and the server erases it on the spot: the piece files are overwritten with random bytes and removed, and the key the server sealed them with is
destroyed, so even a stray copy left on a solid-state disk can't be opened. If your phone can't reach the server at
that moment, it tries again until it does. A file nobody deletes is erased after at most 7 days. Detach, the panic
passcode and Burn also erase your files from the server: Burn waits for it, while Detach and the panic passcode wipe
your phone at once and send the erase requests in the same moment without waiting (on an account's only device; if
your phone is offline then, the server forgets the files within 7 days at most).

What the server can still see about a file, as with any message: that something of about that size was uploaded,
when it was uploaded and collected, and, if you connect without Tor, your IP address while you do. It can't see what
it is, what it's called or who it is for.

## What we collect

**Account information: none.** Pulshade has no sign-up. Your account is a set of keys made on your device. We never
see your recovery code, your passcode, your keys or your contacts.

**Messages and calls.** These are encrypted on your device before they leave it. Our server only passes on sealed
envelopes, padded to a few fixed sizes. We can't read them. Envelopes wait in the server's memory only, are deleted once collected or after 7 days, and are not written to disk or logged.

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

**Collectibles.** If you are given a collectible, the server keeps what it needs to show it and let its owner claim it
again with a backup code: the item, its number and a hash of the code.

**Reports.** If you report something, the report is sealed so that only Pulshade Admin can read it. It is sent from a
throwaway key and carries your handle only if you add it.

**Network information.** Over Tor, the server sees a made-up address for each connection, not your IP address. If you
turn Tor off in Settings, the server sees your IP address and roughly where you are, and your personas could be tied
together by it. To limit abuse, the server counts requests per sender using a hash of the address with a salt that is
replaced every hour. It never keeps the address itself. No request log is kept.

**What the server can see about traffic.** It can see that a sealed envelope arrived at a random mailbox, when, and
how large (within a few set sizes). It can't see who sent it, who you are behind Tor, or what is inside.

## What we don't do

- We don't sell, rent or share your information.
- We don't use advertising, analytics or tracking, in the app or on the server.
- We don't build profiles of you. We can't link your personas to each other.
- The app talks only to Pulshade's servers.

## Outside the app

- Wherever you download Pulshade from, such as the App Store or our website, sees your IP address and what you
  download. Apple also checks the app when a Mac first opens it. These services have their own policies.
- If you turn on "Wake when locked" on iPhone, notifications go through Apple's service: Apple sees your device token
  and when a notification is delivered, never message contents, and Pulshade's server keeps your token, in memory only,
  linked to your mailboxes while it's on. Pulshade recommends leaving this off if you need the strongest anonymity.
- Your phone or computer may keep its own records of notifications and app use, which we can't control. By default,
  notifications say only "New message".

## Your choices and rights

- **Lock, Detach and Burn** on the Burn tab control what stays on your device and the server. Burn deletes your account
  everywhere, and it can't be undone.
- Because we hold no account details about you, we usually can't tell which data is yours. For a public handle or a
  collectible, contact us at [contact address] and we'll act on what we can verify.
- **If you live in the EU, UK or a similar region**, you may have rights to access, correct and delete your data, or
  to complain to your data-protection authority. We can't look up what we can't link to you, and the above is what
  we hold. [Lawyer: confirm legal basis, controller details and any representative needed.]

## Children

Pulshade is not for children under [13 / 16 / your age rating]. We don't knowingly collect their information and, with
no accounts, can't tell who is a child. If you think a child is using Pulshade, contact us.

## Changes

If we change this policy we'll update the date above and tell people in the app's announcements. The code and
documentation show what the app does at any time.

## Contact

[Name or company, address if required], [contact address]
