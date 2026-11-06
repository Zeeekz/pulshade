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

## What we collect

**Account information: none.** Pulshade has no sign-up. Your account is a set of keys made on your device. We never
see your recovery code, your passcode, your keys or your contacts.

**Messages and calls.** These are encrypted on your device before they leave it. Our server only passes on sealed
envelopes, padded to a few fixed sizes. We can't read them. Envelopes wait in the server's memory only, are deleted once collected or after 7 days, and are not written to disk or logged.

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

- **Lock, Detach and Burn** in Settings control what stays on your device and the server. Burn deletes your account
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
