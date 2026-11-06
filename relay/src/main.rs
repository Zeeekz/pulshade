//! Pulshade relay: a dumb post office for sealed envelopes.
//!
//! It knows no users, no names and no keys. A mailbox is two random values:
//! the owner keeps a secret *receive key* and hands out its SHA-256 hash as the
//! *send id*. Anyone with the send id can drop envelopes in; only the holder of
//! the receive key can read them out. Envelopes are opaque, deleted on acknowledgement
//! or after seven days, and no request is ever logged. They wait in memory and nowhere
//! else: nothing about waiting mail or wake-ups is written to disk, so a restart empties them.

mod admin;
mod backup;
mod caller;
mod calls;
mod directory;
mod onion;
mod pow;
mod push;
mod release;
mod sealed;

use axum::{
    Json, Router,
    body::Bytes,
    extract::{DefaultBodyLimit, FromRef, Path, State, WebSocketUpgrade},
    http::{HeaderMap, StatusCode},
    routing::{get, post, put},
};
use backup::Backups;
use directory::{Directory, Entry, HeldFor, Limiter, Owned, OwnerProof, Removal};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::io::Read;
use std::{
    collections::{HashMap, HashSet, VecDeque},
    net::SocketAddr,
    path::PathBuf,
    sync::{Arc, LazyLock, Mutex, atomic::{AtomicBool, AtomicUsize, Ordering}},
    time::{Duration, Instant},
};
use tokio::sync::{Notify, Semaphore};

const MAX_ENVELOPE: usize = 4 * 1024 * 1024;
const MAX_QUEUE: usize = 2_000;
/// Everything waiting in memory, all mailboxes together. Past this, deposits are refused (507) instead of letting
/// the process grow until it's killed, which would lose every queued envelope at once.
const MAX_TOTAL_BYTES: usize = 384 * 1024 * 1024;
/// Request bodies being received at once, all requests together, apart from the first `SHORT_MAIL` bytes of each. An
/// upload is held in memory whole until it is stored or refused, so without this a few dozen slow, large uploads
/// could take all the memory there is. Past it, a large upload is refused (503) and tried again by the app; short
/// messages never count, so they always get through.
const MAX_IN_FLIGHT: usize = 96 * 1024 * 1024;
/// Envelope ids one mailbox's acknowledgement may name: twice what a mailbox can hold, and many times what a fetch
/// hands over.
const MAX_ACK_IDS: usize = 2 * MAX_QUEUE;
/// Mailboxes holding mail at once.
const MAX_MAILBOXES: usize = 200_000;
/// Receive keys per push registration, so a phone with more registers in several goes.
const MAX_PUSH_KEYS: usize = 256;
const MAX_KEYS_PER_FETCH: usize = 512;
const MAX_ITEMS_PER_KEY: usize = 64;
/// The most envelope bytes one fetch answers with (apart from a single envelope larger than this, which goes alone).
const MAX_FETCH_BYTES: usize = 1024 * 1024;
const TTL: Duration = Duration::from_secs(7 * 24 * 3600);
/// The longest a fetch may wait for mail.
const MAX_WAIT: u64 = 25;

/// Wakes waiting fetches whenever anything is deposited, so mail goes out the moment it lands.
static ARRIVALS: LazyLock<Notify> = LazyLock::new(Notify::new);
/// Different every time the relay starts. The health check carries it, so an app can tell the relay restarted and
/// register for wake-ups again straight away.
static BOOT: LazyLock<String> = LazyLock::new(|| {
    let mut raw = [0u8; 8];
    std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut raw)).expect("no randomness");
    hex::encode(raw)
});
/// How often waiting mail and wake-up registrations are written out, at most.

type Id = [u8; 32];

struct Item {
    id: u64,
    at: Instant,
    blob: Bytes,
}

struct Store {
    queues: HashMap<Id, VecDeque<Item>>,
    /// The size of everything in `queues`, kept up to date as mail comes and goes (and recounted by `purge`).
    bytes: usize,
    /// Envelope ids are unpredictable, so they say nothing about how busy the relay is.
    id_seed: [u8; 32],
    counter: u64,
}

impl Default for Store {
    fn default() -> Self {
        let mut id_seed = [0u8; 32];
        std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut id_seed)).expect("no randomness");
        Store { queues: HashMap::new(), bytes: 0, id_seed, counter: 0 }
    }
}

impl Store {
    /// A fresh id below 2^53, so it survives any JSON reader.
    fn next_id(&mut self) -> u64 {
        self.counter += 1;
        let digest = Sha256::new().chain_update(self.id_seed).chain_update(self.counter.to_be_bytes()).finalize();
        u64::from_be_bytes(digest[..8].try_into().unwrap()) & ((1 << 53) - 1)
    }
}

type Shared = Arc<Mutex<Store>>;

#[derive(Clone)]
struct AppState {
    store: Shared,
    directory: Arc<Mutex<Directory>>,
    backups: Arc<Backups>,
    releases: Arc<release::Releases>,
    calls: Arc<calls::Rooms>,
    limits: Arc<Mutex<Limiter>>,
    /// Room for request bodies being received, counted in bytes: `MAX_IN_FLIGHT` in all.
    in_flight: Arc<Semaphore>,
    /// The operator's token, from `admin.token` beside the relay.
    admin_token: Arc<String>,
    started: Instant,
}

impl FromRef<AppState> for Shared {
    fn from_ref(state: &AppState) -> Shared {
        state.store.clone()
    }
}

fn parse_id(hex_str: &str) -> Option<Id> {
    let raw = hex::decode(hex_str).ok()?;
    raw.try_into().ok()
}

fn send_id_for(receive_key: &Id) -> Id {
    Sha256::digest(receive_key).into()
}

/// Whether mail in this deposit should wake a phone. An app says so with `x-pulshade-wake`: 1 for a message, 0 for
/// anything else (a typing signal, a receipt). The relay can't read what's inside, so without the word, as from
/// apps that don't send it yet, it wakes as it always did.
fn wakes(headers: &HeaderMap) -> bool {
    headers.get("x-pulshade-wake").and_then(|v| v.to_str().ok()) != Some("0")
}

/// Whether the deposit starts a call (`x-pulshade-wake: 2`), which rings a phone instead of showing a banner.
fn rings(headers: &HeaderMap) -> bool {
    headers.get("x-pulshade-wake").and_then(|v| v.to_str().ok()) == Some("2")
}

async fn deposit(State(store): State<Shared>, Path(send_id): Path<String>, headers: HeaderMap, body: Bytes) -> StatusCode {
    let Some(id) = parse_id(&send_id) else { return StatusCode::BAD_REQUEST };
    if body.is_empty() || body.len() > MAX_ENVELOPE {
        return StatusCode::PAYLOAD_TOO_LARGE;
    }
    let mut store = store.lock().unwrap();
    // Full: the oldest waiting mail makes way, so the relay never stops taking new messages. (Refusing instead let
    // anyone who filled it with junk silence everybody until the junk expired.)
    let new_mailbox = !store.queues.contains_key(&id);
    if store.bytes + body.len() > MAX_TOTAL_BYTES || (new_mailbox && store.queues.len() >= MAX_MAILBOXES) {
        make_room(&mut store, body.len(), new_mailbox);
    }
    if store.bytes + body.len() > MAX_TOTAL_BYTES {
        return StatusCode::INSUFFICIENT_STORAGE;
    }
    let item = Item { id: store.next_id(), at: Instant::now(), blob: body };
    let size = item.blob.len();
    let queue = store.queues.entry(id).or_default();
    if queue.len() >= MAX_QUEUE {
        return StatusCode::INSUFFICIENT_STORAGE;
    }
    queue.push_back(item);
    store.bytes += size;
    drop(store);
    ARRIVALS.notify_waiters();
    // A phone that asked for it is woken, with nothing about the mail in the push.
    if wakes(&headers) {
        push::global().notify_as(id, if rings(&headers) { push::Wake::Call } else { push::Wake::Message });
    }
    StatusCode::ACCEPTED
}

/// Drops the oldest waiting mail, whoever it is for, until there is room for `need` bytes (and a new mailbox, if
/// `slot`) with a twentieth of the budget to spare, so this runs once in a long while, not on every deposit.
fn make_room(store: &mut Store, need: usize, slot: bool) {
    use std::cmp::Reverse;
    use std::collections::BinaryHeap;
    let bytes_goal = MAX_TOTAL_BYTES - MAX_TOTAL_BYTES / 20;
    let slots_goal = MAX_MAILBOXES - MAX_MAILBOXES / 20;
    let mut fronts: BinaryHeap<Reverse<(Instant, Id)>> = store.queues.iter()
        .filter_map(|(mailbox, queue)| queue.front().map(|item| Reverse((item.at, *mailbox))))
        .collect();
    while store.bytes + need > bytes_goal || (slot && store.queues.len() >= slots_goal) {
        let Some(Reverse((_, mailbox))) = fronts.pop() else { break };
        let Some(queue) = store.queues.get_mut(&mailbox) else { continue };
        if let Some(item) = queue.pop_front() {
            let size = item.blob.len();
            let next = queue.front().map(|next| next.at);
            if queue.is_empty() { store.queues.remove(&mailbox); }
            store.bytes = store.bytes.saturating_sub(size);
            if let Some(at) = next { fronts.push(Reverse((at, mailbox))); }
        }
    }
}

