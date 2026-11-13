# Security

Pulshade exists to keep people safe, so a security hole is the most important kind of bug. Thank you for looking.

Pulshade has **not yet had an independent audit**. The ratchet, the handshake and the envelopes are our own code
following published designs, and "Known limits in full" in docs/how-it-works.md lists what we already know falls short.

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

## What doesn't

- the limits already listed under "Known limits in full" in docs/how-it-works.md (unless you've found a way to make one worse)
- attacks that need an unlocked device in hand, or malware already running as the user
- someone you chat with keeping, copying or photographing what you sent them
- running a modified copy of the app or relay yourself

## Testing safely

Use your own accounts. Please don't load-test or attack Pulshade's servers.
Don't access anyone else's data, and stop as soon as you've shown the problem. Research done in good faith along
these lines is welcome, and won't be treated as an attack.
