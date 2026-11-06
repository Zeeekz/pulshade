# Maintaining Pulshade

Notes for running Pulshade's own server and making its builds. None of this is needed to use Pulshade, or to read
and test the code (see [Building from source](../README.md#building-from-source)).

## The operator's toolbox

The operator runs Pulshade's own server with their own tools, over SSH, through `pulshade-server` on the server
(see [Running the relay on a server](#running-the-relay-on-a-server)). For a relay of your own on this Mac,
`./scripts/run-relay.sh` is all it takes.

The relay keeps its admin token in `admin.token` beside its data (`relay/admin.token` on a Mac), made on first run
and readable only by the relay's own user. Never share it.

**Pulshade Admin** is the operator's own Mac app, separate from Pulshade, which has no admin in it, and isn't part of
this repository. It reaches the relay only over SSH, through `pulshade-server` on the server, so the admin token never
leaves the server. Its keys live in that Mac's Keychain: the admin key signs announcements and the reports mailbox,
and its public half goes in `relay/admin-key.pub`, which every Pulshade build carries. Lose the admin key and you make
a new one, then release the apps again.

**Moderators.** People you trust to read reports and take down or ban handles, and nothing else. In Pulshade Admin,
Team → Let someone in: they install the app, choose "I'm a moderator" and send you a request (a name and the public
half of an SSH key made on their Mac). You paste it, set a passphrase and save the invite file, then send them the
file and tell them the passphrase another way. On the server this adds their key to a locked `pulshade-mod` account
whose every key is forced to run `pulshade-mod-gate` with their name, so they never get a shell. The gate allows
only reading and sharing reports, looking handles up, and taking down or banning handles and accounts; it refuses
everything else (announcements, reserving, backups, restarts, any other mailbox) whatever the app says. It logs
each request with the moderator's name (`pulshade-server mod-log`, or Team → What they did): handles and what was
done, never a report or anything a person wrote. Reports are shared through one list on the server, sealed with a
key made from the reports key, so the server can't read it, and every moderator sees the same open, reviewing and
done reports. A moderator holds the reports key (to open reports) but never the admin key, the admin token or the
reports mailbox's key, which the server keeps. Remove one under Team: they're cut off at once, and keep only what
they'd already opened. Run `pulshade-server update` once first so the server has the gate. The server's side is
tested with `./scripts/server/test-mod-gate.sh`; it hasn't been run against a real server and its SSH setup yet.

**Restarting empties waiting messages.** They are held in memory only, so a restart loses what hasn't been collected.

## Running the relay on a server

The relay can run on any Debian or Ubuntu server with 2 GB of memory or more (smaller ones work, but build slowly).
It needs no open ports: it only listens over its onion address.

**Moving a relay there** keeps its onion address, handles and bans, so the apps don't need rebuilding. Make a tar
file holding the relay's data folder as `data/` and its storage key as `storage.key`, copy it to the server and run
`sudo ./scripts/server/install.sh --import relay-data.tar`, which erases the copy once it's in. Then stop the old
relay for good, since two relays with the same onion keys would fight over the address.

**A new relay** with a new onion address: copy the repository to the server and run
`sudo ./scripts/server/install.sh`. Apps reach it only once they're rebuilt with the new address.

The installer builds the relay, runs it as a `pulshade` user under systemd (it restarts itself and starts with the
server), keeps the storage key in `/etc/pulshade` apart from the data in `/var/lib/pulshade`, lets only SSH through
the firewall and turns on security updates. Running it again updates the relay and keeps its data.

**Wake-up pushes** (optional, for locked iPhones: see [wake-up pushes](push-notifications.md)) need an Apple push key.
Make an APNs key in your Apple developer account (Keys, with the Apple Push Notifications service ticked, for sandbox
and production) and put the `.p8` file on the server as `/var/lib/pulshade/apns.p8`, with its IDs in
`/var/lib/pulshade/apns.json` (`{"key_id": "…", "team_id": "…", "topic": "your.app.bundle.id"}`), both readable only
by the relay's user. Restart the relay to pick them up. Without them `GET /v1/push` says `{"enabled": false}` and
phones don't register. Registrations are kept in memory only, so a restart clears them until each phone renews.

On the server, `pulshade-server` runs it: `start`, `stop`, `restart`, `status`, `logs`, `stats`, `ban @name`,
`backup` and the rest (`pulshade-server help` lists it all). `pulshade-server update` fetches the latest code and
rebuilds it.

Keep a copy of `/etc/pulshade/storage.key` somewhere safe: the server's backups can't be opened without it.

## The server's addresses

- **Onion address.** The server publishes itself as an onion service. Its keys live in `relay/pulshade-onion/` (on a
  server, `/var/lib/pulshade/pulshade-onion/`, and `pulshade-server backup` keeps them), so the address stays the
  same; a new one takes about a minute to be published. `PULSHADE_ONION=0` turns it off.
- **Direct address (optional).** Put the server's ordinary https address in `relay/direct-address` (or set
  `PULSHADE_RELAY_DIRECT`) before building, and the apps can switch Tor off and use it. For testing at home, the
  server's Wi-Fi address works (`http://192.168.x.x:7878`); remove it before making builds for anyone else.
- **Saved data.** The handle directory is `pulshade-directory.json` beside the server (`PULSHADE_DIRECTORY` moves
  it), with moderation in `pulshade-moderation.json`. Both only ever hold what people chose to make public, and both
  are sealed with a storage key from the Keychain. Accounts' sealed backups are in `pulshade-backups/` and
  are erased after 180 days.

## Keeping the server's disk quiet

The server keeps calls, rate-limit counts, waiting messages and wake-up registrations in memory only: none of them
is ever written to disk. What does reach the disk is the handle directory, held handles and moderation lists (sealed
with the storage key) and accounts' sealed backups (no chats). These keep the rest off the disk:

- **Core dumps** are turned off by the server itself, so a crash never writes its memory to a file.
- **Swap.** macOS encrypts swap. On Linux, use encrypted swap or none, or memory can still reach the disk.
- **The storage key** lives in the Keychain. Where there isn't one (Linux), the server won't start until
  `PULSHADE_STORAGE_KEY_FILE` points at a key file somewhere other than the relay's folder (it makes one there on
  first run), so a copy of that folder doesn't carry its own key. A `storage.key` beside the data from an older
  server still works, with a warning to move it.
- **Secrets on disk.** `pulshade-onion/` holds the onion service's private keys: whoever has them can pose as the
  server. With `admin.token`, keep them on an encrypted disk (FileVault), readable only by the server's user.
  `pulshade-server backup` seals the onion keys with the storage key, so a backup can't be opened without it.

## Builds

`build-app.sh` and `install-iphone.sh` build in the server's onion address (from `relay/pulshade-onion/hostname`) and
the creator key, and the direct address if there is one. A release build only ever talks to the server it was built
for; development builds take any.

- **Mac:** `./scripts/build-app.sh` builds `build/Pulshade.app`; quit Pulshade before putting it in Applications.
  Signed with your development certificate when there is one, so the Keychain keeps trusting it across rebuilds.
- **iPhone:** put your signing team in `ios/Local.xcconfig` (`DEVELOPMENT_TEAM = <team id>`), plug the phone in and
  unlock it, then `./scripts/install-iphone.sh`. The Xcode project is generated from `project.yml` by XcodeGen.
- **Icon:** `swift scripts/make-icon.swift Resources/AppIcon.icns` re-renders it (and `Resources/AppIcon.png`).

## Handy for development

- A second identity on the same Mac: `PULSHADE_PROFILE=two build/Pulshade.app/Contents/MacOS/Pulshade`.
- Sample data for reviewing the design (development builds only): `./scripts/build-app.sh debug`, then
  `PULSHADE_DEMO=1 build/Pulshade.app/Contents/MacOS/Pulshade`.
- Tests: `./scripts/test.sh` runs everything against a throwaway server on port 7890, never the real one. The tests
  that go out over the real Tor network are off unless you ask:
  `PULSHADE_TOR_TEST=1 PULSHADE_TEST_ONION=http://….onion swift test --filter TorNetworkTests`.