/// What the route runs: the same deposit, after checking how much this caller has been sending. Deposits are
/// anonymous, so without it one client could fill the relay with junk. Each Tor circuit counts on its own address.
async fn deposit_limited(State(state): State<AppState>, caller::Caller(who): caller::Caller, Path(send_id): Path<String>,
                         headers: HeaderMap, body: Bytes) -> StatusCode {
    let new_mailbox = parse_id(&send_id).is_some_and(|id| !state.store.lock().unwrap().queues.contains_key(&id));
    {
        // Straight from this machine (the proxy always names the real client): the operator, or a test.
        if who.is_loopback() { return deposit(State(state.store), Path(send_id), headers, body).await; }
        let mut limits = state.limits.lock().unwrap();
        let kib = u32::try_from(body.len() / 1024 + 1).unwrap_or(u32::MAX);
        // Generous on purpose: typing signals, receipts and several devices or housemates behind one address all count.
        // The aim is to stop a flood, not to notice a busy chat.
        if !limits.allow(who, "deposit", 12_000, Duration::from_secs(3600))
            || !limits.allow_n(who, "deposit-size", 512 * 1024, Duration::from_secs(3600), kib)
            || (new_mailbox && !limits.allow(who, "deposit-new", 2_500, Duration::from_secs(3600))) {
            return StatusCode::TOO_MANY_REQUESTS;
        }
    }
    deposit(State(state.store), Path(send_id), headers, body).await
}

#[derive(Deserialize)]
struct FetchRequest {
    keys: Vec<String>,
    /// Seconds to wait for mail when there's none yet (capped at `MAX_WAIT`). Older apps leave it out and get
    /// an answer straight away.
    #[serde(default)]
    wait: u64,
}

#[derive(Serialize)]
struct Envelope {
    /// Index into the request's `keys`.
    k: usize,
    id: u64,
    blob: String,
    /// Seconds since it was deposited, so the receiver can date it without trusting the sender's clock.
    age: u64,
}

#[derive(Serialize)]
struct FetchResponse {
    items: Vec<Envelope>,
}

async fn fetch(State(store): State<Shared>, Json(req): Json<FetchRequest>) -> Result<Json<FetchResponse>, StatusCode> {
    if req.keys.len() > MAX_KEYS_PER_FETCH {
        return Err(StatusCode::BAD_REQUEST);
    }
    let mailboxes: Vec<Option<Id>> = req.keys.iter().map(|key| parse_id(key).map(|k| send_id_for(&k))).collect();
    let deadline = Instant::now() + Duration::from_secs(req.wait.min(MAX_WAIT));
    loop {
        // Listening before looking, so a deposit in between still wakes us.
        let arrived = ARRIVALS.notified();
        tokio::pin!(arrived);
        arrived.as_mut().enable();
        let items = collect(&store, &mailboxes);
        let now = Instant::now();
        if !items.is_empty() || now >= deadline {
            return Ok(Json(FetchResponse { items }));
        }
        let _ = tokio::time::timeout(deadline - now, arrived).await;
    }
}

/// Mail up to this size is a message or a receipt; above it, a photo or a piece of a story.
const SHORT_MAIL: usize = 64 * 1024;

/// What a fetch hands over: short mail first, from every mailbox, then the big. A message sent after a story's
/// pieces used to wait behind them, fetched a piece at a time over a slow circuit, and a big piece at the front of
/// one mailbox held up the others in the same answer. Mail is read in either order, and each is acknowledged by its
/// id, so taking the short ones first changes nothing for the apps.
fn collect(store: &Shared, mailboxes: &[Option<Id>]) -> Vec<Envelope> {
    let store = store.lock().unwrap();
    let mut items = Vec::new();
    let mut bytes = 0;
    'passes: for big in [false, true] {
        for (k, mailbox) in mailboxes.iter().enumerate() {
            let Some(queue) = mailbox.and_then(|id| store.queues.get(&id)) else { continue };
            for item in queue.iter().filter(|item| (item.blob.len() > SHORT_MAIL) == big).take(MAX_ITEMS_PER_KEY) {
                // One answer stays small enough to arrive over a slow circuit before the app gives up; the rest
                // comes on the next fetch, once this has been acknowledged. The first envelope always goes, however big.
                if !items.is_empty() && bytes + item.blob.len() > MAX_FETCH_BYTES { break 'passes; }
                bytes += item.blob.len();
                items.push(Envelope { k, id: item.id, blob: B64.encode(&item.blob), age: item.at.elapsed().as_secs() });
            }
        }
    }
    items
}

#[derive(Deserialize)]
struct Ack {
    key: String,
    ids: Vec<u64>,
}

#[derive(Deserialize)]
struct AckRequest {
    acks: Vec<Ack>,
}

async fn ack(State(store): State<Shared>, Json(req): Json<AckRequest>) -> StatusCode {
    if req.acks.iter().any(|a| a.ids.len() > MAX_ACK_IDS) {
        return StatusCode::BAD_REQUEST;
    }
    // Gathered by mailbox before the lock is taken, so each queue is gone through once and looking an id up costs
    // the same however many were sent.
    let mut gone: HashMap<Id, HashSet<u64>> = HashMap::new();
    for a in req.acks {
        let Some(receive_key) = parse_id(&a.key) else { continue };
        gone.entry(send_id_for(&receive_key)).or_default().extend(a.ids);
    }
    let mut store = store.lock().unwrap();
    for (send_id, ids) in gone {
        let mut freed = 0;
        if let Some(queue) = store.queues.get_mut(&send_id) {
            queue.retain(|item| {
                let keep = !ids.contains(&item.id);
                if !keep { freed += item.blob.len(); }
                keep
            });
            if queue.is_empty() {
                store.queues.remove(&send_id);
            }
        }
        store.bytes = store.bytes.saturating_sub(freed);
    }
    StatusCode::NO_CONTENT
}

// MARK: Push

#[derive(Deserialize)]
struct PushRegister {
    /// The receive keys of the mailboxes to wake this phone for. Holding them proves they're the phone's own.
    keys: Vec<String>,
    token: String,
    /// A token from a development build, which Apple's sandbox issues and only its sandbox accepts.
    #[serde(default)]
    sandbox: bool,
    /// Whether the push makes a sound: the phone's own Sound setting.
    #[serde(default = "yes")]
    sound: bool,
    /// The message tone it picked, one of `push::TONES`; anything else is the default sound.
    #[serde(default)]
    tone: Option<String>,
    /// The phone's token for call pushes, which ring it like a phone call.
    #[serde(default)]
    voip: Option<String>,
}

fn yes() -> bool {
    true
}

#[derive(Deserialize)]
struct PushOff {
    keys: Vec<String>,
}

#[derive(Deserialize)]
struct PushForget {
    token: String,
}

fn mailboxes_of(keys: &[String]) -> Vec<Id> {
    keys.iter().filter_map(|k| parse_id(k)).map(|k| send_id_for(&k)).collect()
}

/// Says whether this relay can send pushes at all, so the app only offers them where they'll work.
async fn push_status() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "enabled": push::global().enabled() }))
}

async fn push_register(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    headers: HeaderMap,
    Json(req): Json<PushRegister>,
) -> StatusCode {
    let who = pow::rate_key(ip, &headers, "push");
    if !state.limits.lock().unwrap().allow(who, "push", 60, Duration::from_secs(3600)) {
        return StatusCode::TOO_MANY_REQUESTS;
    }
    let push = push::global();
    if !push.enabled() {
        return StatusCode::NOT_IMPLEMENTED;
    }
    if req.keys.len() > MAX_PUSH_KEYS || !push::valid_token(&req.token) || req.voip.as_deref().is_some_and(|v| !push::valid_token(v)) {
        return StatusCode::BAD_REQUEST;
    }
    let extras = push::Extras { tone: req.tone, voip: req.voip };
    if push.register_with(&mailboxes_of(&req.keys), &req.token.to_lowercase(), req.sandbox, req.sound, extras) {
        StatusCode::NO_CONTENT
    } else {
        StatusCode::INSUFFICIENT_STORAGE
    }
}

/// Everything registered for a device token goes. A phone sends this when its identity is wiped or a decoy opens,
/// where it has no keys to name the mailboxes with.
async fn push_forget(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    headers: HeaderMap,
    Json(req): Json<PushForget>,
) -> StatusCode {
    let who = pow::rate_key(ip, &headers, "push");
    if !state.limits.lock().unwrap().allow(who, "push", 60, Duration::from_secs(3600)) {
        return StatusCode::TOO_MANY_REQUESTS;
    }
    if !push::valid_token(&req.token) {
        return StatusCode::BAD_REQUEST;
    }
    push::global().forget(&req.token.to_lowercase());
    StatusCode::NO_CONTENT
}

