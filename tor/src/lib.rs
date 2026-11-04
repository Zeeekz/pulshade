//! Tor for Pulshade: Arti, behind a SOCKS5 port on 127.0.0.1 that only the app can use.
//!
//! Every SOCKS username gets its own circuits, so each of the app's lanes (a persona, an inbox, sending)
//! reaches the relay from a different exit and can't be linked to the others by circuit. The password is
//! a secret the app picks at launch; anything else on the machine that finds the port is turned away.

use std::collections::{BTreeSet, HashMap};
use std::ffi::{CStr, CString, c_char};
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::atomic::{AtomicI32, AtomicU16, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use arti_client::config::pt::TransportConfigBuilder;
use arti_client::config::{BoolOrAuto, BridgeConfigBuilder, Reconfigure, TorClientConfig, TorClientConfigBuilder};
use arti_client::{BootstrapBehavior, DataStream, IsolationToken, StreamPrefs, TorClient};
use tokio::io::{AsyncReadExt, AsyncWriteExt, copy_bidirectional};
use tokio::net::{TcpListener, TcpStream};

/// Bootstrap progress, 0 to 100, or -1 when Tor couldn't start.
static PROGRESS: AtomicI32 = AtomicI32::new(0);
/// The SOCKS port, 0 until started. It can change if the port has to be opened again and the old one is gone.
static PORT: AtomicU16 = AtomicU16::new(0);
/// Asks the listener to open its port again, and answers with the port it's on.
static RELISTEN: OnceLock<tokio::sync::mpsc::UnboundedSender<std::sync::mpsc::Sender<u16>>> = OnceLock::new();

type Client = TorClient<tor_rtcompat::PreferredRuntime>;

/// Where Tor keeps its state and its cache.
static DIRS: OnceLock<(String, String)> = OnceLock::new();
/// The bridges in use, one bridge line per line; empty for none.
static BRIDGES: Mutex<String> = Mutex::new(String::new());
/// The client once it's made, so bridges can be changed while it runs.
static CLIENT: OnceLock<Arc<Client>> = OnceLock::new();

/// The pluggable transports Pulshade runs (tor/pt, from Tor Project's lyrebird, built into the app).
const TRANSPORTS: [&str; 2] = ["webtunnel", "snowflake"];

unsafe extern "C" {
    fn pulshade_pt_start(state_dir: *const c_char) -> *mut c_char;
    fn pulshade_pt_free(text: *mut c_char);
}

/// Starts the transports the first time a bridge needs one, and returns where each listens.
fn transports(state_dir: &str) -> HashMap<String, SocketAddr> {
    static STARTED: OnceLock<HashMap<String, SocketAddr>> = OnceLock::new();
    STARTED
        .get_or_init(|| {
            let dir = format!("{state_dir}/pt");
            let _ = std::fs::create_dir_all(&dir);
            let Ok(dir) = CString::new(dir) else { return HashMap::new() };
            let raw = unsafe { pulshade_pt_start(dir.as_ptr()) };
            if raw.is_null() {
                return HashMap::new();
            }
            let text = unsafe { CStr::from_ptr(raw) }.to_string_lossy().into_owned();
            unsafe { pulshade_pt_free(raw) };
            text.split(',')
                .filter_map(|pair| {
                    let (name, addr) = pair.split_once('=')?;
                    Some((name.to_owned(), addr.parse().ok()?))
                })
                .collect()
        })
        .clone()
}

/// The bridge lines Arti can use, with the transport each needs: lines that parse, whose transport (if any) is one
/// Pulshade runs. Tor's own "Bridge " prefix is allowed.
fn usable(lines: &str) -> Vec<(BridgeConfigBuilder, Option<String>)> {
    lines
        .lines()
        .map(str::trim)
        .map(|line| line.strip_prefix("Bridge ").unwrap_or(line).trim())
        .filter(|line| !line.is_empty())
        .filter_map(|line| {
            let bridge = line.parse::<BridgeConfigBuilder>().ok()?;
            // A plain bridge starts with its address; anything else starts with its transport's name.
            let first = line.split_whitespace().next()?;
            let transport = (!first.contains(':')).then(|| first.to_owned());
            if transport.as_deref().is_some_and(|name| !TRANSPORTS.contains(&name)) {
                return None;
            }
            Some((bridge, transport))
        })
        .collect()
}

/// Tor's configuration, with these bridges (none for an empty string).
fn config(state_dir: &str, cache_dir: &str, bridges: &str) -> Option<TorClientConfig> {
    let mut config = TorClientConfigBuilder::from_directories(state_dir, cache_dir);
    // The app's own container is private to it; on iOS its folders don't pass Arti's ownership checks.
    config.storage().permissions().dangerously_trust_everyone();
    let bridges = usable(bridges);
    if !bridges.is_empty() {
        let mut needed = BTreeSet::new();
        for (bridge, transport) in bridges {
            needed.extend(transport);
            config.bridges().bridges().push(bridge);
        }
        let running = if needed.is_empty() { HashMap::new() } else { transports(state_dir) };
        for name in needed {
            let addr = *running.get(&name)?;
            let mut transport = TransportConfigBuilder::default();
            transport.protocols(vec![name.parse().ok()?]).proxy_addr(addr);
            config.bridges().transports().push(transport);
        }
        config.bridges().enabled(BoolOrAuto::Explicit(true));
    }
    config.build().ok()
}

/// How many of these bridge lines Pulshade can use.
///
/// # Safety
/// `lines` must be a valid, NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pulshade_tor_count_bridges(lines: *const c_char) -> i32 {
    let Ok(lines) = unsafe { CStr::from_ptr(lines) }.to_str() else { return 0 };
    usable(lines).len() as i32
}

