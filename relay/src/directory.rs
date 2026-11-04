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
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeSet, HashMap},
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
    /// What everyone is told, oldest first.
    announcements: Vec<Announcement>,
    announcements_path: Option<PathBuf>,
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
        let announcements_path = path.with_file_name("pulshade-announcements.json");
        let (entries, plain_entries) = read_sealed(&path, &sealer);
        let (moderation, plain_moderation) = read_sealed(&moderation_path, &sealer);
        let (held, _): (HashMap<String, serde_json::Value>, _) = read_sealed(&held_path, &sealer);
        let (announcements, _) = read_sealed(&announcements_path, &sealer);
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
            announcements,
            announcements_path: Some(announcements_path),
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
        Ok(count)
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
