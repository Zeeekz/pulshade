//! Wake-up pushes through Apple, so a locked iPhone hears about new mail.
//!
//! A phone that opts in registers its Apple device token against the mailboxes it reads, proving it owns
//! them with their receive keys. When an envelope is deposited, the relay sends Apple one push with no
//! message in it: only "New message". The phone then fetches the real thing over Tor as usual.
//!
//! What the relay holds is a token per mailbox, in memory only (a restart forgets them until the phone next
//! opens Pulshade and registers again, and so does a week without it opening). Apple learns that a device was
//! woken, and when. Nothing else leaves.
//!
//! The limits are there so this can't be turned on the relay or on Apple: a token can hold only so many mailboxes,
//! the table has a ceiling (the oldest registrations make way), a device is woken at most once in a while however
//! much mail lands, and the relay as a whole sends only so many pushes a second.

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD as B64URL};
use p256::ecdsa::{Signature, SigningKey, signature::Signer};
use p256::pkcs8::DecodePrivateKey;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    sync::{Arc, LazyLock, Mutex},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

type Id = [u8; 32];

/// A phone is not woken more often than this, however much mail lands or in how many of its mailboxes. Short, so
/// each message gets its own banner; it only stops a burst (a story's pieces, say) becoming a stream of them. The
/// relay can't tell a message from a receipt, so some banners are for mail that isn't one.
const COOLDOWN: Duration = Duration::from_secs(3);
/// A phone is not rung again within this, so one call that reaches it twice (two personas, say) rings once.
const CALL_COOLDOWN: Duration = Duration::from_secs(10);
/// A registration is forgotten after this long without being renewed (phones renew at every launch, and every few
/// hours while Pulshade is open). Short, so a wiped account's pushes stop on their own.
const TTL: Duration = Duration::from_secs(7 * 24 * 3600);
const MAX_TARGETS: usize = 100_000;
/// One device has this many mailboxes at most: more is not a phone.
const MAX_PER_TOKEN: usize = 2_048;
/// Pushes the relay sends to Apple in a second, all devices together. Mail past it is delivered as ever; its
/// phones just aren't woken for it.
const MAX_SENDS_PER_SECOND: u32 = 30;
/// Apple accepts a signed token for up to an hour; this one is renewed well inside that.
const JWT_LIFE: Duration = Duration::from_secs(40 * 60);

#[derive(Clone, Deserialize)]
pub struct Config {
    pub key_id: String,
    pub team_id: String,
    #[serde(default = "default_topic")]
    pub topic: String,
    /// The `.p8` file, relative to where the relay runs.
    #[serde(default = "default_key_file")]
    pub key_file: String,
    #[serde(skip)]
    pub production_url: String,
    #[serde(skip)]
    pub sandbox_url: String,
}

fn default_topic() -> String {
    "app.pulshade.ios".into()
}

fn default_key_file() -> String {
    "apns.p8".into()
}

impl Config {
    /// From `apns.json` next to the relay, with the key in the file it names. None when push isn't set up.
    pub fn load() -> Option<(Config, SigningKey)> {
        let mut config: Config = serde_json::from_str(&std::fs::read_to_string("apns.json").ok()?).ok()?;
        config.production_url = "https://api.push.apple.com".into();
        config.sandbox_url = "https://api.sandbox.push.apple.com".into();
        let pem = std::fs::read_to_string(&config.key_file).ok()?;
        let key = SigningKey::from_pkcs8_pem(&pem).ok()?;
        Some((config, key))
    }
}

struct Target {
    token: String,
    sandbox: bool,
    sound: bool,
    /// The tone picked in the app, from `TONES`; None is the system's default sound.
    tone: Option<String>,
    /// The phone's separate token for call pushes (PushKit), if its app sent one.
    voip: Option<String>,
    at: Instant,
}

/// Tones an app may ask for. The relay only ever puts one of these names in a push, never text an app sent.
pub const TONES: &[&str] = &["pulse", "chime", "bubble", "drop", "knock", "tick"];

/// What else a phone tells the relay when it registers.
#[derive(Default, Clone)]
pub struct Extras {
    pub tone: Option<String>,
    pub voip: Option<String>,
}

/// Why mail landed: an ordinary message, or the start of a call, which rings the phone.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Wake {
    Message,
    Call,
}

