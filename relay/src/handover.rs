//! Keeping waiting mail and wake-up registrations through a restart, without writing them anywhere.
//!
//! Both live in the relay's memory only, so a restart used to empty them. When the service manager stops the relay
//! to start a new one, the old relay packs what it holds into a memory-backed file (`memfd`: it has no name and is
//! never on a disk) and gives it to systemd's file-descriptor store, which keeps it in systemd's own memory. The
//! next relay is started with that descriptor and reads it back. A plain stop, a crash or a reboot hands nothing on,
//! so the promise stays the same: nothing waiting is ever written to disk.
//!
//! Mail is written into the file one message at a time straight from where it lives, and read back one at a time,
//! so handing over never holds a second copy of what is waiting (the server has little memory to spare).
//!
//! Only plain data crosses: mail with how long it has waited, the mailbox counters, the wake-up registrations with
//! how old each is, and the boot mark (so phones don't see a restart that lost nothing). Calls, rate-limit counts
//! and cooldowns are left behind: they matter for seconds.

use std::io::{Read, Write};
use std::time::Duration;

const MAGIC: &[u8; 4] = b"PHO1";
/// The name the descriptor is stored under, so the next relay knows which one is its own.
#[allow(dead_code)]
pub const NAME: &str = "pulshade-state";
/// What may be carried over is capped, so a damaged descriptor can't make the relay allocate without end.
const MAX_MAILBOXES: u32 = 2_000_000;
const MAX_ITEMS: u32 = 10_000_000;
const MAX_BLOB: u32 = 64 * 1024 * 1024;
const MAX_PUSH: u32 = 1_000_000;
/// More mail than the relay ever holds (its own cap is 384 MiB), so a damaged file can't make it allocate without end.
const MAX_TOTAL: u64 = 1024 * 1024 * 1024;

#[derive(Debug, PartialEq)]
pub struct Mail {
    pub id: u64,
    /// How long it has been waiting, so it expires on time in the new relay.
    pub waited: Duration,
    pub quiet: bool,
    pub blob: Vec<u8>,
}

#[derive(Debug, PartialEq)]
pub struct Registration {
    pub mailbox: [u8; 32],
    pub token: String,
    pub sandbox: bool,
    pub sound: bool,
    pub tone: Option<String>,
    pub voip: Option<String>,
    /// How long ago the phone registered, so its week runs on from where it was.
    pub age: Duration,
}

#[derive(Debug, PartialEq)]
pub struct Snapshot {
    pub boot: String,
    pub id_seed: [u8; 32],
    pub counter: u64,
    pub mailboxes: Vec<([u8; 32], Vec<Mail>)>,
    pub registrations: Vec<Registration>,
}

fn put_u8<W: Write + ?Sized>(w: &mut W, v: u8) -> std::io::Result<()> { w.write_all(&[v]) }
fn put_u32<W: Write + ?Sized>(w: &mut W, v: u32) -> std::io::Result<()> { w.write_all(&v.to_be_bytes()) }
fn put_u64<W: Write + ?Sized>(w: &mut W, v: u64) -> std::io::Result<()> { w.write_all(&v.to_be_bytes()) }
fn put_bytes<W: Write + ?Sized>(w: &mut W, v: &[u8]) -> std::io::Result<()> {
    put_u32(w, u32::try_from(v.len()).map_err(|_| std::io::ErrorKind::InvalidInput)?)?;
    w.write_all(v)
}
fn put_option<W: Write + ?Sized>(w: &mut W, v: &Option<String>) -> std::io::Result<()> {
    match v {
        Some(s) => { put_u8(w, 1)?; put_bytes(w, s.as_bytes()) }
        None => put_u8(w, 0),
    }
}

/// The start of a snapshot: the boot mark, the id seed and counter, and how many mailboxes follow.
pub fn write_head<W: Write + ?Sized>(w: &mut W, boot: &str, id_seed: &[u8; 32], counter: u64, mailboxes: usize) -> std::io::Result<()> {
    w.write_all(MAGIC)?;
    put_bytes(w, boot.as_bytes())?;
    w.write_all(id_seed)?;
    put_u64(w, counter)?;
    put_u32(w, u32::try_from(mailboxes).map_err(|_| std::io::ErrorKind::InvalidInput)?)
}

/// One mailbox, then exactly `count` calls of `write_mail`.
pub fn write_mailbox<W: Write + ?Sized>(w: &mut W, id: &[u8; 32], count: usize) -> std::io::Result<()> {
    w.write_all(id)?;
    put_u32(w, u32::try_from(count).map_err(|_| std::io::ErrorKind::InvalidInput)?)
}

