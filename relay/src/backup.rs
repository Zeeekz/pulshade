//! Sealed account backups, left behind when someone logs out of their only device.
//!
//! A backup is an opaque blob sealed on the device with a key only the recovery code can make. It's
//! stored under a public key that's also derived from the recovery code but from nothing else, so it
//! can't be tied to the account's directory key or anything it sends. Every read, write and removal
//! must carry a fresh signature from that key. Backups live on disk until restored or erased, or for
//! 180 days at most.

use axum::http::StatusCode;
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    path::{Path, PathBuf},
    sync::Mutex,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

/// The largest backup taken. The apps pad a backup to a power of two and sealing adds a few bytes, so this is the
/// 32 MB size and everything under it. (The limit was 64 MB exactly, which the 64 MB size never fitted under.)
pub const MAX_BACKUP: usize = 32 * 1024 * 1024 + 1024;
/// All backups on disk together. Past this, new ones are refused (507) instead of filling the disk; one already
/// here can still be replaced by another no larger.
pub const MAX_STORED: u64 = 2 * 1024 * 1024 * 1024;
/// How long a backup waits for its recovery code before it's erased.
pub const BACKUP_TTL: Duration = Duration::from_secs(180 * 24 * 3600);

/// A signed "it's me" for reading or removing a backup.
#[derive(Deserialize)]
pub struct Proof {
    /// Base64 signature over `label | key bytes | ts (u64 BE)`.
    pub sig: String,
    pub ts: u64,
}

pub struct Backups {
    dir: Option<PathBuf>,
    /// The most the folder may hold: `MAX_STORED`, or less in tests.
    ceiling: u64,
    /// Held while a backup is checked against the ceiling and written, so two at once can't both take the last room.
    writing: Mutex<()>,
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn signed_message(label: &str, key: &VerifyingKey, ts: u64, body: Option<&[u8]>) -> Vec<u8> {
    let mut message = label.as_bytes().to_vec();
    message.extend_from_slice(key.as_bytes());
    message.extend_from_slice(&ts.to_be_bytes());
    if let Some(body) = body {
        message.extend_from_slice(&Sha256::digest(body));
    }
    message
}

impl Backups {
    pub fn at(dir: PathBuf) -> Self {
        let _ = std::fs::create_dir_all(&dir);
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
        Backups { dir: Some(dir), ceiling: MAX_STORED, writing: Mutex::new(()) }
    }

    /// The size of everything in the folder.
    fn stored(&self) -> u64 {
        let Some(files) = self.dir.as_ref().and_then(|dir| std::fs::read_dir(dir).ok()) else { return 0 };
        files.flatten().filter_map(|file| file.metadata().ok()).map(|meta| meta.len()).sum()
    }

    #[cfg(test)]
    pub fn temporary() -> Self {
        let dir = std::env::temp_dir().join(format!("pulshade-backups-{}", hex::encode(rand_bytes())));
        Self::at(dir)
    }

    /// Checks the key is real and the signature over this request is fresh and its own.
    fn verify(key_hex: &str, label: &str, sig_b64: &str, ts: u64, body: Option<&[u8]>) -> Result<String, StatusCode> {
        let raw: [u8; 32] = hex::decode(key_hex).ok().and_then(|r| r.try_into().ok()).ok_or(StatusCode::BAD_REQUEST)?;
        let key = VerifyingKey::from_bytes(&raw).map_err(|_| StatusCode::BAD_REQUEST)?;
        let sig: [u8; 64] = B64.decode(sig_b64).ok().and_then(|r| r.try_into().ok()).ok_or(StatusCode::BAD_REQUEST)?;
        if now().abs_diff(ts) > 300 {
            return Err(StatusCode::UNAUTHORIZED);
        }
        key.verify(&signed_message(label, &key, ts, body), &Signature::from_bytes(&sig))
            .map_err(|_| StatusCode::UNAUTHORIZED)?;
        // Always the lower-case form, so one key has exactly one file.
        Ok(hex::encode(raw))
    }

    fn file(&self, name: &str) -> Result<PathBuf, StatusCode> {
        self.dir.as_ref().map(|d| d.join(name)).ok_or(StatusCode::INTERNAL_SERVER_ERROR)
    }

