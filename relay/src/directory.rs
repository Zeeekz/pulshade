//! The public @handle directory.
//!
//! Only people who opt in appear here. An entry is an opaque, signed profile blob plus the
//! Ed25519 key that signed it. The first key to claim a handle owns it; only that key can
//! update or remove it, and a removed handle stays held for that key for three months, so a name
//! can't pass straight to someone else and an old link or a name passed on by word of mouth can't
//! reach a stranger. An account may have three handles at most, listed and held together. Lookups are by exact handle only: there is no listing or search,
//! so the directory can't be downloaded. Unlike mailboxes, entries are public by choice and
//! saved to disk so they survive a restart.

use axum::http::StatusCode;
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use crate::sealed::Sealer;
use sha2::{Digest, Sha256};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    net::IpAddr,
    path::PathBuf,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

/// Room for a picture and a banner.
pub const MAX_PROFILE: usize = 512 * 1024;

/// How long a handle that's let go of stays held before anyone may claim it: three months.
pub const HOLD_SECS: u64 = 90 * 24 * 3600;

/// How long a handle its owner lets go of early stays unclaimable, so it can't pass straight to someone
/// else who then gets messages meant for the last owner: 30 days.
pub const COOL_OFF_SECS: u64 = 30 * 24 * 3600;

/// Handles one account may have, listed and held together, so nobody can use up names by
/// claiming and letting go of them.
pub const MAX_HANDLES: usize = 3;

/// A handle no longer listed.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
struct Hold {
    /// A hash of the key it's held for. None once its account burned: nobody may claim it, and
    /// nothing on the relay ties it to anyone.
    key: Option<String>,
    /// When it was let go of, in seconds since 1970.
    since: u64,
    /// When it frees up, if not three months after `since`: a handle let go of early cools off for less.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    until: Option<u64>,
}

impl Hold {
    fn ends(&self) -> u64 {
        self.until.unwrap_or(self.since + HOLD_SECS)
    }

    fn live(&self) -> bool {
        now() < self.ends()
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Entry {
    /// Base64 Ed25519 public key that owns the handle.
    pub key: String,
    /// Base64 profile blob; the relay never looks inside.
    pub blob: String,
    /// Base64 signature over `"pulshade.dir.v1" | handle | updated (u64 BE) | blob`.
    pub sig: String,
    /// Seconds since 1970, chosen by the owner. Each update must be newer than the last.
    pub updated: u64,
}

#[derive(Deserialize)]
pub struct Removal {
    /// Base64 signature over `"pulshade.dir.del.v1" | handle | ts (u64 BE)`.
    pub sig: String,
    pub ts: u64,
}

/// "Which handles are mine?", answered only for whoever holds the key.
#[derive(Deserialize)]
pub struct OwnerProof {
    /// Base64 Ed25519 public key.
    pub key: String,
    /// Base64 signature over `"pulshade.dir.mine.v1" | key bytes | ts (u64 BE)`.
    pub sig: String,
    pub ts: u64,
}

/// A handle the key let go of, still held for it until `until` (seconds since 1970).
#[derive(Serialize, Debug, PartialEq)]
pub struct HeldFor {
    pub handle: String,
    pub until: u64,
}

#[derive(Serialize, Debug, PartialEq)]
pub struct Owned {
    pub handle: String,
    pub entry: Entry,
}

/// A collectible the operator gave an account: number `serial` of `item`, signed by the Pulshade Admin key over
/// `"pulshade.collectible.v1" | item | 0 | serial (u32 BE) | owner key bytes`. The apps check that signature against
/// the key built into them; the relay only keeps the numbers in order, behind the admin token.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Grant {
    pub item: String,
    pub serial: u32,
    /// Base64 Ed25519 public key of the account it was given to.
    pub owner: String,
    pub sig: String,
    /// Taken back by the creator: no longer handed to its owner, but its number stays used.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub taken: bool,
    /// Let go by its owner: it belongs to nobody, and the next egg that rolls this item hatches this number again
    /// before any new one is made. The owner is forgotten, so nothing ties the number to whoever had it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub released: bool,
    /// A hash of the owner's backup code (base64 SHA-256), which brings it back to whichever account enters the code.
    /// It's what keeps a collectible through a burn: the relay then forgets the owner and keeps only this.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    /// Claimed with its code by this key (base64), waiting for the admin app to sign it over.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claim: Option<String>,
}

/// A collectible as its owner sees it: the signed grant, and whether a backup code is set for it.
#[derive(Serialize, Debug, PartialEq)]
pub struct Mine {
    pub item: String,
    pub serial: u32,
    pub owner: String,
    pub sig: String,
    pub coded: bool,
    /// How many of this item there can be, so the app can tell which number is the last.
    pub limit: u32,
}

/// A backup code set by the owner for one collectible: proof over `"pulshade.collect.code.v1" | item | 0 | serial
/// (u32 BE) | code hash bytes | ts`.
#[derive(Deserialize)]
pub struct CodeSet {
    pub key: String,
    pub sig: String,
    pub ts: u64,
    pub item: String,
    pub serial: u32,
    /// Base64 SHA-256 of the code.
    pub hash: String,
}

/// A backup code entered in another account: proof over `"pulshade.collect.claim.v1" | code hash bytes | ts`, so the
/// code can only be claimed for the key that signed.
#[derive(Deserialize)]
pub struct Claim {
    pub key: String,
    pub sig: String,
    pub ts: u64,
    pub code: String,
}

/// What a backup code brought back.
#[derive(Serialize, Debug, PartialEq)]
pub struct Claimed {
    pub item: String,
    pub serial: u32,
}

/// A giveaway: a limited run of one collectible, for the first people to enter its code while it's open. The relay
/// keeps only a hash of the code, so a leaked file doesn't give it away, and counts the claims in the order they came.
/// The admin app then signs each one over to the account that claimed it, one number at a time, as for any other.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Giveaway {
    /// A short name the operator picks, like `bonfire-2026`.
    pub id: String,
    pub item: String,
    /// Base64 SHA-256 of the code as `normalised_code` makes it.
    pub hash: String,
    /// Seconds since 1970: when it opens and when it closes.
    pub opens: u64,
    pub closes: u64,
    /// How many people can claim.
    pub max: u32,
    #[serde(default)]
    pub claims: Vec<GiveawayClaim>,
}

/// One account's place in a giveaway. `done` once the admin app has signed its collectible. A burned account's key is
/// blanked, so the place stays used but names nobody.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct GiveawayClaim {
    pub key: String,
    pub at: u64,
    #[serde(default)]
    pub done: bool,
}

/// A giveaway code entered by an account: proof over `"pulshade.collect.giveaway.v1" | code hash bytes | ts`, so it can
/// only be claimed for the key that signed.
#[derive(Deserialize)]
pub struct GiveawayEntry {
    pub key: String,
    pub sig: String,
    pub ts: u64,
    pub code: String,
}

/// What entering a code got: which collectible, and what place in line.
#[derive(Serialize, Debug, PartialEq)]
pub struct GiveawayPlace {
    pub item: String,
    pub place: usize,
}

/// An egg the operator gave an account. Hatching starts when its owner starts it, takes the kind's time, and then
/// the relay rolls what's inside and signs that pet over to the owner.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Egg {
    pub id: String,
    /// Base64 Ed25519 public key of the account it was given to.
    pub owner: String,
    pub kind: String,
    pub given: u64,
    /// When it will be ready (seconds since 1970), once its owner has started it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hatches_at: Option<u64>,
}

/// An egg as its owner sees it. It doesn't say what's inside, only which sort of egg it is.
#[derive(Serialize, Debug, PartialEq)]
pub struct EggView {
    pub id: String,
    pub kind: String,
    pub hatches_at: Option<u64>,
    /// How long this kind takes to hatch, in seconds.
    pub seconds: u64,
    /// The relay's clock, so the app can count down without trusting its own.
    pub now: u64,
}

/// One egg named by its owner: proof over `"pulshade.eggs.start.v1"` or `"pulshade.eggs.hatch.v1" | egg id | ts`.
#[derive(Deserialize)]
pub struct EggAction {
    pub key: String,
    pub sig: String,
    pub ts: u64,
    pub id: String,
}

/// A collectible handed to another account: proof over `"pulshade.collect.gift.v1" | item | 0 | serial (u32 BE) |
/// recipient key bytes | ts`.
#[derive(Deserialize)]
pub struct GiftOut {
    pub key: String,
    pub sig: String,
    pub ts: u64,
    pub item: String,
    pub serial: u32,
    pub to: String,
}

/// A collectible let go: proof over `"pulshade.collect.release.v1" | item | 0 | serial (u32 BE) | ts`.
#[derive(Deserialize)]
pub struct ReleaseOut {
    pub key: String,
    pub sig: String,
    pub ts: u64,
    pub item: String,
    pub serial: u32,
}

/// The sorts of egg: how long they take, and what can be inside with its chance out of 100.
pub struct EggKind {
    pub name: &'static str,
    pub seconds: u64,
    pub inside: &'static [(&'static str, u32)],
}

pub const EGG_KINDS: [EggKind; 1] = [
    // Pulze is the usual dragon; the golden one is the rare one.
    EggKind { name: "dragon", seconds: 10 * 60, inside: &[("greendragon", 85), ("golddragon", 15)] },
];

pub fn egg_kind(name: &str) -> Option<&'static EggKind> {
    EGG_KINDS.iter().find(|k| k.name == name)
}

fn random_below(n: u32) -> u32 {
    use std::io::Read;
    let mut raw = [0u8; 4];
    std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut raw)).expect("no randomness");
    // Biased by less than one in a million for n up to 100: fine for a game.
    (u32::from_be_bytes(raw) as u64 % n as u64) as u32
}

/// A message from Pulshade to everyone, shown in the apps as a chat from @announcements. Signed by the Pulshade
/// Admin key over `"pulshade.announcement.v1" | id | 0 | date (u64 BE) | text`; the apps check that against the key
/// built into them, so the relay can only pass on what the admin app wrote, or leave it out.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Announcement {
    /// A UUID, chosen by the admin app.
    pub id: String,
    pub text: String,
    /// Seconds since 1970.
    pub date: u64,
    pub sig: String,
}

/// What the operator has decided: names nobody may use, accounts that may not list themselves, extra
/// reserved names, and where reports go. Saved beside the directory.
#[derive(Default, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Moderation {
    #[serde(default)]
    pub banned_handles: BTreeSet<String>,
    #[serde(default)]
    pub banned_keys: BTreeSet<String>,
    #[serde(default)]
    pub reserved: BTreeSet<String>,
    /// The creator's mailbox for abuse reports: `{ "sendID", "agreementKey", "signingKey" }`, all base64.
    #[serde(default)]
    pub report_inbox: Option<serde_json::Value>,
}

#[derive(Default)]
pub struct Directory {
    entries: HashMap<String, Entry>,
    path: Option<PathBuf>,
    /// The creator's key (base64 Ed25519). Only it can claim reserved handles.
    creator: Option<String>,
    pub moderation: Moderation,
    moderation_path: Option<PathBuf>,
    /// Handles no longer listed: only the key each is held for may list it again, until the hold runs out.
    held: HashMap<String, Hold>,
    held_path: Option<PathBuf>,
    /// Collectibles the creator gave out, for each owner to fetch.
    grants: Vec<Grant>,
    grants_path: Option<PathBuf>,
    /// What everyone is told, oldest first.
    announcements: Vec<Announcement>,
    announcements_path: Option<PathBuf>,
    /// Limited runs of a collectible, for whoever enters the code first.
    giveaways: Vec<Giveaway>,
    giveaways_path: Option<PathBuf>,
    /// How many of an item there can be, where the operator has set it to something other than the usual 100.
    limits: BTreeMap<String, u32>,
    limits_path: Option<PathBuf>,
    /// Eggs the operator gave out, waiting to be hatched by their owners.
    eggs: Vec<Egg>,
    eggs_path: Option<PathBuf>,
    /// The relay's own signing key, for the pets it hatches and the collectibles people gift on.
    pet_key: Option<SigningKey>,
    /// Seals both files before they're written. None only in tests, which keep nothing on disk.
    sealer: Option<Sealer>,
}

/// Brand names nobody but the creator may use.
const RESERVED: [&str; 8] = ["zeekz", "pulshade", "official", "admin", "support", "help", "team", "security"];