/// One message of the mailbox just written. The bytes go straight out: nothing is copied first.
pub fn write_mail<W: Write + ?Sized>(w: &mut W, id: u64, waited: Duration, quiet: bool, blob: &[u8]) -> std::io::Result<()> {
    put_u64(w, id)?;
    put_u64(w, waited.as_millis() as u64)?;
    put_u8(w, quiet as u8)?;
    put_bytes(w, blob)
}

/// The end of a snapshot, after every mailbox.
pub fn write_registrations<W: Write + ?Sized>(w: &mut W, registrations: &[Registration]) -> std::io::Result<()> {
    put_u32(w, u32::try_from(registrations.len()).map_err(|_| std::io::ErrorKind::InvalidInput)?)?;
    for r in registrations {
        w.write_all(&r.mailbox)?;
        put_bytes(w, r.token.as_bytes())?;
        put_u8(w, r.sandbox as u8)?;
        put_u8(w, r.sound as u8)?;
        put_option(w, &r.tone)?;
        put_option(w, &r.voip)?;
        put_u64(w, r.age.as_millis() as u64)?;
    }
    Ok(())
}

fn take<R: Read, const N: usize>(r: &mut R) -> Option<[u8; N]> {
    let mut b = [0u8; N];
    r.read_exact(&mut b).ok()?;
    Some(b)
}
fn get_u8<R: Read>(r: &mut R) -> Option<u8> { take::<_, 1>(r).map(|b| b[0]) }
fn get_u32<R: Read>(r: &mut R) -> Option<u32> { take(r).map(u32::from_be_bytes) }
fn get_u64<R: Read>(r: &mut R) -> Option<u64> { take(r).map(u64::from_be_bytes) }
/// A length and that many bytes, read in as they come: a length that lies can't make this allocate more than
/// what is really there.
fn get_bytes<R: Read>(r: &mut R, most: u32) -> Option<Vec<u8>> {
    let n = get_u32(r)?;
    if n > most { return None; }
    let mut out = Vec::new();
    r.take(n as u64).read_to_end(&mut out).ok()?;
    (out.len() == n as usize).then_some(out)
}
fn get_string<R: Read>(r: &mut R) -> Option<String> { String::from_utf8(get_bytes(r, 4096)?).ok() }
fn get_option<R: Read>(r: &mut R) -> Option<Option<String>> {
    match get_u8(r)? {
        0 => Some(None),
        1 => Some(Some(get_string(r)?)),
        _ => None,
    }
}

/// Reads a snapshot, one message at a time, straight into what the new relay will hold. None if this isn't a
/// snapshot or it's damaged anywhere (or has anything after its end): then the relay starts empty, as it always did.
pub fn read<R: Read>(r: &mut R) -> Option<Snapshot> {
    if take::<_, 4>(r)? != *MAGIC { return None; }
    let boot = String::from_utf8(get_bytes(r, 64)?).ok()?;
    let id_seed = take::<_, 32>(r)?;
    let counter = get_u64(r)?;
    let boxes = get_u32(r)?;
    if boxes > MAX_MAILBOXES { return None; }
    let mut mailboxes = Vec::with_capacity((boxes as usize).min(4096));
    let (mut total, mut bytes) = (0u32, 0u64);
    for _ in 0..boxes {
        let id = take::<_, 32>(r)?;
        let count = get_u32(r)?;
        total = total.checked_add(count)?;
        if total > MAX_ITEMS { return None; }
        let mut mail = Vec::with_capacity((count as usize).min(4096));
        for _ in 0..count {
            let item = get_u64(r)?;
            let waited = Duration::from_millis(get_u64(r)?);
            let quiet = get_u8(r)? != 0;
            let blob = get_bytes(r, MAX_BLOB)?;
            bytes += blob.len() as u64;
            if bytes > MAX_TOTAL { return None; }
            mail.push(Mail { id: item, waited, quiet, blob });
        }
        mailboxes.push((id, mail));
    }
    let pushes = get_u32(r)?;
    if pushes > MAX_PUSH { return None; }
    let mut registrations = Vec::with_capacity((pushes as usize).min(4096));
    for _ in 0..pushes {
        let mailbox = take::<_, 32>(r)?;
        let token = get_string(r)?;
        let sandbox = get_u8(r)? != 0;
        let sound = get_u8(r)? != 0;
        let tone = get_option(r)?;
        let voip = get_option(r)?;
        let age = Duration::from_millis(get_u64(r)?);
        registrations.push(Registration { mailbox, token, sandbox, sound, tone, voip, age });
    }
    // Nothing may follow.
    let mut extra = [0u8; 1];
    if r.read(&mut extra).ok()? != 0 { return None; }
    Some(Snapshot { boot, id_seed, counter, mailboxes, registrations })
}

