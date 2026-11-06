//! A load test for the relay: a few hundred made-up people who text each other and post video stories, some of
//! them away. It talks to a relay over HTTP the way the apps do (deposit, a fetch that waits, acknowledge), with
//! made-up mailboxes and random bytes for mail, and says what got through and how fast.
//!
//! Run a relay of your own for it, never the live one:
//!
//!     PULSHADE_BIND=127.0.0.1:7979 PULSHADE_ONION=0 PULSHADE_DIRECTORY=/tmp/load/dir.json cargo run --release
//!     cargo run --release --example load -- relay=http://127.0.0.1:7979 pid=<the relay's>
//!
//! Everything is `name=value`; see `Plan` for the names and what they start as.

use base64::{Engine, engine::general_purpose::STANDARD as B64};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU8, AtomicU64, AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

#[derive(Clone)]
struct Plan {
    relay: String,
    /// The relay's process, to watch its memory. 0 doesn't.
    pid: u32,
    users: usize,
    /// How many people each one talks to.
    contacts: usize,
    /// The share of people who are away for the whole run and come back at the end.
    away: f64,
    /// The share of the people who are here that post a video story.
    posting: f64,
    /// Pieces in one video story, and the size of each as the relay gets it: 2 of 2 MiB from an app that sends
    /// frames, 4 of 3 MiB from an older one.
    pieces: usize,
    piece_kib: usize,
    /// Seconds between one person's texts, on average.
    text_every: f64,
    /// Seconds of texting alone before the stories start, and over how long the posters start.
    warmup: f64,
    spread: f64,
    /// A phone's upload and download speeds, in megabits a second.
    up_mbps: f64,
    down_mbps: f64,
    /// Seconds to wait, with nothing more arriving, before calling the stories done.
    settle: f64,
}

impl Plan {
    fn from_args() -> Plan {
        let mut plan = Plan {
            relay: "http://127.0.0.1:7979".into(), pid: 0, users: 300, contacts: 20, away: 0.2, posting: 0.25,
            pieces: 2, piece_kib: 2048, text_every: 10.0, warmup: 15.0, spread: 30.0, up_mbps: 8.0, down_mbps: 20.0,
            settle: 20.0,
        };
        for arg in std::env::args().skip(1) {
            let Some((name, value)) = arg.split_once('=') else { panic!("expected name=value, got {arg}") };
            let number = || value.parse::<f64>().unwrap_or_else(|_| panic!("{name} needs a number"));
            match name {
                "relay" => plan.relay = value.trim_end_matches('/').into(),
                "pid" => plan.pid = number() as u32,
                "users" => plan.users = number() as usize,
                "contacts" => plan.contacts = number() as usize,
                "away" => plan.away = number(),
                "posting" => plan.posting = number(),
                "pieces" => plan.pieces = number() as usize,
                "piece_kib" => plan.piece_kib = number() as usize,
                "text_every" => plan.text_every = number(),
                "warmup" => plan.warmup = number(),
                "spread" => plan.spread = number(),
                "up_mbps" => plan.up_mbps = number(),
                "down_mbps" => plan.down_mbps = number(),
                "settle" => plan.settle = number(),
                _ => panic!("no setting called {name}"),
            }
        }
        assert!(plan.contacts < plan.users && plan.contacts >= 2, "contacts must be at least 2 and fewer than users");
        assert!(plan.pieces >= 1 && plan.pieces < 250);
        plan
    }
}

/// A small random number maker, one per task, so runs don't need a crate for it.
struct Dice(u64);

