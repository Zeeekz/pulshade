# Security

Pulshade exists to keep people safe, so a security hole is the most important kind of bug. Thank you for looking.

Pulshade has **not yet had an independent audit**. The ratchet, the handshake and the envelopes are our own code
following published designs.

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately through GitHub: on the repository's **Security** tab,
choose **Report a vulnerability**. Only the maintainer sees it.

Helpful things to include:

- what an attacker can do, and what they need first (a network position, the relay, a stolen device, a contact)
- the steps to reproduce it, or a proof of concept
- the version or commit you tested

You'll get a reply as soon as possible, and we'll agree on when to make it public once a fix is out. If you'd like,
you'll be credited in the release notes.

## What counts

Anything that breaks a promise the README makes, for example:

- reading messages, calls, files or stored data without the keys
- forging or replaying messages, or impersonating someone
- linking identities, personas or devices to each other, or revealing someone's IP address while Tor is on
- telling whether a decoy or panic passcode is set up
- the relay learning more than it should, accepting admin actions it shouldn't, or losing other people's messages
- recovering anything after Lock, Detach or Burn that should be gone

## Known limits

- A passcode can still be guessed on the device itself by someone who can run code on it while it is unlocked: every
  guess needs the device's Secure Enclave and an Argon2id run, but nothing in the chip limits how many it answers, and
  the app's own wait and wipe count don't bind such an attacker. A 6-digit PIN would likely fall to that within hours to days (an estimate, not measured). Where
  there is no Secure Enclave, a copied lock file is protected by Argon2id alone.
- An automatic lock keeps the account's keys in memory, so messages still arrive, unless "Close everything when it
  locks" is on. A lock you press always clears them.
- A decoy or panic passcode set before build 22 stays in the older form (PBKDF2) until it is set again.
- A Burn the server hasn't confirmed leaves a sealed order on the phone for up to 30 days, which shows a burn happened.

## What doesn't

- what every end-to-end messenger shares, such as someone watching both ends of the network lining up timing
- attacks that need an unlocked device in hand, or malware already running as the user
- someone you chat with keeping, copying or photographing what you sent them
- running a modified copy of the app or relay yourself

## Testing safely

Use your own accounts. Please don't load-test or attack Pulshade's servers.
Don't access anyone else's data, and stop as soon as you've shown the problem. Research done in good faith along
these lines is welcome, and won't be treated as an attack.