    pub fn put(&self, key_hex: &str, sig: &str, ts: u64, blob: &[u8]) -> Result<(), StatusCode> {
        if blob.is_empty() || blob.len() > MAX_BACKUP {
            return Err(StatusCode::PAYLOAD_TOO_LARGE);
        }
        let name = Self::verify(key_hex, "pulshade.backup.put.v1", sig, ts, Some(blob))?;
        let path = self.file(&name)?;
        let _writing = self.writing.lock().unwrap();
        let replaced = std::fs::metadata(&path).map(|meta| meta.len()).unwrap_or(0);
        if self.stored().saturating_sub(replaced) + blob.len() as u64 > self.ceiling {
            return Err(StatusCode::INSUFFICIENT_STORAGE);
        }
        let tmp = path.with_extension("tmp");
        let written = crate::sealed::write_private(&tmp, blob).and_then(|()| std::fs::rename(&tmp, path));
        if written.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
        written.map_err(|_| StatusCode::INSUFFICIENT_STORAGE)
    }

    /// The backup's file, open for reading, and its size, so it can be sent a piece at a time.
    pub fn open(&self, key_hex: &str, proof: &Proof) -> Result<(std::fs::File, u64), StatusCode> {
        let name = Self::verify(key_hex, "pulshade.backup.get.v1", &proof.sig, proof.ts, None)?;
        let file = std::fs::File::open(self.file(&name)?).map_err(|_| StatusCode::NOT_FOUND)?;
        let size = file.metadata().map_err(|_| StatusCode::NOT_FOUND)?.len();
        Ok((file, size))
    }

    #[cfg(test)]
    pub fn get(&self, key_hex: &str, proof: &Proof) -> Result<Vec<u8>, StatusCode> {
        use std::io::Read;
        let (mut file, size) = self.open(key_hex, proof)?;
        let mut blob = Vec::with_capacity(size as usize);
        file.read_to_end(&mut blob).map_err(|_| StatusCode::NOT_FOUND)?;
        Ok(blob)
    }

    pub fn remove(&self, key_hex: &str, proof: &Proof) -> Result<(), StatusCode> {
        let name = Self::verify(key_hex, "pulshade.backup.del.v1", &proof.sig, proof.ts, None)?;
        let path = self.file(&name)?;
        if !path.exists() {
            return Err(StatusCode::NOT_FOUND);
        }
        if let Ok(sidecar) = self.file(&format!("{name}.del")) { let _ = erase(&sidecar); }
        erase(&path).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
    }

    /// Remembers a hash of a delete-only token for this backup (the file is a hash, never the token). Whoever holds the
    /// token can erase the backup with `forget` and can do nothing else with it: the panic passcode keeps one so it can
    /// take the relay's copy away without holding the account's keys. Called after a signed `put`.
    pub fn set_forget_hash(&self, key_hex: &str, hash: &[u8; 32]) {
        let Some(name) = hex::decode(key_hex).ok().filter(|r| r.len() == 32).map(hex::encode) else { return };
        let Ok(path) = self.file(&format!("{name}.del")) else { return };
        let tmp = path.with_extension("deltmp");
        if crate::sealed::write_private(&tmp, hash).and_then(|()| std::fs::rename(&tmp, &path)).is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
    }

    /// Erases the backup (and the stored hash) for whoever presents the delete-only token it was filed with.
    pub fn forget(&self, key_hex: &str, token_hex: &str) -> Result<(), StatusCode> {
        let name = hex::decode(key_hex).ok().filter(|r| r.len() == 32).map(hex::encode).ok_or(StatusCode::BAD_REQUEST)?;
        let token = hex::decode(token_hex).ok().filter(|r| r.len() == 32).ok_or(StatusCode::BAD_REQUEST)?;
        let sidecar = self.file(&format!("{name}.del"))?;
        // 410, not 404: a relay without this route answers 404, and the app must tell the two apart.
        let stored = std::fs::read(&sidecar).map_err(|_| StatusCode::GONE)?;
        let given = Sha256::digest(&token);
        // Compared without stopping at the first difference.
        let same = stored.len() == given.len() && stored.iter().zip(given.iter()).fold(0u8, |d, (a, b)| d | (a ^ b)) == 0;
        if !same {
            return Err(StatusCode::UNAUTHORIZED);
        }
        let _writing = self.writing.lock().unwrap();
        let blob = self.file(&name)?;
        if blob.exists() { erase(&blob).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?; }
        erase(&sidecar).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
    }

