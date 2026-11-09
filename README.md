# Pulshade

Anonymous, end-to-end encrypted messaging for Mac and iPhone. No phone number, no email, no username.

Built by Zeekz.

> **Pulshade hasn't had an independent security audit yet.** Its encryption is our own code following published
> designs. Until it's been audited, please don't rely on it where your safety depends on it.

## What it does

- **Nothing to sign up with.** Your account is a set of keys made on your device. A recovery code is the only way
  back in.
- **Tor, built in.** From the first launch, before there's even an account, everything goes through Tor to
  Pulshade's onion server, so the server never learns your IP address. Nothing to install.
- **End-to-end encrypted, with post-quantum protection.** Every chat uses a Double Ratchet (the design Signal uses),
  started with a handshake that mixes X25519 and ML-KEM-768 and refreshed with new post-quantum keys as you chat.
  Nothing you say is signed, so a message can't be proven to anyone else.
- **Personas and burners.** Separate identities that can't be tied together, and throwaway ones that destroy
  themselves on a timer.
- **One-time chats.** A chat for a single conversation, shared by QR code, link or a 12-digit code you read out.
- **Decoy and panic passcodes.** One opens a harmless empty account; the other quietly destroys the real one.
- **Lock, Detach and Burn.** Lock the app; detach this device with one tap, which wipes it at once and keeps your
  profile, contacts and groups in a sealed backup that only your recovery code opens (never your chats); or burn it
  everywhere, as if it never existed.
- **The rest of a messenger.** Groups, channels, broadcasts, voice notes, calls, reactions, replies, disappearing
  messages, linked devices, and in-person verification (Pulse check). Stories you choose the audience and length of,
  can edit after posting, and see who viewed, with the views encrypted like messages.

## What the server sees

Pulshade runs its own servers, and the official app talks to nothing else. They're built to know as little as
possible:

- **Not what you say.** Messages, calls, profiles and backups are encrypted on your device, and the server only
  passes on sealed envelopes, padded to a few set sizes. (A public @handle is the exception, by choice: its name and
  picture are there for anyone to look up.)
- **Not who you are.** There are no accounts on the server, only mailboxes named by random numbers, and envelopes
  don't carry their sender.
- **Not where you are.** Over Tor the server sees a made-up address for each connection, never your IP address.
  Each persona and inbox uses its own Tor circuit, so they can't be linked by address.
- **Nothing for long.** Envelopes are deleted once collected, or after 7 days. While they wait they are held in memory and, sealed, in a journal on the server's disk (every record sealed with a key the server keeps only in memory), so a restart, crash or reboot doesn't lose them. Collected mail is overwritten and removed from the journal within minutes.
  Files you send (up to 100 MB) are the one other thing the server keeps on disk besides that journal, profiles and backups: sealed on your
  phone with a key that only travels inside the end-to-end encrypted message, sealed again by the server, erased the
  moment the message is deleted (the server's key for it is destroyed) or after 7 days. A phone only ever holds a
  received file in memory.
  The relay and the web server in front of it keep no request log. Your sealed backup (profile, contacts, groups; never chats) is saved again as things change and erased 180
  days after its last save, so a detached account's waits at most that long for its recovery code. Turn it off in
  Settings and it's erased at once.

The full design, from the key derivations to the decoy passcode's disk layout, is in
[How Pulshade works](docs/how-it-works.md).

## Known limits

An honest list. More detail is in [How Pulshade works](docs/how-it-works.md).

- **Not yet audited** (see above).
- **Tor hides addresses, not timing.** Someone watching both ends of the network could still line up when things
  happen. Unless you turn on bridges (Settings → Network), your network can see you use Tor, though not that it's
  Pulshade.
- **Turning Tor off is a real step down.** It's allowed, for speed, and the app explains first: the server then sees
  your IP address, and your personas can be tied together by it.
- **Disappearing messages and deleted stories trust the other device.** A modified app could keep them, and anyone
  can photograph a screen. A story deleted or expired is gone from every unmodified app, but one posted before
  deleting existed can't be recalled and just runs out its time.
- **One operator.** Everything goes through Pulshade's servers, which can see when and how much traffic flows, but
  never what it says, or who you are behind Tor.
- **Post-quantum keys refresh every 50 messages or a day**, not on every reply, and a refresh makes that message
  larger.
- **Old files on an SSD.** Pulshade replaces its keys every time it locks, but the operating system, not the app,
  decides when old disk blocks are truly erased.
- **iPhone:** messages arrive while the app is open, unless you turn on **Wake when locked** (Settings →
  Notifications), which lets the relay wake your phone through Apple. Apple then learns that it was woken, and when
  (see [wake-up pushes](docs/push-notifications.md)). Screenshots come out blank through iOS behaviour Apple
  doesn't document, so an update could undo that.
- **Outside the app,** your IP address still reaches wherever you downloaded it, and Apple when a Mac first checks
  the app.

## Requirements

macOS 26 or later, or iOS 26 or later.

## Building from source

The code is open so anyone can check what the app and the server do. A build you make yourself is for reading,
testing and auditing: the official app only ever talks to Pulshade's servers.

You'll need Xcode, Rust (`rustup`), Go and, for the iPhone, [XcodeGen](https://github.com/yonaskolb/XcodeGen). The first
build compiles Tor ([Arti](https://gitlab.torproject.org/tpo/core/arti)) and its bridge transports (Snowflake and
webtunnel, from Tor Project's [lyrebird](https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird)),
which takes a few minutes.

```bash
./scripts/build-app.sh debug      # builds build/Pulshade.app, a development build
open build/Pulshade.app
```

```bash
swift test                        # the tests that run on their own, no server needed
```

The apps are in `Sources/Pulshade` (the Mac and iPhone share all their code) and the Tor
bridge in `tor/`. The server is not published.

## Security

Found a vulnerability? Please report it privately, not in a public issue: see [SECURITY.md](SECURITY.md).

## License

Pulshade (the apps and the Tor bridge) is open source under the [MIT License](LICENSE). You can use,
study, change and share it, as long as you keep the copyright and license notice.
Bundled third-party code keeps its own license (`tor/vendor/sysinfo` is MIT).

The license covers the code, not the name: a build or fork you run yourself must use its own servers and a name of
its own, not "Pulshade".

Copyright © 2026 Zeekz.
