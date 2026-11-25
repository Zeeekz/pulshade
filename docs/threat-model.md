# Threat model

This is what Pulshade is built to protect, from whom, and what it explicitly does not protect. It is the
document the code and the tests should be read against. It describes intentions and mechanisms; it is not a
claim that every mechanism has been independently verified.

## Assets

- **Message content** — text, photos, videos, voice notes, files, calls, stories, reactions, replies.
- **Account keys** — the seed, the device keys, the ratchet state, the group keys.
- **Social graph** — who talks to whom, who is in which group, who follows which channel.
- **Identity linkage** — which personas, devices and inboxes belong to the same person.
- **Location** — the IP address behind a connection.
- **The fact that an account exists** — including whether a decoy or panic passcode is set.
- **Data after Lock / Detach / Burn** — what remains on the device and on the relay.

## Adversaries

1. **Network observer** (ISP, Wi-Fi, a national firewall). Sees connections, addresses, sizes and timing.
2. **Relay operator** (whoever runs the server, including a compromised one). Sees mailboxes, envelopes,
   request metadata, and can drop, delay, duplicate or reorder mail.
3. **Malicious or curious contact** (someone you chat with). Sends crafted messages, links, files, stories,
   codes; may try to make you open something.
4. **Device thief / someone with the locked or unlocked device**, including a border agent demanding a passcode.
5. **Platform** (Apple). Sees app installs, push tokens, crash reports, App Store identity.
6. **Persona/device correlator.** Tries to tie two identities, two devices or two inboxes together.

## Assumptions

- The device's OS and Secure Enclave are not compromised; iOS Data Protection and the Keychain work.
- Apple's push service (APNs) is honest but *does* see push metadata (see "Out of scope").
- Tor is not broken in real time; Arti is used correctly as built.
- The user's contacts are not all colluding to reconstruct a conversation by comparing what they received.
- Endpoints are not compromised: malware with the unlocked device can read what is on screen.

## Guarantees and the mechanisms behind them

| Promise | Mechanism | Where |
|---|---|---|
| Message content is readable only by the two ends | Double Ratchet with ChaCha20-Poly1305; X25519 + ML-KEM-768 handshake; per-message keys | `Ratchet.swift`, `Handshake.swift`, `Envelope*.swift` |
| No sender identity on the wire | Sealed envelopes; sender bound inside the AEAD, not in the outer header | `EnvelopeCore.swift`, `EnvelopePQ.swift` |
| The relay can't tell who is talking to whom | Random mailbox names, one circuit per persona/inbox, padded envelope sizes | `Relay.swift`, `Tor.swift` |
| The relay can't read profiles, backups or files | Client-side sealing; files sealed with a key that travels only in the E2EE message | `Envelope*.swift`, `Blob.swift` |
| A copied lock file can't be guessed off the device | Argon2id (64 MiB) per guess, then each slot's key needs the Secure Enclave's answer for that passcode (an OPRF-style point multiplication), so every guess needs this device's chip; the whole file re-sealed with a rotating Keychain key. Without a Secure Enclave, Argon2id alone. Code running on the unlocked device can still guess at the chip's speed | `Vault.swift` |
| Decoy and panic passcodes are indistinguishable | Three same-shaped slots, all decrypted on every attempt; filler data files | `Vault.swift` |
| Old messages don't open after a compromise | Forward secrecy via the ratchet and removal of skipped keys | `Ratchet.swift` |
| Out-of-order, duplicated and lost mail is survivable | Skipped-key cache, replay rejection, chunked PQ exchange | `Ratchet.swift`, `DeliveryChaosTests.swift` |
| Crafted codes, links and files can't crash the app | Bounds-checked parsers; fuzz-style tests | `ParserFuzzTests.swift`, `Wire.swift`, `ChatLinks.swift` |
| Nothing is logged | No logging calls in the app; sealed storage only | whole tree |

## Out of scope (and why)

- **APNs.** Apple sees that a device received a push. The payload is sealed, but the token and timing are
  visible to Apple. Push stops when notifications are turned off (there is no separate switch); the app documents this rather than claiming otherwise.
- **Traffic analysis by a global observer.** Sizes are padded and Tor hides the address, but timing and
  volume can still say "someone is active".
- **A compromised endpoint.** Malware, a keylogger or someone reading an unlocked screen is outside the
  cryptographic guarantees. Decoy/panic passcodes address coercion, not live compromise.
- **A modified client or relay.** Running a build you changed may weaken every guarantee here.
- **Contacts keeping what you sent them.** The protocol cannot unsend what the other end already has.
- **The relay's own build.** The server is not published, so its behaviour is not independently checkable.
  That is a verifiability gap, not an assumption that it is malicious.

## What would falsify a guarantee

Each promise above should have a test that fails if the mechanism is removed. The delivery-chaos suite and the
parser fuzz suite are the first of those. The remaining ones — vault/Keychain behaviour on a real device, relay
metadata, push behaviour — need either a device test or an external reviewer, and are listed in
[security-assurance.md](security-assurance.md).