    /// Erases every backup written more than `max_age` ago.
    pub fn sweep(&self, max_age: Duration) {
        let Some(dir) = &self.dir else { return };
        let Ok(files) = std::fs::read_dir(dir) else { return };
        for file in files.flatten() {
            let old = file.metadata().and_then(|m| m.modified()).ok()
                .and_then(|at| at.elapsed().ok())
                .is_some_and(|age| age > max_age);
            if old { let _ = erase(&file.path()); }
        }
    }
}

/// Overwrites with random bytes and flushes them to the disk, so the sealed bytes don't linger, then removes. On a
/// solid-state disk, or one with snapshots, an old copy can still survive somewhere the file system can't reach; the
/// backup is encrypted on the device with a key made from the recovery code, which is what keeps such a copy closed.
fn erase(path: &Path) -> std::io::Result<()> {
    use std::io::{Read, Write};
    if let Ok(meta) = std::fs::metadata(path) {
        let mut noise = vec![0u8; usize::try_from(meta.len()).unwrap_or(0)];
        if let Ok(mut random) = std::fs::File::open("/dev/urandom") { let _ = random.read_exact(&mut noise); }
        if let Ok(mut file) = std::fs::OpenOptions::new().write(true).open(path) {
            let _ = file.write_all(&noise);
            let _ = file.sync_all();
        }
    }
    std::fs::remove_file(path)
}

#[cfg(test)]
fn rand_bytes() -> [u8; 16] {
    let mut raw = [0u8; 16];
    use std::io::Read;
    std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut raw)).unwrap();
    raw
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    fn signed(signer: &SigningKey, owner: &SigningKey, label: &str, ts: u64, body: Option<&[u8]>) -> String {
        B64.encode(signer.sign(&signed_message(label, &owner.verifying_key(), ts, body)).to_bytes())
    }

    #[test]
    fn only_the_key_holder_reads_writes_and_removes() {
        let backups = Backups::temporary();
        let alice = SigningKey::from_bytes(&[3; 32]);
        let mallory = SigningKey::from_bytes(&[4; 32]);
        let id = hex::encode(alice.verifying_key().as_bytes());
        let t = now();
        let blob = b"sealed account";

        let put = |signer: &SigningKey, body: &[u8], ts: u64| {
            backups.put(&id, &signed(signer, &alice, "pulshade.backup.put.v1", ts, Some(body)), ts, body)
        };
        let proof = |signer: &SigningKey, label: &str, ts: u64| Proof { sig: signed(signer, &alice, label, ts, None), ts };

        assert_eq!(put(&mallory, blob, t), Err(StatusCode::UNAUTHORIZED), "someone else's key");
        assert_eq!(put(&alice, blob, t - 3600), Err(StatusCode::UNAUTHORIZED), "no replays");
        let wrong_body = backups.put(&id, &signed(&alice, &alice, "pulshade.backup.put.v1", t, Some(b"other")), t, blob);
        assert_eq!(wrong_body, Err(StatusCode::UNAUTHORIZED), "signature covers the contents");
        assert_eq!(backups.get(&id, &proof(&alice, "pulshade.backup.get.v1", t)), Err(StatusCode::NOT_FOUND));

        put(&alice, blob, t).unwrap();
        assert_eq!(backups.get(&id, &proof(&mallory, "pulshade.backup.get.v1", t)), Err(StatusCode::UNAUTHORIZED));
        assert_eq!(backups.get(&id, &proof(&alice, "pulshade.backup.del.v1", t)), Err(StatusCode::UNAUTHORIZED),
                   "a removal proof can't be used to read");
        assert_eq!(backups.get(&id.to_uppercase(), &proof(&alice, "pulshade.backup.get.v1", t)).unwrap(), blob);

        assert_eq!(backups.remove(&id, &proof(&mallory, "pulshade.backup.del.v1", t)), Err(StatusCode::UNAUTHORIZED));
        backups.remove(&id, &proof(&alice, "pulshade.backup.del.v1", t)).unwrap();
        assert_eq!(backups.get(&id, &proof(&alice, "pulshade.backup.get.v1", t)), Err(StatusCode::NOT_FOUND));
    }

    #[test]
    fn old_backups_are_erased() {
        let backups = Backups::temporary();
        let alice = SigningKey::from_bytes(&[5; 32]);
        let id = hex::encode(alice.verifying_key().as_bytes());
        let (t, blob) = (now(), b"sealed account");
        backups.put(&id, &signed(&alice, &alice, "pulshade.backup.put.v1", t, Some(blob)), t, blob).unwrap();
        let get = || backups.get(&id, &Proof { sig: signed(&alice, &alice, "pulshade.backup.get.v1", t, None), ts: t });

        backups.sweep(BACKUP_TTL);
        assert_eq!(get().unwrap(), blob, "a fresh backup stays");
        std::thread::sleep(Duration::from_millis(20));
        backups.sweep(Duration::from_millis(10));
        assert_eq!(get(), Err(StatusCode::NOT_FOUND), "an old one goes");
    }

    /// The folder has a ceiling, so backups can't fill the disk. One already there can still be saved again.
    #[test]
    fn backups_are_refused_once_the_folder_is_full() {
        use std::os::unix::fs::PermissionsExt;
        let mut backups = Backups::temporary();
        backups.ceiling = 250;
        let t = now();
        let put = |seed: u8, body: &[u8]| {
            let owner = SigningKey::from_bytes(&[seed; 32]);
            let id = hex::encode(owner.verifying_key().as_bytes());
            backups.put(&id, &signed(&owner, &owner, "pulshade.backup.put.v1", t, Some(body)), t, body).map(|()| id)
        };
        let first = put(11, &[1u8; 100]).unwrap();
        put(12, &[2u8; 100]).unwrap();
        assert_eq!(put(13, &[3u8; 100]), Err(StatusCode::INSUFFICIENT_STORAGE), "no room for a third");
        assert_eq!(put(13, &[3u8; 50]).map(|_| ()), Ok(()), "what fits is still taken");
        assert_eq!(put(11, &[4u8; 100]).map(|_| ()), Ok(()), "one already here is replaced");
        assert_eq!(put(11, &[5u8; 101]), Err(StatusCode::INSUFFICIENT_STORAGE), "but not by a larger one");
        assert_eq!(backups.stored(), 250);
        let mode = std::fs::metadata(backups.file(&first).unwrap()).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "only the relay reads it");
        let _ = std::fs::remove_dir_all(backups.dir.as_ref().unwrap());
    }

    #[test]
    fn a_delete_only_token_erases_the_backup_and_nothing_else() {
        let backups = Backups::temporary();
        let owner = SigningKey::from_bytes(&[9u8; 32]);
        let id = hex::encode(owner.verifying_key().to_bytes());
        let ts = now();
        let body: &[u8] = b"sealed";
        backups.put(&id, &signed(&owner, &owner, "pulshade.backup.put.v1", ts, Some(body)), ts, body).unwrap();
        let token = [3u8; 32];
        backups.set_forget_hash(&id, &Sha256::digest(token).into());
        assert_eq!(backups.forget(&id, &hex::encode([4u8; 32])), Err(StatusCode::UNAUTHORIZED), "a wrong token does nothing");
        assert_eq!(backups.forget(&id, "zz"), Err(StatusCode::BAD_REQUEST));
        assert!(backups.file(&id).unwrap().exists());
        assert_eq!(backups.forget(&id, &hex::encode(token)), Ok(()));
        assert!(!backups.file(&id).unwrap().exists(), "the backup is gone");
        assert!(!backups.file(&format!("{id}.del")).unwrap().exists(), "and so is the stored hash");
        assert_eq!(backups.forget(&id, &hex::encode(token)), Err(StatusCode::GONE), "a second try finds nothing");
    }
}