impl Dice {
    fn new(seed: u64) -> Dice {
        Dice(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    /// From 0 up to, not including, 1.
    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }
    fn between(&mut self, low: f64, high: f64) -> f64 {
        low + (high - low) * self.unit()
    }
}

const TEXT: u8 = 0;
const PIECE: u8 = 1;
/// What every made-up envelope starts with: when it was sent, what it is, who from.
const HEAD: usize = 18;

struct Head {
    sent_micros: u64,
    kind: u8,
    /// 0 for a text sent before the stories started, 1 for one sent while they were going.
    phase: u8,
    sender: u32,
    story: u16,
    index: u8,
}

impl Head {
    fn write(&self, of: u8, out: &mut [u8]) {
        out[..8].copy_from_slice(&self.sent_micros.to_be_bytes());
        out[8] = self.kind;
        out[9] = self.phase;
        out[10..14].copy_from_slice(&self.sender.to_be_bytes());
        out[14..16].copy_from_slice(&self.story.to_be_bytes());
        out[16] = self.index;
        out[17] = of;
    }
    fn read(raw: &[u8]) -> Option<Head> {
        if raw.len() < HEAD { return None }
        Some(Head {
            sent_micros: u64::from_be_bytes(raw[..8].try_into().ok()?), kind: raw[8], phase: raw[9],
            sender: u32::from_be_bytes(raw[10..14].try_into().ok()?), story: u16::from_be_bytes(raw[14..16].try_into().ok()?),
            index: raw[16],
        })
    }
}

#[derive(Default)]
struct Tally {
    /// What the relay answered to deposits, by status (0 is no answer at all).
    statuses: Mutex<BTreeMap<u16, usize>>,
    retries: AtomicUsize,
    gave_up: AtomicUsize,
    /// Texts to people who are here: sent, and how long each took, by phase.
    texts_sent: [AtomicUsize; 2],
    text_millis: [Mutex<Vec<u32>>; 2],
    /// Texts to people who are away: sent, and collected once they came back.
    away_texts_sent: AtomicUsize,
    away_texts_got: AtomicUsize,
    /// Pieces each person has of each story: (reader, poster, story) to the piece numbers.
    pieces: Mutex<HashMap<(u32, u32, u16), HashSet<u8>>>,
    /// Stories that arrived whole, for people here and away, and how long the first kind took from the moment the
    /// poster pressed send.
    whole_here: AtomicUsize,
    whole_away: AtomicUsize,
    story_millis: Mutex<Vec<u32>>,
    pieces_got: AtomicUsize,
    bytes_up: AtomicU64,
    bytes_down: AtomicU64,
    fetch_errors: AtomicUsize,
    /// The last moment anything arrived, in microseconds since the start.
    last_arrival: AtomicU64,
}

struct World {
    plan: Plan,
    http: reqwest::Client,
    start: Instant,
    nonce: [u8; 8],
    /// Who is away.
    away: Vec<bool>,
    tally: Tally,
    phase: AtomicU8,
    stop: AtomicBool,
}

impl World {
    fn micros(&self) -> u64 {
        self.start.elapsed().as_micros() as u64
    }

    /// The people `who` talks to: the nearest on either side, so everyone has the same number.
    fn contacts(&self, who: usize) -> Vec<usize> {
        let n = self.plan.users;
        (1..=self.plan.contacts).map(|step| {
            let hop = step.div_ceil(2);
            if step % 2 == 1 { (who + hop) % n } else { (who + n - hop) % n }
        }).collect()
    }

    /// The secret the reader collects mail from `from` with. The relay files it under this key's hash.
    fn receive_key(&self, from: usize, to: usize) -> [u8; 32] {
        Sha256::new().chain_update(b"load").chain_update(self.nonce)
            .chain_update((from as u64).to_be_bytes()).chain_update((to as u64).to_be_bytes()).finalize().into()
    }

    fn send_id(&self, from: usize, to: usize) -> String {
        hex::encode(Sha256::digest(self.receive_key(from, to)))
    }

