//! Sealing for the relay's own files. The handle directory and moderation lists are written to disk
//! encrypted with a key kept in the macOS Keychain, so the files alone reveal nothing.

use chacha20poly1305::{ChaCha20Poly1305, KeyInit, Nonce, aead::Aead};
use std::{path::Path, process::Command};

const MAGIC: &[u8; 4] = b"PSL1";
const SERVICE: &str = "app.pulshade.relay";
const ACCOUNT: &str = "storage-key";

pub struct Sealer {
    cipher: ChaCha20Poly1305,
}

fn random<const N: usize>() -> [u8; N] {
    let mut raw = [0u8; N];
    use std::io::Read;
    std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut raw)).expect("no randomness");
    raw
}

fn parse(hex_key: &str) -> Option<[u8; 32]> {
    hex::decode(hex_key.trim()).ok()?.try_into().ok()
}

impl Sealer {
    pub fn with_key(key: [u8; 32]) -> Self {
        Sealer { cipher: ChaCha20Poly1305::new(&key.into()) }
    }

    /// `PULSHADE_STORAGE_KEY` if set (tests use a throwaway one), otherwise the Keychain, creating the
    /// key on first run. Where there's no Keychain, a key file at `PULSHADE_STORAGE_KEY_FILE`, made there on
    /// first run: somewhere other than the data, so one copy of the relay's folder doesn't carry both. A
    /// `storage.key` beside the data, from older relays, still works but gets a warning.
    pub fn standard(beside: &Path) -> Self {
        Self::standard_or_explain(beside).unwrap_or_else(|why| {
            eprintln!("{why}");
            std::process::exit(1);
        })
    }

    fn standard_or_explain(beside: &Path) -> Result<Self, String> {
        if let Some(key) = std::env::var("PULSHADE_STORAGE_KEY").ok().as_deref().and_then(parse) {
            return Ok(Self::with_key(key));
        }
        if let Some(key) = Self::keychain() {
            return Ok(Self::with_key(key));
        }
        if let Ok(path) = std::env::var("PULSHADE_STORAGE_KEY_FILE") {
            let file = Path::new(&path);
            if let Ok(existing) = std::fs::read_to_string(file) {
                return parse(&existing).map(Self::with_key).ok_or(format!("{path} doesn't hold a storage key"));
            }
            let key: [u8; 32] = random();
            std::fs::write(file, hex::encode(key)).map_err(|e| format!("could not write {path}: {e}"))?;
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o600));
            return Ok(Self::with_key(key));
        }
        let old = beside.with_file_name("storage.key");
        if let Some(key) = std::fs::read_to_string(&old).ok().as_deref().and_then(parse) {
            eprintln!("warning: the storage key sits beside the data it seals ({}); move it elsewhere and set PULSHADE_STORAGE_KEY_FILE", old.display());
            return Ok(Self::with_key(key));
        }
        Err("no Keychain here: set PULSHADE_STORAGE_KEY_FILE to a path outside the relay's folder (an encrypted volume, say) for the storage key".into())
    }

    fn keychain() -> Option<[u8; 32]> {
        let find = || {
            Command::new("security").args(["find-generic-password", "-s", SERVICE, "-a", ACCOUNT, "-w"]).output().ok()
                .filter(|o| o.status.success())
                .and_then(|o| parse(&String::from_utf8_lossy(&o.stdout)))
        };
        if let Some(key) = find() {
            return Some(key);
        }
        let fresh: [u8; 32] = random();
        let added = Command::new("security")
            .args(["add-generic-password", "-s", SERVICE, "-a", ACCOUNT, "-l", "Pulshade relay storage", "-w", &hex::encode(fresh)])
            .status().ok()?;
        if added.success() { find() } else { None }
    }

    pub fn seal(&self, plain: &[u8]) -> Vec<u8> {
        let nonce: [u8; 12] = random();
        let sealed = self.cipher.encrypt(Nonce::from_slice(&nonce), plain).expect("sealing failed");
        [MAGIC.as_slice(), &nonce, &sealed].concat()
    }

    /// The contents of a sealed file. Files from before sealing are plain JSON and pass straight through.
    pub fn open(&self, raw: &[u8]) -> Option<Vec<u8>> {
        if !raw.starts_with(MAGIC) {
            return Some(raw.to_vec());
        }
        let rest = &raw[MAGIC.len()..];
        if rest.len() < 12 {
            return None;
        }
        self.cipher.decrypt(Nonce::from_slice(&rest[..12]), &rest[12..]).ok()
    }

    pub fn is_sealed(raw: &[u8]) -> bool {
        raw.starts_with(MAGIC)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seals_and_opens_and_lets_old_files_through() {
        let sealer = Sealer::with_key([9; 32]);
        let sealed = sealer.seal(br#"{"nova":1}"#);
        assert!(Sealer::is_sealed(&sealed));
        assert!(!sealed.windows(4).any(|w| w == b"nova"), "nothing readable in the file");
        assert_eq!(sealer.open(&sealed).unwrap(), br#"{"nova":1}"#);
        assert_eq!(sealer.open(br#"{"old":2}"#).unwrap(), br#"{"old":2}"#);
        assert!(Sealer::with_key([8; 32]).open(&sealed).is_none(), "another key can't open it");
        let mut tampered = sealed.clone();
        *tampered.last_mut().unwrap() ^= 1;
        assert!(sealer.open(&tampered).is_none());
    }
}