pub fn valid_handle(handle: &str) -> bool {
    (1..=24).contains(&handle.len())
        && handle.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

/// One- and two-character handles and brand names belong to the creator.
pub fn reserved(handle: &str) -> bool {
    handle.len() < 3 || RESERVED.contains(&handle)
}

/// Names that run Pulshade's own services, like abuse reports. Nobody but the creator may claim them.
const SERVICE: [&str; 6] = ["abuse", "report", "safety", "moderation", "announcements", "announcement"];

fn key(b64: &str) -> Option<VerifyingKey> {
    let raw: [u8; 32] = B64.decode(b64).ok()?.try_into().ok()?;
    VerifyingKey::from_bytes(&raw).ok()
}

impl OwnerProof {
    /// A fresh signature by the key over `label | about | ts`, where `about` is the key itself unless given.
    fn check(&self, label: &[u8], about: Option<&[u8]>) -> Result<(), StatusCode> {
        if now().abs_diff(self.ts) > 300 {
            return Err(StatusCode::UNAUTHORIZED);
        }
        let owner = key(&self.key).ok_or(StatusCode::BAD_REQUEST)?;
        let sig = signature(&self.sig).ok_or(StatusCode::BAD_REQUEST)?;
        let mut message = label.to_vec();
        message.extend_from_slice(about.unwrap_or(owner.as_bytes()));
        message.extend_from_slice(&self.ts.to_be_bytes());
        owner.verify(&message, &sig).map_err(|_| StatusCode::UNAUTHORIZED)
    }
}

/// What a hold remembers of the key: enough to recognise it again, without keeping the key itself.
fn key_hash(b64: &str) -> String {
    B64.encode(Sha256::digest(B64.decode(b64).unwrap_or_default()))
}

fn signature(b64: &str) -> Option<Signature> {
    let raw: [u8; 64] = B64.decode(b64).ok()?.try_into().ok()?;
    Some(Signature::from_bytes(&raw))
}

/// A saved file and whether it was still plain. Stops the relay if a sealed file can't be opened:
/// starting empty would write over it.
fn read_sealed<T: serde::de::DeserializeOwned + Default>(path: &PathBuf, sealer: &Sealer) -> (T, bool) {
    let Ok(raw) = std::fs::read(path) else { return (T::default(), false) };
    let plain = sealer.open(&raw).unwrap_or_else(|| {
        panic!("can't open {}: the storage key in the Keychain doesn't match the one it was sealed with", path.display())
    });
    (serde_json::from_slice(&plain).unwrap_or_default(), !Sealer::is_sealed(&raw))
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

impl Directory {
    pub fn load(path: PathBuf, creator: Option<String>, sealer: Sealer) -> Self {
        let moderation_path = path.with_file_name("pulshade-moderation.json");
        let held_path = path.with_file_name("pulshade-held.json");
        let grants_path = path.with_file_name("pulshade-collectibles.json");
        let announcements_path = path.with_file_name("pulshade-announcements.json");
        let giveaways_path = path.with_file_name("pulshade-giveaways.json");
        let limits_path = path.with_file_name("pulshade-collectible-limits.json");
        let eggs_path = path.with_file_name("pulshade-eggs.json");
        let (entries, plain_entries) = read_sealed(&path, &sealer);
        let (moderation, plain_moderation) = read_sealed(&moderation_path, &sealer);
        let (held, _): (HashMap<String, serde_json::Value>, _) = read_sealed(&held_path, &sealer);
        let (grants, _) = read_sealed(&grants_path, &sealer);
        let (announcements, _) = read_sealed(&announcements_path, &sealer);
        let (giveaways, _) = read_sealed(&giveaways_path, &sealer);
        let (limits, _) = read_sealed(&limits_path, &sealer);
        let (eggs, _) = read_sealed(&eggs_path, &sealer);
        // The first holds were just the key's hash, with no date: their three months start now.
        let held = held.into_iter().filter_map(|(h, v)| match v {
            serde_json::Value::String(key) => Some((h, Hold { key: Some(key), since: now(), until: None })),
            other => serde_json::from_value(other).ok().map(|hold| (h, hold)),
        }).collect();
        let dir = Directory {
            entries,
            path: Some(path),
            creator: creator.filter(|k| key(k).is_some()),
            moderation,
            moderation_path: Some(moderation_path),
            held,
            held_path: Some(held_path),
            grants,
            grants_path: Some(grants_path),
            announcements,
            announcements_path: Some(announcements_path),
            giveaways,
            giveaways_path: Some(giveaways_path),
            limits,
            limits_path: Some(limits_path),
            eggs,
            eggs_path: Some(eggs_path),
            pet_key: None,
            sealer: Some(sealer),
        };
        // Files written before sealing are sealed straight away.
        if plain_entries { dir.persist(); }
        if plain_moderation { dir.persist_moderation(); }
        dir
    }

    pub fn creator(&self) -> Option<&str> {
        self.creator.as_deref()
    }

    /// Reserved by the built-in rules, as a service name, or by the operator.
    pub fn is_reserved(&self, handle: &str) -> bool {
        reserved(handle) || SERVICE.contains(&handle) || self.moderation.reserved.contains(handle)
    }

    /// Picks up a creator key added after start-up.
    pub fn adopt_creator(&mut self, creator: Option<String>) {
        if self.creator.is_none() {
            self.creator = creator.filter(|k| key(k).is_some());
        }
    }

    #[cfg(test)]
    pub fn with_creator(creator: &str) -> Self {
        Directory { creator: Some(creator.to_string()), ..Default::default() }
    }

    fn persist_moderation(&self) {
        if let (Some(path), Ok(raw)) = (&self.moderation_path, serde_json::to_vec(&self.moderation)) {
            self.write_sealed(path, &raw);
        }
    }

    fn persist(&self) {
        if let (Some(path), Ok(raw)) = (&self.path, serde_json::to_vec(&self.entries)) {
            self.write_sealed(path, &raw);
        }
    }

    fn persist_held(&self) {
        if let (Some(path), Ok(raw)) = (&self.held_path, serde_json::to_vec(&self.held)) {
            self.write_sealed(path, &raw);
        }
    }

    fn persist_grants(&self) {
        if let (Some(path), Ok(raw)) = (&self.grants_path, serde_json::to_vec(&self.grants)) {
            self.write_sealed(path, &raw);
        }
    }

    fn persist_limits(&self) {
        if let (Some(path), Ok(raw)) = (&self.limits_path, serde_json::to_vec(&self.limits)) {
            self.write_sealed(path, &raw);
        }
    }

    fn persist_eggs(&self) {
        if let (Some(path), Ok(raw)) = (&self.eggs_path, serde_json::to_vec(&self.eggs)) {
            self.write_sealed(path, &raw);
        }
    }

    fn persist_giveaways(&self) {
        if let (Some(path), Ok(raw)) = (&self.giveaways_path, serde_json::to_vec(&self.giveaways)) {
            self.write_sealed(path, &raw);
        }
    }

    fn persist_announcements(&self) {
        if let (Some(path), Ok(raw)) = (&self.announcements_path, serde_json::to_vec(&self.announcements)) {
            self.write_sealed(path, &raw);
        }
    }

    /// Keeps a handle that's no longer listed for the key that owned it, or for nobody once it's retired.
    fn hold(&mut self, handle: &str, key: Option<&str>) {
        self.held.insert(handle.to_string(), Hold { key: key.map(key_hash), since: now(), until: None });
        self.persist_held();
    }

    /// Forgets holds whose three months are up.
    fn prune_holds(&mut self) {
        let before = self.held.len();
        self.held.retain(|_, hold| hold.live());
        if self.held.len() != before { self.persist_held(); }
    }

    fn live_hold(&self, handle: &str) -> Option<&Hold> {
        self.held.get(handle).filter(|hold| hold.live())
    }

    /// How many handles a key has, listed or held for it, besides `except`.
    fn handles_of(&self, key: &str, except: &str) -> usize {
        let hash = key_hash(key);
        self.entries.iter().filter(|(h, e)| *h != except && e.key == key).count()
            + self.held.iter().filter(|(h, hold)| *h != except && hold.live() && hold.key.as_deref() == Some(hash.as_str())).count()
    }

    /// Seals in memory, then swaps the file in whole, so nothing readable ever reaches the disk.
    fn write_sealed(&self, path: &PathBuf, plain: &[u8]) {
        let Some(sealer) = &self.sealer else { return };
        let tmp = path.with_extension("tmp");
        if std::fs::write(&tmp, sealer.seal(plain)).is_ok() {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
            let _ = std::fs::rename(tmp, path);
        }
    }

    pub fn get(&self, handle: &str) -> Option<Entry> {
        self.entries.get(handle).cloned()
    }

    pub fn put(&mut self, handle: &str, entry: Entry) -> Result<(), StatusCode> {
        if !valid_handle(handle) {
            return Err(StatusCode::BAD_REQUEST);
        }
        // Banned names and accounts are refused outright, even for the creator until unbanned.
        if self.moderation.banned_handles.contains(handle) || self.moderation.banned_keys.contains(&entry.key) {
            return Err(StatusCode::FORBIDDEN);
        }
        if self.is_reserved(handle) && self.creator.as_deref() != Some(entry.key.as_str()) {
            return Err(StatusCode::FORBIDDEN);
        }
        let blob = B64.decode(&entry.blob).map_err(|_| StatusCode::BAD_REQUEST)?;
        if blob.is_empty() || blob.len() > MAX_PROFILE {
            return Err(StatusCode::PAYLOAD_TOO_LARGE);
        }
        let owner = key(&entry.key).ok_or(StatusCode::BAD_REQUEST)?;
        let sig = signature(&entry.sig).ok_or(StatusCode::BAD_REQUEST)?;
        let mut message = b"pulshade.dir.v1".to_vec();
        message.extend_from_slice(handle.as_bytes());
        message.extend_from_slice(&entry.updated.to_be_bytes());
        message.extend_from_slice(&blob);
        owner.verify(&message, &sig).map_err(|_| StatusCode::UNAUTHORIZED)?;
        if let Some(existing) = self.entries.get(handle) {
            // Taken by someone else, or an old copy being replayed.
            if existing.key != entry.key {
                return Err(StatusCode::CONFLICT);
            }
            if entry.updated <= existing.updated {
                return Err(StatusCode::CONFLICT);
            }
        } else {
            self.prune_holds();
            // Let go of recently: only the key it's held for may take it back.
            if let Some(hold) = self.live_hold(handle) {
                if hold.key.as_deref() != Some(key_hash(&entry.key).as_str()) {
                    return Err(StatusCode::LOCKED);
                }
            }
            if self.creator.as_deref() != Some(entry.key.as_str()) && self.handles_of(&entry.key, handle) >= MAX_HANDLES {
                return Err(StatusCode::UNPROCESSABLE_ENTITY);
            }
            if self.held.remove(handle).is_some() { self.persist_held(); }
        }
        self.entries.insert(handle.to_string(), entry);
        self.persist();
        Ok(())
    }

    /// Every handle the key owns, for a device restoring an account. Proving ownership with a fresh
    /// signature means nobody can map a public key to its handles.
    pub fn owned(&self, proof: &OwnerProof) -> Result<Vec<Owned>, StatusCode> {
        proof.check(b"pulshade.dir.mine.v1", None)?;
        let mut found: Vec<Owned> = self.entries.iter()
            .filter(|(_, e)| e.key == proof.key)
            .map(|(h, e)| Owned { handle: h.clone(), entry: e.clone() })
            .collect();
        found.sort_by(|a, b| b.entry.updated.cmp(&a.entry.updated));
        Ok(found)
    }

    pub fn remove(&mut self, handle: &str, removal: Removal) -> Result<(), StatusCode> {
        let existing = self.entries.get(handle).ok_or(StatusCode::NOT_FOUND)?;
        if now().abs_diff(removal.ts) > 300 {
            return Err(StatusCode::UNAUTHORIZED);
        }
        let owner = key(&existing.key).ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;
        let sig = signature(&removal.sig).ok_or(StatusCode::BAD_REQUEST)?;
        let mut message = b"pulshade.dir.del.v1".to_vec();
        message.extend_from_slice(handle.as_bytes());
        message.extend_from_slice(&removal.ts.to_be_bytes());
        owner.verify(&message, &sig).map_err(|_| StatusCode::UNAUTHORIZED)?;
        let key = existing.key.clone();
        self.entries.remove(handle);
        self.persist();
        self.hold(handle, Some(&key));
        Ok(())
    }

    /// The handles held for a key it no longer lists, soonest free first, for its owner to see in Settings.
    pub fn held_for(&self, proof: &OwnerProof) -> Result<Vec<HeldFor>, StatusCode> {
        proof.check(b"pulshade.dir.held.v1", None)?;
        let hash = key_hash(&proof.key);
        let mut found: Vec<HeldFor> = self.held.iter()
            .filter(|(_, hold)| hold.live() && hold.key.as_deref() == Some(hash.as_str()))
            .map(|(h, hold)| HeldFor { handle: h.clone(), until: hold.ends() })
            .collect();
        found.sort_by_key(|f| f.until);
        Ok(found)
    }

    /// Lets go of a handle held for this key before its three months are up, so the key has room for
    /// another. The name then cools off for 30 days, tied to nobody, before anyone may claim it.
    pub fn unhold(&mut self, handle: &str, proof: &OwnerProof) -> Result<(), StatusCode> {
        proof.check(b"pulshade.dir.unhold.v1", Some(handle.as_bytes()))?;
        let hold = self.live_hold(handle).ok_or(StatusCode::NOT_FOUND)?;
        if hold.key.as_deref() != Some(key_hash(&proof.key).as_str()) {
            return Err(StatusCode::NOT_FOUND);
        }
        let now = now();
        self.held.insert(handle.to_string(), Hold { key: None, since: now, until: Some(now + COOL_OFF_SECS) });
        self.persist_held();
        Ok(())
    }

    /// For an account that's burning: every handle it lists or holds stays unclaimable for three
    /// months, but is no longer tied to its key. Returns how many there were.
    pub fn retire(&mut self, proof: &OwnerProof) -> Result<usize, StatusCode> {
        proof.check(b"pulshade.dir.retire.v1", None)?;
        let listed: Vec<String> = self.entries.iter().filter(|(_, e)| e.key == proof.key).map(|(h, _)| h.clone()).collect();
        for h in &listed { self.entries.remove(h); }
        if !listed.is_empty() { self.persist(); }
        let hash = key_hash(&proof.key);
        let mut count = listed.len();
        for hold in self.held.values_mut().filter(|hold| hold.key.as_deref() == Some(hash.as_str())) {
            hold.key = None;
            count += 1;
        }
        for h in listed { self.held.insert(h, Hold { key: None, since: now(), until: None }); }
        self.persist_held();
        // Its collectibles go with it, so nothing on the relay names the key any more. Their numbers stay used, and
        // one with a backup code stays claimable, tied to nobody, for whoever enters the code.
        let before = self.grants.clone();
        for g in self.grants.iter_mut().filter(|g| g.owner == proof.key) {
            g.owner = String::new();
            g.sig = String::new();
            if g.code.is_none() { g.taken = true; }
        }
        if self.grants != before { self.persist_grants(); }
        // Eggs unhatched go with the account.
        let eggs = self.eggs.len();
        self.eggs.retain(|e| e.owner != proof.key);
        if self.eggs.len() != eggs { self.persist_eggs(); }
        // Its places in giveaways stay used, but no longer name it. One it hadn't been given yet goes with it.
        let mut changed = false;
        for claim in self.giveaways.iter_mut().flat_map(|g| g.claims.iter_mut()).filter(|c| c.key == proof.key) {
            claim.key = String::new();
            claim.done = true;
            changed = true;
        }
        if changed { self.persist_giveaways(); }
        Ok(count)
    }
}

// MARK: Collectibles

/// A backup code as typed: capitals, no spaces or dashes, and the letters people confuse read as digits.
pub fn normalised_code(code: &str) -> String {
    code.chars().filter(|c| c.is_ascii_alphanumeric()).map(|c| match c.to_ascii_uppercase() {
        'O' => '0', 'I' | 'L' => '1', other => other,
    }).collect()
}

/// How many of each collectible there can be unless the operator says otherwise: #1 to #100.
pub const DEFAULT_PER_ITEM: u32 = 100;

/// The most the operator can allow of one collectible.
pub const MOST_PER_ITEM: u32 = 10_000;

/// Collectibles that can't be moved to another account with a backup code: earned, not passed on.
pub const SOULBOUND: [&str; 1] = ["guardian"];

pub fn valid_item(item: &str) -> bool {
    (1..=32).contains(&item.len()) && item.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
}

impl Directory {
    /// Every collectible given to the key, for its owner; asking takes a fresh signature, so nobody else can. One
    /// claimed by another account with its code is no longer this key's.
    pub fn collectibles_of(&self, proof: &OwnerProof) -> Result<Vec<Mine>, StatusCode> {
        proof.check(b"pulshade.collect.mine.v1", None)?;
        Ok(self.grants.iter().filter(|g| g.owner == proof.key && !g.taken && g.claim.is_none())
            .map(|g| Mine { item: g.item.clone(), serial: g.serial, owner: g.owner.clone(), sig: g.sig.clone(), coded: g.code.is_some(),
                            limit: self.limit_of(&g.item) })
            .collect())
    }

    /// Sets (or replaces) the backup code for one of the key's collectibles.
    pub fn set_code(&mut self, set: &CodeSet) -> Result<(), StatusCode> {
        let hash = B64.decode(&set.hash).ok().filter(|h| h.len() == 32).ok_or(StatusCode::BAD_REQUEST)?;
        if SOULBOUND.contains(&set.item.as_str()) { return Err(StatusCode::FORBIDDEN); }
        let mut about = set.item.as_bytes().to_vec();
        about.push(0);
        about.extend_from_slice(&set.serial.to_be_bytes());
        about.extend_from_slice(&hash);
        OwnerProof { key: set.key.clone(), sig: set.sig.clone(), ts: set.ts }.check(b"pulshade.collect.code.v1", Some(&about))?;
        let grant = self.grants.iter_mut()
            .find(|g| g.item == set.item && g.serial == set.serial && g.owner == set.key && !g.taken && g.claim.is_none())
            .ok_or(StatusCode::NOT_FOUND)?;
        grant.code = Some(set.hash.clone());
        self.persist_grants();
        Ok(())
    }

    /// Brings back every collectible with this backup code for the claiming key. The code is used up; the admin app
    /// then signs each one over to the new key, with its number unchanged.
    pub fn claim(&mut self, claim: &Claim) -> Result<Vec<Claimed>, StatusCode> {
        let code = normalised_code(&claim.code);
        let hash = Sha256::digest(code.as_bytes());
        OwnerProof { key: claim.key.clone(), sig: claim.sig.clone(), ts: claim.ts }.check(b"pulshade.collect.claim.v1", Some(&hash))?;
        let hash = B64.encode(hash);
        let mut found = vec![];
        for g in self.grants.iter_mut().filter(|g| g.code.as_deref() == Some(hash.as_str()) && !g.taken && !SOULBOUND.contains(&g.item.as_str())) {
            g.code = None;
            g.claim = Some(claim.key.clone());
            found.push(Claimed { item: g.item.clone(), serial: g.serial });
        }
        if found.is_empty() { return Err(StatusCode::NOT_FOUND); }
        self.persist_grants();
        Ok(found)
    }

    /// Opens a giveaway, from the admin app. The code arrives already hashed.
    pub fn add_giveaway(&mut self, g: Giveaway) -> Result<(), String> {
        if !(1..=32).contains(&g.id.len()) || !g.id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') {
            return Err("A giveaway's name is lowercase letters, numbers and dashes".into());
        }
        if !valid_item(&g.item) { return Err("That isn't an item".into()); }
        if B64.decode(&g.hash).map(|h| h.len()) != Ok(32) { return Err("That isn't a code hash".into()); }
        if g.closes <= g.opens { return Err("It has to close after it opens".into()); }
        let limit = self.limit_of(&g.item);
        if !(1..=limit).contains(&g.max) { return Err(format!("A giveaway is 1 to {limit}")) }
        if self.giveaways.iter().any(|o| o.id == g.id) { return Err("There's already a giveaway with that name".into()); }
        if self.giveaways.iter().any(|o| o.hash == g.hash) { return Err("Another giveaway already uses that code".into()); }
        self.giveaways.push(Giveaway { claims: vec![], ..g });
        self.persist_giveaways();
        Ok(())
    }

    pub fn remove_giveaway(&mut self, id: &str) -> bool {
        let before = self.giveaways.len();
        self.giveaways.retain(|g| g.id != id);
        let removed = self.giveaways.len() != before;
        if removed { self.persist_giveaways(); }
        removed
    }

    pub fn giveaways(&self) -> &[Giveaway] {
        &self.giveaways
    }

    /// A code entered by an account. Only while it's open, only until it's full, and once per account (entering it
    /// again just says its place). The code isn't checked against a name, so a wrong one and a closed one look alike.
    pub fn claim_giveaway(&mut self, entry: &GiveawayEntry) -> Result<GiveawayPlace, StatusCode> {
        let hash = Sha256::digest(normalised_code(&entry.code).as_bytes());
        OwnerProof { key: entry.key.clone(), sig: entry.sig.clone(), ts: entry.ts }.check(b"pulshade.collect.giveaway.v1", Some(&hash))?;
        if self.moderation.banned_keys.contains(&entry.key) { return Err(StatusCode::FORBIDDEN); }
        let hash = B64.encode(hash);
        let at = now();
        let giveaway = self.giveaways.iter_mut()
            .find(|g| g.hash == hash && (g.opens..=g.closes).contains(&at)).ok_or(StatusCode::NOT_FOUND)?;
        if let Some(place) = giveaway.claims.iter().position(|c| c.key == entry.key) {
            return Ok(GiveawayPlace { item: giveaway.item.clone(), place: place + 1 });
        }
        if giveaway.claims.len() >= giveaway.max as usize { return Err(StatusCode::GONE); }
        giveaway.claims.push(GiveawayClaim { key: entry.key.clone(), at, done: false });
        let place = GiveawayPlace { item: giveaway.item.clone(), place: giveaway.claims.len() };
        self.persist_giveaways();
        Ok(place)
    }

    /// Everyone who has claimed and is waiting for the admin app to sign their collectible, in the order they claimed.
    pub fn giveaways_waiting(&self) -> Vec<(String, String, String)> {
        let mut all: Vec<(u64, String, String, String)> = self.giveaways.iter().flat_map(|g| {
            g.claims.iter().filter(|c| !c.done && !c.key.is_empty()).map(|c| (c.at, g.id.clone(), g.item.clone(), c.key.clone()))
        }).collect();
        all.sort_by_key(|(at, ..)| *at);
        all.into_iter().map(|(_, id, item, key)| (id, item, key)).collect()
    }

    /// Gives the collectible the admin app signed for an account waiting in a giveaway, and ticks it off.
    pub fn give_giveaway(&mut self, id: &str, grant: Grant) -> Result<(), String> {
        let giveaway = self.giveaways.iter().find(|g| g.id == id).ok_or("No such giveaway")?;
        if giveaway.item != grant.item { return Err("That isn't this giveaway's collectible".into()); }
        if !giveaway.claims.iter().any(|c| c.key == grant.owner && !c.done) { return Err("That account isn't waiting for it".into()); }
        let owner = grant.owner.clone();
        self.give_collectible(grant)?;
        if let Some(claim) = self.giveaways.iter_mut().find(|g| g.id == id)
            .and_then(|g| g.claims.iter_mut().find(|c| c.key == owner && !c.done)) {
            claim.done = true;
        }
        self.persist_giveaways();
        Ok(())
    }

    /// Collectibles claimed with a code and waiting for the admin app to sign them over.
    pub fn claims(&self) -> Vec<Claimed> {
        self.grants.iter().filter(|g| g.claim.is_some() && !g.taken)
            .map(|g| Claimed { item: g.item.clone(), serial: g.serial }).collect()
    }

    /// The account each waiting claim goes to, for the admin app to sign for.
    pub fn claimed_by(&self, item: &str, serial: u32) -> Option<String> {
        self.grants.iter().find(|g| g.item == item && g.serial == serial && !g.taken).and_then(|g| g.claim.clone())
    }

    /// Swaps in the admin app's signature for the claiming key: the collectible is now that account's.
    pub fn reissue(&mut self, signed: Grant) -> Result<(), String> {
        signature(&signed.sig).ok_or("That isn't a signature")?;
        let grant = self.grants.iter_mut()
            .find(|g| g.item == signed.item && g.serial == signed.serial && !g.taken && g.claim.as_deref() == Some(signed.owner.as_str()))
            .ok_or(format!("Nobody is waiting for {} #{}", signed.item, signed.serial))?;
        grant.owner = signed.owner;
        grant.sig = signed.sig;
        grant.claim = None;
        grant.code = None;
        self.persist_grants();
        Ok(())
    }

    /// Every collectible an account was given, taken back ones included, for the operator.
    pub fn grants_of(&self, key: &str) -> Vec<Grant> {
        self.grants.iter().filter(|g| g.owner == key).cloned().collect()
    }

    /// Takes a collectible back: its owner's app stops showing it the next time it checks.
    pub fn take_collectible(&mut self, item: &str, serial: u32) -> bool {
        let Some(grant) = self.grants.iter_mut().find(|g| g.item == item && g.serial == serial && !g.taken) else { return false };
        grant.taken = true;
        self.persist_grants();
        true
    }

    /// How many of `item` there can be: what the operator set, or 100.
    pub fn limit_of(&self, item: &str) -> u32 {
        self.limits.get(item).copied().unwrap_or(DEFAULT_PER_ITEM)
    }

    /// The limits the operator has set, for the items that have one.
    pub fn limits(&self) -> &BTreeMap<String, u32> {
        &self.limits
    }

    /// Sets how many of `item` there can be, up or down, but never below how many have already been given out: those
    /// numbers are taken. Raising it only makes room for more; nobody's number changes.
    pub fn set_limit(&mut self, item: &str, limit: u32) -> Result<(), String> {
        if !valid_item(item) { return Err("That isn't an item".into()); }
        if !(1..=MOST_PER_ITEM).contains(&limit) { return Err(format!("It has to be from 1 to {MOST_PER_ITEM}")); }
        let given = self.given().get(item).copied().unwrap_or(0);
        if limit < given { return Err(format!("{given} have already been given out, so it can't go below {given}")); }
        if limit == DEFAULT_PER_ITEM { self.limits.remove(item); } else { self.limits.insert(item.to_string(), limit); }
        self.persist_limits();
        Ok(())
    }

    /// How many of each item have been given out.
    pub fn given(&self) -> BTreeMap<String, u32> {
        let mut counts = BTreeMap::new();
        for g in &self.grants {
            let n = counts.entry(g.item.clone()).or_insert(0);
            *n = (*n).max(g.serial);
        }
        counts
    }

    /// Keeps a collectible the admin app signed. Serials run 1, 2, 3… for each item, so a number is never reused.
    pub fn give_collectible(&mut self, mut grant: Grant) -> Result<(), String> {
        (grant.code, grant.claim) = (None, None);
        if !valid_item(&grant.item) { return Err("That isn't an item".into()); }
        key(&grant.owner).ok_or("That isn't an account key")?;
        signature(&grant.sig).ok_or("That isn't a signature")?;
        if grant.taken { return Err("That isn't a collectible".into()); }
        let next = self.given().get(&grant.item).copied().unwrap_or(0) + 1;
        let limit = self.limit_of(&grant.item);
        if next > limit { return Err(format!("All {limit} of {} have been given out", grant.item)); }
        if grant.serial != next { return Err(format!("The next {} is #{next}", grant.item)); }
        self.grants.push(grant);
        self.persist_grants();
        Ok(())
    }

    /// The key the relay signs hatched and gifted collectibles with.
    pub fn set_pet_key(&mut self, key: SigningKey) {
        self.pet_key = Some(key);
    }

    fn sign_grant(&self, item: &str, serial: u32, owner_b64: &str) -> Result<String, StatusCode> {
        let pet = self.pet_key.as_ref().ok_or(StatusCode::SERVICE_UNAVAILABLE)?;
        let owner = B64.decode(owner_b64).map_err(|_| StatusCode::BAD_REQUEST)?;
        let mut message = b"pulshade.collectible.v1".to_vec();
        message.extend_from_slice(item.as_bytes());
        message.push(0);
        message.extend_from_slice(&serial.to_be_bytes());
        message.extend_from_slice(&owner);
        Ok(B64.encode(pet.sign(&message).to_bytes()))
    }

    /// Gives an account an egg.
    pub fn give_egg(&mut self, owner: &str, kind: &str) -> Result<String, String> {
        key(owner).ok_or("That isn't an account key")?;
        egg_kind(kind).ok_or_else(|| format!("No such egg. Eggs: {}", EGG_KINDS.iter().map(|k| k.name).collect::<Vec<_>>().join(", ")))?;
        let mut raw = [0u8; 8];
        {
            use std::io::Read;
            std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut raw)).map_err(|_| "no randomness")?;
        }
        let id = hex::encode(raw);
        self.eggs.push(Egg { id: id.clone(), owner: owner.to_string(), kind: kind.to_string(), given: now(), hatches_at: None });
        self.persist_eggs();
        Ok(id)
    }

    /// Every egg waiting, for the operator.
    pub fn eggs(&self) -> &[Egg] {
        &self.eggs
    }

    /// The eggs an account holds, for that account only.
    pub fn eggs_of(&self, proof: &OwnerProof) -> Result<Vec<EggView>, StatusCode> {
        proof.check(b"pulshade.eggs.mine.v1", None)?;
        Ok(self.eggs.iter().filter(|e| e.owner == proof.key).filter_map(|e| {
            let kind = egg_kind(&e.kind)?;
            Some(EggView { id: e.id.clone(), kind: e.kind.clone(), hatches_at: e.hatches_at, seconds: kind.seconds, now: now() })
        }).collect())
    }

    /// Puts an egg to hatch: it will be ready after its kind's time, counted by the relay.
    pub fn start_egg(&mut self, action: &EggAction) -> Result<EggView, StatusCode> {
        OwnerProof { key: action.key.clone(), sig: action.sig.clone(), ts: action.ts }.check(b"pulshade.eggs.start.v1", Some(action.id.as_bytes()))?;
        let egg = self.eggs.iter_mut().find(|e| e.id == action.id && e.owner == action.key).ok_or(StatusCode::NOT_FOUND)?;
        let kind = egg_kind(&egg.kind).ok_or(StatusCode::NOT_FOUND)?;
        // Starting it again doesn't restart the clock.
        let at = *egg.hatches_at.get_or_insert(now() + kind.seconds);
        let view = EggView { id: egg.id.clone(), kind: egg.kind.clone(), hatches_at: Some(at), seconds: kind.seconds, now: now() };
        self.persist_eggs();
        Ok(view)
    }

    /// Opens an egg that's ready: rolls what's inside, numbers it, signs it to the owner and uses the egg up. If the
    /// pet rolled has run out, the other one inside is tried, and if all have, the egg stays.
    pub fn hatch_egg(&mut self, action: &EggAction) -> Result<Mine, StatusCode> {
        OwnerProof { key: action.key.clone(), sig: action.sig.clone(), ts: action.ts }.check(b"pulshade.eggs.hatch.v1", Some(action.id.as_bytes()))?;
        let at = self.eggs.iter().position(|e| e.id == action.id && e.owner == action.key).ok_or(StatusCode::NOT_FOUND)?;
        let kind = egg_kind(&self.eggs[at].kind).ok_or(StatusCode::NOT_FOUND)?;
        match self.eggs[at].hatches_at {
            None => return Err(StatusCode::CONFLICT),
            Some(t) if t > now() => return Err(StatusCode::TOO_EARLY),
            _ => {}
        }
        let total: u32 = kind.inside.iter().map(|(_, w)| w).sum();
        let mut roll = random_below(total);
        let mut order: Vec<&str> = vec![];
        for (item, weight) in kind.inside {
            if roll < *weight && order.is_empty() { order.push(item); }
            roll = roll.saturating_sub(*weight);
        }
        for (item, _) in kind.inside { if !order.contains(item) { order.push(item); } }
        for item in order {
            // A number somebody let go comes round again before a new one is made.
            let free: Vec<usize> = self.grants.iter().enumerate().filter(|(_, g)| g.item == item && g.released && !g.taken).map(|(i, _)| i).collect();
            let reused = if free.is_empty() { None } else { Some(free[random_below(free.len() as u32) as usize]) };
            let serial = match reused {
                Some(i) => self.grants[i].serial,
                None => self.given().get(item).copied().unwrap_or(0) + 1,
            };
            if reused.is_none() && serial > self.limit_of(item) { continue; }
            let sig = self.sign_grant(item, serial, &action.key)?;
            match reused {
                Some(i) => {
                    let g = &mut self.grants[i];
                    (g.owner, g.sig, g.released, g.code, g.claim) = (action.key.clone(), sig.clone(), false, None, None);
                }
                None => self.grants.push(Grant { item: item.to_string(), serial, owner: action.key.clone(), sig: sig.clone(), taken: false, released: false, code: None, claim: None }),
            }
            self.eggs.remove(at);
            self.persist_grants();
            self.persist_eggs();
            return Ok(Mine { item: item.to_string(), serial, owner: action.key.clone(), sig, coded: false, limit: self.limit_of(item) });
        }
        Err(StatusCode::GONE)
    }

    /// Hands a collectible to another account: the relay signs it over, with its number unchanged. Not one that's
    /// earned (a Guardian), and the old backup code stops working.
    pub fn gift(&mut self, out: &GiftOut) -> Result<(), StatusCode> {
        key(&out.to).ok_or(StatusCode::BAD_REQUEST)?;
        let to = B64.decode(&out.to).map_err(|_| StatusCode::BAD_REQUEST)?;
        if SOULBOUND.contains(&out.item.as_str()) || out.to == out.key { return Err(StatusCode::FORBIDDEN); }
        let mut about = out.item.as_bytes().to_vec();
        about.push(0);
        about.extend_from_slice(&out.serial.to_be_bytes());
        about.extend_from_slice(&to);
        OwnerProof { key: out.key.clone(), sig: out.sig.clone(), ts: out.ts }.check(b"pulshade.collect.gift.v1", Some(&about))?;
        let at = self.grants.iter().position(|g| g.item == out.item && g.serial == out.serial && g.owner == out.key && !g.taken && g.claim.is_none())
            .ok_or(StatusCode::NOT_FOUND)?;
        let sig = self.sign_grant(&out.item, out.serial, &out.to)?;
        let grant = &mut self.grants[at];
        grant.owner = out.to.clone();
        grant.sig = sig;
        grant.code = None;
        self.persist_grants();
        Ok(())
    }

    /// Lets a collectible go: it's no longer anyone's and goes back into circulation, so the number can hatch again.
    pub fn release(&mut self, out: &ReleaseOut) -> Result<(), StatusCode> {
        let mut about = out.item.as_bytes().to_vec();
        about.push(0);
        about.extend_from_slice(&out.serial.to_be_bytes());
        OwnerProof { key: out.key.clone(), sig: out.sig.clone(), ts: out.ts }.check(b"pulshade.collect.release.v1", Some(&about))?;
        let grant = self.grants.iter_mut()
            .find(|g| g.item == out.item && g.serial == out.serial && g.owner == out.key && !g.taken && g.claim.is_none())
            .ok_or(StatusCode::NOT_FOUND)?;
        (grant.released, grant.owner, grant.sig, grant.code) = (true, String::new(), String::new(), None);
        self.persist_grants();
        Ok(())
    }

    /// How many of `item` are back in circulation, waiting to hatch.
    pub fn released_of(&self, item: &str) -> usize {
        self.grants.iter().filter(|g| g.item == item && g.released && !g.taken).count()
    }

    /// Takes every collectible back from everyone, backup codes and claims included, and starts each item's numbering
    /// again at #1. Apps drop them the next time they check. Returns how many there were.
    pub fn reset_collectibles(&mut self) -> usize {
        let count = self.grants.iter().filter(|g| !g.taken).count();
        self.grants.clear();
        self.persist_grants();
        count
    }
}