async fn push_off(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    headers: HeaderMap,
    Json(req): Json<PushOff>,
) -> StatusCode {
    let who = pow::rate_key(ip, &headers, "push");
    if !state.limits.lock().unwrap().allow(who, "push", 60, Duration::from_secs(3600)) {
        return StatusCode::TOO_MANY_REQUESTS;
    }
    if req.keys.len() > MAX_PUSH_KEYS {
        return StatusCode::BAD_REQUEST;
    }
    push::global().remove(&mailboxes_of(&req.keys));
    StatusCode::NO_CONTENT
}

// MARK: Directory

async fn lookup(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    Path(handle): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Entry>, StatusCode> {
    let who = pow::rate_key(ip, &headers, &format!("lookup|{handle}"));
    if !state.limits.lock().unwrap().allow(who, "lookup", 60, Duration::from_secs(60)) {
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }
    state.directory.lock().unwrap().get(&handle.to_lowercase()).map(Json).ok_or(StatusCode::NOT_FOUND)
}

async fn claim(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    Path(handle): Path<String>,
    headers: HeaderMap,
    Json(entry): Json<Entry>,
) -> StatusCode {
    let who = pow::rate_key(ip, &headers, &format!("claim|{handle}"));
    if !state.limits.lock().unwrap().allow(who, "claim", 30, Duration::from_secs(3600)) {
        return StatusCode::TOO_MANY_REQUESTS;
    }
    let mut directory = state.directory.lock().unwrap();
    directory.adopt_creator(creator_key());
    match directory.put(&handle, entry) {
        Ok(()) => StatusCode::NO_CONTENT,
        Err(code) => code,
    }
}

async fn mine(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    headers: HeaderMap,
    Json(proof): Json<OwnerProof>,
) -> Result<Json<Vec<Owned>>, StatusCode> {
    let who = pow::rate_key(ip, &headers, "mine");
    if !state.limits.lock().unwrap().allow(who, "mine", 60, Duration::from_secs(3600)) {
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }
    state.directory.lock().unwrap().owned(&proof).map(Json)
}

/// The handles held for a key it no longer lists, for its owner's Settings.
async fn held(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    headers: HeaderMap,
    Json(proof): Json<OwnerProof>,
) -> Result<Json<Vec<HeldFor>>, StatusCode> {
    let who = pow::rate_key(ip, &headers, "held");
    if !state.limits.lock().unwrap().allow(who, "held", 60, Duration::from_secs(3600)) {
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }
    state.directory.lock().unwrap().held_for(&proof).map(Json)
}

/// The collectibles given to an account, for that account only.
async fn collectibles(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    headers: HeaderMap,
    Json(proof): Json<OwnerProof>,
) -> Result<Json<Vec<directory::Mine>>, StatusCode> {
    let who = pow::rate_key(ip, &headers, "collectibles");
    if !state.limits.lock().unwrap().allow(who, "collectibles", 60, Duration::from_secs(3600)) {
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }
    state.directory.lock().unwrap().collectibles_of(&proof).map(Json)
}

/// Sets the owner's backup code for one of its collectibles.
async fn collectible_code(State(state): State<AppState>, Json(set): Json<directory::CodeSet>) -> StatusCode {
    match state.directory.lock().unwrap().set_code(&set) {
        Ok(()) => StatusCode::NO_CONTENT,
        Err(code) => code,
    }
}

/// A backup code entered in another account. Limited hard, and a proof of work over Tor, so codes can't be guessed.
async fn claim_collectibles(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    headers: HeaderMap,
    Json(claim): Json<directory::Claim>,
) -> Result<Json<Vec<directory::Claimed>>, StatusCode> {
    let who = pow::rate_key(ip, &headers, "collectible-claim");
    if !state.limits.lock().unwrap().allow(who, "collectible-claim", 10, Duration::from_secs(3600)) {
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }
    state.directory.lock().unwrap().claim(&claim).map(Json)
}

/// A giveaway code entered by an account. Limited hard, and a proof of work over Tor, so codes can't be guessed.
async fn claim_giveaway(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    headers: HeaderMap,
    Json(entry): Json<directory::GiveawayEntry>,
) -> Result<Json<directory::GiveawayPlace>, StatusCode> {
    let who = pow::rate_key(ip, &headers, "giveaway-claim");
    if !state.limits.lock().unwrap().allow(who, "giveaway-claim", 10, Duration::from_secs(3600)) {
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }
    state.directory.lock().unwrap().claim_giveaway(&entry).map(Json)
}

/// The eggs an account holds, for that account only.
async fn eggs(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    headers: HeaderMap,
    Json(proof): Json<OwnerProof>,
) -> Result<Json<Vec<directory::EggView>>, StatusCode> {
    let who = pow::rate_key(ip, &headers, "eggs");
    if !state.limits.lock().unwrap().allow(who, "eggs", 120, Duration::from_secs(3600)) {
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }
    state.directory.lock().unwrap().eggs_of(&proof).map(Json)
}

/// Puts one of the account's eggs to hatch.
async fn egg_start(State(state): State<AppState>, Json(action): Json<directory::EggAction>) -> Result<Json<directory::EggView>, StatusCode> {
    state.directory.lock().unwrap().start_egg(&action).map(Json)
}

/// Opens an egg that's ready.
async fn egg_hatch(State(state): State<AppState>, Json(action): Json<directory::EggAction>) -> Result<Json<directory::Mine>, StatusCode> {
    state.directory.lock().unwrap().hatch_egg(&action).map(Json)
}

/// Gives a collectible to another account.
async fn collectible_gift(State(state): State<AppState>, Json(out): Json<directory::GiftOut>) -> StatusCode {
    match state.directory.lock().unwrap().gift(&out) {
        Ok(()) => StatusCode::NO_CONTENT,
        Err(code) => code,
    }
}

/// Lets a collectible go.
async fn collectible_release(State(state): State<AppState>, Json(out): Json<directory::ReleaseOut>) -> StatusCode {
    match state.directory.lock().unwrap().release(&out) {
        Ok(()) => StatusCode::NO_CONTENT,
        Err(code) => code,
    }
}

async fn unhold(State(state): State<AppState>, Path(handle): Path<String>, Json(proof): Json<OwnerProof>) -> StatusCode {
    match state.directory.lock().unwrap().unhold(&handle, &proof) {
        Ok(()) => StatusCode::NO_CONTENT,
        Err(code) => code,
    }
}

/// An account burning: its handles stay unclaimable for a while, but no longer point back to it.
async fn retire(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    headers: HeaderMap,
    Json(proof): Json<OwnerProof>,
) -> StatusCode {
    let who = pow::rate_key(ip, &headers, "retire");
    if !state.limits.lock().unwrap().allow(who, "retire", 30, Duration::from_secs(3600)) {
        return StatusCode::TOO_MANY_REQUESTS;
    }
    match state.directory.lock().unwrap().retire(&proof) {
        Ok(_) => StatusCode::NO_CONTENT,
        Err(code) => code,
    }
}

async fn admin(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    headers: HeaderMap,
    Json(req): Json<admin::AdminRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if !state.limits.lock().unwrap().allow(ip, "admin", 240, Duration::from_secs(3600)) {
        return Err((StatusCode::TOO_MANY_REQUESTS, "slow down".into()));
    }
    let token = headers.get("x-pulshade-admin-token").and_then(|v| v.to_str().ok());
    let traffic = {
        let store = state.store.lock().unwrap();
        admin::Traffic {
            mailboxes: store.queues.len(),
            waiting: store.queues.values().map(VecDeque::len).sum(),
            uptime_secs: state.started.elapsed().as_secs(),
            calls: state.calls.active(),
        }
    };
    let mut directory = state.directory.lock().unwrap();
    if !admin::authorised(token, &state.admin_token) {
        return Err((StatusCode::UNAUTHORIZED, "not the operator".into()));
    }
    admin::run(&mut directory, &req, traffic).map(Json).map_err(|e| (StatusCode::BAD_REQUEST, e))
}

/// Where to send abuse reports: the Pulshade Admin app's mailbox and keys, signed by its key, if set up.
async fn report_inbox(State(state): State<AppState>) -> Result<Json<serde_json::Value>, StatusCode> {
    state.directory.lock().unwrap().moderation.report_inbox.clone().map(Json).ok_or(StatusCode::NOT_FOUND)
}

/// Everything Pulshade has told everyone, signed by the admin app. The same answer for every app. Apps check every
/// minute, so one that already has the current list (`x-pulshade-version`) gets a bare 304 instead of all of it.
async fn announcements(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    headers: HeaderMap,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let who = pow::rate_key(ip, &headers, "announcements");
    if !state.limits.lock().unwrap().allow(who, "announcements", 120, Duration::from_secs(3600)) {
        return StatusCode::TOO_MANY_REQUESTS.into_response();
    }
    let dir = state.directory.lock().unwrap();
    let version = dir.announcements_version();
    let header = [(axum::http::HeaderName::from_static("x-pulshade-version"), version.clone())];
    if headers.get("x-pulshade-version").and_then(|v| v.to_str().ok()) == Some(version.as_str()) {
        return (StatusCode::NOT_MODIFIED, header).into_response();
    }
    (header, Json(dir.announcements().to_vec())).into_response()
}

/// The operator token, made on first run and readable only by this machine's user.
fn admin_token() -> String {
    if let Ok(existing) = std::fs::read_to_string("admin.token") {
        let existing = existing.trim().to_string();
        if !existing.is_empty() { return existing; }
    }
    let mut raw = [0u8; 32];
    std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut raw)).expect("no randomness");
    let token = hex::encode(raw);
    sealed::write_private(std::path::Path::new("admin.token"), token.as_bytes()).expect("could not write admin.token");
    token
}