    /// Hands one envelope to the relay, trying again every couple of seconds as the app does. False if it never went.
    async fn deposit(&self, from: usize, to: usize, body: Vec<u8>, wake: bool) -> bool {
        let url = format!("{}/v1/q/{}", self.plan.relay, self.send_id(from, to));
        let size = body.len();
        // A phone takes this long to upload it.
        if size > 64 * 1024 {
            tokio::time::sleep(Duration::from_secs_f64(size as f64 * 8.0 / (self.plan.up_mbps * 1e6))).await;
        }
        let body = axum::body::Bytes::from(body);
        for attempt in 0..90 {
            if attempt > 0 {
                self.tally.retries.fetch_add(1, Ordering::Relaxed);
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
            let sent = self.http.put(&url).header("content-type", "application/octet-stream")
                .header("x-pulshade-wake", if wake { "1" } else { "0" }).body(body.clone()).send().await;
            let status = sent.map(|r| r.status().as_u16()).unwrap_or(0);
            *self.tally.statuses.lock().unwrap().entry(status).or_default() += 1;
            if status == 202 {
                self.tally.bytes_up.fetch_add(size as u64, Ordering::Relaxed);
                return true;
            }
            if status == 413 || status == 400 { break }
        }
        self.tally.gave_up.fetch_add(1, Ordering::Relaxed);
        false
    }
}

#[derive(Deserialize)]
struct Fetched {
    items: Vec<Item>,
}

#[derive(Deserialize)]
struct Item {
    k: usize,
    id: u64,
    blob: String,
}

/// One person's phone collecting mail: a fetch that waits, then an acknowledgement, over and over. With `until_empty`
/// (someone coming back) it stops at the first fetch with nothing in it.
async fn read_mail(world: Arc<World>, who: usize, until_empty: bool) {
    let mut dice = Dice::new(who as u64 + 1);
    let from = world.contacts(who);
    let keys: Vec<String> = from.iter().map(|&c| hex::encode(world.receive_key(c, who))).collect();
    let away = world.away[who];
    while !world.stop.load(Ordering::Relaxed) {
        let wait = if until_empty { 0 } else { 25 };
        let asked = world.http.post(format!("{}/v1/fetch", world.plan.relay))
            .header("content-type", "application/json")
            .body(serde_json::json!({ "keys": keys, "wait": wait }).to_string()).timeout(Duration::from_secs(60)).send().await;
        let fetched = match asked {
            Ok(answer) if answer.status().is_success() => answer.bytes().await.ok().and_then(|raw| serde_json::from_slice::<Fetched>(&raw).ok()),
            _ => None,
        };
        let Some(fetched) = fetched else {
            world.tally.fetch_errors.fetch_add(1, Ordering::Relaxed);
            tokio::time::sleep(Duration::from_secs_f64(dice.between(1.5, 3.0))).await;
            continue;
        };
        if fetched.items.is_empty() {
            if until_empty { return }
            continue;
        }
        let mut acks: HashMap<usize, Vec<u64>> = HashMap::new();
        let mut size = 0usize;
        for item in &fetched.items {
            acks.entry(item.k).or_default().push(item.id);
            size += item.blob.len() / 4 * 3;
            let Some(head) = item.blob.get(..24).and_then(|start| B64.decode(start).ok()).and_then(|raw| Head::read(&raw)) else { continue };
            let now = world.micros();
            world.tally.last_arrival.store(now, Ordering::Relaxed);
            let millis = (now.saturating_sub(head.sent_micros) / 1000) as u32;
            match head.kind {
                TEXT if away => { world.tally.away_texts_got.fetch_add(1, Ordering::Relaxed); }
                TEXT => world.tally.text_millis[head.phase.min(1) as usize].lock().unwrap().push(millis),
                _ => {
                    world.tally.pieces_got.fetch_add(1, Ordering::Relaxed);
                    let mut pieces = world.tally.pieces.lock().unwrap();
                    let have = pieces.entry((who as u32, head.sender, head.story)).or_default();
                    if have.insert(head.index) && have.len() == world.plan.pieces {
                        if away {
                            world.tally.whole_away.fetch_add(1, Ordering::Relaxed);
                        } else {
                            world.tally.whole_here.fetch_add(1, Ordering::Relaxed);
                            world.tally.story_millis.lock().unwrap().push(millis);
                        }
                    }
                }
            }
        }
        world.tally.bytes_down.fetch_add(size as u64, Ordering::Relaxed);
        // A phone takes this long to download it.
        if size > 64 * 1024 {
            tokio::time::sleep(Duration::from_secs_f64(size as f64 * 8.0 / (world.plan.down_mbps * 1e6))).await;
        }
        let acks: Vec<_> = acks.into_iter().map(|(k, ids)| serde_json::json!({ "key": keys[k], "ids": ids })).collect();
        let _ = world.http.post(format!("{}/v1/ack", world.plan.relay)).header("content-type", "application/json")
            .body(serde_json::json!({ "acks": acks }).to_string()).send().await;
        if !until_empty {
            tokio::time::sleep(Duration::from_secs_f64(dice.between(0.1, 0.6))).await;
        }
    }
}

/// One person texting whoever they talk to, now and then, for the whole run.
async fn send_texts(world: Arc<World>, who: usize) {
    let mut dice = Dice::new(who as u64 + 1_000_003);
    let to = world.contacts(who);
    tokio::time::sleep(Duration::from_secs_f64(dice.between(0.0, world.plan.text_every))).await;
    while !world.stop.load(Ordering::Relaxed) {
        let reader = to[(dice.next() % to.len() as u64) as usize];
        let phase = world.phase.load(Ordering::Relaxed);
        if phase > 1 { return }
        // A text is padded to a kibibyte or so.
        let mut body = vec![0u8; 1024];
        Head { sent_micros: world.micros(), kind: TEXT, phase, sender: who as u32, story: 0, index: 0 }.write(1, &mut body);
        if world.deposit(who, reader, body, true).await {
            if world.away[reader] {
                world.tally.away_texts_sent.fetch_add(1, Ordering::Relaxed);
            } else {
                world.tally.texts_sent[phase.min(1) as usize].fetch_add(1, Ordering::Relaxed);
            }
        }
        tokio::time::sleep(Duration::from_secs_f64(dice.between(0.5, 1.5) * world.plan.text_every)).await;
    }
}

/// One person posting a video story: every piece to every contact, one after another, as the app sends them.
async fn post_story(world: Arc<World>, who: usize, after: f64) {
    tokio::time::sleep(Duration::from_secs_f64(after)).await;
    let pressed = world.micros();
    for reader in world.contacts(who) {
        for index in 0..world.plan.pieces {
            let mut body = vec![0u8; world.plan.piece_kib * 1024];
            // Random all through, like sealed mail, so nothing along the way (the relay's own machine included) can
            // squeeze it and make the relay look lighter than it is.
            let mut dice = Dice::new(pressed ^ ((reader as u64) << 20) ^ index as u64);
            for chunk in body.chunks_mut(8) { chunk.copy_from_slice(&dice.next().to_be_bytes()[..chunk.len()]); }
            Head { sent_micros: pressed, kind: PIECE, phase: 1, sender: who as u32, story: 1, index: index as u8 }
                .write(world.plan.pieces as u8, &mut body);
            world.deposit(who, reader, body, false).await;
        }
    }
}

fn relay_rss_mib(pid: u32) -> Option<f64> {
    let out = std::process::Command::new("ps").args(["-o", "rss=", "-p", &pid.to_string()]).output().ok()?;
    String::from_utf8_lossy(&out.stdout).trim().parse::<f64>().ok().map(|kib| kib / 1024.0)
}

fn spread(times: &mut Vec<u32>) -> String {
    if times.is_empty() { return "none".into() }
    times.sort_unstable();
    let at = |share: f64| times[((times.len() - 1) as f64 * share) as usize] as f64 / 1000.0;
    format!("half within {:.2}s, 95% within {:.2}s, 99% within {:.2}s, slowest {:.2}s", at(0.5), at(0.95), at(0.99), at(1.0))
}

#[tokio::main]
async fn main() {
    let plan = Plan::from_args();
    let mut nonce = [0u8; 8];
    nonce.copy_from_slice(&std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos().to_be_bytes()[8..]);
    // Every nth person is away, spread evenly.
    let away: Vec<bool> = (0..plan.users).map(|i| ((i + 1) as f64 * plan.away).floor() > (i as f64 * plan.away).floor()).collect();
    let world = Arc::new(World {
        http: reqwest::Client::builder().pool_max_idle_per_host(4096).timeout(Duration::from_secs(120)).build().unwrap(),
        start: Instant::now(), nonce, away, tally: Tally::default(), phase: AtomicU8::new(0), stop: AtomicBool::new(false),
        plan: plan.clone(),
    });
    let here: Vec<usize> = (0..plan.users).filter(|&i| !world.away[i]).collect();
    let posters: Vec<usize> = here.iter().copied().enumerate()
        .filter(|(n, _)| ((*n + 1) as f64 * plan.posting).floor() > (*n as f64 * plan.posting).floor()).map(|(_, i)| i).collect();
    let copy_mib = (plan.pieces * plan.piece_kib) as f64 / 1024.0;
    let (mut due_here, mut due_away) = (0usize, 0usize);
    for &poster in &posters {
        for reader in world.contacts(poster) {
            if world.away[reader] { due_away += 1 } else { due_here += 1 }
        }
    }
    println!("{} people, {} away, each talking to {}. {} post a video story of {} pieces ({:.0} MiB a copy):",
             plan.users, plan.users - here.len(), plan.contacts, posters.len(), plan.pieces, copy_mib);
    println!("{} copies for people who are here, {} for people who are away, {:.1} GiB in all.\n",
             due_here, due_away, (due_here + due_away) as f64 * copy_mib / 1024.0);

    let peak = Arc::new(Mutex::new(0f64));
    if plan.pid != 0 {
        let (peak, world, pid) = (peak.clone(), world.clone(), plan.pid);
        tokio::spawn(async move {
            while !world.stop.load(Ordering::Relaxed) {
                if let Some(now) = relay_rss_mib(pid) {
                    let mut peak = peak.lock().unwrap();
                    *peak = peak.max(now);
                }
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
        });
    }
    let resting = relay_rss_mib(plan.pid);

    let mut readers = Vec::new();
    for &who in &here {
        readers.push(tokio::spawn(read_mail(world.clone(), who, false)));
        tokio::spawn(send_texts(world.clone(), who));
    }
    println!("texting only for {:.0}s...", plan.warmup);
    tokio::time::sleep(Duration::from_secs_f64(plan.warmup)).await;

    println!("stories start...");
    world.phase.store(1, Ordering::Relaxed);
    let story_start = Instant::now();
    let mut posting = Vec::new();
    for (n, &who) in posters.iter().enumerate() {
        let after = plan.spread * n as f64 / posters.len().max(1) as f64;
        posting.push(tokio::spawn(post_story(world.clone(), who, after)));
    }
    let report = {
        let world = world.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(10)).await;
                println!("  {:>4.0}s: {} of {} stories whole for people here, relay at {} MiB",
                         story_start.elapsed().as_secs_f64(), world.tally.whole_here.load(Ordering::Relaxed), due_here,
                         relay_rss_mib(world.plan.pid).map_or("?".into(), |m| format!("{m:.0}")));
            }
        })
    };
    for task in posting { let _ = task.await; }
    let uploaded = story_start.elapsed();
    // Done when everything due has arrived, or nothing more has for a while.
    loop {
        tokio::time::sleep(Duration::from_millis(500)).await;
        let quiet = world.micros().saturating_sub(world.tally.last_arrival.load(Ordering::Relaxed)) as f64 / 1e6;
        if world.tally.whole_here.load(Ordering::Relaxed) >= due_here || quiet > plan.settle { break }
    }
    let settled = story_start.elapsed();
    report.abort();

    // Texting stops, the last ones land, and then the people who were away come back.
    world.phase.store(2, Ordering::Relaxed);
    tokio::time::sleep(Duration::from_secs(3)).await;
    println!("people who were away come back...");
    let back: Vec<_> = (0..plan.users).filter(|&i| world.away[i]).map(|who| tokio::spawn(read_mail(world.clone(), who, true))).collect();
    for task in back { let _ = task.await; }
    world.stop.store(true, Ordering::Relaxed);
    for task in readers { task.abort(); }

    let t = &world.tally;
    let count = |n: &AtomicUsize| n.load(Ordering::Relaxed);
    let share = |got: usize, of: usize| if of == 0 { "none due".to_string() } else { format!("{got} of {of} ({:.1}%)", got as f64 * 100.0 / of as f64) };
    println!("\n== What happened ==");
    println!("Stories whole, people here:   {}", share(count(&t.whole_here), due_here));
    println!("  from pressing send:         {}", spread(&mut t.story_millis.lock().unwrap()));
    println!("Stories whole, people away:   {}", share(count(&t.whole_away), due_away));
    for (phase, name) in ["before the stories", "during the stories"].iter().enumerate() {
        let mut times = t.text_millis[phase].lock().unwrap();
        println!("Texts {name}:     {}", share(times.len(), count(&t.texts_sent[phase])));
        println!("  delivery:                   {}", spread(&mut times));
    }
    println!("Texts kept for people away:   {}", share(count(&t.away_texts_got), count(&t.away_texts_sent)));
    println!("Uploading took {:.0}s; all settled {:.0}s after the first story.", uploaded.as_secs_f64(), settled.as_secs_f64());
    println!("Sent {:.2} GiB, collected {:.2} GiB.", t.bytes_up.load(Ordering::Relaxed) as f64 / (1u64 << 30) as f64,
             t.bytes_down.load(Ordering::Relaxed) as f64 / (1u64 << 30) as f64);
    let statuses = t.statuses.lock().unwrap();
    let answers: Vec<String> = statuses.iter().map(|(status, n)| format!("{status}: {n}")).collect();
    println!("Deposit answers: {}. Tried again {} times, gave up on {}. Fetches that failed: {}.",
             answers.join(", "), count(&t.retries), count(&t.gave_up), count(&t.fetch_errors));
    if let Some(resting) = resting {
        println!("Relay memory: {:.0} MiB at rest, {:.0} MiB at its highest.", resting, *peak.lock().unwrap());
    }
}
