//! The Mac app's updates. The operator copies a signed release into `pulshade-release/`, beside the directory; the
//! relay only hands it out. The app checks the signature against a key built
//! into it, so a relay that's been tampered with can't send an app of its own.

use axum::body::Bytes;
use std::{
    path::PathBuf,
    sync::Mutex,
    time::SystemTime,
};

/// The release's description and signature, small and read fresh each time.
pub const MANIFEST: &str = "mac.json";
/// The zipped app.
pub const ARCHIVE: &str = "mac.zip";

pub struct Releases {
    folder: PathBuf,
    /// The archive, kept once read so downloads share one copy, until a new release replaces the file.
    cached: Mutex<Option<(SystemTime, Bytes)>>,
}

impl Releases {
    pub fn at(folder: PathBuf) -> Self {
        Releases { folder, cached: Mutex::new(None) }
    }

    pub fn manifest(&self) -> Option<Bytes> {
        std::fs::read(self.folder.join(MANIFEST)).ok().map(Bytes::from)
    }

    pub fn archive(&self) -> Option<Bytes> {
        let path = self.folder.join(ARCHIVE);
        let modified = std::fs::metadata(&path).and_then(|m| m.modified()).ok()?;
        let mut cached = self.cached.lock().unwrap();
        if let Some((at, bytes)) = cached.as_ref() && *at == modified {
            return Some(bytes.clone());
        }
        let bytes = Bytes::from(std::fs::read(&path).ok()?);
        *cached = Some((modified, bytes.clone()));
        Some(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hands_out_what_the_operator_put_there_and_notices_a_new_release() {
        let dir = std::env::temp_dir().join(format!("pulshade-release-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let releases = Releases::at(dir.clone());
        assert!(releases.manifest().is_none() && releases.archive().is_none());

        std::fs::write(dir.join(MANIFEST), b"{\"build\":1}").unwrap();
        std::fs::write(dir.join(ARCHIVE), b"first").unwrap();
        assert_eq!(releases.manifest().unwrap(), Bytes::from_static(b"{\"build\":1}"));
        assert_eq!(releases.archive().unwrap(), Bytes::from_static(b"first"));

        // A file system's clock can be coarse, so make sure the new file's time differs.
        std::thread::sleep(std::time::Duration::from_millis(1100));
        std::fs::write(dir.join(ARCHIVE), b"second").unwrap();
        assert_eq!(releases.archive().unwrap(), Bytes::from_static(b"second"));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