/// Connects through these bridges from now on (an empty string for none). Returns how many are usable, or -1 if
/// Tor is running and couldn't switch to them; they're used from the next start either way.
///
/// # Safety
/// `lines` must be a valid, NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pulshade_tor_set_bridges(lines: *const c_char) -> i32 {
    let Ok(lines) = unsafe { CStr::from_ptr(lines) }.to_str() else { return -1 };
    *BRIDGES.lock().unwrap() = lines.to_owned();
    let count = usable(lines).len() as i32;
    let (Some(client), Some((state, cache))) = (CLIENT.get(), DIRS.get()) else { return count };
    let switched = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        config(state, cache, lines).is_some_and(|new| client.reconfigure(&new, Reconfigure::AllOrNothing).is_ok())
    }));
    if switched.unwrap_or(false) { count } else { -1 }
}

/// The client, once it's made. Making it reads Tor's saved state from disk, which can take a moment on a
/// phone, so it happens in the background and connections wait for it.
#[derive(Clone)]
enum Ready {
    Starting,
    Up(Arc<Client>),
    Failed,
}

struct Proxy {
    client: tokio::sync::watch::Receiver<Ready>,
    secret: String,
}

/// Each lane's isolation: streams with the same token share circuits, so a lane keeps its circuit until it's
/// renewed. Memory only.
static LANES: Mutex<Option<HashMap<String, IsolationToken>>> = Mutex::new(None);

/// Each lane's latest circuit, for the app's anonymity report: the relays' addresses in order, and
/// "onion" for the last leg into an onion service. Memory only.
static CIRCUITS: Mutex<Option<HashMap<String, Vec<String>>>> = Mutex::new(None);

fn remember_circuit(lane: &str, stream: &arti_client::DataStream) {
    use tor_linkspec::HasAddrs;
    use tor_proto::client::stream::ClientStreamCtrl;
    let Some(tunnel) = stream.client_stream_ctrl().and_then(|c| c.tunnel()) else { return };
    let Some(path) = tunnel.all_paths().into_iter().next() else { return };
    let hops = path
        .iter()
        .map(|hop| match hop.as_chan_target() {
            Some(relay) => {
                let addrs: Vec<_> = relay.addrs().collect();
                addrs.iter().find(|a| a.is_ipv4()).or(addrs.first()).map(|a| a.ip().to_string()).unwrap_or_default()
            }
            None => "onion".to_owned(),
        })
        .collect();
    CIRCUITS.lock().unwrap().get_or_insert_with(HashMap::new).insert(lane.to_owned(), hops);
}