// MARK: Announcements

/// Longest announcement, in characters.
pub const MAX_ANNOUNCEMENT: usize = 4000;

/// How many are kept: an app that was away longer than that misses the oldest.
pub const KEPT_ANNOUNCEMENTS: usize = 50;

impl Directory {
    /// Everything everyone is told, oldest first. The same for every app, so asking says nothing about who asks.
    pub fn announcements(&self) -> &[Announcement] {
        &self.announcements
    }

    /// Changes whenever one is added or taken back, so an app can ask "anything new?" without fetching the list.
    pub fn announcements_version(&self) -> String {
        let mut hash = Sha256::new();
        for a in &self.announcements { hash.update(a.id.as_bytes()); hash.update([0]); }
        hash.finalize()[..12].iter().map(|b| format!("{b:02x}")).collect()
    }

    /// Keeps an announcement the admin app signed, dropping the oldest past the limit.
    pub fn announce(&mut self, a: Announcement) -> Result<(), String> {
        let id_ok = a.id.len() == 36 && a.id.chars().all(|c| c.is_ascii_hexdigit() || c == '-');
        if !id_ok { return Err("That isn't an announcement".into()); }
        if a.text.trim().is_empty() { return Err("Write something to announce".into()); }
        if a.text.chars().count() > MAX_ANNOUNCEMENT { return Err(format!("Announcements are {MAX_ANNOUNCEMENT} characters at most")); }
        signature(&a.sig).ok_or("That isn't a signature")?;
        if self.announcements.iter().any(|old| old.id.eq_ignore_ascii_case(&a.id)) { return Err("That was already announced".into()); }
        self.announcements.push(a);
        let extra = self.announcements.len().saturating_sub(KEPT_ANNOUNCEMENTS);
        self.announcements.drain(..extra);
        self.persist_announcements();
        Ok(())
    }