/// A registration as the relay keeps it on disk between runs (sealed, with the waiting mail), so a restart doesn't
/// silence every phone until its owner next opens the app. `registered` is when, by the wall clock.
#[derive(Serialize, Deserialize)]
pub struct Saved {
    pub mailbox: String,
    pub token: String,
    pub sandbox: bool,
    pub sound: bool,
    #[serde(default)]
    pub tone: Option<String>,
    #[serde(default)]
    pub voip: Option<String>,
    pub registered: u64,
}

struct Signed {
    jwt: String,
    made: Instant,
}

pub struct Push {
    config: Option<(Config, SigningKey)>,
    targets: Mutex<HashMap<Id, Target>>,
    /// When each device was last woken.
    last: Mutex<HashMap<String, Instant>>,
    /// When each device was last rung (by its call token), so a call's copies don't ring it twice.
    last_call: Mutex<HashMap<String, Instant>>,
    /// The second being counted, and how many pushes went out in it.
    rate: Mutex<(Instant, u32)>,
    jwt: Mutex<Option<Signed>>,
    http: reqwest::Client,
    /// Registrations changed since they were last written out.
    changed: AtomicBool,
}

/// The one the relay runs with, set up from `apns.json` when there is one.
static GLOBAL: LazyLock<Arc<Push>> = LazyLock::new(|| Arc::new(Push::new(Config::load())));

pub fn global() -> Arc<Push> {
    GLOBAL.clone()
}

impl Push {
    pub fn new(config: Option<(Config, SigningKey)>) -> Push {
        Push {
            config,
            targets: Mutex::default(),
            last: Mutex::default(),
            last_call: Mutex::default(),
            rate: Mutex::new((Instant::now(), 0)),
            jwt: Mutex::default(),
            changed: AtomicBool::new(false),
            http: reqwest::Client::builder().timeout(Duration::from_secs(15)).build().expect("http client"),
        }
    }

    /// Whether the operator has put an APNs key beside the relay.
    pub fn enabled(&self) -> bool {
        self.config.is_some()
    }

    /// Every live registration, to write to disk, and whether any changed since the last time this was asked.
    pub fn saved(&self) -> (Vec<Saved>, bool) {
        let changed = self.changed.swap(false, Ordering::SeqCst);
        let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let targets = self.targets.lock().unwrap();
        let saved = targets.iter().map(|(id, t)| Saved {
            mailbox: hex::encode(id),
            token: t.token.clone(),
            sandbox: t.sandbox,
            sound: t.sound,
            tone: t.tone.clone(),
            voip: t.voip.clone(),
            registered: now.saturating_sub(t.at.elapsed().as_secs()),
        }).collect();
        (saved, changed)
    }

    /// Registrations written out by the last run. Ones past their week are left behind.
    pub fn restore(&self, saved: Vec<Saved>) -> usize {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let mut targets = self.targets.lock().unwrap();
        for s in saved {
            let age = Duration::from_secs(now.saturating_sub(s.registered));
            let Some(mailbox) = hex::decode(&s.mailbox).ok().and_then(|raw| Id::try_from(raw).ok()) else { continue };
            if age >= TTL || !valid_token(&s.token) || targets.len() >= MAX_TARGETS {
                continue;
            }
            let at = Instant::now().checked_sub(age).unwrap_or_else(Instant::now);
            let voip = s.voip.filter(|v| valid_token(v));
            let tone = s.tone.filter(|t| TONES.contains(&t.as_str()));
            targets.insert(mailbox, Target { token: s.token, sandbox: s.sandbox, sound: s.sound, tone, voip, at });
        }
        targets.len()
    }

    /// Remembers `token` for these mailboxes (by send id), replacing any earlier one. False if the token already holds
    /// as many mailboxes as a device can. When the table is full, the oldest registrations make way.
    pub fn register(&self, mailboxes: &[Id], token: &str, sandbox: bool, sound: bool) -> bool {
        self.register_with(mailboxes, token, sandbox, sound, Extras::default())
    }