/// Every lane's latest circuit, one per line: `lane<TAB>hop,hop,hop`. Free it with `pulshade_tor_free`.
#[unsafe(no_mangle)]
pub extern "C" fn pulshade_tor_circuits() -> *mut c_char {
    let text = CIRCUITS.lock().unwrap().as_ref().map_or(String::new(), |all| {
        all.iter().map(|(lane, hops)| format!("{}\t{}\n", lane.replace(['\t', '\n'], " "), hops.join(","))).collect()
    });
    CString::new(text).unwrap_or_default().into_raw()
}

/// Frees a string returned by this library.
///
/// # Safety
/// `text` must come from `pulshade_tor_circuits`, and be freed only once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pulshade_tor_free(text: *mut c_char) {
    if !text.is_null() {
        drop(unsafe { CString::from_raw(text) });
    }
}

fn isolation(lane: &str) -> IsolationToken {
    *LANES.lock().unwrap().get_or_insert_with(HashMap::new).entry(lane.to_owned()).or_insert_with(IsolationToken::new)
}

fn set_isolation(lane: &str, token: IsolationToken) {
    LANES.lock().unwrap().get_or_insert_with(HashMap::new).insert(lane.to_owned(), token);
}

/// How long a lane's own circuit gets before a fresh one races it.
const RACE_AFTER: Duration = Duration::from_secs(4);

/// Opens a stream for a lane. A new circuit into an onion service usually connects in 2 to 5 seconds, but now
/// and then one waits on an introduction point for 15 seconds or more. So past a few seconds, a second attempt
/// on a fresh circuit races it, and whichever connects first is kept, and becomes the lane's circuit. One that
/// fails outright is tried once more on a fresh circuit.
async fn open(client: &Client, host: &str, port: u16, lane: &str) -> Option<DataStream> {
    let first = connect(client, host, port, isolation(lane));
    tokio::pin!(first);
    match tokio::time::timeout(RACE_AFTER, &mut first).await {
        Ok(Ok(stream)) => return Some(stream),
        Ok(Err(_)) => {}
        Err(_) => {
            let fresh = IsolationToken::new();
            let second = connect(client, host, port, fresh);
            tokio::pin!(second);
            return tokio::select! {
                made = &mut first => match made {
                    Ok(stream) => Some(stream),
                    Err(_) => second.await.ok().inspect(|_| set_isolation(lane, fresh)),
                },
                made = &mut second => match made {
                    Ok(stream) => {
                        set_isolation(lane, fresh);
                        Some(stream)
                    }
                    Err(_) => first.await.ok(),
                },
            };
        }
    }
    let fresh = IsolationToken::new();
    set_isolation(lane, fresh);
    connect(client, host, port, fresh).await.ok()
}

async fn connect(client: &Client, host: &str, port: u16, token: IsolationToken) -> Result<DataStream, arti_client::Error> {
    let mut prefs = StreamPrefs::new();
    prefs.set_isolation(token);
    prefs.connect_to_onion_services(arti_client::config::BoolOrAuto::Explicit(true));
    client.connect_with_prefs((host, port), &prefs).await
}

/// Gives a lane a fresh isolation token, so its next stream builds a new circuit. A circuit into an onion
/// service can stay up while carrying nothing; without this, every request on that lane would hang on it.
///
/// # Safety
/// `lane` must be a valid, NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pulshade_tor_renew(lane: *const c_char) {
    let Ok(lane) = unsafe { CStr::from_ptr(lane) }.to_str() else { return };
    LANES.lock().unwrap().get_or_insert_with(HashMap::new).insert(lane.to_owned(), IsolationToken::new());
    if let Some(all) = CIRCUITS.lock().unwrap().as_mut() {
        all.remove(lane);
    }
}