    /// Takes an announcement back: apps remove it the next time they check.
    pub fn unannounce(&mut self, id: &str) -> bool {
        let before = self.announcements.len();
        self.announcements.retain(|a| !a.id.eq_ignore_ascii_case(id));
        let gone = self.announcements.len() != before;
        if gone { self.persist_announcements(); }
        gone
    }
}

// MARK: Operator actions

impl Directory {
    pub fn count(&self) -> usize {
        self.entries.len()
    }

    pub fn handles(&self) -> Vec<(String, Entry)> {
        let mut all: Vec<_> = self.entries.iter().map(|(h, e)| (h.clone(), e.clone())).collect();
        all.sort_by(|a, b| a.0.cmp(&b.0));
        all
    }

    pub fn held_count(&self) -> usize {
        self.held.values().filter(|hold| hold.live()).count()
    }

    pub fn is_held(&self, handle: &str) -> bool {
        self.live_hold(handle).is_some()
    }

    /// Held, but for nobody: its account burned, or its owner let go of it and it's cooling off.
    pub fn is_retired(&self, handle: &str) -> bool {
        self.live_hold(handle).is_some_and(|hold| hold.key.is_none())
    }

    /// Takes a listing down. The name stays held for its owner's key; `free` lets anyone claim it.
    pub fn take_down(&mut self, handle: &str) -> bool {
        let Some(entry) = self.entries.remove(handle) else { return false };
        self.persist();
        self.hold(handle, Some(&entry.key));
        true
    }

    /// Gives a name to the account it belongs to, say after someone else took it: any listing comes
    /// down, and only that key may claim it for the next three months.
    pub fn give(&mut self, handle: &str, to: &str) -> Result<(), StatusCode> {
        key(to).ok_or(StatusCode::BAD_REQUEST)?;
        if self.entries.remove(handle).is_some() { self.persist(); }
        self.hold(handle, Some(to));
        Ok(())
    }

    /// Lets anyone claim a held name. Only the operator does this, on purpose.
    pub fn free(&mut self, handle: &str) -> bool {
        let found = self.held.remove(handle).is_some();
        if found { self.persist_held(); }
        found
    }

    /// Takes a listing down and stops the name ever being used again.
    pub fn ban_handle(&mut self, handle: &str) {
        self.take_down(handle);
        self.moderation.banned_handles.insert(handle.to_string());
        self.persist_moderation();
    }

    pub fn unban_handle(&mut self, handle: &str) -> bool {
        let found = self.moderation.banned_handles.remove(handle);
        self.persist_moderation();
        found
    }

    /// Stops an account listing itself, and takes down everything it already has. Returns the handles removed.
    pub fn ban_key(&mut self, key: &str) -> Vec<String> {
        let gone: Vec<String> = self.entries.iter().filter(|(_, e)| e.key == key).map(|(h, _)| h.clone()).collect();
        for h in &gone { self.entries.remove(h); }
        self.persist();
        // Held for the banned key, so nobody else can take up its names.
        for h in &gone { self.held.insert(h.clone(), Hold { key: Some(key_hash(key)), since: now(), until: None }); }
        self.persist_held();
        self.moderation.banned_keys.insert(key.to_string());
        self.persist_moderation();
        gone
    }

    pub fn unban_key(&mut self, key: &str) -> bool {
        let found = self.moderation.banned_keys.remove(key);
        self.persist_moderation();
        found
    }

    pub fn reserve(&mut self, handle: &str) {
        self.moderation.reserved.insert(handle.to_string());
        self.persist_moderation();
    }

    pub fn unreserve(&mut self, handle: &str) -> bool {
        let found = self.moderation.reserved.remove(handle);
        self.persist_moderation();
        found
    }

    pub fn set_report_inbox(&mut self, inbox: Option<serde_json::Value>) {
        self.moderation.report_inbox = inbox;
        self.persist_moderation();
    }
}

/// Simple per-address limits, so nobody can scrape handles or grab thousands of them. Addresses are never
/// kept as they are: each is hashed with a secret salt that's replaced every hour, so even the relay's
/// memory can't say which address did what. An entry is only held while its window is open: `sweep`
/// forgets every one whose window has ended.
pub struct Limiter {
    /// When the window opened, how long it lasts, and the count so far.
    hits: HashMap<([u8; 16], &'static str), (Instant, Duration, u32)>,
    salt: [u8; 32],
    salted_at: Instant,
}

impl Default for Limiter {
    fn default() -> Self {
        Limiter { hits: HashMap::new(), salt: Self::fresh_salt(), salted_at: Instant::now() }
    }
}

impl Limiter {
    const SALT_LIFETIME: Duration = Duration::from_secs(3600);