    pub fn register_with(&self, mailboxes: &[Id], token: &str, sandbox: bool, sound: bool, extras: Extras) -> bool {
        let tone = extras.tone.filter(|t| TONES.contains(&t.as_str()));
        let voip = extras.voip.map(|v| v.to_lowercase()).filter(|v| valid_token(v));
        self.changed.store(true, Ordering::SeqCst);
        let mut targets = self.targets.lock().unwrap();
        let held = targets.values().filter(|t| t.token == token).count();
        let new = mailboxes.iter().filter(|id| targets.get(*id).is_none_or(|t| t.token != token)).count();
        if held + new > MAX_PER_TOKEN {
            return false;
        }
        if targets.len() + new > MAX_TARGETS {
            let now = Instant::now();
            targets.retain(|_, t| now.duration_since(t.at) < TTL);
            if targets.len() + new > MAX_TARGETS {
                let mut ages: Vec<(Instant, Id)> = targets.iter().map(|(id, t)| (t.at, *id)).collect();
                ages.sort();
                for (_, id) in ages.into_iter().take(targets.len() + new - MAX_TARGETS) {
                    targets.remove(&id);
                }
            }
        }
        for id in mailboxes {
            targets.insert(*id, Target { token: token.to_string(), sandbox, sound, tone: tone.clone(), voip: voip.clone(), at: Instant::now() });
        }
        true
    }

    pub fn remove(&self, mailboxes: &[Id]) {
        self.changed.store(true, Ordering::SeqCst);
        self.targets.lock().unwrap().retain(|id, _| !mailboxes.contains(id));
    }

    /// Everything registered for a device token, for a phone that has no keys to name its mailboxes with.
    pub fn forget(&self, token: &str) {
        self.changed.store(true, Ordering::SeqCst);
        self.targets.lock().unwrap().retain(|_, t| t.token != token);
        self.last.lock().unwrap().remove(token);
    }

    fn drop_voip(&self, voip: &str) {
        self.changed.store(true, Ordering::SeqCst);
        for t in self.targets.lock().unwrap().values_mut() {
            if t.voip.as_deref() == Some(voip) { t.voip = None; }
        }
    }

    /// Drops registrations that were never renewed, and cooldown records that no longer matter.
    pub fn sweep(&self) {
        let now = Instant::now();
        let mut targets = self.targets.lock().unwrap();
        let before = targets.len();
        targets.retain(|_, t| now.duration_since(t.at) < TTL);
        if targets.len() != before { self.changed.store(true, Ordering::SeqCst); }
        drop(targets);
        self.last.lock().unwrap().retain(|_, at| now.duration_since(*at) < COOLDOWN);
        self.last_call.lock().unwrap().retain(|_, at| now.duration_since(*at) < CALL_COOLDOWN);
    }

    pub fn registered(&self) -> usize {
        self.targets.lock().unwrap().len()
    }

    /// Mail landed in this mailbox: wake its phone, if it has one registered and wasn't woken a moment ago.
    pub fn notify(self: &Arc<Self>, mailbox: Id) {
        self.notify_as(mailbox, Wake::Message);
    }

    /// As `notify`, but for a call, a phone that gave a call token is rung (a call screen, however it was asleep).
    /// One without falls back to an ordinary wake-up.
    pub fn notify_as(self: &Arc<Self>, mailbox: Id, wake: Wake) {
        if self.config.is_none() {
            return;
        }
        let (token, sandbox, sound, tone, voip) = {
            let targets = self.targets.lock().unwrap();
            let Some(target) = targets.get(&mailbox) else { return };
            (target.token.clone(), target.sandbox, target.sound, target.tone.clone(), target.voip.clone())
        };
        if let (Wake::Call, Some(voip)) = (wake, voip) {
            {
                let mut last = self.last_call.lock().unwrap();
                if last.get(&voip).is_some_and(|at| at.elapsed() < CALL_COOLDOWN) {
                    return;
                }
                let mut rate = self.rate.lock().unwrap();
                if rate.0.elapsed() >= Duration::from_secs(1) {
                    *rate = (Instant::now(), 0);
                }
                if rate.1 >= MAX_SENDS_PER_SECOND {
                    return;
                }
                rate.1 += 1;
                last.insert(voip.clone(), Instant::now());
            }
            let this = self.clone();
            tokio::spawn(async move { this.send_call(&voip, sandbox).await });
            return;
        }
        {
            let mut last = self.last.lock().unwrap();
            if last.get(&token).is_some_and(|at| at.elapsed() < COOLDOWN) {
                return;
            }
            // Over the relay's own ceiling this second: skip, and the next deposit tries again.
            let mut rate = self.rate.lock().unwrap();
            if rate.0.elapsed() >= Duration::from_secs(1) {
                *rate = (Instant::now(), 0);
            }
            if rate.1 >= MAX_SENDS_PER_SECOND {
                return;
            }
            rate.1 += 1;
            last.insert(token.clone(), Instant::now());
        }
        let this = self.clone();
        tokio::spawn(async move { this.send(&token, sandbox, sound, tone.as_deref()).await });
    }