/// Starts Tor once and returns the SOCKS port, or 0 if it couldn't. Later calls return the same port.
/// Returns straight away: making the client and bootstrapping carry on in the background, and connections
/// made before they're done wait for them.
///
/// # Safety
/// The arguments must be valid, NUL-terminated UTF-8 strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pulshade_tor_start(
    state_dir: *const c_char,
    cache_dir: *const c_char,
    secret: *const c_char,
    bridges: *const c_char,
) -> u16 {
    let port = PORT.load(Ordering::Relaxed);
    if port != 0 {
        return port;
    }
    let text = |p: *const c_char| unsafe { CStr::from_ptr(p) }.to_str().map(str::to_owned);
    let (Ok(state_dir), Ok(cache_dir), Ok(secret), Ok(bridges)) = (text(state_dir), text(cache_dir), text(secret), text(bridges)) else {
        return 0;
    };
    *BRIDGES.lock().unwrap() = bridges;
    std::panic::catch_unwind(|| start(state_dir, cache_dir, secret)).ok().flatten().unwrap_or(0)
}

/// 0 to 100 while connecting, 100 once ready, -1 if Tor failed to start.
#[unsafe(no_mangle)]
pub extern "C" fn pulshade_tor_progress() -> i32 {
    PROGRESS.load(Ordering::Relaxed)
}

fn start(state_dir: String, cache_dir: String, secret: String) -> Option<u16> {
    let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().ok()?;
    let listener = runtime.block_on(TcpListener::bind((Ipv4Addr::LOCALHOST, 0))).ok()?;
    let port = listener.local_addr().ok()?.port();

    let (ready, client) = tokio::sync::watch::channel(Ready::Starting);
    runtime.spawn(async move {
        let made = tokio::task::spawn_blocking(move || {
            let _ = DIRS.set((state_dir.clone(), cache_dir.clone()));
            let bridges = BRIDGES.lock().unwrap().clone();
            let config = config(&state_dir, &cache_dir, &bridges)?;
            let tor_runtime = tor_rtcompat::PreferredRuntime::current().ok()?;
            TorClient::with_runtime(tor_runtime)
                .config(config)
                .bootstrap_behavior(BootstrapBehavior::OnDemand)
                .create_unbootstrapped()
                .ok()
        })
        .await
        .ok()
        .flatten();
        let Some(watched) = made else {
            PROGRESS.store(-1, Ordering::Relaxed);
            let _ = ready.send(Ready::Failed);
            return;
        };
        let _ = CLIENT.set(watched.clone());
        let _ = ready.send(Ready::Up(watched.clone()));
        let mut events = watched.bootstrap_events();
        tokio::spawn(async move {
            use futures::StreamExt;
            while let Some(status) = events.next().await {
                if PROGRESS.load(Ordering::Relaxed) >= 0 {
                    PROGRESS.store(if status.ready_for_traffic() { 100 } else { (status.as_frac() * 99.0) as i32 }, Ordering::Relaxed);
                }
            }
        });
        if watched.bootstrap().await.is_err() {
            PROGRESS.store(-1, Ordering::Relaxed);
        }
    });
    let proxy = Arc::new(Proxy { client, secret });

    let (relisten, mut asked) = tokio::sync::mpsc::unbounded_channel::<std::sync::mpsc::Sender<u16>>();
    let _ = RELISTEN.set(relisten);
    runtime.spawn(async move {
        let mut listener = listener;
        loop {
            // iOS shuts an app's listening sockets while it's suspended, and accepting fails from then on. So
            // when it fails, or the app comes back to the front, the port is opened again.
            let reply = tokio::select! {
                accepted = listener.accept() => match accepted {
                    Ok((stream, _)) => {
                        let proxy = proxy.clone();
                        tokio::spawn(async move {
                            let _ = serve(stream, &proxy).await;
                        });
                        continue;
                    }
                    Err(_) => {
                        tokio::time::sleep(Duration::from_millis(200)).await;
                        None
                    }
                },
                Some(reply) = asked.recv() => Some(reply),
            };
            let port = PORT.load(Ordering::Relaxed);
            drop(listener);
            listener = listen(port).await;
            if let Some(reply) = reply {
                let _ = reply.send(PORT.load(Ordering::Relaxed));
            }
        }
    });
    // The runtime lives as long as the app.
    std::mem::forget(runtime);
    PORT.store(port, Ordering::Relaxed);
    Some(port)
}