/// Sends the service manager one notification, with a descriptor if there is one.
#[cfg(target_os = "linux")]
fn notify(text: &str, descriptor: Option<std::os::fd::RawFd>) -> Result<(), String> {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    let path = std::env::var("NOTIFY_SOCKET").map_err(|_| "there is no service manager to talk to".to_string())?;
    let raw = path.as_bytes();
    // SAFETY: plain system calls on a socket this function creates and owns; every pointer handed to the kernel
    // points at a value that lives until the call returns.
    unsafe {
        let socket = libc::socket(libc::AF_UNIX, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, 0);
        if socket < 0 { return Err("couldn't open a socket".into()); }
        let socket = OwnedFd::from_raw_fd(socket);

        let mut address: libc::sockaddr_un = std::mem::zeroed();
        address.sun_family = libc::AF_UNIX as libc::sa_family_t;
        if raw.is_empty() || raw.len() >= address.sun_path.len() { return Err("the service socket's name is not usable".into()); }
        for (i, b) in raw.iter().enumerate() { address.sun_path[i] = *b as libc::c_char; }
        // A name starting with @ is in the abstract namespace: its first byte is a zero.
        if raw[0] == b'@' { address.sun_path[0] = 0; }
        let address_len = (std::mem::size_of::<libc::sa_family_t>() + raw.len()) as libc::socklen_t;

        let mut vector = libc::iovec { iov_base: text.as_ptr() as *mut libc::c_void, iov_len: text.len() };
        let space = libc::CMSG_SPACE(std::mem::size_of::<libc::c_int>() as u32) as usize;
        // Words, not bytes, so the control message is aligned the way the kernel expects.
        let mut control = vec![0u64; space.div_ceil(8)];
        let mut message: libc::msghdr = std::mem::zeroed();
        message.msg_name = &mut address as *mut libc::sockaddr_un as *mut libc::c_void;
        message.msg_namelen = address_len;
        message.msg_iov = &mut vector;
        message.msg_iovlen = 1;
        if let Some(descriptor) = descriptor {
            message.msg_control = control.as_mut_ptr() as *mut libc::c_void;
            message.msg_controllen = space as _;
            let header = libc::CMSG_FIRSTHDR(&message);
            if header.is_null() { return Err("no room for the descriptor".into()); }
            (*header).cmsg_level = libc::SOL_SOCKET;
            (*header).cmsg_type = libc::SCM_RIGHTS;
            (*header).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<libc::c_int>() as u32) as _;
            std::ptr::write(libc::CMSG_DATA(header) as *mut libc::c_int, descriptor);
        }
        if libc::sendmsg(socket.as_raw_fd(), &message, 0) < 0 {
            return Err(format!("the service manager didn't take it: {}", std::io::Error::last_os_error()));
        }
    }
    Ok(())
}

/// Writes a snapshot with `write` into a memory-backed file and gives it to the service manager (systemd) to keep
/// until the next relay starts. Nothing is written to disk. An error means it wasn't kept, and the next relay starts
/// empty.
#[cfg(target_os = "linux")]
pub fn give_to_service(write: impl FnOnce(&mut dyn Write) -> std::io::Result<()>) -> Result<(), String> {
    use std::io::{BufWriter, Seek, SeekFrom};
    use std::os::fd::AsRawFd;
    // SAFETY: a new anonymous file this function owns; File closes it.
    let file = unsafe {
        use std::os::fd::FromRawFd;
        let name = std::ffi::CString::new("pulshade-handover").map_err(|e| e.to_string())?;
        let memfd = libc::memfd_create(name.as_ptr(), libc::MFD_CLOEXEC);
        if memfd < 0 { return Err("couldn't make a memory file".into()); }
        std::fs::File::from_raw_fd(memfd)
    };
    let mut out = BufWriter::with_capacity(1 << 20, file);
    write(&mut out).map_err(|e| e.to_string())?;
    let mut file = out.into_inner().map_err(|e| e.to_string())?;
    // The receiver reads from the start: the descriptor's position is shared with the copy it is given.
    file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    notify(&format!("FDSTORE=1\nFDNAME={NAME}\n"), Some(file.as_raw_fd()))
}

/// Tells the service manager to let go of what it kept, once it's been taken over: otherwise a later crash would
/// start the relay with mail that was already delivered.
#[cfg(target_os = "linux")]
pub fn forget_in_service() {
    let _ = notify(&format!("FDSTOREREMOVE=1\nFDNAME={NAME}\n"), None);
}

