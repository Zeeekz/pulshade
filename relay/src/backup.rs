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
    time::{Duration, SystemTime, UNIX_EPOCH},
};

pub const MAX_BACKUP: usize = 64 * 1024 * 1024;
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
        Backups { dir: Some(dir) }
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
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, blob).map_err(|_| StatusCode::INSUFFICIENT_STORAGE)?;
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
        std::fs::rename(tmp, path).map_err(|_| StatusCode::INSUFFICIENT_STORAGE)
    }

    pub fn get(&self, key_hex: &str, proof: &Proof) -> Result<Vec<u8>, StatusCode> {
        let name = Self::verify(key_hex, "pulshade.backup.get.v1", &proof.sig, proof.ts, None)?;
        std::fs::read(self.file(&name)?).map_err(|_| StatusCode::NOT_FOUND)
    }

    pub fn remove(&self, key_hex: &str, proof: &Proof) -> Result<(), StatusCode> {
        let name = Self::verify(key_hex, "pulshade.backup.del.v1", &proof.sig, proof.ts, None)?;
        let path = self.file(&name)?;
        if !path.exists() {
            return Err(StatusCode::NOT_FOUND);
        }
        erase(&path).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
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

/// Overwrites first, so the sealed bytes don't linger on disk, then removes.
fn erase(path: &Path) -> std::io::Result<()> {
    if let Ok(meta) = std::fs::metadata(path) {
        let _ = std::fs::write(path, vec![0u8; meta.len() as usize]);
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
}