    fn fresh_salt() -> [u8; 32] {
        use std::io::Read;
        let mut salt = [0u8; 32];
        std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut salt)).expect("no randomness");
        salt
    }

    fn tag(&self, ip: IpAddr) -> [u8; 16] {
        let digest = Sha256::new().chain_update(self.salt).chain_update(ip.to_string()).finalize();
        digest[..16].try_into().unwrap()
    }

    pub fn allow(&mut self, ip: IpAddr, kind: &'static str, max: u32, window: Duration) -> bool {
        let now = Instant::now();
        if now.duration_since(self.salted_at) >= Self::SALT_LIFETIME {
            // A new salt makes every old entry meaningless, so they go with it.
            self.salt = Self::fresh_salt();
            self.salted_at = now;
            self.hits.clear();
        }
        let tag = self.tag(ip);
        let entry = self.hits.entry((tag, kind)).or_insert((now, window, 0));
        if now.duration_since(entry.0) >= entry.1 {
            *entry = (now, window, 0);
        }
        entry.2 += 1;
        entry.2 <= max
    }

    /// Forgets every address whose window has ended.
    pub fn sweep(&mut self) {
        let now = Instant::now();
        self.hits.retain(|_, (start, window, _)| now.duration_since(*start) < *window);
    }

    #[cfg(test)]
    pub fn remembered(&self) -> usize {
        self.hits.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    fn signed(signer: &SigningKey, handle: &str, blob: &[u8], updated: u64) -> Entry {
        let mut message = b"pulshade.dir.v1".to_vec();
        message.extend_from_slice(handle.as_bytes());
        message.extend_from_slice(&updated.to_be_bytes());
        message.extend_from_slice(blob);
        Entry {
            key: B64.encode(signer.verifying_key().to_bytes()),
            blob: B64.encode(blob),
            sig: B64.encode(signer.sign(&message).to_bytes()),
            updated,
        }
    }

    #[test]
    fn claim_update_and_protect() {
        let mut dir = Directory::default();
        let alice = SigningKey::from_bytes(&[1; 32]);
        let mallory = SigningKey::from_bytes(&[2; 32]);
        assert!(dir.put("nova", signed(&alice, "nova", b"v1", 10)).is_ok());
        assert_eq!(dir.put("nova", signed(&mallory, "nova", b"evil", 99)), Err(StatusCode::CONFLICT));
        assert_eq!(dir.put("nova", signed(&alice, "nova", b"old", 5)), Err(StatusCode::CONFLICT), "no replays");
        assert!(dir.put("nova", signed(&alice, "nova", b"v2", 11)).is_ok());
        assert_eq!(B64.decode(dir.get("nova").unwrap().blob).unwrap(), b"v2");
    }

    #[test]
    fn rejects_forgeries_and_bad_handles() {
        let mut dir = Directory::default();
        let alice = SigningKey::from_bytes(&[1; 32]);
        let mut forged = signed(&alice, "nova", b"v1", 10);
        forged.blob = B64.encode(b"tampered");
        assert_eq!(dir.put("nova", forged), Err(StatusCode::UNAUTHORIZED));
        assert_eq!(dir.put("No Va", signed(&alice, "No Va", b"x", 1)), Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn only_owner_removes() {
        let mut dir = Directory::default();
        let alice = SigningKey::from_bytes(&[1; 32]);
        let mallory = SigningKey::from_bytes(&[2; 32]);
        dir.put("nova", signed(&alice, "nova", b"v1", 10)).unwrap();
        let removal = |k: &SigningKey| {
            let ts = now();
            let mut m = b"pulshade.dir.del.v1".to_vec();
            m.extend_from_slice(b"nova");
            m.extend_from_slice(&ts.to_be_bytes());
            Removal { sig: B64.encode(k.sign(&m).to_bytes()), ts }
        };
        assert_eq!(dir.remove("nova", removal(&mallory)), Err(StatusCode::UNAUTHORIZED));
        assert!(dir.remove("nova", removal(&alice)).is_ok());
        assert!(dir.get("nova").is_none());
    }

    #[test]
    fn a_released_handle_never_passes_to_someone_else() {
        let mut dir = Directory::default();
        let alice = SigningKey::from_bytes(&[1; 32]);
        let mallory = SigningKey::from_bytes(&[2; 32]);
        dir.put("nova", signed(&alice, "nova", b"v1", 10)).unwrap();
        let ts = now();
        let mut m = b"pulshade.dir.del.v1".to_vec();
        m.extend_from_slice(b"nova");
        m.extend_from_slice(&ts.to_be_bytes());
        dir.remove("nova", Removal { sig: B64.encode(alice.sign(&m).to_bytes()), ts }).unwrap();
        assert!(dir.get("nova").is_none() && dir.is_held("nova"));
        assert_eq!(dir.put("nova", signed(&mallory, "nova", b"evil", 99)), Err(StatusCode::LOCKED));
        // The owner takes it back whenever they like, newer copy or not.
        assert!(dir.put("nova", signed(&alice, "nova", b"back", 11)).is_ok());
        assert!(!dir.is_held("nova"));
        assert_eq!(B64.decode(dir.get("nova").unwrap().blob).unwrap(), b"back");
    }

    fn remove_signed(dir: &mut Directory, signer: &SigningKey, handle: &str) {
        let ts = now();
        let mut m = b"pulshade.dir.del.v1".to_vec();
        m.extend_from_slice(handle.as_bytes());
        m.extend_from_slice(&ts.to_be_bytes());
        dir.remove(handle, Removal { sig: B64.encode(signer.sign(&m).to_bytes()), ts }).unwrap();
    }

    #[test]
    fn holds_run_out_after_three_months() {
        let mut dir = Directory::default();
        let alice = SigningKey::from_bytes(&[1; 32]);
        let carol = SigningKey::from_bytes(&[3; 32]);
        dir.put("nova", signed(&alice, "nova", b"v1", 10)).unwrap();
        remove_signed(&mut dir, &alice, "nova");
        dir.held.get_mut("nova").unwrap().since = now() - HOLD_SECS + 60;
        assert_eq!(dir.put("nova", signed(&carol, "nova", b"x", 1)), Err(StatusCode::LOCKED), "a minute to go");
        dir.held.get_mut("nova").unwrap().since = now() - HOLD_SECS - 1;
        assert!(!dir.is_held("nova"));
        assert!(dir.put("nova", signed(&carol, "nova", b"x", 1)).is_ok());
        assert!(dir.held.is_empty(), "the old hold is forgotten");
    }

    #[test]
    fn an_account_has_three_handles_at_most() {
        let mut dir = Directory::default();
        let alice = SigningKey::from_bytes(&[1; 32]);
        dir.put("one", signed(&alice, "one", b"x", 1)).unwrap();
        dir.put("two", signed(&alice, "two", b"x", 1)).unwrap();
        remove_signed(&mut dir, &alice, "two");
        dir.put("three", signed(&alice, "three", b"x", 1)).unwrap();
        // Listed and held together make three: claiming and letting go can't use up names.
        assert_eq!(dir.put("four", signed(&alice, "four", b"x", 1)), Err(StatusCode::UNPROCESSABLE_ENTITY));
        // Updating one it has, or taking back one held for it, is fine.
        assert!(dir.put("one", signed(&alice, "one", b"y", 2)).is_ok());
        assert!(dir.put("two", signed(&alice, "two", b"y", 2)).is_ok());
        // Once a hold runs out, there's room again.
        remove_signed(&mut dir, &alice, "two");
        dir.held.get_mut("two").unwrap().since = 0;
        assert!(dir.put("four", signed(&alice, "four", b"x", 1)).is_ok());
        // The creator isn't limited.
        let creator = SigningKey::from_bytes(&[7; 32]);
        let mut mine = Directory::with_creator(&B64.encode(creator.verifying_key().to_bytes()));
        for h in ["aaa", "bbb", "ccc", "ddd"] { assert!(mine.put(h, signed(&creator, h, b"x", 1)).is_ok()); }
    }

    #[test]
    fn burning_retires_names_without_a_trace_of_the_key() {
        let mut dir = Directory::default();
        let alice = SigningKey::from_bytes(&[1; 32]);
        let mallory = SigningKey::from_bytes(&[2; 32]);
        dir.put("nova", signed(&alice, "nova", b"x", 1)).unwrap();
        dir.put("old_nova", signed(&alice, "old_nova", b"x", 1)).unwrap();
        remove_signed(&mut dir, &alice, "old_nova");
        let proof = |signer: &SigningKey, ts: u64| {
            let mut m = b"pulshade.dir.retire.v1".to_vec();
            m.extend_from_slice(alice.verifying_key().as_bytes());
            m.extend_from_slice(&ts.to_be_bytes());
            OwnerProof { key: B64.encode(alice.verifying_key().to_bytes()), sig: B64.encode(signer.sign(&m).to_bytes()), ts }
        };
        assert_eq!(dir.retire(&proof(&mallory, now())), Err(StatusCode::UNAUTHORIZED), "only the key itself");
        assert_eq!(dir.retire(&proof(&alice, now())), Ok(2));
        assert!(dir.get("nova").is_none());
        assert!(dir.is_retired("nova") && dir.is_retired("old_nova"));
        assert!(dir.held.values().all(|hold| hold.key.is_none()), "nothing ties them to the key");
        for h in ["nova", "old_nova"] {
            assert_eq!(dir.put(h, signed(&alice, h, b"x", 5)), Err(StatusCode::LOCKED), "not even for the old key");
            assert_eq!(dir.put(h, signed(&mallory, h, b"x", 5)), Err(StatusCode::LOCKED));
        }
    }

    #[test]
    fn the_operator_can_give_a_name_back() {
        let mut dir = Directory::default();
        let alice = SigningKey::from_bytes(&[1; 32]);
        let mallory = SigningKey::from_bytes(&[2; 32]);
        dir.put("nova", signed(&mallory, "nova", b"fake", 1)).unwrap();
        assert!(dir.give("nova", &B64.encode(alice.verifying_key().to_bytes())).is_ok());
        assert!(dir.get("nova").is_none());
        assert_eq!(dir.put("nova", signed(&mallory, "nova", b"fake", 2)), Err(StatusCode::LOCKED));
        assert!(dir.put("nova", signed(&alice, "nova", b"real", 1)).is_ok());
        assert_eq!(dir.give("nova", "not a key"), Err(StatusCode::BAD_REQUEST));
    }

    #[test]
    fn an_owner_sees_and_lets_go_of_its_held_handles() {
        let mut dir = Directory::default();
        let alice = SigningKey::from_bytes(&[1; 32]);
        let mallory = SigningKey::from_bytes(&[2; 32]);
        dir.put("nova", signed(&alice, "nova", b"x", 1)).unwrap();
        dir.put("old_nova", signed(&alice, "old_nova", b"x", 1)).unwrap();
        remove_signed(&mut dir, &alice, "old_nova");
        let proof = |signer: &SigningKey, owner: &SigningKey, label: &[u8], about: &[u8], ts: u64| {
            let mut m = label.to_vec();
            m.extend_from_slice(about);
            m.extend_from_slice(&ts.to_be_bytes());
            OwnerProof { key: B64.encode(owner.verifying_key().to_bytes()), sig: B64.encode(signer.sign(&m).to_bytes()), ts }
        };
        let alice_key = alice.verifying_key().to_bytes();
        let held = dir.held_for(&proof(&alice, &alice, b"pulshade.dir.held.v1", &alice_key, now())).unwrap();
        assert_eq!(held.iter().map(|h| h.handle.as_str()).collect::<Vec<_>>(), ["old_nova"], "listed ones aren't held");
        assert!(held[0].until > now() + HOLD_SECS - 60);
        assert_eq!(dir.held_for(&proof(&mallory, &alice, b"pulshade.dir.held.v1", &alice_key, now())), Err(StatusCode::UNAUTHORIZED));
        // Only the key it's held for can let it go, and a signature for one handle can't let go of another.
        assert_eq!(dir.unhold("old_nova", &proof(&mallory, &mallory, b"pulshade.dir.unhold.v1", b"old_nova", now())), Err(StatusCode::NOT_FOUND));
        assert_eq!(dir.unhold("old_nova", &proof(&alice, &alice, b"pulshade.dir.unhold.v1", b"nova", now())), Err(StatusCode::UNAUTHORIZED));
        assert!(dir.unhold("old_nova", &proof(&alice, &alice, b"pulshade.dir.unhold.v1", b"old_nova", now())).is_ok());
        // It no longer counts against her, or shows as hers, but nobody may take it while it cools off.
        assert!(dir.held_for(&proof(&alice, &alice, b"pulshade.dir.held.v1", &alice_key, now())).unwrap().is_empty());
        assert_eq!(dir.handles_of(&B64.encode(alice_key), ""), 1);
        assert!(dir.is_retired("old_nova"));
        assert_eq!(dir.put("old_nova", signed(&mallory, "old_nova", b"x", 1)), Err(StatusCode::LOCKED));
        assert_eq!(dir.put("old_nova", signed(&alice, "old_nova", b"x", 2)), Err(StatusCode::LOCKED), "not even by her");
        assert_eq!(dir.unhold("old_nova", &proof(&alice, &alice, b"pulshade.dir.unhold.v1", b"old_nova", now())), Err(StatusCode::NOT_FOUND));
        dir.held.get_mut("old_nova").unwrap().until = Some(now() - 1);
        assert!(dir.put("old_nova", signed(&mallory, "old_nova", b"x", 1)).is_ok(), "free for anyone after 30 days");
    }

    #[test]
    fn announcements_are_checked_kept_and_taken_back() {
        let mut dir = Directory::default();
        let sig = B64.encode([0u8; 64]);
        let a = |id: &str, text: &str| Announcement { id: id.into(), text: text.into(), date: 1, sig: sig.clone() };
        let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF";
        assert!(dir.announce(a("not-a-uuid", "Hello")).is_err());
        assert!(dir.announce(a(id, "  ")).is_err(), "nothing to say");
        assert!(dir.announce(a(id, &"x".repeat(MAX_ANNOUNCEMENT + 1))).is_err());
        assert!(dir.announce(Announcement { sig: "nope".into(), ..a(id, "Hello") }).is_err());
        let empty = dir.announcements_version();
        assert!(dir.announce(a(id, "Hello")).is_ok());
        assert_ne!(dir.announcements_version(), empty, "a new one changes the version");
        assert!(dir.announce(a(id, "Again")).is_err(), "an id is used once");
        assert_eq!(dir.announcements().len(), 1);
        for n in 0..KEPT_ANNOUNCEMENTS {
            assert!(dir.announce(a(&format!("00000000-0000-0000-0000-{n:012}"), "More")).is_ok());
        }
        assert_eq!(dir.announcements().len(), KEPT_ANNOUNCEMENTS);
        assert!(!dir.announcements().iter().any(|x| x.id == id), "the oldest goes first");
        let before = dir.announcements_version();
        assert!(dir.unannounce("00000000-0000-0000-0000-000000000003"));
        assert_ne!(dir.announcements_version(), before, "so does taking one back");
        assert!(!dir.unannounce("00000000-0000-0000-0000-000000000003"));
        assert_eq!(dir.announcements().len(), KEPT_ANNOUNCEMENTS - 1);
        assert!(dir.is_reserved("announcements"), "nobody can pass themselves off as it");
    }

    /// Everything a giveaway test needs: keys, signed entries and the admin app's grants.
    fn giveaway_kit() -> (SigningKey, Directory) {
        let creator = SigningKey::from_bytes(&[7; 32]);
        let dir = Directory::with_creator(&B64.encode(creator.verifying_key().to_bytes()));
        (creator, dir)
    }

    fn b64k(k: &SigningKey) -> String { B64.encode(k.verifying_key().to_bytes()) }

    fn entry(by: &SigningKey, typed: &str) -> GiveawayEntry {
        let ts = now();
        let mut m = b"pulshade.collect.giveaway.v1".to_vec();
        m.extend_from_slice(&Sha256::digest(normalised_code(typed).as_bytes()));
        m.extend_from_slice(&ts.to_be_bytes());
        GiveawayEntry { key: b64k(by), sig: B64.encode(by.sign(&m).to_bytes()), ts, code: typed.into() }
    }

    fn giveaway(code: &str, item: &str, max: u32) -> Giveaway {
        let t = now();
        Giveaway { id: "bonfire".into(), item: item.into(), hash: B64.encode(Sha256::digest(normalised_code(code).as_bytes())),
                   opens: t - 60, closes: t + 3600, max, claims: vec![] }
    }

    fn grant_for(creator: &SigningKey, item: &str, serial: u32, owner: &SigningKey) -> Grant {
        let mut m = b"pulshade.collectible.v1".to_vec();
        m.extend_from_slice(item.as_bytes());
        m.push(0);
        m.extend_from_slice(&serial.to_be_bytes());
        m.extend_from_slice(&owner.verifying_key().to_bytes());
        Grant { item: item.into(), serial, owner: b64k(owner), sig: B64.encode(creator.sign(&m).to_bytes()), taken: false, released: false, code: None, claim: None }
    }

    #[test]
    fn a_giveaway_goes_to_the_first_people_in_while_it_is_open() {
        let (creator, mut dir) = giveaway_kit();
        let (alice, bob, carol, mallory) = (SigningKey::from_bytes(&[1; 32]), SigningKey::from_bytes(&[2; 32]), SigningKey::from_bytes(&[3; 32]), SigningKey::from_bytes(&[4; 32]));
        dir.add_giveaway(giveaway("remember remember", "bonfire", 2)).unwrap();

        assert_eq!(dir.claim_giveaway(&entry(&alice, "WRONG")), Err(StatusCode::NOT_FOUND));
        // Typed loosely, the way a person would.
        assert_eq!(dir.claim_giveaway(&entry(&alice, "Remember, Remember!")).unwrap(), GiveawayPlace { item: "bonfire".into(), place: 1 });
        assert_eq!(dir.claim_giveaway(&entry(&alice, "remember remember")).unwrap().place, 1, "again just says its place");
        assert_eq!(dir.claim_giveaway(&entry(&bob, "remember remember")).unwrap().place, 2);
        assert_eq!(dir.claim_giveaway(&entry(&carol, "remember remember")), Err(StatusCode::GONE), "full");
        let mut stolen = entry(&mallory, "remember remember");
        stolen.key = b64k(&carol);
        assert_eq!(dir.claim_giveaway(&stolen), Err(StatusCode::UNAUTHORIZED), "an entry is signed by the key it's for");

        // The admin app signs them in the order they came, one number each.
        let waiting = dir.giveaways_waiting();
        assert_eq!(waiting.iter().map(|(_, _, k)| k.clone()).collect::<Vec<_>>(), vec![b64k(&alice), b64k(&bob)]);
        assert!(dir.give_giveaway("bonfire", grant_for(&creator, "bonfire", 1, &carol)).is_err(), "carol isn't waiting");
        assert!(dir.give_giveaway("bonfire", grant_for(&creator, "partyhat", 1, &alice)).is_err(), "wrong collectible");
        assert!(dir.give_giveaway("bonfire", grant_for(&creator, "bonfire", 1, &alice)).is_ok());
        assert!(dir.give_giveaway("bonfire", grant_for(&creator, "bonfire", 2, &alice)).is_err(), "only once");
        assert!(dir.give_giveaway("bonfire", grant_for(&creator, "bonfire", 2, &bob)).is_ok());
        assert!(dir.giveaways_waiting().is_empty());
        assert_eq!(dir.given().get("bonfire"), Some(&2));
    }

    #[test]
    fn a_giveaway_is_closed_before_it_opens_and_after_it_ends() {
        let (_, mut dir) = giveaway_kit();
        let alice = SigningKey::from_bytes(&[1; 32]);
        let mut early = giveaway("early", "bonfire", 5);
        early.id = "early".into();
        early.opens = now() + 600;
        early.closes = now() + 1200;
        dir.add_giveaway(early).unwrap();
        let mut late = giveaway("late", "bonfire", 5);
        late.id = "late".into();
        late.opens = now() - 1200;
        late.closes = now() - 600;
        dir.add_giveaway(late).unwrap();
        assert_eq!(dir.claim_giveaway(&entry(&alice, "early")), Err(StatusCode::NOT_FOUND));
        assert_eq!(dir.claim_giveaway(&entry(&alice, "late")), Err(StatusCode::NOT_FOUND));
    }

    #[test]
    fn a_giveaway_is_set_up_carefully() {
        let (_, mut dir) = giveaway_kit();
        assert!(dir.add_giveaway(giveaway("a code", "bonfire", 0)).is_err());
        assert!(dir.add_giveaway(giveaway("a code", "bonfire", DEFAULT_PER_ITEM + 1)).is_err());
        assert!(dir.add_giveaway(giveaway("a code", "Bad Item", 5)).is_err());
        let mut backwards = giveaway("a code", "bonfire", 5);
        backwards.closes = backwards.opens;
        assert!(dir.add_giveaway(backwards).is_err());
        let mut unhashed = giveaway("a code", "bonfire", 5);
        unhashed.hash = "a code".into();
        assert!(dir.add_giveaway(unhashed).is_err(), "only the hash is ever sent");
        assert!(dir.add_giveaway(giveaway("a code", "bonfire", 5)).is_ok());
        assert!(dir.add_giveaway(giveaway("another", "bonfire", 5)).is_err(), "the name is taken");
        let mut same_code = giveaway("a code", "bonfire", 5);
        same_code.id = "other".into();
        assert!(dir.add_giveaway(same_code).is_err(), "two giveaways can't share a code");
        assert!(dir.remove_giveaway("bonfire"));
        assert!(!dir.remove_giveaway("bonfire"));
    }

    #[test]
    fn a_banned_account_cannot_enter_and_a_burned_one_leaves_its_place_nameless() {
        let (_, mut dir) = giveaway_kit();
        let (alice, mallory) = (SigningKey::from_bytes(&[1; 32]), SigningKey::from_bytes(&[2; 32]));
        dir.add_giveaway(giveaway("code", "bonfire", 5)).unwrap();
        dir.ban_key(&b64k(&mallory));
        assert_eq!(dir.claim_giveaway(&entry(&mallory, "code")), Err(StatusCode::FORBIDDEN));
        dir.claim_giveaway(&entry(&alice, "code")).unwrap();
        let ts = now();
        let mut m = b"pulshade.dir.retire.v1".to_vec();
        m.extend_from_slice(&alice.verifying_key().to_bytes());
        m.extend_from_slice(&ts.to_be_bytes());
        dir.retire(&OwnerProof { key: b64k(&alice), sig: B64.encode(alice.sign(&m).to_bytes()), ts }).unwrap();
        assert!(dir.giveaways()[0].claims.iter().all(|c| c.key.is_empty()), "nothing names the burned key");
        assert_eq!(dir.giveaways()[0].claims.len(), 1, "but the place stays used");
        assert!(dir.giveaways_waiting().is_empty());
    }

    #[test]
    fn a_guardian_cannot_be_moved_with_a_backup_code() {
        let (creator, mut dir) = giveaway_kit();
        let alice = SigningKey::from_bytes(&[1; 32]);
        dir.give_collectible(grant_for(&creator, "guardian", 1, &alice)).unwrap();
        let ts = now();
        let hash = Sha256::digest(b"CODE");
        let mut about = b"guardian".to_vec();
        about.push(0);
        about.extend_from_slice(&1u32.to_be_bytes());
        about.extend_from_slice(&hash);
        let mut m = b"pulshade.collect.code.v1".to_vec();
        m.extend_from_slice(&about);
        m.extend_from_slice(&ts.to_be_bytes());
        let set = CodeSet { key: b64k(&alice), sig: B64.encode(alice.sign(&m).to_bytes()), ts, item: "guardian".into(), serial: 1, hash: B64.encode(hash) };
        assert_eq!(dir.set_code(&set), Err(StatusCode::FORBIDDEN), "earned, not passed on");
    }

    #[test]
    fn collectibles_are_numbered_in_order_and_only_owners_see_them() {
        let creator = SigningKey::from_bytes(&[7; 32]);
        let alice = SigningKey::from_bytes(&[1; 32]);
        let mallory = SigningKey::from_bytes(&[2; 32]);
        let mut dir = Directory::with_creator(&B64.encode(creator.verifying_key().to_bytes()));
        let grant = |signer: &SigningKey, item: &str, serial: u32, owner: &SigningKey| {
            let mut m = b"pulshade.collectible.v1".to_vec();
            m.extend_from_slice(item.as_bytes());
            m.push(0);
            m.extend_from_slice(&serial.to_be_bytes());
            m.extend_from_slice(&owner.verifying_key().to_bytes());
            Grant { item: item.into(), serial, owner: B64.encode(owner.verifying_key().to_bytes()), sig: B64.encode(signer.sign(&m).to_bytes()), taken: false, released: false, code: None, claim: None }
        };
        assert!(dir.give_collectible(grant(&creator, "partyhat", 2, &alice)).is_err(), "serials start at 1");
        assert!(dir.give_collectible(grant(&creator, "partyhat", 1, &alice)).is_ok());
        assert!(dir.give_collectible(grant(&creator, "partyhat", 1, &mallory)).is_err(), "a number is never reused");
        let mut unsigned = grant(&creator, "partyhat", 2, &alice);
        unsigned.sig = "not a signature".into();
        assert!(dir.give_collectible(unsigned).is_err());
        assert_eq!(dir.given().get("partyhat"), Some(&1));

        let proof = |signer: &SigningKey, owner: &SigningKey, label: &[u8]| {
            let ts = now();
            let mut m = label.to_vec();
            m.extend_from_slice(&owner.verifying_key().to_bytes());
            m.extend_from_slice(&ts.to_be_bytes());
            OwnerProof { key: B64.encode(owner.verifying_key().to_bytes()), sig: B64.encode(signer.sign(&m).to_bytes()), ts }
        };
        assert_eq!(dir.collectibles_of(&proof(&alice, &alice, b"pulshade.collect.mine.v1")).unwrap().len(), 1);
        assert_eq!(dir.collectibles_of(&proof(&mallory, &alice, b"pulshade.collect.mine.v1")), Err(StatusCode::UNAUTHORIZED));
        assert!(dir.collectibles_of(&proof(&mallory, &mallory, b"pulshade.collect.mine.v1")).unwrap().is_empty());
        // Taking one back hides it from its owner, and its number isn't given out again.
        assert!(dir.take_collectible("partyhat", 1));
        assert!(!dir.take_collectible("partyhat", 1));
        assert!(dir.collectibles_of(&proof(&alice, &alice, b"pulshade.collect.mine.v1")).unwrap().is_empty());
        assert_eq!(dir.grants_of(&B64.encode(alice.verifying_key().to_bytes())).len(), 1);
        assert!(dir.give_collectible(grant(&creator, "partyhat", 1, &alice)).is_err());
        assert!(dir.give_collectible(grant(&creator, "partyhat", 2, &alice)).is_ok());
        // Burning takes them off the relay.
        dir.retire(&proof(&alice, &alice, b"pulshade.dir.retire.v1")).unwrap();
        assert!(dir.collectibles_of(&proof(&alice, &alice, b"pulshade.collect.mine.v1")).unwrap().is_empty());
        assert!(dir.grants.iter().all(|g| g.owner != B64.encode(alice.verifying_key().to_bytes())));
    }

    fn proof_over(signer: &SigningKey, label: &[u8], about: &[u8]) -> (String, String, u64) {
        let ts = now();
        let mut m = label.to_vec();
        m.extend_from_slice(about);
        m.extend_from_slice(&ts.to_be_bytes());
        (B64.encode(signer.verifying_key().to_bytes()), B64.encode(signer.sign(&m).to_bytes()), ts)
    }

    #[test]
    fn an_egg_hatches_after_its_time_into_a_signed_numbered_pet() {
        let relay = SigningKey::from_bytes(&[9; 32]);
        let alice = SigningKey::from_bytes(&[1; 32]);
        let mallory = SigningKey::from_bytes(&[2; 32]);
        let alice_key = B64.encode(alice.verifying_key().to_bytes());
        let mut dir = Directory::default();
        dir.set_pet_key(relay.clone());
        assert!(dir.give_egg(&alice_key, "chicken").is_err(), "only known eggs");
        let id = dir.give_egg(&alice_key, "dragon").unwrap();
        let action = |signer: &SigningKey, label: &[u8]| {
            let (key, sig, ts) = proof_over(signer, label, id.as_bytes());
            EggAction { key, sig, ts, id: id.clone() }
        };
        assert_eq!(dir.hatch_egg(&action(&alice, b"pulshade.eggs.hatch.v1")), Err(StatusCode::CONFLICT), "not started");
        assert_eq!(dir.start_egg(&action(&mallory, b"pulshade.eggs.start.v1")).err(), Some(StatusCode::NOT_FOUND), "not hers");
        let started = dir.start_egg(&action(&alice, b"pulshade.eggs.start.v1")).unwrap();
        assert_eq!(started.hatches_at, Some(now() + 600));
        assert_eq!(dir.hatch_egg(&action(&alice, b"pulshade.eggs.hatch.v1")), Err(StatusCode::TOO_EARLY));
        // Starting again doesn't restart the clock.
        dir.eggs[0].hatches_at = Some(now() - 1);
        assert_eq!(dir.start_egg(&action(&alice, b"pulshade.eggs.start.v1")).unwrap().hatches_at, Some(now() - 1));
        assert_eq!(dir.hatch_egg(&action(&mallory, b"pulshade.eggs.hatch.v1")), Err(StatusCode::NOT_FOUND));

        let pet = dir.hatch_egg(&action(&alice, b"pulshade.eggs.hatch.v1")).unwrap();
        assert!(["greendragon", "golddragon"].contains(&pet.item.as_str()));
        assert_eq!(pet.serial, 1);
        assert!(dir.eggs.is_empty(), "the egg is used up");
        // The relay's signature is over the same bytes the apps check.
        let mut m = b"pulshade.collectible.v1".to_vec();
        m.extend_from_slice(pet.item.as_bytes());
        m.push(0);
        m.extend_from_slice(&1u32.to_be_bytes());
        m.extend_from_slice(&alice.verifying_key().to_bytes());
        assert!(relay.verifying_key().verify(&m, &signature(&pet.sig).unwrap()).is_ok());
        let (key, sig, ts) = proof_over(&alice, b"pulshade.collect.mine.v1", &alice.verifying_key().to_bytes());
        assert_eq!(dir.collectibles_of(&OwnerProof { key, sig, ts }).unwrap().len(), 1);
    }

    #[test]
    fn the_dragon_egg_rolls_about_eighty_five_in_a_hundred_for_pulze() {
        let mut dir = Directory::default();
        dir.set_pet_key(SigningKey::from_bytes(&[9; 32]));
        dir.limits.insert("greendragon".into(), 10_000);
        dir.limits.insert("golddragon".into(), 10_000);
        let alice = SigningKey::from_bytes(&[1; 32]);
        let key = B64.encode(alice.verifying_key().to_bytes());
        let mut pulze = 0;
        for _ in 0..600 {
            let id = dir.give_egg(&key, "dragon").unwrap();
            dir.eggs.last_mut().unwrap().hatches_at = Some(now() - 1);
            let (k, sig, ts) = proof_over(&alice, b"pulshade.eggs.hatch.v1", id.as_bytes());
            if dir.hatch_egg(&EggAction { key: k, sig, ts, id }).unwrap().item == "greendragon" { pulze += 1; }
        }
        // 85% of 600 is 510; five standard deviations is about 45.
        assert!((460..=560).contains(&pulze), "got {pulze} Pulze in 600");
    }

    #[test]
    fn a_pet_let_go_hatches_again_for_someone_else_before_any_new_number() {
        let relay = SigningKey::from_bytes(&[9; 32]);
        let alice = SigningKey::from_bytes(&[1; 32]);
        let bob = SigningKey::from_bytes(&[2; 32]);
        let mut dir = Directory::default();
        dir.set_pet_key(relay.clone());
        dir.limits.insert("greendragon".into(), 1);
        dir.limits.insert("golddragon".into(), 1);
        let hatch = |dir: &mut Directory, who: &SigningKey| {
            let key = B64.encode(who.verifying_key().to_bytes());
            let id = dir.give_egg(&key, "dragon").unwrap();
            dir.eggs.last_mut().unwrap().hatches_at = Some(now() - 1);
            let (k, sig, ts) = proof_over(who, b"pulshade.eggs.hatch.v1", id.as_bytes());
            dir.hatch_egg(&EggAction { key: k, sig, ts, id })
        };
        // Both pets of the run are out, so alice's third egg has nothing to give.
        let first = hatch(&mut dir, &alice).unwrap();
        let second = hatch(&mut dir, &alice).unwrap();
        assert_eq!(hatch(&mut dir, &alice), Err(StatusCode::GONE));
        // She lets the first go; the next egg, bob's, can hatch that very number.
        let mut about = first.item.as_bytes().to_vec();
        about.push(0);
        about.extend_from_slice(&first.serial.to_be_bytes());
        let (key, sig, ts) = proof_over(&alice, b"pulshade.collect.release.v1", &about);
        dir.release(&ReleaseOut { key, sig, ts, item: first.item.clone(), serial: first.serial }).unwrap();
        let again = hatch(&mut dir, &bob).unwrap();
        assert_eq!((again.item.as_str(), again.serial), (first.item.as_str(), first.serial), "the same one, in new hands");
        assert_eq!(again.owner, B64.encode(bob.verifying_key().to_bytes()));
        assert_ne!(again.sig, first.sig);
        assert_eq!(dir.released_of(&first.item), 0);
        // Alice no longer has it, and still has the other.
        let (key, sig, ts) = proof_over(&alice, b"pulshade.collect.mine.v1", &alice.verifying_key().to_bytes());
        let mine = dir.collectibles_of(&OwnerProof { key, sig, ts }).unwrap();
        assert_eq!(mine.len(), 1);
        assert_eq!(mine[0].item, second.item);
    }

    #[test]
    fn a_full_run_falls_back_to_the_other_pet_and_then_keeps_the_egg() {
        let mut dir = Directory::default();
        dir.set_pet_key(SigningKey::from_bytes(&[9; 32]));
        let alice = SigningKey::from_bytes(&[1; 32]);
        let key = B64.encode(alice.verifying_key().to_bytes());
        dir.limits.insert("greendragon".into(), 1);
        dir.limits.insert("golddragon".into(), 1);
        let hatch = |dir: &mut Directory| {
            let id = dir.give_egg(&key, "dragon").unwrap();
            dir.eggs.last_mut().unwrap().hatches_at = Some(now() - 1);
            let (k, sig, ts) = proof_over(&alice, b"pulshade.eggs.hatch.v1", id.as_bytes());
            dir.hatch_egg(&EggAction { key: k, sig, ts, id })
        };
        let a = hatch(&mut dir).unwrap().item;
        let b = hatch(&mut dir).unwrap().item;
        assert_ne!(a, b, "one of each, whatever was rolled");
        assert_eq!(hatch(&mut dir), Err(StatusCode::GONE));
        assert_eq!(dir.eggs.len(), 1, "the egg stays");
    }

    #[test]
    fn a_collectible_can_be_gifted_or_let_go_by_its_owner_only() {
        let relay = SigningKey::from_bytes(&[9; 32]);
        let creator = SigningKey::from_bytes(&[7; 32]);
        let alice = SigningKey::from_bytes(&[1; 32]);
        let bob = SigningKey::from_bytes(&[2; 32]);
        let mallory = SigningKey::from_bytes(&[3; 32]);
        let mut dir = Directory::with_creator(&B64.encode(creator.verifying_key().to_bytes()));
        dir.set_pet_key(relay.clone());
        let alice_key = B64.encode(alice.verifying_key().to_bytes());
        for item in ["partyhat", "guardian"] {
            dir.grants.push(Grant { item: item.into(), serial: 1, owner: alice_key.clone(), sig: "x".into(), taken: false, released: false, code: Some("c".into()), claim: None });
        }
        let about = |item: &str, serial: u32, to: Option<&SigningKey>| {
            let mut a = item.as_bytes().to_vec();
            a.push(0);
            a.extend_from_slice(&serial.to_be_bytes());
            if let Some(t) = to { a.extend_from_slice(&t.verifying_key().to_bytes()); }
            a
        };
        let gift = |signer: &SigningKey, item: &str, to: &SigningKey| {
            let (key, sig, ts) = proof_over(signer, b"pulshade.collect.gift.v1", &about(item, 1, Some(to)));
            GiftOut { key, sig, ts, item: item.into(), serial: 1, to: B64.encode(to.verifying_key().to_bytes()) }
        };
        assert_eq!(dir.gift(&gift(&mallory, "partyhat", &mallory)), Err(StatusCode::FORBIDDEN), "not to yourself");
        let mut stolen = gift(&mallory, "partyhat", &mallory);
        stolen.to = B64.encode(bob.verifying_key().to_bytes());
        assert!(dir.gift(&stolen).is_err(), "the proof names the recipient");
        let theirs = gift(&mallory, "partyhat", &bob);
        assert_eq!(dir.gift(&theirs), Err(StatusCode::NOT_FOUND), "it isn't mallory's");
        assert_eq!(dir.gift(&gift(&alice, "guardian", &bob)), Err(StatusCode::FORBIDDEN), "earned, not passed on");
        assert!(dir.gift(&gift(&alice, "partyhat", &bob)).is_ok());
        let g = dir.grants.iter().find(|g| g.item == "partyhat").unwrap();
        assert_eq!(g.owner, B64.encode(bob.verifying_key().to_bytes()));
        assert_eq!(g.code, None, "the old backup code stops working");
        let mut m = b"pulshade.collectible.v1".to_vec();
        m.extend_from_slice(b"partyhat");
        m.push(0);
        m.extend_from_slice(&1u32.to_be_bytes());
        m.extend_from_slice(&bob.verifying_key().to_bytes());
        assert!(relay.verifying_key().verify(&m, &signature(&g.sig).unwrap()).is_ok());
        assert_eq!(dir.gift(&gift(&alice, "partyhat", &bob)), Err(StatusCode::NOT_FOUND), "alice no longer has it");

        // Letting go: only the owner, and the number stays used.
        let release = |signer: &SigningKey, item: &str| {
            let (key, sig, ts) = proof_over(signer, b"pulshade.collect.release.v1", &about(item, 1, None));
            ReleaseOut { key, sig, ts, item: item.into(), serial: 1 }
        };
        assert_eq!(dir.release(&release(&alice, "partyhat")), Err(StatusCode::NOT_FOUND));
        assert!(dir.release(&release(&bob, "partyhat")).is_ok());
        assert_eq!(dir.given().get("partyhat"), Some(&1));
        assert_eq!(dir.released_of("partyhat"), 1, "it's back in circulation");
        assert_eq!(dir.release(&release(&bob, "partyhat")), Err(StatusCode::NOT_FOUND));
        let (key, sig, ts) = proof_over(&bob, b"pulshade.collect.mine.v1", &bob.verifying_key().to_bytes());
        assert!(dir.collectibles_of(&OwnerProof { key, sig, ts }).unwrap().is_empty(), "bob has let it go");
    }

    #[test]
    fn a_backup_code_brings_a_collectible_back_after_a_burn() {
        let creator = SigningKey::from_bytes(&[7; 32]);
        let alice = SigningKey::from_bytes(&[1; 32]);
        let reborn = SigningKey::from_bytes(&[3; 32]);
        let mallory = SigningKey::from_bytes(&[2; 32]);
        let b64 = |k: &SigningKey| B64.encode(k.verifying_key().to_bytes());
        let mut dir = Directory::default();
        let signed = |owner: &SigningKey, serial: u32| {
            let mut m = b"pulshade.collectible.v1".to_vec();
            m.extend_from_slice(b"tophat");
            m.push(0);
            m.extend_from_slice(&serial.to_be_bytes());
            m.extend_from_slice(&owner.verifying_key().to_bytes());
            Grant { item: "tophat".into(), serial, owner: b64(owner), sig: B64.encode(creator.sign(&m).to_bytes()), taken: false, released: false, code: None, claim: None }
        };
        dir.give_collectible(signed(&alice, 1)).unwrap();
        dir.give_collectible(signed(&alice, 2)).unwrap();
        let code = "K7Q2-9XMB-0LIO";
        let hash = Sha256::digest(normalised_code(code).as_bytes());
        let set = |signer: &SigningKey, owner: &SigningKey, serial: u32| {
            let ts = now();
            let mut m = b"pulshade.collect.code.v1".to_vec();
            m.extend_from_slice(b"tophat");
            m.push(0);
            m.extend_from_slice(&serial.to_be_bytes());
            m.extend_from_slice(&hash);
            m.extend_from_slice(&ts.to_be_bytes());
            CodeSet { key: b64(owner), sig: B64.encode(signer.sign(&m).to_bytes()), ts, item: "tophat".into(), serial, hash: B64.encode(hash) }
        };
        let claim = |by: &SigningKey, typed: &str| {
            let ts = now();
            let mut m = b"pulshade.collect.claim.v1".to_vec();
            m.extend_from_slice(&Sha256::digest(normalised_code(typed).as_bytes()));
            m.extend_from_slice(&ts.to_be_bytes());
            Claim { key: b64(by), sig: B64.encode(by.sign(&m).to_bytes()), ts, code: typed.into() }
        };
        let mine = |k: &SigningKey| {
            let ts = now();
            let mut m = b"pulshade.collect.mine.v1".to_vec();
            m.extend_from_slice(&k.verifying_key().to_bytes());
            m.extend_from_slice(&ts.to_be_bytes());
            dir_mine(&OwnerProof { key: b64(k), sig: B64.encode(k.sign(&m).to_bytes()), ts })
        };
        fn dir_mine(p: &OwnerProof) -> OwnerProof { OwnerProof { key: p.key.clone(), sig: p.sig.clone(), ts: p.ts } }

        assert_eq!(dir.set_code(&set(&mallory, &alice, 1)), Err(StatusCode::UNAUTHORIZED), "only the owner sets a code");
        assert_eq!(dir.set_code(&set(&mallory, &mallory, 1)), Err(StatusCode::NOT_FOUND), "not mallory's");
        assert!(dir.set_code(&set(&alice, &alice, 1)).is_ok());
        assert!(dir.collectibles_of(&mine(&alice)).unwrap().iter().any(|m| m.serial == 1 && m.coded));

        // A burn keeps the coded one, tied to nobody, and drops the other.
        let ts = now();
        let mut m = b"pulshade.dir.retire.v1".to_vec();
        m.extend_from_slice(&alice.verifying_key().to_bytes());
        m.extend_from_slice(&ts.to_be_bytes());
        dir.retire(&OwnerProof { key: b64(&alice), sig: B64.encode(alice.sign(&m).to_bytes()), ts }).unwrap();
        assert!(dir.grants.iter().all(|g| g.owner.is_empty() && g.sig.is_empty()), "nothing names the burned key");
        assert_eq!(dir.grants.iter().filter(|g| !g.taken).count(), 1, "only the coded one can come back");

        assert_eq!(dir.claim(&claim(&reborn, "WRONG-CODE")), Err(StatusCode::NOT_FOUND));
        let mut stolen = claim(&mallory, code);
        stolen.key = b64(&reborn);
        assert_eq!(dir.claim(&stolen), Err(StatusCode::UNAUTHORIZED), "a claim is signed by the key it's for");
        // Typed loosely: lower case, spaces, O for 0 and I or L for 1.
        assert_eq!(dir.claim(&claim(&reborn, "k7q2 9xmb oli0")).unwrap(), vec![Claimed { item: "tophat".into(), serial: 1 }]);
        assert_eq!(dir.claim(&claim(&mallory, code)), Err(StatusCode::NOT_FOUND), "a code works once");
        assert_eq!(dir.claims().len(), 1);
        assert_eq!(dir.claimed_by("tophat", 1), Some(b64(&reborn)));

        assert!(dir.reissue(signed(&mallory, 1)).is_err(), "only for the account that claimed it");
        assert!(dir.reissue(signed(&reborn, 1)).is_ok());
        assert!(dir.claims().is_empty());
        let back = dir.collectibles_of(&mine(&reborn)).unwrap();
        assert_eq!((back.len(), back[0].serial, back[0].coded), (1, 1, false), "same number, and it needs a new code");
        assert_eq!(dir.given().get("tophat"), Some(&2), "numbering carries on");
    }

    #[test]
    fn a_hundred_of_each_and_a_reset_starts_again_at_one() {
        let creator = SigningKey::from_bytes(&[7; 32]);
        let alice = SigningKey::from_bytes(&[1; 32]);
        let mut dir = Directory::default();
        let grant = |item: &str, serial: u32| {
            let mut m = b"pulshade.collectible.v1".to_vec();
            m.extend_from_slice(item.as_bytes());
            m.push(0);
            m.extend_from_slice(&serial.to_be_bytes());
            m.extend_from_slice(&alice.verifying_key().to_bytes());
            Grant { item: item.into(), serial, owner: B64.encode(alice.verifying_key().to_bytes()),
                    sig: B64.encode(creator.sign(&m).to_bytes()), taken: false, released: false, code: None, claim: None }
        };
        for n in 1..=DEFAULT_PER_ITEM { dir.give_collectible(grant("partyhat", n)).unwrap(); }
        let err = dir.give_collectible(grant("partyhat", DEFAULT_PER_ITEM + 1)).unwrap_err();
        assert!(err.contains("100"), "{err}");
        assert!(dir.give_collectible(grant("tophat", 1)).is_ok(), "each item has its own 100");
        dir.take_collectible("tophat", 1);
        assert_eq!(dir.reset_collectibles(), DEFAULT_PER_ITEM as usize, "taken-back ones aren't counted");
        assert!(dir.given().is_empty());
        assert!(dir.give_collectible(grant("partyhat", 1)).is_ok(), "numbering starts again at #1");
    }

    #[test]
    fn the_operator_can_change_how_many_of_a_collectible_there_are() {
        let creator = SigningKey::from_bytes(&[7u8; 32]);
        let alice = SigningKey::from_bytes(&[8u8; 32]);
        let mut dir = Directory::default();
        let grant = |item: &str, serial: u32| {
            let mut m = b"pulshade.collectible.v1".to_vec();
            m.extend_from_slice(item.as_bytes());
            m.push(0);
            m.extend_from_slice(&serial.to_be_bytes());
            m.extend_from_slice(&alice.verifying_key().to_bytes());
            Grant { item: item.into(), serial, owner: B64.encode(alice.verifying_key().to_bytes()),
                    sig: B64.encode(creator.sign(&m).to_bytes()), taken: false, released: false, code: None, claim: None }
        };
        assert_eq!(dir.limit_of("pulze"), DEFAULT_PER_ITEM, "100 unless set");
        // Fewer: only 3 of these will ever be.
        dir.set_limit("pulze", 3).unwrap();
        for n in 1..=3 { dir.give_collectible(grant("pulze", n)).unwrap(); }
        assert!(dir.give_collectible(grant("pulze", 4)).unwrap_err().contains("All 3"));
        assert_eq!(dir.limit_of("partyhat"), DEFAULT_PER_ITEM, "each item has its own");
        // It can't drop below what's been given out, or to nothing, or past the most.
        assert!(dir.set_limit("pulze", 2).unwrap_err().contains("3 have already"));
        assert!(dir.set_limit("pulze", 0).is_err());
        assert!(dir.set_limit("pulze", MOST_PER_ITEM + 1).is_err());
        assert!(dir.set_limit("Not An Item", 5).is_err());
        // More: room for the next one, and the ones already given keep their numbers.
        dir.set_limit("pulze", 500).unwrap();
        assert!(dir.give_collectible(grant("pulze", 4)).is_ok());
        assert_eq!(dir.limit_of("pulze"), 500);
        // Back to 100 forgets the setting.
        dir.set_limit("pulze", DEFAULT_PER_ITEM).unwrap();
        assert!(dir.limits().is_empty());
        // A giveaway can be as big as what is left to give.
        dir.set_limit("pulze", 8).unwrap();
        assert!(dir.add_giveaway(giveaway("a code", "pulze", 9)).is_err());
        assert!(dir.add_giveaway(giveaway("a code", "pulze", 8)).is_ok());
    }

    #[test]
    fn reserved_handles_belong_to_the_creator() {
        let creator = SigningKey::from_bytes(&[7; 32]);
        let someone = SigningKey::from_bytes(&[8; 32]);
        let mut dir = Directory::with_creator(&B64.encode(creator.verifying_key().to_bytes()));
        assert_eq!(dir.put("1", signed(&someone, "1", b"x", 1)), Err(StatusCode::FORBIDDEN));
        assert_eq!(dir.put("zeekz", signed(&someone, "zeekz", b"x", 1)), Err(StatusCode::FORBIDDEN));
        assert!(dir.put("1", signed(&creator, "1", b"me", 1)).is_ok());
        assert!(dir.put("zeekz", signed(&creator, "zeekz", b"me", 1)).is_ok());
        // Without a creator configured, nobody gets them.
        let mut open = Directory::default();
        assert_eq!(open.put("1", signed(&creator, "1", b"x", 1)), Err(StatusCode::FORBIDDEN));
    }

    #[test]
    fn only_the_key_holder_lists_its_handles() {
        let mut dir = Directory::default();
        let alice = SigningKey::from_bytes(&[1; 32]);
        let mallory = SigningKey::from_bytes(&[2; 32]);
        dir.put("nova", signed(&alice, "nova", b"v1", 10)).unwrap();
        dir.put("nova_two", signed(&alice, "nova_two", b"v2", 20)).unwrap();
        dir.put("other", signed(&mallory, "other", b"x", 5)).unwrap();
        let proof = |signer: &SigningKey, owner: &SigningKey, ts: u64| {
            let mut m = b"pulshade.dir.mine.v1".to_vec();
            m.extend_from_slice(owner.verifying_key().as_bytes());
            m.extend_from_slice(&ts.to_be_bytes());
            OwnerProof { key: B64.encode(owner.verifying_key().to_bytes()), sig: B64.encode(signer.sign(&m).to_bytes()), ts }
        };
        let mine = dir.owned(&proof(&alice, &alice, now())).unwrap();
        assert_eq!(mine.iter().map(|o| o.handle.as_str()).collect::<Vec<_>>(), ["nova_two", "nova"], "newest first");
        assert_eq!(dir.owned(&proof(&mallory, &alice, now())), Err(StatusCode::UNAUTHORIZED), "someone else's key");
        assert_eq!(dir.owned(&proof(&alice, &alice, now() - 3600)), Err(StatusCode::UNAUTHORIZED), "no replays");
    }

    #[test]
    fn bans_and_reserved_names() {
        let mut dir = Directory::default();
        let alice = SigningKey::from_bytes(&[1; 32]);
        let mallory = SigningKey::from_bytes(&[2; 32]);
        let mallory_key = B64.encode(mallory.verifying_key().to_bytes());
        dir.put("bad_one", signed(&mallory, "bad_one", b"x", 1)).unwrap();
        dir.put("bad_two", signed(&mallory, "bad_two", b"x", 2)).unwrap();
        dir.put("nova", signed(&alice, "nova", b"x", 1)).unwrap();

        // A banned name can't be claimed again, by anyone.
        dir.ban_handle("bad_one");
        assert!(dir.get("bad_one").is_none());
        assert_eq!(dir.put("bad_one", signed(&alice, "bad_one", b"x", 5)), Err(StatusCode::FORBIDDEN));
        assert!(dir.unban_handle("bad_one"));
        assert_eq!(dir.put("bad_one", signed(&alice, "bad_one", b"x", 6)), Err(StatusCode::LOCKED), "still Mallory's");
        assert!(dir.free("bad_one"));
        assert!(dir.put("bad_one", signed(&alice, "bad_one", b"x", 6)).is_ok());

        // A banned account loses every listing and can't make new ones, and nobody else gets its names.
        assert_eq!(dir.ban_key(&mallory_key), vec!["bad_two".to_string()]);
        assert_eq!(dir.put("bad_two", signed(&alice, "bad_two", b"x", 1)), Err(StatusCode::LOCKED));
        assert_eq!(dir.put("fresh", signed(&mallory, "fresh", b"x", 9)), Err(StatusCode::FORBIDDEN));
        assert!(dir.get("nova").is_some(), "Others are untouched");

        // Operator-reserved and service names need the creator.
        dir.reserve("brand");
        assert_eq!(dir.put("brand", signed(&alice, "brand", b"x", 1)), Err(StatusCode::FORBIDDEN));
        assert_eq!(dir.put("abuse", signed(&alice, "abuse", b"x", 1)), Err(StatusCode::FORBIDDEN));
        assert!(dir.unreserve("brand"));
        assert!(dir.put("brand", signed(&alice, "brand", b"x", 2)).is_ok());

        // Taking a listing down keeps the name for its owner, until the operator frees it.
        let carol = SigningKey::from_bytes(&[3; 32]);
        assert!(dir.take_down("nova"));
        assert_eq!(dir.put("nova", signed(&carol, "nova", b"x", 1)), Err(StatusCode::LOCKED));
        assert!(dir.put("nova", signed(&alice, "nova", b"x", 3)).is_ok());
        assert!(dir.take_down("nova"));
        assert!(dir.free("nova") && !dir.free("nova"));
        assert!(dir.put("nova", signed(&carol, "nova", b"x", 1)).is_ok());
    }

    #[test]
    fn limiter_caps_bursts() {
        let mut limits = Limiter::default();
        let ip: IpAddr = "10.0.0.1".parse().unwrap();
        for _ in 0..5 { assert!(limits.allow(ip, "x", 5, Duration::from_secs(60))); }
        assert!(!limits.allow(ip, "x", 5, Duration::from_secs(60)));
    }

    #[test]
    fn files_on_disk_are_sealed() {
        let dir = std::env::temp_dir().join(format!("pulshade-sealed-{}", now()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("pulshade-directory.json");
        // A file from before sealing.
        let alice = SigningKey::from_bytes(&[5; 32]);
        let mut old = Directory::default();
        old.put("plainold", signed(&alice, "plainold", b"v1", 10)).unwrap();
        std::fs::write(&path, serde_json::to_vec(&old.entries).unwrap()).unwrap();

        let mut dir_one = Directory::load(path.clone(), None, Sealer::with_key([1; 32]));
        assert!(dir_one.get("plainold").is_some(), "old files still load");
        dir_one.put("secretname", signed(&alice, "secretname", b"v2", 20)).unwrap();
        dir_one.reserve("hiddenname");
        dir_one.put("heldname", signed(&alice, "heldname", b"v3", 30)).unwrap();
        dir_one.take_down("heldname");
        for file in ["pulshade-directory.json", "pulshade-moderation.json", "pulshade-held.json"] {
            let raw = std::fs::read(dir.join(file)).unwrap();
            assert!(Sealer::is_sealed(&raw), "{file} is sealed");
            for word in [&b"plainold"[..], b"secretname", b"hiddenname", b"heldname"] {
                assert!(!raw.windows(word.len()).any(|w| w == word), "{file} shows nothing readable");
            }
        }
        let again = Directory::load(path.clone(), None, Sealer::with_key([1; 32]));
        assert!(again.get("secretname").is_some() && again.is_reserved("hiddenname") && again.is_held("heldname"));
        let wrong = std::panic::catch_unwind(|| Directory::load(path.clone(), None, Sealer::with_key([2; 32])));
        assert!(wrong.is_err(), "the wrong key stops the relay instead of starting empty");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn limiter_forgets_addresses_when_their_window_ends() {
        let mut limits = Limiter::default();
        let a: IpAddr = "10.0.0.1".parse().unwrap();
        let b: IpAddr = "10.0.0.2".parse().unwrap();
        limits.allow(a, "x", 5, Duration::from_millis(20));
        limits.allow(b, "y", 5, Duration::from_secs(3600));
        std::thread::sleep(Duration::from_millis(40));
        limits.sweep();
        assert_eq!(limits.remembered(), 1, "only the address whose window is still open stays");
    }
}
