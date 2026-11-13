# Sealed store: a design proposal

Status: proposal, for Zeekz to review. Nothing here is built.
Scope: the phone's media store, group mail life, the relay's memory cap, threats, build order.

## 0. The rule this proposal serves

1. The relay only passes sealed mail through. It does not keep anything past transit.
2. Once something lands on a device it is downloaded to that device and kept there, encrypted with our own key.
3. Nothing readable is on any disk, ever. Burn and Detach leave no trace. Temp and cache files count.
4. Deleting really deletes.
5. Wherever Pulshade deletes data, on the phone or the relay, it overwrites the bytes and then deletes the file. Always.
   (Decided by Zeekz, 2026-11-11. See section 5.4 for what this does and does not achieve on flash disks.)

Already decided, not reopened: our own key for everything we write (never only the system's file protection); Burn and
Detach overwrite, delete and destroy keys; we only scrub exact names we made (`TempFiles.isOurs`) and `Caches/<our bundle id>`.

## 1. What is true today (checked in the code, with corrections)

Labels: **[checked]** read in the code or docs; **[brief]** taken from the request, not found in code; **[memory]** from memory, not verified.

| Claim in the brief | What the code and docs say |
| --- | --- |
| Chats live in `data-*.vault`, key from the identity, padded to 64 KB steps | **Right** [checked, `Vault.save`: AES-GCM with `identity.storageKey`, `paddedSize` 64 KB doubling]. |
| Received files are not kept, opened once from memory, the server erases on collect | **Right** [checked, `Attachment.collected` in `Blob.swift`, `docs/blob-store.md`]. |
| Story clips are memory-only | **Right** [checked, `MemoryClip` and `ClipLoader` serve bytes to AVFoundation from a `Data`]. |
| Library videos are read into memory, 250 MB cap on iPhone | **Different in code** [checked, `StoryPlayback.swift`]. The limit is 1.5 GB (`largest`), and the file is memory-mapped, not copied, so it is mostly storage rather than RAM. I found no 250 MB constant; the brief's number may be from an older build. Files sent are capped at 100 MiB (`BlobCrypto.maxFile`). |
| Relay seals every file it writes | **Right** [checked, `sealed.rs`, `journal.rs`, `groups.rs`, `blob.rs`, `docs/how-it-works.md`]. |
| 1:1 mail served from RAM, cap 384 MB, `PULSHADE_MAIL_MIB` | **Right** [checked, `main.rs`: `BUDGET`, 384 MiB default]. |
| What happens at the cap | **Worth knowing, it is not a refusal.** When full, waiting mail *makes way*: oldest story pieces first, then photos, then, only when nothing big is left, short messages (`make_room`). The dropped mail is also removed from the journal. So hitting the cap means offline people silently lose their oldest mail. A 507 only happens if making room is not enough [checked]. |
| Group mail is on disk until the epoch's life ends, 3 days, not erased on read | **Right** [checked, `GroupEpoch.defaultDays = 3`, `groups.rs`]. |

Two things the brief did not say, found while reading:

- **The vault is not crypto-erased on delete.** `data-*.vault` is sealed with `identity.storageKey`, which does not change.
  `identity.lock` and `identity.bio` are wrapped in a Keychain key that is replaced on every rewrite, so old copies in flash
  stop opening. The data vault has no such wrapper. Delete a message, the vault is rewritten, but an older copy of the
  vault left in the SSD's spare blocks still opens with the identity key. The rule "deleting must really delete" is not met
  for chats today, only for the identity file. Section 3.3 fixes this with the same mechanism as the media store.
- **Group media outlives group mail.** A photo or voice note over 48 KB in a shared-mailbox group goes up once with no reader
  tokens and lives its full 7 days on the relay's disk (`docs/blob-store.md`), while the message lives 3 days.

## 2. How Signal does it (from memory, not checked)

| | Signal [memory] | Pulshade today | Pulshade proposed |
| --- | --- | --- | --- |
| Server mail | Held per recipient device, deleted when the device acknowledges; undelivered mail kept up to about 30 days | Held in RAM + sealed journal, deleted on ack, 7 days max | Same, plus a bigger or tiered store (section 5) |
| Groups | Sender encrypts once for all members, the server splits it into each member's own queue. Server sees the recipient list of a send, not which group it is. Deleted on ack. | One shared mailbox, not deleted on read, 3 days | One shared mailbox, 7 days by default (section 4) |
| Attachments | Uploaded encrypted to a CDN, kept about 30 days, key in the message | Relay disk, erased on collect (1:1) or 7 days | Same on the relay; **kept on the phone** |
| Phone store | Messages in an encrypted database, key held by the OS keystore. Attachments: on Android encrypted per file; iOS and desktop have changed over versions and I am not sure of the current state | Vault for chats, nothing for received files | Sealed shelf with per-item keys, rotating wrapper key |
| Delete | Removes the row and file; secure-delete in the database; no guarantee against flash copies | Overwrite then unlink | Destroy the item's key and rotate the wrapper |
| Backups | Optional end-to-end encrypted cloud backup (recent, paid for media beyond a limit) | None, on purpose | None. The user said no server storage |

Where Pulshade differs, on purpose: the relay cannot see group members (shared mailbox), so it cannot delete group mail
on delivery. Signal's server can, because it knows each recipient's queue. That is the cost of hiding membership
(section 4).

## 3. Question 1: a sealed store on the phone ("the shelf")

### 3.1 What the user gets

- Open a received file or video again, any time, until deleted or its chat timer ends.
- Big videos play from disk, not RAM. No more RAM ceiling on what a phone can keep.
- A download interrupted by the app being killed resumes from the last good 1 MiB piece on the next launch.
- Chats stop carrying big media inside the vault. The vault stays small, and each save re-seals less.
  (The docs say a chat video "is kept in the chat". If that means inside the vault, every save re-seals all of it. To check.)

### 3.2 Shape

```
identity.storageKey (needs passcode) ─┐
Keychain shelf key Kk (replaced often) ┴─ HKDF ─> index key Ki ─> seals  shelf-<name>.idx
                                                                       │
          index = list of items: id, item key Kx (32 B), size, kind, chunk map,
                  message reference, expiry, relay blob id and token (for resume)
                                                                       │
          Kx seals the item's file  store/<random>.blk  in 1 MiB pieces (ChaCha20-Poly1305,
          nonce = piece number, bound to the item id, piece number and last-piece flag, as `BlobCrypto` does now)
```

Decisions inside it:

1. **A new random key per item (Kx), not the sender's file key.** The sender's key sits in the message, and so in old
   copies of the vault, and the sender and group members know it. A local key Kx lives only in the index. Cost: one
   decrypt and re-encrypt pass while downloading, which is cheap. Reuse `BlobCrypto` code for the piece format.
2. **The keys are in the index, never in the vault.** A message in the vault holds only an item id and display
   metadata. Delete the item and the only copy of Kx is gone from the live index.
3. **The index is wrapped twice**: by the Keychain key Kk and by the identity's storage key, mixed with HKDF. If only the
   Keychain is stolen (a phone unlocked once and imaged) the shelf stays closed without the passcode. If only the
   passcode is known, a copy of the index from flash is useless once Kk is replaced. Without the second wrap the shelf
   would be weaker than the vault. Reuse `FileKeys`, whose two-key window already makes rotation crash-safe.
4. **Index per identity**, so the decoy and panic identities each have their own, as with the vault.
5. **Files are one per item with random names**, excluded from backups, `0o600`, in a folder `0o700`. On iPhone use
   `completeFileProtectionUnlessOpen` so a download can start while locked. This is a second layer, not the protection.

### 3.3 Delete, and the replaced Keychain key

Delete (user, unsend, timer, chat delete, Burn of a persona) of a batch D:

1. Make a new key Kk'. Keychain now holds `[Kk, Kk']` (the `FileKeys.store` window, so a crash never strands the index).
2. Write a new index without D, under Ki' made from Kk', atomically. It lists the files still to be erased.
3. Keychain keeps only `[Kk']`. Old copies of the index in flash can no longer be opened.
4. Overwrite each file in D with random bytes and unlink it. Remove it from the pending list.
5. On launch, if two keys are found or the pending list is not empty, finish steps 3 and 4.

User deletes run at once. Timer expiries are batched (every 30 seconds, at lock, at unlock), so a burst is one rotation.
Rotation needs the identity key, so it only runs unlocked. Lock also rotates, as `identity.lock` does now.

**The same fix for the vault.** Wrap `data-*.vault` the same way and rotate Kk after every delete batch and at every
lock. Rotating on every save is not needed, only when something was deleted. This closes the gap in section 1.
It is the first stage because the shelf depends on it and it is the smaller change.

Rough cost: an index of 150 bytes per item is 1.5 MB at 10,000 items. A Keychain write is tens of milliseconds on an
iPhone (to measure, not measured). Fine for deletes, not for every save.

### 3.4 Receiving, resuming, playing

- **Receive:** the message arrives with a pointer. The phone makes a partial item (index entry with chunk map, blob id,
  relay token) at the first piece. Each 1 MiB piece is fetched, opened with the file key, checked, re-sealed under Kx,
  written at its place, and the chunk map saved. Only after every piece is checked and the sha256 matches does it send
  `done` (the relay then erases it). Relay protocol is unchanged.
- **Resume:** after a kill, the relaunch finds partial items and asks the relay for the missing pieces (`head`, `Range`).
  This works as long as the relay still holds the file. Honest limit: Tor runs inside the app (Arti), so nothing downloads
  while the app is not running. "Resume" means on next launch, not in the background.
- **Play and open:** `ClipLoader` today reads a `Data` in memory. Make it read from a small `ByteSource` (count, read a
  range). Add `ShelfSource` that opens only the pieces a range needs and keeps a few in a small memory cache. Plain bytes
  exist only in memory. `MemoryClip` stays for clips just recorded or edited. AVFoundation already reads through the
  loader for play, export and poster, so no plain temp file is needed.
- **Send:** the same shelf holds what you sent, so you can reopen it. Today a library video is read into memory first;
  streaming it into the shelf removes the RAM ceiling for sending too.
- **Save a copy** stays as an explicit, labelled exception: Photos and Files need a plain file. System viewers
  (QuickLook, share sheets) also need one and must stay behind that same warning.
- **Where a plain copy may still appear (to check in code):** the picker's copy (`story-pick-` in the temp folder) and
  the camera's recording (`story-rec-`). Both are ours and already swept, but there is a window between creation and
  sealing. Narrow it by sealing at once and scrubbing on `TempFiles.sweep`.

### 3.5 How it fits the rest

| Feature | What changes |
| --- | --- |
| Disappearing timers | Item expiry copied into the index. A sweep deletes due items in one batch. A timer that ran out while locked is processed at unlock before any chat is shown. Honest limit: the other device may ignore the timer (already in the docs). |
| Single vault | Vault holds item ids and metadata only. A copy of the vault from flash shows that a file of N bytes and a name existed (same as today's message metadata), never its content or key. |
| Decoy and panic | Each identity has its own index. The panic passcode shreds all indexes with the vault files. **The shelf's size is visible on disk** and cannot be hidden like the vault's (four same-sized files): a decoy account that looks empty beside gigabytes of sealed files is not credible. Decided: this becomes a setup choice, "Hide how much I keep" (section 3.7), off by default. |
| Device linking | The shelf does not move by itself. The new device shows "on your other device" and can ask for it (a fresh blob with a new key, erased on collect). First release: leave it out. |
| Sealed relay backup | Unchanged. Never holds chats or media. Moving to a new phone without linking means starting empty. Say so plainly in Settings. |
| Detach, Burn, panic | Delete the Keychain item (Burn: delete outright; Detach: replace then delete), overwrite and unlink every `.blk` and `.idx`, remove the folder. Add the shelf to `Vault.destroy` and `scrubLeftovers`, and to the "what's on the disk" paragraph in `docs/how-it-works.md`. |
| Storage | Add Settings → Storage: size, per chat, "keep media for forever / a year / 30 days / 7 days". Default: until deleted. Without it the shelf is a surprise. |

### 3.6 What it does and does not promise

Works on iPhone and Mac the same way, because the protection is the key, not the file system:

| | iPhone | Mac |
| --- | --- | --- |
| Why deleting works | The item key and the old index wrapper are destroyed. A stray copy of the file or the old index in flash is ciphertext whose key is gone. Needs the new key to be really gone from the Keychain. | Same. FileVault encrypts the volume but is not what we rely on. |
| What can still leak | Old Keychain database rows left in flash (protected by Apple's class keys, so recovery would still need the device and the passcode). Wear levelling keeps stale ciphertext. | APFS is copy-on-write, so overwrite-in-place does not overwrite. Local snapshots (Time Machine) may hold older copies of our files and of the Keychain. The double wrap exists mainly for this: an old index plus an old Keychain also needs the passcode. |
| To check before shipping | That `FileKeys` items are in the data-protection keychain on the Mac (`kSecUseDataProtectionKeychain`); I found no use of it in `Sources`. That `isExcludedFromBackup` keeps the folder out of Time Machine snapshots. | |

**It does not guarantee:** deletion from flash (the drive decides when blocks are erased; only the key makes it
unreadable); copies on other people's phones; screenshots and screen recordings (screen protection is a best effort);
anything if someone gets the passcode **and** an old Keychain row **and** an old index (a rare, real window, same as the
"Keychain is on the same disk" limit in the docs); the other device honouring a timer; and nothing about the system's own
caches for things we hand to the system (notification text, Photos).

### 3.7 Setup choice: "Hide how much I keep" (decided)

Offered once, during setup, and changeable later in Settings → Storage. Off by default. In plain words for the screen:

> **Hide how much I keep**
> Pulshade keeps your photos, videos and files locked on this phone. Anyone who gets hold of your phone and looks at its
> storage can see *how much* Pulshade is holding, even though they can't open it. If you use a decoy passcode, that is a
> clue: a "fake" account that looks empty but sits next to gigabytes of locked data.
> Turn this on and Pulshade reserves a fixed amount of space and fills the rest with random noise, so the amount
> looks the same however much you really keep.
> **The cost:** the space is used up on your phone from the start. Pick a size: 1 GB, 4 GB or 10 GB.
> If you don't use a decoy passcode, you can leave this off.

How it works: a pool of fixed-size segment files (for example 64 MB each), filled with random bytes up front, shared by
every identity on the install. The index says which pieces of which segment belong to which item; delete overwrites that
range with random bytes, so a half-empty pool looks the same as a full one. When the pool is full the phone asks
before growing it (growing shows a size change). Without the choice, items are stored one file each (section 3.2).
This is an extra to build after the shelf itself works. It is honest about its limit: someone watching the phone's
free space over time can still see the pool grow if it has to grow.

## 4. Question 2: group mail on the relay

**Can the relay delete on delivery without learning membership? No, not honestly.** Every scheme needs the relay to
count readers, and counting readers is the leak:

| Idea | Why it fails |
| --- | --- |
| Delete when everyone has read it | The relay must know how many "everyone" is (group size). |
| One-time read tokens per member per message (as for 1:1 blobs) | N tokens per post: 5,000 members × 33 bytes = 165 KB per message, and it names N. Padding N to a power of two hides little. |
| A per-member verifier the relay holds | A stable identifier per member. The relay can count members and see each one's reading pattern. |
| Signal's way (per-recipient queues) | The relay sees the recipient list of every send. Exactly what the shared mailbox was built to avoid (`groups-design.md` section 1). |

**How others do it (from memory, not checked).** Telegram keeps ordinary chats and all group chats on its servers for good
(its servers hold the keys, so they are not end-to-end private), which is why nobody there misses a message. Signal keeps
undelivered mail for about 30 days and then drops it. Pulshade's rule is that the server keeps nothing it doesn't have to,
so a time limit is unavoidable. The honest choice is how long.

**Recommendation: a fixed life plus catch-up. Stop looking for delete-on-delivery. Default 7 days.**

Zeekz's goal is that nobody misses or loses a message. Build 14 cut group mail from 7 days to 3 as a tidy-up, not because
anything needed it. Group mail lives on the relay's disk, not in its RAM. It is not free: a group may add 50 MiB a day, so 350 MiB over a
week, and the group store's cap is 1 GiB (`DEFAULT_CAP`, `groups.rs`), so fewer than four saturated groups fill it and
then every group's deposits are refused. Stage 0 must raise that cap (`PULSHADE_GROUP_MIB`) or lower the per-group daily
limit, and add group-disk bytes to the counters. Going back to 7 days matches 1:1 mail (also 7) and a holiday-length gap. The privacy cost is a
longer window in which a hostile server host could copy sealed mail; it cannot open it, so this is small.

1. Default **7 days**; admins may choose less (1 to 7). This is advisory: each envelope carries its own life and the
   relay accepts any 1 to 7 (`groups.rs`), so a member can post at 1 day or at 7. Receivers should post again, or
   ignore a life shorter than the group's setting. A group that never wants anything held can pick 1 day and accept
   that people offline for longer will miss messages.
2. **Make group media follow group mail:** send the blob's days header equal to the group's life (it already takes 1 to 7).
   With a 7-day default this changes nothing for most groups, and keeps a short-life group's media from outliving its mail.
3. **Phones drop old epoch keys** once the epoch's life plus the catch-up window have passed. Today (to check) a seized
   phone plus a copied relay segment could still open old group mail while the epoch key exists. Deleting the epoch key
   is the group-mail equivalent of forward secrecy.
4. Say it plainly in the privacy page: group mail waits on the relay up to 7 days, sealed, because the server must not
   know who reads.

Trade-off: a member away longer than the life depends on someone online still holding their posts (14 days, 200 posts or
2 MB per group). A channel follower cannot ask, so can miss posts. Unchanged by this proposal.

## 5. Question 3: the relay's memory cap

### 5.1 How many people hit 384 MiB?

Waiting bytes ≈ installs × (share active × envelopes a day ÷ 24 × hours a closed app waits × size) + stranded mail.
Envelope sizes are 2 KB, 8 KB, 32 KB, 128 KB (`EnvelopeCore` buckets); most are 2 KB. Mail from an iPhone user's contacts
waits whenever the app is closed and "Wake when locked" is off (it is on by default, so this is mostly phones whose owners turned it off).
Stranded mail is mail to phones that are off, lost or uninstalled, until its 7 days end. The budget counts envelope bytes;
resident memory at the cap was about 1.35 × that (511 MiB in the 2026-11-10 test).

| Scenario | Active | Envelopes a day each | Average size | Wait | Stranded | Per install | Installs to fill 384 MiB, even load | At an evening peak (2×) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Light | 30% | 60 | 2.5 KB | 3 h | 5% of installs, 30 each | about 9 KB | about 45,000 | about 22,000 |
| Likely | 50% | 150 | 3.5 KB | 3 h | 5%, 100 each | about 50 KB | about 8,000 | about 4,000 |
| Heavy | 70% | 300 | 5 KB | 4 h | 10%, 300 each | about 325 KB | about 1,200 | about 600 |

All assumptions are guesses. The spread is 70 times. Day-one numbers: 1:1 chat is a thin trickle, so **I expect "Likely"
or better, with the heavy tail coming from stranded mailboxes and from small stories** (an unwatched 30 KB photo story to
300 contacts is about 9 MB waiting). The one measurement that settles it: bytes waiting divided by installs active in
the last day. Live now is about 33.5 MB (9%); with the install count that gives KB per install directly. (Ask: how many
installs are there right now?)

**What the cap does when hit** (section 1): offline people's oldest mail is dropped quietly, big first, text last. For a
messenger that is the worst way to fail, which is why the cap matters more than the 9% suggests.

Also worth knowing: one stranded mailbox can hold up to 2,000 envelopes (`MAX_QUEUE`), about 6 MB at 3 KB. About 64 of
those alone fill the cap.

### 5.2 Options

| Option | Fixes | Costs | Verdict |
| --- | --- | --- | --- |
| **Bigger server plan** | Cap scales with RAM. Load test: resident is about 1.35 × budget plus 224 MiB for the leaving and in-flight budgets. A 4 GB plan allows a budget near 1.2 GiB. | Money (price not looked up; plan change is due by 2026-12-02 anyway). CPU stays 1 core unless the plan adds one. Traffic: 1.5 TB a month is about 580 KB/s, and every file crosses the relay twice, so about 25 GB of media a day in total. | **Do this.** Cheapest and safest. |
| Serve 1:1 mail from the disk journal | Cap becomes the disk (15 GB). | Group test: 4 to 9 ms CPU a post from disk, against about 1 ms from memory. On 1 core, a plausible 2 to 4 times slower than the Mac used, that is most of a core at a few hundred reads a second. The ten-minute journal rewrite under the lock gets worse. | **Superseded: Zeekz decided to do this** (section 5.4). |
| **Spill, not drop** (a middle way) | At the cap, push the oldest mail to the disk journal (kept, indexed in memory) instead of removing it. Common path stays 1 ms. Only a returning offline phone reads from disk. | Medium work in `main.rs` and `journal.rs`; groups already have the segment and cursor machinery to copy. | Build **only if** measured peak passes about 50% of the new cap. |
| Shorter retention for offline recipients | Cuts the stranded tail (7 → 3 days is about 2.3 times less). | A phone away over a long weekend loses 1:1 mail. 1:1 senders do not resend after the relay says 202, so the loss is silent. | **No** for 1:1. |
| Cap policy: per-mailbox byte cap, alarms | One dead friend cannot take 6 MB. Per-mailbox cap no less than twice the largest piece (`MAX_ENVELOPE` is 4 MiB, and a video story piece is 4 MiB per recipient), so 8 MiB or more, or count bytes with the rank logic in `make_room_for_stranger`; alarm at 50% and 80% of budget. | Tiny code. A very quiet cap shortens mail for heavy chatters, so tune. | **Do this** with the plan change. |

### 5.3 Recommendation

1. With the plan change (before 2026-12-02): take a plan with at least 4 GB RAM; set `PULSHADE_MAIL_MIB` about 1,100 and
   `MemoryMax` to match; keep the load-test ratio. Do not raise the budget on the current 1.4 GB server (per the load test).
2. Add the per-mailbox byte cap and counters for peak bytes waiting and distinct mailboxes, so the next review has data.
3. **Changed by the decision in 5.4:** 1:1 mail waits on the sealed disk store with a RAM cache, not RAM alone. The memory
   budget stops being the limit, so the plan size is a smaller question than above. The bigger-plan advice still helps CPU
   and the cache, but is no longer urgent.
4. If the new plan has 2 cores, the group disk-read cost stops being the first thing to hurt. (A small cache of opened group
   records, noted in the load test, would also help; not built.)

### 5.4 Decision: mail waits on the disk, not in memory (Zeekz, 2026-11-11)

Zeekz chose to stop treating RAM as the store. The relay only passes mail through, always sealed, and a message is
overwritten and deleted from the server as soon as the phone has it. This replaces the plan to wait and measure. It also
removes the quiet-drop problem: the limit becomes disk space, and a full disk refuses new mail (507) instead of dropping
old mail, which the apps already handle.

**Shape (reuse what group mail already does, `groups.rs`):**
- Mail is written in segments, each sealed with its own key held in the sealed index. A small index in memory says where
  each envelope is. RAM holds the index and a bounded cache of recent mail, so the common path (deposit, then the
  recipient collects within a second or two) stays about 1 ms and does not touch the disk for reading.
- The disk copy is the source of truth, written before the 202. A restart loses nothing, as now.
- **Collected means gone:** when a phone acks, its envelopes are marked dead. A segment whose envelopes are all dead has
  its key destroyed, its bytes overwritten and the file deleted at once. A segment kept alive by one slow reader is
  rewritten (live envelopes only) when it is mostly dead, so a stranded mailbox cannot keep other people's collected mail
  on the disk for days. The old ten-minute whole-journal rewrite goes away; it was the pause the load test found.
- Disk budget on the 15 GB server, split so no one use starves the others: blobs 8 GiB today, group mail 1 GiB today,
  and 1:1 mail needs its own share (a first guess is 2 GiB, tuned with the counters). Revisit the blob and group shares
  together.
- Per-mailbox limits stay (`MAX_QUEUE`, plus the byte cap in 5.2), so one dead mailbox cannot take the share.

**Costs, honestly:**
- On the 1-core server, disk reads cost more CPU than memory (the shared-group test showed 4 to 9 ms a post against about
  1 ms). The cache keeps this off the common path, but a returning phone that was offline for days reads from disk. Measure
  with the load test before and after (`relay/loadtest`, the 1:1 stages); the group test is the nearest evidence, not proof.
- More writes to the disk, so more wear. Small compared with the 1 TB scale of a VPS disk, but measure.
- Medium work in `main.rs` and `journal.rs`, and a security review of the changed delete path (erase on ack, compaction).

**Overwriting: what it does and does not do.** Zeekz asked for overwrite-then-delete everywhere, and the proposal now
says to do it everywhere (streamed in chunks, not in memory; synced before delete). It cannot be the guarantee, because a
flash drive or a copy-on-write disk writes the new bytes somewhere else and erases the old blocks when it chooses. What
makes the data unreadable is that the key is destroyed. So the rule is both: destroy the key *and* overwrite *and* delete.
One detail: overwrite with random bytes rather than zeros. Zeros and random are equally safe against a person reading the
disk, but some drives compress or skip all-zero writes, so zeros may not actually overwrite anything; random bytes also
match the code's existing habit (`shred`, `Data.random`). If Zeekz prefers zeros, nothing breaks; say so.

**Where this rule is not yet true in the code today** (from the security check): `Vault.shred` loads a whole file in
memory, `scrub(item:)` skips files over 64 MB, and `destroy` covers only lock, vault and bio files. Stage 0 and stage 1
fix these first.

## 6. Question 4: threats

| Threat | What they get | What stops the rest | Honest limits |
| --- | --- | --- | --- |
| **Seized phone, locked, never unlocked since boot** | Ciphertext only. Keychain keys with "after first unlock" are not released before the first unlock. | Passcode, Secure Enclave binding (`identity.lock`), our keys | A weak passcode is attacked on the device, throttled by the Secure Enclave and our own wait counter. |
| **Seized phone, unlocked once since boot** | The Keychain items can be read by someone with the right tools. | The shelf and vault need the identity key (passcode) as well as the Keychain key, because of the double wrap | The vault today does not have that second wrap for its rotation, only the identity key. Section 3.3 adds the Keychain wrapper. |
| **Coerced passcode** | Everything. | Decoy and panic passcodes | Shelf size gives away a lot (question A). |
| **Forensic recovery from flash** | Stale ciphertext of deleted files, old index copies, possibly old Keychain rows. | Item keys destroyed; Keychain wrapper replaced after each delete | Needs the passcode plus an old Keychain row plus the old index. Not zero, and not provable. |
| **Seized or hostile relay host, disk only** | Sealed journal, sealed segments, sealed blobs. Nothing opens: the storage key is not on the disk. | Storage key in a RAM-only folder and on the operator's Mac | Like any disk copy, it shows sizes and times of mail. |
| **Hostile host, RAM snapshot or live access** | The storage key and all mail in RAM, still end-to-end sealed. They can read metadata: which mailbox, when, how big, and, in Fast mode, IP addresses. | End-to-end encryption; Tor hides addresses | Cannot be fully fixed on a rented server. Say so; the privacy page already does. A host could also copy the sealed group mail for later (a reason not to keep it longer than a week). |
| **Hostile group member** | Everything they were sent while a member; keys they hold; can post junk; can keep a copy forever. | Removal makes a new epoch they never get; sender chains; signed settings | Cannot be un-sent; a screenshot cannot be stopped; a member who was removed keeps what they had. Hostile admins can disrupt (already in the design). |
| **Another person's phone** | Everything you sent them. | Nothing technical | Disappearing messages are a request, not a force. |

## 7. Question 5: build order and review

| Stage | What | Needs independent review before it ships? |
| --- | --- | --- |
| 0 | Relay: **1:1 mail on the sealed disk store (5.4)**, erase-on-ack with overwrite, streamed shredding that covers every file type, plan, `PULSHADE_MAIL_MIB`, per-mailbox cap, counters, group blob life = group mail life. No phone change. Do this first and alone. | Light: a review of the cap and eviction change only. |
| 1 | Key wrapper and rotation (`FileKeys` extension), applied to **the vault first**; tests for crash windows; a forensic check: write a canary, delete it, image the data folder, search for it and for the old key | **Yes.** This is the part that has to be right: key hierarchy, rotation order, crash recovery, decoy and panic behaviour. |
| 2 | The shelf: item format, index, delete batches, Burn and Detach hooks, Settings → Storage | **Yes**, with stage 1 as one review. |
| 3 | Download to the shelf with resume; open from it; `ByteSource` in `ClipLoader`; keep sent media | Yes for the storage path; a normal code review for the playback. |
| 4 | Timer integration, "keep media for…" setting, update `how-it-works.md` and the privacy page (it now says phones do not keep files) | Doc review only. |
| 5 (later) | Device-link media transfer; spill-not-drop on the relay; epoch-key dropping if not already done | Yes for anything that sends keys. |

**Stage 0, relay part: built (2026-11-11, branch build-14, not deployed).** 1:1 mail now waits on the relay's disk in
sealed segments (the relay's mail-on-disk module and its `Store`), written before the 202, with a bounded cache of recent mail
in memory. Collected mail is dead at once; a segment with nothing alive in it has its key forgotten, is overwritten
and deleted within a fraction of a second; a mostly dead segment is rewritten with only what is alive (immediately when
burned or recalled mail was in it); the ten-minute whole-journal rewrite is gone. A full share answers 507 and drops
nothing (`make_room` now only runs in memory-only mode, `PULSHADE_MAIL_JOURNAL=0`, and in tests). New settings:
`PULSHADE_MAIL_DISK_MIB` (2048), `PULSHADE_MAILBOX_MIB` (64, big mail may use seven eighths so a text always fits),
`PULSHADE_MAIL_CACHE_MIB` (64); `PULSHADE_MAIL_MIB` no longer matters on the disk store. The first start moves an old
journal's mail into the segments and erases the journal. Old sealed files that were only unlinked when replaced (blob and
backup indexes, the directory, backups) now go through overwrite-then-delete, and the backup and spool erasers stream. The
stale comment at the old `main.rs:53` is replaced. Counters: `stats` gains `diskShares`, bytes and envelopes waiting on
disk, cache bytes, peaks, distinct mailboxes, segments, group disk bytes (see `relay/LOAD-TEST.md` for numbers).
**After the security review of the disk store (2026-11-11):** mail for a mailbox nobody has collected from is held to a quarter
of the share and slots, 4 MiB and 100 envelopes a mailbox, and 2 days; the rest is kept for mailboxes a phone has collected
from (details in `relay/OPERATIONS.md`). Records are sealed for their segment and place and padded to size buckets, a failed
erasure or dead-log write is retried or forces a rewrite, and the old journal is kept until all its mail is on the disk.
**Left in stage 0:** the independent review of the erase and rewrite path (listed in `docs/audit-pack.md`); tuning the
shares with real counters (2 GiB mail, 8 GiB blobs, 1 GiB groups on a 15 GB disk: the group cap is still 1 GiB, raise
`PULSHADE_GROUP_MIB` or cut the per-group daily limit before 7-day group life ships); group blob life = group mail life
(an app change); the plan change and the live deploy (needs Zeekz's say-so, friends are on TestFlight); and the app-side
and relay-side parts of stages 1 to 5, which are untouched. Not done on purpose: the Tor onion identity file and
`admin.token` are replaced by rename and not overwritten (they are secrets the relay keeps, not mail).

"Independent" means someone who did not write it. An in-house security pass is a good first filter but is not that.
The ratchet and handshake are not yet audited either (`how-it-works.md`, "Known limits"); the shelf's maths is simple
(standard sealing, standard key derivation) and its risk is in the delete and crash order, so a short, targeted review is
enough, but it should include running the forensic test on a real iPhone and a real Mac, not only the simulator.

## 8. What I recommend (the short version)

1. **Do the relay and plan work first** (stage 0). It is small and removes the quiet-drop risk.
2. **Build the shelf**, but start with the vault's key wrapper, since "deleting must really delete" is not true for chats
   today.
3. **Keep group mail short-lived**: 7 days by default (shorter if admins choose), group media matched, old epoch keys deleted. Do not try to delete
   on delivery.
4. **Do not move 1:1 mail to disk** yet. Spill instead of drop, only if measured.

## 8b. Findings from the in-house security check (2026-11-11)

A read-only review of this proposal against the code. It is a first filter, not the independent review. Everything below
is folded into the stages in section 7.

| # | Severity | Finding | What the design must say |
| --- | --- | --- | --- |
| 1 | High | The key-drop step can fail silently: `FileKeys.revoke` and the drop use `try?`, and the next write reloads every surviving key. A failed drop would keep the old wrapper and "deleted" items stay recoverable. Nothing checks the new index opens before the old key goes, so a Keychain error could lose everything. | A delete counts as done only when the new index has been read back under the new key, the old key is confirmed gone from the Keychain, and the item keys are destroyed. A failed drop is retried on a timer and at launch, and the delete shows as incomplete until it succeeds. The `FileKeys` window needs a retry loop, which it has not got today. |
| 2 | High | Per-identity Keychain items on the vault break decoy deniability: only real identities would have an item, and `FileKeys.accounts()` lists them all, so someone reading the Keychain after one unlock sees which `data-*.vault` files are real. | Make dummy Keychain items for every filler and decoy file and rotate them on the same schedule, or use one shared item for all identities. Add to the stage 1 forensic test. |
| 3 | High | Wiping big files: `Vault.shred` writes `Data.random(size)`, which holds the whole file in memory, and `scrub(item:)` skips files over 64 MB. "Overwrite every file" is wrong for multi-GB `.blk` files. `destroy` (Detach, panic) shreds only `lock`, `vault` and `bio`, so `.idx` and `.blk` would stay. | Wipe order: Keychain key, then index, then blocks. Overwriting is best effort and streamed in chunks; the guarantee rests on the key, not the overwrite. Extend `destroy` to `.idx` and `.blk`. |
| 4 | Medium | Partial downloads: the index holds blob ids and tokens, so `BurnOrder.blobs` must include them or `done` never fires. A partial item whose blob expired needs a "gone, ask the sender again" state. Pieces and the index must be synced to disk before the chunk map is saved and before `done` is sent, or a crash after `done` loses the file. Rewriting a piece under the same nonce is safe only if the bytes are identical. A sender could fill the disk with pointers. | Add all of these to section 3.4: a per-write random nonce stored with each piece, a cap on partial items per contact, automatic download only from accepted contacts. |
| 5 | Medium | Group life 7 days is not free (see section 4). | Raise the group store cap or lower the per-group daily limit in stage 0. |
| 6 | Medium | Admin-chosen group life is not enforced by the relay. | Treat it as advisory (section 4). |
| 7 | Medium | A 2 MiB per-mailbox cap would make video story pieces undeliverable. | Cap at 8 MiB or more (section 5.2). |
| 8 | Medium | Eviction as an attack: deposits are anonymous and `make_room` evicts the oldest big mail relay-wide, so junk spread over many mailboxes through fresh Tor circuits can push out real mail. Not confirmed how fast; treat as possible. | Add to the threat table. Mitigation: a per-caller-class share of the budget. A bigger cap only slows it. |
| 9 | Low | On the Mac, `FileKeys` uses the file-based login keychain (no `kSecUseDataProtectionKeychain`). Row deletion there is not secure and snapshots may hold old rows. | Make this a blocker for stage 1. State plainly that the Mac guarantee is weaker than the iPhone one. |

**Threat table gaps** (to add to section 6): crafted media from a malicious contact or member (parser attack surface, disk
fill); another process running as the same Mac user; plain bytes in memory and in swap (the shelf's read cache; Mac swap
is protected only by FileVault); Spotlight and QuickLook thumbnails and app-switcher snapshots; file sizes and
modification times on disk; linking of resumed `Range` fetches of one blob id across launches (Fast mode shows the IP
address); someone deleting or rolling back the index, which loses data. Also: the row "needs the passcode plus an old
Keychain row plus the old index" is overstated, since anyone with the passcode and the device can already open the
current vault. Reword it to say what old copies add (deleted items).

**Unverified claims:** that phones drop old epoch keys (still unchecked; `groups-design.md` says only that epochs are
replaced on removal and at least every 30 days); the Keychain write time; the Signal and Telegram comparisons (from
memory). A code comment in the relay says deposits are refused (507) at the cap, which contradicts the code
(mail makes way); fix the comment, not this proposal.

## 9. Decisions (Zeekz, 2026-11-11)

- **H. 1:1 mail on disk, overwrite and delete everywhere:** decided; section 5.4. Open: overwrite with random bytes rather
  than zeros (recommended), and the disk share for 1:1 mail.

- **A. Decoy and panic with a shelf:** a setup choice, "Hide how much I keep", off by default, in plain words (section 3.7).
- **B. Keep media:** until deleted, with a Storage screen.
- **C. Group mail life:** 7 days by default so nobody misses messages; admins may shorten it. (Groups themselves last
  until deleted. This is only how long the relay holds mail for people who are offline.)
- **D. Server:** five people use it now. Do not pay for a bigger plan early; take the cheapest plan with 2 GB or more at
  the 2026-12-02 change (measure before setting `PULSHADE_MAIL_MIB`: the load-test ratio gives a budget of only about
  1 GiB at 2 GB, with no margin for Tor and the OS), add the counters, and upgrade when the measured peak says so. The 4 GB advice in section 5.3
  is for hundreds or thousands of active users.
- **E. Library video limit:** the code says 1.5 GB (mapped), not 250 MB (section 1).
- **F. Moving to a new phone:** accepted. A new phone starts without old media unless linked from a working old one.
- **G. Review:** an in-house security check, done (section 8b), and an independent review of
  stages 1 and 2 before they ship, arranged by Zeekz.