/// What the previous relay gave the service manager, if this relay was started with it, as a file to read from the
/// start (it is read as it goes, never loaded whole).
#[cfg(target_os = "linux")]
pub fn take_from_service() -> Option<std::fs::File> {
    use std::io::{Seek, SeekFrom};
    use std::os::fd::FromRawFd;
    // systemd says which descriptors are for this process (LISTEN_PID), how many (LISTEN_FDS, from number 3) and
    // their names (LISTEN_FDNAMES).
    if std::env::var("LISTEN_PID").ok()?.parse::<u32>().ok()? != std::process::id() { return None; }
    let count: usize = std::env::var("LISTEN_FDS").ok()?.parse().ok()?;
    let names = std::env::var("LISTEN_FDNAMES").ok()?;
    let at = names.split(':').take(count).position(|n| n == NAME)?;
    // SAFETY: systemd opened this descriptor for this process and nothing else here owns it.
    let mut file = unsafe { std::fs::File::from_raw_fd(3 + at as i32) };
    file.seek(SeekFrom::Start(0)).ok()?;
    Some(file)
}

#[cfg(not(target_os = "linux"))]
pub fn give_to_service(_write: impl FnOnce(&mut dyn Write) -> std::io::Result<()>) -> Result<(), String> {
    Err("only a Linux service manager can keep it".into())
}

#[cfg(not(target_os = "linux"))]
pub fn take_from_service() -> Option<std::fs::File> {
    None
}

#[cfg(not(target_os = "linux"))]
pub fn forget_in_service() {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn sample() -> Snapshot {
        Snapshot {
            boot: "0123456789abcdef".into(),
            id_seed: [7; 32],
            counter: 42,
            mailboxes: vec![
                ([1; 32], vec![
                    Mail { id: 5, waited: Duration::from_secs(90), quiet: false, blob: vec![1, 2, 3] },
                    Mail { id: 6, waited: Duration::from_millis(1), quiet: true, blob: vec![9; 100_000] },
                ]),
                ([2; 32], vec![]),
            ],
            registrations: vec![
                Registration { mailbox: [1; 32], token: "ab".repeat(32), sandbox: true, sound: false, tone: Some("chime".into()), voip: None,
                               age: Duration::from_secs(3600) },
                Registration { mailbox: [2; 32], token: "cd".repeat(32), sandbox: false, sound: true, tone: None, voip: Some("ef".repeat(32)),
                               age: Duration::from_secs(1) },
            ],
        }
    }

    pub fn encode(s: &Snapshot) -> Vec<u8> {
        let mut out = Vec::new();
        write_head(&mut out, &s.boot, &s.id_seed, s.counter, s.mailboxes.len()).unwrap();
        for (id, mail) in &s.mailboxes {
            write_mailbox(&mut out, id, mail.len()).unwrap();
            for m in mail { write_mail(&mut out, m.id, m.waited, m.quiet, &m.blob).unwrap(); }
        }
        write_registrations(&mut out, &s.registrations).unwrap();
        out
    }

    fn decode(data: &[u8]) -> Option<Snapshot> { read(&mut Cursor::new(data)) }

    #[test]
    fn what_goes_in_comes_out() {
        let snapshot = sample();
        assert_eq!(decode(&encode(&snapshot)), Some(snapshot));
    }

    #[test]
    fn anything_damaged_is_refused_whole() {
        let good = encode(&sample());
        assert!(decode(&[]).is_none());
        assert!(decode(b"nope").is_none());
        for cut in [4, 20, 60, good.len() / 2, good.len() - 1] {
            assert!(decode(&good[..cut]).is_none(), "cut at {cut}");
        }
        let mut longer = good.clone();
        longer.push(0);
        assert!(decode(&longer).is_none(), "trailing bytes");
        let mut wrong = good.clone();
        wrong[0] = b'X';
        assert!(decode(&wrong).is_none(), "wrong marker");
    }

    #[test]
    fn a_huge_count_does_not_allocate() {
        let mut out = Vec::new();
        write_head(&mut out, "boot", &[0; 32], 0, 0).unwrap();
        let at = out.len() - 4;
        out[at..].copy_from_slice(&u32::MAX.to_be_bytes());
        assert!(decode(&out).is_none());
    }

    #[test]
    fn a_length_that_lies_does_not_allocate() {
        // One message that claims 60 MiB and has 3 bytes.
        let mut out = Vec::new();
        write_head(&mut out, "boot", &[0; 32], 0, 1).unwrap();
        write_mailbox(&mut out, &[1; 32], 1).unwrap();
        put_u64(&mut out, 1).unwrap();
        put_u64(&mut out, 0).unwrap();
        put_u8(&mut out, 0).unwrap();
        put_u32(&mut out, 60 * 1024 * 1024).unwrap();
        out.extend_from_slice(&[1, 2, 3]);
        assert!(decode(&out).is_none());
    }
}