async fn release(State(state): State<AppState>, Path(handle): Path<String>, Json(removal): Json<Removal>) -> StatusCode {
    match state.directory.lock().unwrap().remove(&handle, removal) {
        Ok(()) => StatusCode::NO_CONTENT,
        Err(code) => code,
    }
}

async fn backup_put(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    Path(key): Path<String>,
    headers: HeaderMap,
    body: axum::body::Body,
) -> StatusCode {
    // The backup itself is only read once the request has passed everything that can be checked without it, so
    // one that will be refused anyway never takes up memory.
    let who = pow::rate_key(ip, &headers, &format!("backup|{key}"));
    if !state.limits.lock().unwrap().allow(who, "backup", 20, Duration::from_secs(3600)) {
        return StatusCode::TOO_MANY_REQUESTS;
    }
    let header = |name: &str| headers.get(name).and_then(|v| v.to_str().ok()).map(str::to_string);
    let (Some(sig), Some(ts)) = (header("x-pulshade-sig"), header("x-pulshade-ts").and_then(|t| t.parse().ok())) else {
        return StatusCode::BAD_REQUEST;
    };
    let declared = header("content-length").and_then(|n| n.parse::<usize>().ok());
    if declared.is_some_and(|n| n > backup::MAX_BACKUP) {
        return StatusCode::PAYLOAD_TOO_LARGE;
    }
    use futures_util::StreamExt;
    // Grown as the pieces come, never set aside ahead on the request's say-so.
    let mut blob = Vec::new();
    let mut pieces = body.into_data_stream();
    while let Some(piece) = pieces.next().await {
        let Ok(piece) = piece else { return StatusCode::BAD_REQUEST };
        if blob.len() + piece.len() > backup::MAX_BACKUP {
            return StatusCode::PAYLOAD_TOO_LARGE;
        }
        blob.extend_from_slice(&piece);
    }
    match state.backups.put(&key, &sig, ts, &blob) {
        Ok(()) => {
            // A delete-only token's hash, if the app sent one, kept beside the backup.
            if let Some(hash) = header("x-pulshade-forget").and_then(|h| hex::decode(h).ok()).and_then(|r| <[u8; 32]>::try_from(r).ok()) {
                state.backups.set_forget_hash(&key, &hash);
            }
            StatusCode::NO_CONTENT
        }
        Err(code) => code,
    }
}

#[derive(Deserialize)]
struct Forget {
    token: String,
}

/// Erases a backup for the holder of its delete-only token (the panic passcode's), with no signature.
async fn backup_forget(State(state): State<AppState>, caller::Caller(ip): caller::Caller, Path(key): Path<String>,
                       Json(body): Json<Forget>) -> StatusCode {
    if !ip.is_loopback() && !state.limits.lock().unwrap().allow(ip, "backup-forget", 20, Duration::from_secs(3600)) {
        return StatusCode::TOO_MANY_REQUESTS;
    }
    match state.backups.forget(&key, &body.token) {
        Ok(()) => StatusCode::NO_CONTENT,
        Err(code) => code,
    }
}

/// A file as the body of an answer, read a piece at a time, so a large one is never in memory whole.
fn in_pieces(file: std::fs::File) -> axum::body::Body {
    axum::body::Body::from_stream(futures_util::stream::unfold(Some(file), |file| async move {
        let mut file = file?;
        let mut piece = vec![0u8; 64 * 1024];
        match file.read(&mut piece) {
            Ok(0) => None,
            Ok(n) => {
                piece.truncate(n);
                Some((Ok(Bytes::from(piece)), Some(file)))
            }
            Err(e) => Some((Err(e), None)),
        }
    }))
}

async fn backup_get(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    Path(key): Path<String>,
    headers: HeaderMap,
    Json(proof): Json<backup::Proof>,
) -> Result<axum::response::Response, StatusCode> {
    use axum::{http::header, response::IntoResponse};
    let who = pow::rate_key(ip, &headers, &format!("backup-read|{key}"));
    if !state.limits.lock().unwrap().allow(who, "backup-read", 60, Duration::from_secs(3600)) {
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }
    let (file, size) = state.backups.open(&key, &proof)?;
    let about = [(header::CONTENT_TYPE, "application/octet-stream".to_string()), (header::CONTENT_LENGTH, size.to_string())];
    Ok((about, in_pieces(file)).into_response())
}

async fn backup_remove(State(state): State<AppState>, Path(key): Path<String>, Json(proof): Json<backup::Proof>) -> StatusCode {
    match state.backups.remove(&key, &proof) {
        Ok(()) => StatusCode::NO_CONTENT,
        Err(code) => code,
    }
}