/// Listens on `port` again, or on a new one if it's been taken meanwhile, until it can.
async fn listen(port: u16) -> TcpListener {
    loop {
        for wanted in [port, 0] {
            if let Ok(listener) = TcpListener::bind((Ipv4Addr::LOCALHOST, wanted)).await {
                if let Ok(addr) = listener.local_addr() {
                    PORT.store(addr.port(), Ordering::Relaxed);
                }
                return listener;
            }
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

/// For an app coming back to the front: opens the SOCKS port again (iOS may have shut it while the app was
/// suspended) and gives every lane fresh circuits, since the old ones have likely gone quiet. Returns the
/// port, which is the same one unless it was taken meanwhile, or 0 if Tor isn't running.
#[unsafe(no_mangle)]
pub extern "C" fn pulshade_tor_wake() -> u16 {
    let Some(relisten) = RELISTEN.get() else { return 0 };
    if let Some(lanes) = LANES.lock().unwrap().as_mut() {
        lanes.clear();
    }
    let (reply, answer) = std::sync::mpsc::channel();
    if relisten.send(reply).is_err() {
        return 0;
    }
    answer.recv_timeout(Duration::from_secs(3)).unwrap_or_else(|_| PORT.load(Ordering::Relaxed))
}

/// One SOCKS5 connection (RFC 1928, with RFC 1929 username and password).
async fn serve(mut stream: TcpStream, proxy: &Proxy) -> std::io::Result<()> {
    let invalid = || std::io::Error::from(std::io::ErrorKind::InvalidData);

    let [version, count] = read::<2>(&mut stream).await?;
    let mut methods = vec![0; count as usize];
    stream.read_exact(&mut methods).await?;
    if version != 5 || !methods.contains(&2) {
        stream.write_all(&[5, 0xff]).await?;
        return Err(invalid());
    }
    stream.write_all(&[5, 2]).await?;

    let [_, length] = read::<2>(&mut stream).await?;
    let mut user = vec![0; length as usize];
    stream.read_exact(&mut user).await?;
    let [length] = read::<1>(&mut stream).await?;
    let mut password = vec![0; length as usize];
    stream.read_exact(&mut password).await?;
    let (Ok(lane), true) = (String::from_utf8(user), password == proxy.secret.as_bytes()) else {
        stream.write_all(&[1, 1]).await?;
        return Err(invalid());
    };
    stream.write_all(&[1, 0]).await?;

    let [version, command, _, kind] = read::<4>(&mut stream).await?;
    let host = match kind {
        1 => Ipv4Addr::from(read::<4>(&mut stream).await?).to_string(),
        4 => Ipv6Addr::from(read::<16>(&mut stream).await?).to_string(),
        3 => {
            let [length] = read::<1>(&mut stream).await?;
            let mut name = vec![0; length as usize];
            stream.read_exact(&mut name).await?;
            String::from_utf8(name).map_err(|_| invalid())?
        }
        _ => return Err(invalid()),
    };
    let port = u16::from_be_bytes(read::<2>(&mut stream).await?);
    if version != 5 || command != 1 {
        // Only CONNECT.
        stream.write_all(&[5, 7, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
        return Err(invalid());
    }

    let mut ready = proxy.client.clone();
    let client = match ready.wait_for(|r| !matches!(r, Ready::Starting)).await.map(|r| r.clone()) {
        Ok(Ready::Up(client)) => client,
        _ => {
            stream.write_all(&[5, 1, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
            return Ok(());
        }
    };
    let Some(mut tor) = open(&client, &host, port, &lane).await else {
        stream.write_all(&[5, 4, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
        return Ok(());
    };
    remember_circuit(&lane, &tor);
    stream.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
    copy_bidirectional(&mut stream, &mut tor).await?;
    Ok(())
}

async fn read<const N: usize>(stream: &mut TcpStream) -> std::io::Result<[u8; N]> {
    let mut bytes = [0; N];
    stream.read_exact(&mut bytes).await?;
    Ok(bytes)
}