    fn authorization(&self) -> Option<String> {
        let (config, key) = self.config.as_ref()?;
        let mut cached = self.jwt.lock().unwrap();
        if let Some(signed) = cached.as_ref().filter(|s| s.made.elapsed() < JWT_LIFE) {
            return Some(signed.jwt.clone());
        }
        let now = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs();
        let header = B64URL.encode(format!(r#"{{"alg":"ES256","kid":"{}"}}"#, config.key_id));
        let claims = B64URL.encode(format!(r#"{{"iss":"{}","iat":{now}}}"#, config.team_id));
        let signing_input = format!("{header}.{claims}");
        let signature: Signature = key.sign(signing_input.as_bytes());
        let jwt = format!("{signing_input}.{}", B64URL.encode(signature.to_bytes()));
        *cached = Some(Signed { jwt: jwt.clone(), made: Instant::now() });
        Some(jwt)
    }

    /// Rings a phone through its call token: Apple wakes the app at once, which puts up the call screen. It carries
    /// nothing but that a call is coming, and isn't kept if the phone can't be reached now.
    async fn send_call(&self, voip: &str, sandbox: bool) {
        let Some((config, _)) = self.config.as_ref() else { return };
        let Some(jwt) = self.authorization() else { return };
        let base = if sandbox { &config.sandbox_url } else { &config.production_url };
        let response = self
            .http
            .post(format!("{base}/3/device/{voip}"))
            .header("authorization", format!("bearer {jwt}"))
            .header("apns-topic", format!("{}.voip", config.topic))
            .header("apns-push-type", "voip")
            .header("apns-priority", "10")
            .header("apns-expiration", "0")
            .body(r#"{"call":1}"#)
            .send()
            .await;
        match response {
            Ok(r) if r.status().as_u16() == 410 || r.status().as_u16() == 400 => {
                let text = r.text().await.unwrap_or_default();
                if text.contains("Unregistered") || text.contains("BadDeviceToken") || text.contains("DeviceTokenNotForTopic") {
                    self.drop_voip(voip);
                }
            }
            Ok(r) if r.status().as_u16() == 403 => *self.jwt.lock().unwrap() = None,
            _ => {}
        }
    }

    async fn send(&self, token: &str, sandbox: bool, sound: bool, tone: Option<&str>) {
        let Some((config, _)) = self.config.as_ref() else { return };
        let Some(jwt) = self.authorization() else { return };
        let base = if sandbox { &config.sandbox_url } else { &config.production_url };
        // The same text for everyone. No collapse id: each push is a banner of its own, as in any messenger.
        let body = if sound {
            // A tone the phone picked is a file it keeps in its own Library/Sounds, named for the tone.
            let name = tone.filter(|t| TONES.contains(t)).map(|t| format!("tone-{t}.wav")).unwrap_or_else(|| "default".into());
            format!(r#"{{"aps":{{"alert":{{"title":"PULSHADE","body":"New message"}},"sound":"{name}","thread-id":"pulshade"}}}}"#)
        } else {
            r#"{"aps":{"alert":{"title":"PULSHADE","body":"New message"},"thread-id":"pulshade"}}"#.to_string()
        };
        let response = self
            .http
            .post(format!("{base}/3/device/{token}"))
            .header("authorization", format!("bearer {jwt}"))
            .header("apns-topic", &config.topic)
            .header("apns-push-type", "alert")
            .header("apns-priority", "10")
            .body(body)
            .send()
            .await;
        match response {
            // Apple says the token is dead (app deleted, or a token from the other environment): stop using it.
            Ok(r) if r.status().as_u16() == 410 || r.status().as_u16() == 400 => {
                let text = r.text().await.unwrap_or_default();
                if text.contains("Unregistered") || text.contains("BadDeviceToken") || text.contains("DeviceTokenNotForTopic") {
                    self.forget(token);
                }
            }
            Ok(r) if r.status().as_u16() == 403 => {
                // A bad key: renew the signed token next time rather than keep sending a rejected one.
                *self.jwt.lock().unwrap() = None;
            }
            _ => {}
        }
    }
}

/// Whether `token` looks like an Apple device token: hex, a sensible length.
pub fn valid_token(token: &str) -> bool {
    (32..=200).contains(&token.len()) && token.len() % 2 == 0 && token.bytes().all(|b| b.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{Router, extract::State, http::HeaderMap, routing::post};

    const TEST_KEY: &str = "-----BEGIN PRIVATE KEY-----\n\
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgmXmBFK/NqQdTqP7W\n\
nmevMW3kLDVTNTor/tUpF8glb8KhRANCAATot/75BQS0g3J2HIMjwtbQKN33eVC8\n\
nOl4KCikUySqK0sLiU3iyHn+a7zanVQQhi8scw4f4gBEnLmamXFj8G0c\n\
-----END PRIVATE KEY-----\n";

    #[derive(Clone, Default)]
    struct Seen(Arc<Mutex<Vec<(String, HeaderMap, String)>>>, Arc<Mutex<u16>>);

    async fn fake_apple(State(seen): State<Seen>, axum::extract::Path(token): axum::extract::Path<String>,
                        headers: HeaderMap, body: String) -> (axum::http::StatusCode, String) {
        seen.0.lock().unwrap().push((token, headers, body));
        let status = *seen.1.lock().unwrap();
        if status == 410 {
            (axum::http::StatusCode::GONE, r#"{"reason":"Unregistered"}"#.into())
        } else {
            (axum::http::StatusCode::OK, String::new())
        }
    }

    async fn start() -> (Arc<Push>, Seen) {
        let seen = Seen::default();
        *seen.1.lock().unwrap() = 200;
        let app = Router::new().route("/3/device/{token}", post(fake_apple)).with_state(seen.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let config = Config {
            key_id: "KEY1234567".into(),
            team_id: "TEAM123456".into(),
            topic: "app.pulshade.ios".into(),
            key_file: String::new(),
            production_url: url.clone(),
            sandbox_url: url,
        };
        let key = SigningKey::from_pkcs8_pem(TEST_KEY).unwrap();
        (Arc::new(Push::new(Some((config, key)))), seen)
    }

    const TOKEN: &str = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899";

    #[tokio::test]
    async fn a_deposit_wakes_the_registered_phone_with_no_message_in_it() {
        let (push, seen) = start().await;
        push.register(&[[1; 32]], TOKEN, false, true);
        push.notify([1; 32]);
        tokio::time::sleep(Duration::from_millis(300)).await;
        let got = seen.0.lock().unwrap();
        assert_eq!(got.len(), 1);
        let (token, headers, body) = &got[0];
        assert_eq!(token, TOKEN);
        assert_eq!(headers["apns-topic"], "app.pulshade.ios");
        assert_eq!(headers["apns-push-type"], "alert");
        assert!(headers["authorization"].to_str().unwrap().starts_with("bearer "));
        assert!(body.contains("New message"));
        // Nothing about who it's from or what it says.
        assert!(!body.contains("sealed") && !body.contains("from"));
    }

    #[tokio::test]
    async fn the_signed_token_is_a_real_es256_jwt_apple_can_check() {
        let (push, _) = start().await;
        let jwt = push.authorization().unwrap();
        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3);
        let header = String::from_utf8(B64URL.decode(parts[0]).unwrap()).unwrap();
        assert!(header.contains(r#""alg":"ES256""#) && header.contains("KEY1234567"));
        let claims = String::from_utf8(B64URL.decode(parts[1]).unwrap()).unwrap();
        assert!(claims.contains("TEAM123456") && claims.contains("iat"));
        // The signature verifies against the key's public half.
        use p256::ecdsa::signature::Verifier;
        let key = SigningKey::from_pkcs8_pem(TEST_KEY).unwrap();
        let sig = Signature::from_slice(&B64URL.decode(parts[2]).unwrap()).unwrap();
        key.verifying_key().verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &sig).unwrap();
    }

    #[tokio::test]
    async fn a_burst_of_mail_is_one_push_and_unregistered_mailboxes_get_none() {
        let (push, seen) = start().await;
        push.register(&[[2; 32]], TOKEN, true, true);
        for _ in 0..5 { push.notify([2; 32]); }
        push.notify([3; 32]);
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert_eq!(seen.0.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn a_token_apple_calls_dead_is_dropped() {
        let (push, seen) = start().await;
        *seen.1.lock().unwrap() = 410;
        push.register(&[[4; 32]], TOKEN, false, true);
        push.notify([4; 32]);
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert_eq!(push.registered(), 0);
    }

    #[test]
    fn registrations_can_be_removed_and_nothing_is_sent_without_a_key() {
        let push = Arc::new(Push::new(None));
        assert!(!push.enabled());
        push.register(&[[5; 32]], TOKEN, false, true);
        assert_eq!(push.registered(), 1);
        push.remove(&[[5; 32]]);
        assert_eq!(push.registered(), 0);
        assert!(valid_token(TOKEN));
        assert!(!valid_token("not hex"));
    }

    #[tokio::test]
    async fn a_device_that_turned_sound_off_is_woken_silently() {
        let (push, seen) = start().await;
        push.register(&[[6; 32]], TOKEN, false, false);
        push.notify([6; 32]);
        tokio::time::sleep(Duration::from_millis(300)).await;
        let got = seen.0.lock().unwrap();
        assert_eq!(got.len(), 1);
        assert!(!got[0].2.contains("sound"), "{}", got[0].2);
    }

    #[tokio::test]
    async fn a_device_is_woken_once_however_many_of_its_mailboxes_get_mail() {
        let (push, seen) = start().await;
        push.register(&[[7; 32], [8; 32], [9; 32]], TOKEN, false, true);
        for id in [[7; 32], [8; 32], [9; 32]] { push.notify(id); }
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert_eq!(seen.0.lock().unwrap().len(), 1);
    }

    #[test]
    fn one_token_cannot_hold_more_mailboxes_than_a_device_could() {
        let push = Arc::new(Push::new(None));
        let many: Vec<Id> = (0..MAX_PER_TOKEN as u32).map(|n| { let mut id = [0u8; 32]; id[..4].copy_from_slice(&n.to_be_bytes()); id }).collect();
        assert!(push.register(&many, TOKEN, false, true));
        assert!(!push.register(&[[255; 32]], TOKEN, false, true), "one more is refused");
        // Registering again what it already holds is fine, and another device is unaffected.
        assert!(push.register(&many[..10], TOKEN, false, true));
        assert!(push.register(&[[255; 32]], &"cd".repeat(32), false, true));
    }

    #[test]
    fn forgetting_a_token_takes_all_its_mailboxes_and_only_its_own() {
        let push = Arc::new(Push::new(None));
        let other = "cd".repeat(32);
        push.register(&[[1; 32], [2; 32]], TOKEN, false, true);
        push.register(&[[3; 32]], &other, false, true);
        push.forget(TOKEN);
        assert_eq!(push.registered(), 1);
    }

    #[test]
    fn when_the_table_is_full_the_oldest_registrations_make_way() {
        let push = Arc::new(Push::new(None));
        // Fill it with other devices' mailboxes (a few per token, as a phone would), oldest first.
        let mut n = 0u32;
        while push.registered() < MAX_TARGETS {
            let mut ids = Vec::new();
            for _ in 0..100 { let mut id = [0u8; 32]; id[..4].copy_from_slice(&n.to_be_bytes()); id[4] = 1; ids.push(id); n += 1; }
            assert!(push.register(&ids, &format!("{:064x}", n), false, true));
        }
        assert!(push.register(&[[9; 32]], TOKEN, false, true), "a newcomer isn't turned away");
        assert_eq!(push.registered(), MAX_TARGETS);
        assert!(push.targets.lock().unwrap().contains_key(&[9; 32]));
    }

    #[tokio::test]
    async fn the_relay_as_a_whole_sends_only_so_many_pushes_a_second() {
        let (push, seen) = start().await;
        for n in 0..(MAX_SENDS_PER_SECOND + 20) {
            let mut id = [0u8; 32];
            id[..4].copy_from_slice(&n.to_be_bytes());
            push.register(&[id], &format!("{:064x}", n), false, true);
            push.notify(id);
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert_eq!(seen.0.lock().unwrap().len() as u32, MAX_SENDS_PER_SECOND);
    }

    const VOIP: &str = "11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff";

    #[tokio::test]
    async fn a_call_rings_a_phone_that_gave_a_call_token_and_says_nothing_else() {
        let (push, seen) = start().await;
        push.register_with(&[[20; 32]], TOKEN, false, true, Extras { tone: None, voip: Some(VOIP.into()) });
        push.notify_as([20; 32], Wake::Call);
        tokio::time::sleep(Duration::from_millis(300)).await;
        let got = seen.0.lock().unwrap();
        assert_eq!(got.len(), 1, "one push, the call one");
        let (token, headers, body) = &got[0];
        assert_eq!(token, VOIP);
        assert_eq!(headers["apns-topic"], "app.pulshade.ios.voip");
        assert_eq!(headers["apns-push-type"], "voip");
        assert_eq!(headers["apns-expiration"], "0", "not kept for a phone that can't be reached now");
        assert!(!body.contains("New message") && !body.contains("from"));
    }

    #[tokio::test]
    async fn a_call_for_a_phone_without_a_call_token_is_an_ordinary_wake_up() {
        let (push, seen) = start().await;
        push.register(&[[21; 32]], TOKEN, false, true);
        push.notify_as([21; 32], Wake::Call);
        tokio::time::sleep(Duration::from_millis(300)).await;
        let got = seen.0.lock().unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].0, TOKEN);
        assert_eq!(got[0].1["apns-push-type"], "alert");
    }

    #[tokio::test]
    async fn messages_never_use_the_call_token_and_a_call_copied_to_two_mailboxes_rings_once() {
        let (push, seen) = start().await;
        push.register_with(&[[22; 32], [23; 32]], TOKEN, false, true, Extras { tone: None, voip: Some(VOIP.into()) });
        push.notify_as([22; 32], Wake::Message);
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert_eq!(seen.0.lock().unwrap()[0].0, TOKEN);
        push.notify_as([22; 32], Wake::Call);
        push.notify_as([23; 32], Wake::Call);
        tokio::time::sleep(Duration::from_millis(300)).await;
        let rings = seen.0.lock().unwrap().iter().filter(|g| g.0 == VOIP).count();
        assert_eq!(rings, 1);
    }

    #[tokio::test]
    async fn a_call_token_apple_calls_dead_is_dropped_but_the_phone_keeps_its_wake_ups() {
        let (push, seen) = start().await;
        *seen.1.lock().unwrap() = 410;
        push.register_with(&[[24; 32]], TOKEN, false, true, Extras { tone: None, voip: Some(VOIP.into()) });
        push.notify_as([24; 32], Wake::Call);
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert_eq!(push.registered(), 1);
        assert!(push.targets.lock().unwrap()[&[24; 32]].voip.is_none());
    }

    #[tokio::test]
    async fn the_picked_tone_names_the_sound_and_anything_not_on_the_list_is_ignored() {
        let (push, seen) = start().await;
        push.register_with(&[[25; 32]], TOKEN, false, true, Extras { tone: Some("chime".into()), voip: None });
        push.notify([25; 32]);
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert!(seen.0.lock().unwrap()[0].2.contains(r#""sound":"tone-chime.wav""#), "{}", seen.0.lock().unwrap()[0].2);
        let other = "cd".repeat(32);
        push.register_with(&[[26; 32]], &other, false, true, Extras { tone: Some("../../evil\"".into()), voip: Some("not hex".into()) });
        push.notify([26; 32]);
        tokio::time::sleep(Duration::from_millis(300)).await;
        let got = seen.0.lock().unwrap();
        assert!(got[1].2.contains(r#""sound":"default""#), "{}", got[1].2);
        let t = push.targets.lock().unwrap();
        assert!(t[&[26; 32]].tone.is_none() && t[&[26; 32]].voip.is_none());
    }
}