async fn call(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    Path(room): Path<String>,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if !calls::valid_room(&room) {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let who = pow::rate_key(ip, &headers, &format!("call|{room}"));
    if !state.limits.lock().unwrap().allow(who, "call", 120, Duration::from_secs(3600)) {
        return StatusCode::TOO_MANY_REQUESTS.into_response();
    }
    let rooms = state.calls.clone();
    upgrade.max_message_size(calls::MAX_FRAME * 2)
        .on_upgrade(move |socket| rooms.join(room.to_lowercase(), socket))
        .into_response()
}

/// The latest Mac release's description and signature, if the operator has published one.
async fn update_manifest(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    headers: HeaderMap,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let who = pow::rate_key(ip, &headers, "update");
    if !state.limits.lock().unwrap().allow(who, "update", 20, Duration::from_secs(3600)) {
        return StatusCode::TOO_MANY_REQUESTS.into_response();
    }
    match state.releases.manifest() {
        Some(json) => ([(axum::http::header::CONTENT_TYPE, "application/json")], json).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

/// The zipped app itself. Limited, since each download is large.
async fn update_archive(
    State(state): State<AppState>,
    caller::Caller(ip): caller::Caller,
    headers: HeaderMap,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    let who = pow::rate_key(ip, &headers, "update");
    if !state.limits.lock().unwrap().allow(who, "update", 20, Duration::from_secs(3600)) {
        return StatusCode::TOO_MANY_REQUESTS.into_response();
    }
    match state.releases.archive() {
        Some(zip) => ([(axum::http::header::CONTENT_TYPE, "application/zip")], zip).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

/// What one request has taken of the room for bodies being received, given back when the request is done.
struct Room {
    budget: Arc<Semaphore>,
    taken: AtomicUsize,
    /// Set when there was no room left for the next piece.
    full: AtomicBool,
}

impl Room {
    fn take(&self, bytes: usize) -> bool {
        match self.budget.try_acquire_many(bytes as u32) {
            Ok(room) => {
                room.forget();
                self.taken.fetch_add(bytes, Ordering::SeqCst);
                true
            }
            Err(_) => {
                self.full.store(true, Ordering::SeqCst);
                false
            }
        }
    }
}

impl Drop for Room {
    fn drop(&mut self) {
        self.budget.add_permits(self.taken.load(Ordering::SeqCst));
    }
}

/// Counts every request's body against `MAX_IN_FLIGHT` as it arrives, whatever reads it, and answers 503 when there
/// is no room. The count is by what has really arrived, not by what the request says it will send, and is given back
/// once the request has been answered: by then the body is stored, and counted there, or gone.
async fn in_flight(State(state): State<AppState>, request: axum::extract::Request, next: axum::middleware::Next) -> axum::response::Response {
    use axum::response::IntoResponse;
    use futures_util::StreamExt;
    let room = Arc::new(Room { budget: state.in_flight.clone(), taken: AtomicUsize::new(0), full: AtomicBool::new(false) });
    let (parts, body) = request.into_parts();
    let (counting, mut seen) = (room.clone(), 0usize);
    let counted = body.into_data_stream().map(move |piece| {
        let piece = piece?;
        // The first bytes of every request are free, so a message or a receipt is never turned away.
        let before = seen.max(SHORT_MAIL);
        seen += piece.len();
        if seen > before && !counting.take(seen - before) {
            return Err(axum::Error::new(std::io::Error::other("no room for more uploads")));
        }
        Ok(piece)
    });
    let response = next.run(axum::extract::Request::from_parts(parts, axum::body::Body::from_stream(counted))).await;
    if room.full.load(Ordering::SeqCst) {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    }
    response
}

fn purge(store: &Shared) {
    let mut store = store.lock().unwrap();
    let now = Instant::now();
    store.queues.retain(|_, queue| {
        queue.retain(|item| now.duration_since(item.at) < TTL);
        !queue.is_empty()
    });
    // Recounted, so the running total can't drift.
    store.bytes = store.queues.values().flat_map(|q| q.iter()).map(|item| item.blob.len()).sum();
}

// MARK: Nothing waits on disk

/// Waiting mail and wake-up registrations are kept in memory and nowhere else: a restart empties them, by design,
/// and nothing about who has mail waiting or which phone to wake ever touches the server's disk. An earlier version
/// wrote them out, sealed, so a restart wouldn't lose them. A file it left behind is overwritten with random bytes
/// and deleted at start-up, before anything is served.
fn forget_old_spool(path: &std::path::Path) {
    let Ok(meta) = std::fs::metadata(path) else { return };
    let mut noise = vec![0u8; usize::try_from(meta.len()).unwrap_or(0).min(512 * 1024 * 1024)];
    if let Ok(mut random) = std::fs::File::open("/dev/urandom") { let _ = random.read_exact(&mut noise); }
    let _ = std::fs::write(path, &noise);
    let _ = std::fs::remove_file(path);
    eprintln!("removed the old spool file; waiting mail is no longer written to disk");
}


/// Waits for Ctrl-C or the service manager's stop (SIGTERM), either of which ends the relay cleanly.
async fn stop_signal() {
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).expect("no signal handling");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = term.recv() => {}
    }
}

fn app(state: AppState) -> Router {
    Router::new()
        .route("/v1/health", get(|| async { ([("x-pulshade-boot", BOOT.as_str())], "ok") }))
        // The address this request came from, for the app's anonymity report. Answered, never kept.
        .route("/v1/seen", get(|caller::Caller(ip): caller::Caller| async move { ip.to_string() }))
        .route("/v1/q/{send_id}", put(deposit_limited))
        .route("/v1/fetch", post(fetch))
        .route("/v1/ack", post(ack))
        .route("/v1/push", get(push_status).put(push_register))
        .route("/v1/push/off", post(push_off))
        .route("/v1/push/forget", post(push_forget))
        .route("/v1/dir/{handle}", get(lookup).put(claim))
        .route("/v1/dir/{handle}/delete", post(release))
        .route("/v1/mine", post(mine))
        .route("/v1/retire", post(retire))
        .route("/v1/held", post(held))
        .route("/v1/dir/{handle}/unhold", post(unhold))
        .route("/v1/collectibles", post(collectibles))
        .route("/v1/collectibles/code", post(collectible_code))
        .route("/v1/collectibles/claim", post(claim_collectibles))
        .route("/v1/collectibles/giveaway", post(claim_giveaway))
        .route("/v1/collectibles/gift", post(collectible_gift))
        .route("/v1/collectibles/release", post(collectible_release))
        .route("/v1/eggs", post(eggs))
        .route("/v1/eggs/start", post(egg_start))
        .route("/v1/eggs/hatch", post(egg_hatch))
        .route("/v1/backup/{key}", put(backup_put))
        .route("/v1/backup/{key}/get", post(backup_get))
        .route("/v1/backup/{key}/delete", post(backup_remove))
        .route("/v1/backup/{key}/forget", post(backup_forget))
        .route("/v1/call/{room}", get(call))
        .route("/v1/admin", post(admin))
        .route("/v1/report-inbox", get(report_inbox))
        .route("/v1/announcements", get(announcements))
        .route("/v1/update/mac", get(update_manifest))
        .route("/v1/update/mac.zip", get(update_archive))
        .layer(DefaultBodyLimit::max(MAX_ENVELOPE + 1024))
        .layer(axum::middleware::from_fn_with_state(state.clone(), in_flight))
        .with_state(state)
}

/// The creator's public key, from `PULSHADE_CREATOR_KEY` or a `creator.key` file next to the relay.
fn creator_key() -> Option<String> {
    std::env::var("PULSHADE_CREATOR_KEY").ok()
        .or_else(|| std::fs::read_to_string("creator.key").ok())
        .map(|k| k.trim().to_string())
        .filter(|k| !k.is_empty())
}

/// The key the relay signs hatched and gifted pets with: 32 bytes as hex, from `PULSHADE_PET_KEY` or a `pet.key` file
/// next to the relay. Without it, eggs can't hatch and nothing can be gifted.
fn pet_signing_key() -> Option<ed25519_dalek::SigningKey> {
    let hex_seed = std::env::var("PULSHADE_PET_KEY").ok().or_else(|| std::fs::read_to_string("pet.key").ok())?;
    let raw: [u8; 32] = hex::decode(hex_seed.trim()).ok()?.try_into().ok()?;
    Some(ed25519_dalek::SigningKey::from_bytes(&raw))
}

/// Keeps memory off the disk: no core file if the relay crashes, and (on Linux) no other process of this user
/// may read its memory. The addresses counted for rate limits and the waiting envelopes only ever live there.
fn no_core_dumps() {
    let none = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: plain system calls with valid arguments.
    unsafe {
        libc::setrlimit(libc::RLIMIT_CORE, &none);
        #[cfg(target_os = "linux")]
        libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0);
    }
}

/// `pulshade-relay seal` and `unseal`: standard input to standard output under the storage key, for the operator's
/// backups of the onion service's keys.
fn seal_command(command: &str, directory_path: &str) -> ! {
    let sealer = sealed::Sealer::standard(&PathBuf::from(directory_path));
    let mut input = Vec::new();
    std::io::stdin().read_to_end(&mut input).expect("could not read standard input");
    let output = if command == "seal" {
        sealer.seal(&input)
    } else {
        match sealed::Sealer::is_sealed(&input).then(|| sealer.open(&input)).flatten() {
            Some(plain) => plain,
            None => { eprintln!("not sealed with this relay's storage key"); std::process::exit(1) }
        }
    };
    use std::io::Write;
    std::io::stdout().write_all(&output).expect("could not write standard output");
    std::process::exit(0)
}

#[tokio::main]
async fn main() {
    no_core_dumps();
    let directory_path = std::env::var("PULSHADE_DIRECTORY").unwrap_or_else(|_| "pulshade-directory.json".into());
    if let Some(command) = std::env::args().nth(1).filter(|c| c == "seal" || c == "unseal") {
        seal_command(&command, &directory_path);
    }
    let bind = std::env::var("PULSHADE_BIND").unwrap_or_else(|_| "127.0.0.1:7878".into());
    let store: Shared = Arc::default();
    // A spool file an older version left behind is destroyed before anyone can ask for anything.
    forget_old_spool(&PathBuf::from(&directory_path).with_file_name("pulshade-spool.sealed"));
    let state = AppState {
        store: store.clone(),
        calls: Arc::default(),
        backups: Arc::new(Backups::at(PathBuf::from(&directory_path).with_file_name("pulshade-backups"))),
        releases: Arc::new(release::Releases::at(PathBuf::from(&directory_path).with_file_name("pulshade-release"))),
        directory: Arc::new(Mutex::new(Directory::load(PathBuf::from(&directory_path), creator_key(),
                                                       sealed::Sealer::standard(&PathBuf::from(&directory_path))))),
        limits: Arc::default(),
        in_flight: Arc::new(Semaphore::new(MAX_IN_FLIGHT)),
        admin_token: Arc::new(admin_token()),
        started: Instant::now(),
    };
    if let Some(key) = pet_signing_key() { state.directory.lock().unwrap().set_pet_key(key); }

    let (sweeper, backups) = (store.clone(), state.backups.clone());
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(600));
        loop {
            tick.tick().await;
            purge(&sweeper);
            push::global().sweep();
            backups.sweep(backup::BACKUP_TTL);
        }
    });
    // Addresses are only kept while they count towards a limit, checked every minute.
    let limits = state.limits.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(60));
        loop {
            tick.tick().await;
            limits.lock().unwrap().sweep();
        }
    });

    let app = app(state);
    // Also an onion service, unless PULSHADE_ONION=0 (tests). It takes a moment to reach the Tor network.
    if std::env::var("PULSHADE_ONION").as_deref() != Ok("0") {
        let (app, folder) = (app.clone(), onion::folder(&PathBuf::from(&directory_path)));
        tokio::spawn(async move {
            match onion::serve(app, folder).await {
                Ok(address) => eprintln!("pulshade relay onion address: http://{address} (reachable once published, about a minute)"),
                Err(e) => eprintln!("onion service failed: {e}"),
            }
        });
    }

    let listener = tokio::net::TcpListener::bind(&bind).await.expect("could not bind");
    eprintln!("pulshade relay listening on {bind}");
    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(stop_signal())
        .await
        .unwrap();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::IpAddr;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn unix_now() -> u64 {
        SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
    }

    #[tokio::test]
    async fn call_rooms_pass_packets_between_two_devices_only() {
        use futures_util::{SinkExt, StreamExt};
        use tokio_tungstenite::{connect_async, tungstenite::Message as Ws};
        let dir = std::env::temp_dir().join(format!("pulshade-call-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let state = AppState {
            store: Arc::default(),
            calls: Arc::default(),
            backups: Arc::new(Backups::at(dir.join("backups"))),
            releases: Arc::new(release::Releases::at(dir.join("release"))),
            directory: Arc::new(Mutex::new(Directory::default())),
            limits: Arc::default(),
            in_flight: Arc::new(Semaphore::new(MAX_IN_FLIGHT)),
                admin_token: Arc::new("t".into()),
            started: Instant::now(),
        };
        let calls = state.calls.clone();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app(state).into_make_service_with_connect_info::<SocketAddr>()).await.unwrap();
        });
        let room = "ab".repeat(32);
        let url = format!("ws://{addr}/v1/call/{room}");
        let (mut a, _) = connect_async(&url).await.unwrap();
        let (mut b, _) = connect_async(&url).await.unwrap();
        let (mut c, _) = connect_async(&url).await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(calls.active(), 1);

        a.send(Ws::Binary(vec![1, 2, 3].into())).await.unwrap();
        let got = tokio::time::timeout(Duration::from_secs(2), b.next()).await.unwrap().unwrap().unwrap();
        assert_eq!(got.into_data().as_ref(), &[1, 2, 3]);
        b.send(Ws::Binary(vec![9].into())).await.unwrap();
        let back = tokio::time::timeout(Duration::from_secs(2), a.next()).await.unwrap().unwrap().unwrap();
        assert_eq!(back.into_data().as_ref(), &[9]);
        // A third device is turned away.
        let third = tokio::time::timeout(Duration::from_millis(300), c.next()).await;
        assert!(matches!(third, Ok(None) | Ok(Some(Err(_))) | Ok(Some(Ok(Ws::Close(_))))), "third device got {third:?}");

        // One side hanging up closes the other and clears the room.
        a.close(None).await.unwrap();
        let closed = tokio::time::timeout(Duration::from_secs(2), b.next()).await.unwrap();
        assert!(matches!(closed, None | Some(Ok(Ws::Close(_))) | Some(Err(_))));
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(calls.active(), 0);
        let bad = connect_async(format!("ws://{addr}/v1/call/not-a-room")).await;
        assert!(bad.is_err(), "rooms must be 64 hex characters");
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn key(n: u8) -> Id {
        [n; 32]
    }

    #[test]
    fn a_deposit_marked_two_is_a_call() {
        let mut headers = HeaderMap::new();
        assert!(!rings(&headers));
        headers.insert("x-pulshade-wake", "2".parse().unwrap());
        assert!(rings(&headers) && wakes(&headers));
        headers.insert("x-pulshade-wake", "1".parse().unwrap());
        assert!(!rings(&headers));
    }

    #[test]
    fn only_mail_an_app_calls_a_message_wakes_a_phone() {
        let mut headers = HeaderMap::new();
        assert!(wakes(&headers), "an app that doesn't say, wakes it as before");
        headers.insert("x-pulshade-wake", "1".parse().unwrap());
        assert!(wakes(&headers));
        headers.insert("x-pulshade-wake", "0".parse().unwrap());
        assert!(!wakes(&headers), "a typing signal or receipt doesn't");
    }

    #[tokio::test]
    async fn deposit_fetch_ack_round_trip() {
        let store: Shared = Arc::default();
        let receive = key(7);
        let send = hex::encode(send_id_for(&receive));

        assert_eq!(deposit(State(store.clone()), Path(send.clone()), HeaderMap::new(), Bytes::from_static(b"sealed")).await, StatusCode::ACCEPTED);

        let Json(res) = fetch(State(store.clone()), Json(FetchRequest { keys: vec![hex::encode(receive)], wait: 0 })).await.unwrap();
        assert_eq!(res.items.len(), 1);
        assert_eq!(B64.decode(&res.items[0].blob).unwrap(), b"sealed");
        assert_eq!(res.items[0].age, 0);

        let id = res.items[0].id;
        ack(State(store.clone()), Json(AckRequest { acks: vec![Ack { key: hex::encode(receive), ids: vec![id] }] })).await;
        let Json(res) = fetch(State(store.clone()), Json(FetchRequest { keys: vec![hex::encode(receive)], wait: 0 })).await.unwrap();
        assert!(res.items.is_empty());
        assert!(store.lock().unwrap().queues.is_empty());
    }

    /// A fetch that waits answers the moment mail lands, and gives up empty at its deadline.
    #[tokio::test]
    async fn a_waiting_fetch_answers_when_mail_lands() {
        let store: Shared = Arc::default();
        let receive = key(11);
        let send = hex::encode(send_id_for(&receive));
        let started = Instant::now();
        let waiting = tokio::spawn(fetch(State(store.clone()), Json(FetchRequest { keys: vec![hex::encode(receive)], wait: 10 })));
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert_eq!(deposit(State(store.clone()), Path(send), HeaderMap::new(), Bytes::from_static(b"now")).await, StatusCode::ACCEPTED);
        let Json(res) = waiting.await.unwrap().unwrap();
        assert_eq!(res.items.len(), 1);
        assert!(started.elapsed() < Duration::from_secs(2), "answered when the mail landed, not at the deadline");

        let other = key(12);
        let started = Instant::now();
        let Json(res) = fetch(State(store), Json(FetchRequest { keys: vec![hex::encode(other)], wait: 1 })).await.unwrap();
        assert!(res.items.is_empty());
        assert!(started.elapsed() >= Duration::from_secs(1), "nothing for it: waited out the second");
    }

    /// A message sent after a story's pieces is handed over first, and a big piece at the front of one mailbox
    /// doesn't hold up the short mail in the others.
    #[tokio::test]
    async fn short_mail_is_fetched_before_big_pieces_ahead_of_it() {
        let store: Shared = Arc::default();
        let (a, b) = (key(61), key(62));
        let big = |id: u64| Item { id, at: Instant::now(), blob: Bytes::from(vec![1u8; 2_000_000]) };
        let short = |id: u64, body: &'static [u8]| Item { id, at: Instant::now(), blob: Bytes::from_static(body) };
        store.lock().unwrap().queues.insert(send_id_for(&a), VecDeque::from([big(1), big(2), short(3, b"hello")]));
        store.lock().unwrap().queues.insert(send_id_for(&b), VecDeque::from([big(4), short(5, b"hi"), short(6, b"there")]));

        let Json(first) = fetch(State(store.clone()), Json(FetchRequest { keys: vec![hex::encode(a), hex::encode(b)], wait: 0 })).await.unwrap();
        let ids: Vec<u64> = first.items.iter().map(|i| i.id).collect();
        assert_eq!(ids, vec![3, 5, 6], "only the short mail, though big pieces came first in both mailboxes");

        // Acknowledged, the big ones come, one at a time as before.
        let ack_body = AckRequest { acks: vec![
            Ack { key: hex::encode(a), ids: vec![3] },
            Ack { key: hex::encode(b), ids: vec![5, 6] },
        ] };
        assert!(ack(State(store.clone()), Json(ack_body)).await.is_success());
        let Json(next) = fetch(State(store.clone()), Json(FetchRequest { keys: vec![hex::encode(a), hex::encode(b)], wait: 0 })).await.unwrap();
        assert_eq!(next.items.iter().map(|i| i.id).collect::<Vec<_>>(), vec![1], "then the oldest big piece, alone");
    }

    /// What's waiting is counted, so a flood is refused (507) before it can take the relay down, and acknowledging
    /// or expiring mail gives the room back.
    #[tokio::test]
    async fn the_relay_refuses_mail_past_its_memory_budget_and_gives_room_back() {
        let store: Shared = Arc::default();
        let receive = key(21);
        let send = hex::encode(send_id_for(&receive));
        assert_eq!(deposit(State(store.clone()), Path(send.clone()), HeaderMap::new(), Bytes::from_static(b"12345")).await, StatusCode::ACCEPTED);
        assert_eq!(store.lock().unwrap().bytes, 5);
        store.lock().unwrap().bytes = MAX_TOTAL_BYTES - 3;
        // Full: the oldest mail makes way and the new deposit is taken, rather than the relay going deaf.
        assert_eq!(deposit(State(store.clone()), Path(send.clone()), HeaderMap::new(), Bytes::from_static(b"abcd")).await, StatusCode::ACCEPTED);
        assert_eq!(deposit(State(store.clone()), Path(send), HeaderMap::new(), Bytes::from_static(b"abc")).await, StatusCode::ACCEPTED);
        // Expiry recounts from what's really there.
        purge(&store);
        assert_eq!(store.lock().unwrap().bytes, 4 + 3);
        let Json(res) = fetch(State(store.clone()), Json(FetchRequest { keys: vec![hex::encode(receive)], wait: 0 })).await.unwrap();
        let ids: Vec<u64> = res.items.iter().map(|i| i.id).collect();
        ack(State(store.clone()), Json(AckRequest { acks: vec![Ack { key: hex::encode(receive), ids }] })).await;
        assert_eq!(store.lock().unwrap().bytes, 0);
    }

    /// When the relay is full, the oldest mail anywhere goes first and newer mail stays.
    #[test]
    fn making_room_drops_the_oldest_mail_first() {
        let mut store = Store::default();
        let boxes = [[1u8; 32], [2u8; 32], [3u8; 32]];
        for (n, mailbox) in boxes.iter().enumerate() {
            std::thread::sleep(Duration::from_millis(2));
            let item = Item { id: n as u64, at: Instant::now(), blob: Bytes::from(vec![0u8; 10]) };
            store.queues.entry(*mailbox).or_default().push_back(item);
        }
        store.bytes = MAX_TOTAL_BYTES - MAX_TOTAL_BYTES / 20 + 5;
        make_room(&mut store, 1, false);
        assert!(!store.queues.contains_key(&boxes[0]), "the oldest went");
        assert!(store.queues.contains_key(&boxes[1]) && store.queues.contains_key(&boxes[2]), "the newer stayed");
        assert_eq!(store.bytes, MAX_TOTAL_BYTES - MAX_TOTAL_BYTES / 20 - 5);
    }

    /// Deposits are anonymous, so one caller is held to an allowance of its own.
    #[test]
    fn one_caller_cannot_deposit_without_end() {
        let mut limits = Limiter::default();
        let who: std::net::IpAddr = "203.0.113.5".parse().unwrap();
        let other: std::net::IpAddr = "203.0.113.6".parse().unwrap();
        assert!(limits.allow_n(who, "deposit-size", 100, Duration::from_secs(3600), 60));
        assert!(!limits.allow_n(who, "deposit-size", 100, Duration::from_secs(3600), 60), "past its size allowance");
        assert!(limits.allow_n(other, "deposit-size", 100, Duration::from_secs(3600), 60), "someone else is unaffected");
    }

    /// A big story must not hold up what's behind it: one fetch stays under the size cap (but always carries at
    /// least one envelope), and acknowledging what came lets the next fetch bring the rest: the short mail first,
    /// then the big, each in the order sent.
    #[tokio::test]
    async fn a_fetch_stays_small_and_the_rest_follows_after_acknowledging() {
        let store: Shared = Arc::default();
        let receive = key(33);
        let send = hex::encode(send_id_for(&receive));
        let big = Bytes::from(vec![7u8; 400 * 1024]);
        for _ in 0..5 { assert_eq!(deposit(State(store.clone()), Path(send.clone()), HeaderMap::new(), big.clone()).await, StatusCode::ACCEPTED); }
        assert_eq!(deposit(State(store.clone()), Path(send.clone()), HeaderMap::new(), Bytes::from_static(b"hi")).await, StatusCode::ACCEPTED);
        let mut seen = Vec::new();
        for _ in 0..10 {
            let Json(res) = fetch(State(store.clone()), Json(FetchRequest { keys: vec![hex::encode(receive)], wait: 0 })).await.unwrap();
            if res.items.is_empty() { break; }
            let size: usize = res.items.iter().map(|i| B64.decode(&i.blob).unwrap().len()).sum();
            assert!(size <= MAX_FETCH_BYTES, "answered with {size} bytes");
            let ids: Vec<u64> = res.items.iter().map(|i| i.id).collect();
            seen.extend(res.items.iter().map(|i| B64.decode(&i.blob).unwrap().len()));
            ack(State(store.clone()), Json(AckRequest { acks: vec![Ack { key: hex::encode(receive), ids }] })).await;
        }
        // Ids are unpredictable, so order is judged by what each envelope held.
        assert_eq!(seen, vec![2, 400 * 1024, 400 * 1024, 400 * 1024, 400 * 1024, 400 * 1024], "everything arrives, the short one first");
        assert_eq!(store.lock().unwrap().bytes, 0);

        // A single envelope past the cap still goes, alone.
        let huge = Bytes::from(vec![1u8; MAX_FETCH_BYTES + 10]);
        deposit(State(store.clone()), Path(send), HeaderMap::new(), huge).await;
        let Json(res) = fetch(State(store), Json(FetchRequest { keys: vec![hex::encode(receive)], wait: 0 })).await.unwrap();
        assert_eq!(res.items.len(), 1);
    }

    #[tokio::test]
    async fn send_id_cannot_read() {
        let store: Shared = Arc::default();
        let receive = key(9);
        let send = hex::encode(send_id_for(&receive));
        deposit(State(store.clone()), Path(send.clone()), HeaderMap::new(), Bytes::from_static(b"x")).await;
        // Someone holding only the send id gets nothing back.
        let Json(res) = fetch(State(store), Json(FetchRequest { keys: vec![send], wait: 0 })).await.unwrap();
        assert!(res.items.is_empty());
    }

    /// The manifest endpoint has to be rate-limited too: without it, it's a free way to hammer the relay
    /// (and, over Tor, to probe at timing) with no proof of work and no cost at all.
    #[tokio::test]
    async fn update_manifest_is_rate_limited_per_caller() {
        let dir = std::env::temp_dir().join(format!("pulshade-update-manifest-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let state = AppState {
            store: Arc::default(),
            calls: Arc::default(),
            backups: Arc::new(Backups::at(dir.join("backups"))),
            releases: Arc::new(release::Releases::at(dir.join("release"))),
            directory: Arc::new(Mutex::new(Directory::default())),
            limits: Arc::default(),
            in_flight: Arc::new(Semaphore::new(MAX_IN_FLIGHT)),
                admin_token: Arc::new("t".into()),
            started: Instant::now(),
        };
        let ip: IpAddr = "203.0.113.5".parse().unwrap();
        for _ in 0..20 {
            let response = update_manifest(State(state.clone()), caller::Caller(ip), HeaderMap::new()).await;
            assert_ne!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        }
        let response = update_manifest(State(state.clone()), caller::Caller(ip), HeaderMap::new()).await;
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);

        // A different caller gets its own allowance.
        let other: IpAddr = "203.0.113.6".parse().unwrap();
        let response = update_manifest(State(state), caller::Caller(other), HeaderMap::new()).await;
        assert_ne!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn rejects_bad_input() {
        let store: Shared = Arc::default();
        assert_eq!(deposit(State(store.clone()), Path("nothex".into()), HeaderMap::new(), Bytes::from_static(b"x")).await, StatusCode::BAD_REQUEST);
        let send = hex::encode(send_id_for(&key(1)));
        assert_eq!(deposit(State(store), Path(send), HeaderMap::new(), Bytes::new()).await, StatusCode::PAYLOAD_TOO_LARGE);
    }

    fn state_in(dir: &std::path::Path) -> AppState {
        AppState {
            store: Arc::default(),
            calls: Arc::default(),
            backups: Arc::new(Backups::at(dir.join("backups"))),
            releases: Arc::new(release::Releases::at(dir.join("release"))),
            directory: Arc::new(Mutex::new(Directory::default())),
            limits: Arc::default(),
            in_flight: Arc::new(Semaphore::new(MAX_IN_FLIGHT)),
            admin_token: Arc::new("t".into()),
            started: Instant::now(),
        }
    }

    async fn served(state: AppState) -> SocketAddr {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app(state).into_make_service_with_connect_info::<SocketAddr>()).await.unwrap();
        });
        addr
    }

    /// A backup request's signature, as the apps make it.
    fn backup_sig(owner: &ed25519_dalek::SigningKey, label: &str, ts: u64, body: Option<&[u8]>) -> String {
        use ed25519_dalek::Signer;
        let mut message = label.as_bytes().to_vec();
        message.extend_from_slice(owner.verifying_key().as_bytes());
        message.extend_from_slice(&ts.to_be_bytes());
        if let Some(body) = body { message.extend_from_slice(&Sha256::digest(body)); }
        B64.encode(owner.sign(&message).to_bytes())
    }

    /// The way the apps leave and collect a backup still works as it did: the same headers, the same answers, and
    /// the same bytes back, now read from disk a piece at a time.
    #[tokio::test]
    async fn a_backup_goes_up_and_comes_back_whole_as_before() {
        let dir = std::env::temp_dir().join(format!("pulshade-backup-http-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let state = state_in(&dir);
        let addr = served(state.clone()).await;
        let owner = ed25519_dalek::SigningKey::from_bytes(&[21; 32]);
        let url = format!("http://{addr}/v1/backup/{}", hex::encode(owner.verifying_key().as_bytes()));
        // Larger than one piece, and not a whole number of them.
        let blob: Vec<u8> = (0..300_001u32).map(|i| (i % 251) as u8).collect();
        let ts = unix_now();
        let client = reqwest::Client::new();

        let put = client.put(&url)
            .header("content-type", "application/octet-stream")
            .header("x-pulshade-sig", backup_sig(&owner, "pulshade.backup.put.v1", ts, Some(&blob)))
            .header("x-pulshade-ts", ts.to_string())
            .body(blob.clone()).send().await.unwrap();
        assert_eq!(put.status(), StatusCode::NO_CONTENT);

        let proof = serde_json::json!({ "sig": backup_sig(&owner, "pulshade.backup.get.v1", ts, None), "ts": ts }).to_string();
        let got = client.post(format!("{url}/get")).header("content-type", "application/json").body(proof).send().await.unwrap();
        assert_eq!(got.status(), StatusCode::OK);
        assert_eq!(got.headers()["content-length"], "300001");
        assert_eq!(got.headers()["content-type"], "application/octet-stream");
        assert_eq!(got.bytes().await.unwrap().as_ref(), &blob[..]);

        let stranger = ed25519_dalek::SigningKey::from_bytes(&[22; 32]);
        let proof = serde_json::json!({ "sig": backup_sig(&stranger, "pulshade.backup.get.v1", ts, None), "ts": ts }).to_string();
        let refused = client.post(format!("{url}/get")).header("content-type", "application/json").body(proof).send().await.unwrap();
        assert_eq!(refused.status(), StatusCode::UNAUTHORIZED);
        // Everything counted while it arrived has been given back.
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(state.in_flight.available_permits(), MAX_IN_FLIGHT);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An upload is refused before any of it is read when the request already fails its limit or lacks its headers,
    /// so a caller who will be turned away can't make the relay hold megabytes first.
    #[tokio::test]
    async fn a_backup_is_only_read_once_the_request_has_passed_its_checks() {
        use axum::body::Body;
        let dir = std::env::temp_dir().join(format!("pulshade-backup-order-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let state = state_in(&dir);
        let owner = ed25519_dalek::SigningKey::from_bytes(&[23; 32]);
        let id = hex::encode(owner.verifying_key().as_bytes());
        let ip: IpAddr = "203.0.113.40".parse().unwrap();
        // A body that notes when anything asks for it.
        let watched = || {
            let read = Arc::new(AtomicBool::new(false));
            let flag = read.clone();
            let body = Body::from_stream(futures_util::stream::once(async move {
                flag.store(true, Ordering::SeqCst);
                Ok::<_, std::io::Error>(Bytes::from_static(b"sealed"))
            }));
            (body, read)
        };
        let signed = |length: Option<&str>| {
            let mut headers = HeaderMap::new();
            headers.insert("x-pulshade-sig", B64.encode([0u8; 64]).parse().unwrap());
            headers.insert("x-pulshade-ts", unix_now().to_string().parse().unwrap());
            if let Some(length) = length { headers.insert("content-length", length.parse().unwrap()); }
            headers
        };

        let (body, read) = watched();
        assert_eq!(backup_put(State(state.clone()), caller::Caller(ip), Path(id.clone()), HeaderMap::new(), body).await, StatusCode::BAD_REQUEST);
        assert!(!read.load(Ordering::SeqCst), "no signature: refused unread");

        let (body, read) = watched();
        let too_long = (backup::MAX_BACKUP + 1).to_string();
        assert_eq!(backup_put(State(state.clone()), caller::Caller(ip), Path(id.clone()), signed(Some(&too_long)), body).await, StatusCode::PAYLOAD_TOO_LARGE);
        assert!(!read.load(Ordering::SeqCst), "says it is too large: refused unread");

        // With everything in order it is read, and then judged by its signature.
        let (body, read) = watched();
        assert_eq!(backup_put(State(state.clone()), caller::Caller(ip), Path(id.clone()), signed(Some("6")), body).await, StatusCode::UNAUTHORIZED);
        assert!(read.load(Ordering::SeqCst));

        // One that doesn't say how long it is stops being read at the limit.
        let endless = Body::from_stream(futures_util::stream::iter((0..40).map(|_| Ok::<_, std::io::Error>(Bytes::from(vec![0u8; 1024 * 1024])))));
        assert_eq!(backup_put(State(state.clone()), caller::Caller(ip), Path(id.clone()), signed(None), endless).await, StatusCode::PAYLOAD_TOO_LARGE);

        // Past the hourly limit, nothing is read at all.
        for _ in 0..16 {
            let (body, _) = watched();
            backup_put(State(state.clone()), caller::Caller(ip), Path(id.clone()), HeaderMap::new(), body).await;
        }
        let (body, read) = watched();
        assert_eq!(backup_put(State(state.clone()), caller::Caller(ip), Path(id), signed(Some("6")), body).await, StatusCode::TOO_MANY_REQUESTS);
        assert!(!read.load(Ordering::SeqCst), "over the limit: refused unread");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Uploads being received share one budget of memory. With none left a large upload is refused (503) instead of
    /// being held, short mail still gets through, and the room comes back when requests end.
    #[tokio::test]
    async fn large_uploads_are_refused_when_too_much_is_arriving_at_once() {
        let dir = std::env::temp_dir().join(format!("pulshade-in-flight-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let state = state_in(&dir);
        let addr = served(state.clone()).await;
        let url = format!("http://{addr}/v1/q/{}", hex::encode(send_id_for(&key(71))));
        let client = reqwest::Client::new();
        let send = |size: usize| client.put(&url).body(vec![5u8; size]).send();

        // As if other uploads had taken all but a little of the room.
        let others = state.in_flight.clone().try_acquire_many_owned((MAX_IN_FLIGHT - 10_000) as u32).unwrap();
        assert_eq!(send(SHORT_MAIL + 16 * 1024).await.unwrap().status(), StatusCode::SERVICE_UNAVAILABLE);
        assert!(state.store.lock().unwrap().queues.is_empty(), "nothing of it was kept");
        assert_eq!(send(100).await.unwrap().status(), StatusCode::ACCEPTED, "a short message isn't counted");
        assert_eq!(send(SHORT_MAIL).await.unwrap().status(), StatusCode::ACCEPTED);
        assert_eq!(send(SHORT_MAIL + 5_000).await.unwrap().status(), StatusCode::ACCEPTED, "what fits in the room left is taken");

        drop(others);
        assert_eq!(send(SHORT_MAIL + 16 * 1024).await.unwrap().status(), StatusCode::ACCEPTED);
        assert_eq!(send(2 * 1024 * 1024).await.unwrap().status(), StatusCode::ACCEPTED);
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(state.in_flight.available_permits(), MAX_IN_FLIGHT, "all of it given back");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An acknowledgement costs its own length: ids are looked up in a set, a mailbox named twice is gone through
    /// once, and a list longer than any app sends is refused whole.
    #[tokio::test]
    async fn acknowledgements_are_capped_and_cost_no_more_than_their_length() {
        let store: Shared = Arc::default();
        let receive = key(81);
        let send = hex::encode(send_id_for(&receive));
        for _ in 0..MAX_QUEUE {
            assert_eq!(deposit(State(store.clone()), Path(send.clone()), HeaderMap::new(), Bytes::from_static(b"x")).await, StatusCode::ACCEPTED);
        }
        let ids: Vec<u64> = store.lock().unwrap().queues[&send_id_for(&receive)].iter().map(|item| item.id).collect();

        let too_many = AckRequest { acks: vec![Ack { key: hex::encode(receive), ids: (0..=MAX_ACK_IDS as u64).collect() }] };
        assert_eq!(ack(State(store.clone()), Json(too_many)).await, StatusCode::BAD_REQUEST);
        assert_eq!(store.lock().unwrap().bytes, MAX_QUEUE, "and nothing is dropped for it");

        // A full mailbox acknowledged at once, with ids that aren't there mixed in, split over two mentions of it.
        let started = Instant::now();
        let mut first = ids[..MAX_QUEUE / 2].to_vec();
        first.extend(0..(MAX_ACK_IDS - first.len()) as u64);
        let request = AckRequest { acks: vec![
            Ack { key: hex::encode(receive), ids: first },
            Ack { key: "not a key".into(), ids: vec![1] },
            Ack { key: hex::encode(receive), ids: ids[MAX_QUEUE / 2..].to_vec() },
        ] };
        assert_eq!(ack(State(store.clone()), Json(request)).await, StatusCode::NO_CONTENT);
        assert!(started.elapsed() < Duration::from_secs(1));
        assert!(store.lock().unwrap().queues.is_empty());
        assert_eq!(store.lock().unwrap().bytes, 0);
    }
}
