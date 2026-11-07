//! Proof of work for onion requests. Onion circuits carry no address, so each gets a made-up one and its own
//! rate limits, and building fresh circuits would buy fresh allowances. A rate-limited request that carries a
//! proof (a hash with `BITS` leading zero bits, tied to that request and a recent time, used once) keeps its
//! circuit's own allowance. One without shares a single allowance with every other unproven onion request, so
//! new circuits buy nothing.

use axum::http::HeaderMap;
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    net::{IpAddr, Ipv6Addr},
    sync::{LazyLock, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

/// About a quarter of a million hashes on average: a fraction of a second on a phone.
pub const BITS: u32 = 18;
/// How far a proof's time may be from the relay's.
const SKEW: u64 = 600;

/// Proofs already used, so each counts once.
static SEEN: LazyLock<Mutex<HashMap<[u8; 32], Instant>>> = LazyLock::new(Default::default);

/// Onion circuits' made-up addresses are in fd00::/8.
pub fn is_onion(ip: IpAddr) -> bool {
    matches!(ip, IpAddr::V6(v6) if v6.octets()[0] == 0xfd)
}

/// The address a request counts as for rate limits: its own, or for an unproven onion request, the one they all share.
pub fn rate_key(ip: IpAddr, headers: &HeaderMap, bound: &str) -> IpAddr {
    if !is_onion(ip) || proven(headers, bound, now()) {
        return ip;
    }
    IpAddr::V6(Ipv6Addr::new(0xfd00, 0, 0, 0, 0, 0, 0, 0))
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// `x-pulshade-pow: <unix seconds>:<decimal nonce>`, hashed with what the request is for.
fn proven(headers: &HeaderMap, bound: &str, now: u64) -> bool {
    let Some(value) = headers.get("x-pulshade-pow").and_then(|v| v.to_str().ok()) else { return false };
    let Some((ts, nonce)) = value.split_once(':') else { return false };
    let (Ok(ts), Ok(nonce)) = (ts.parse::<u64>(), nonce.parse::<u64>()) else { return false };
    if now.abs_diff(ts) > SKEW {
        return false;
    }
    let digest = hash(bound, ts, nonce);
    if leading_zero_bits(&digest) < BITS {
        return false;
    }
    let mut seen = SEEN.lock().unwrap();
    if seen.len() > 100_000 {
        seen.retain(|_, at| at.elapsed() < Duration::from_secs(SKEW * 2));
    }
    seen.insert(digest, Instant::now()).is_none()
}

fn hash(bound: &str, ts: u64, nonce: u64) -> [u8; 32] {
    Sha256::digest(format!("pulshade.pow.v1|{bound}|{ts}|{nonce}")).into()
}

fn leading_zero_bits(digest: &[u8]) -> u32 {
    let mut bits = 0;
    for byte in digest {
        if *byte == 0 {
            bits += 8;
        } else {
            return bits + byte.leading_zeros();
        }
    }
    bits
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solve(bound: &str, ts: u64) -> u64 {
        (0..).find(|n| leading_zero_bits(&hash(bound, ts, *n)) >= BITS).unwrap()
    }

    fn header(ts: u64, nonce: u64) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert("x-pulshade-pow", format!("{ts}:{nonce}").parse().unwrap());
        headers
    }

    #[test]
    fn a_proof_counts_once_for_its_own_request_only() {
        let ts = now();
        let nonce = solve("lookup|someone", ts);
        assert!(!proven(&header(ts, nonce), "lookup|someone-else", ts));
        assert!(proven(&header(ts, nonce), "lookup|someone", ts));
        assert!(!proven(&header(ts, nonce), "lookup|someone", ts), "used once");
        assert!(!proven(&HeaderMap::new(), "lookup|someone", ts));
    }

    /// The same vector is checked by the app's tests, so both hash a proof the same way.
    #[test]
    fn shared_vector() {
        assert_eq!(solve("vector", 1_800_000_000), 19909);
    }

    #[test]
    fn old_proofs_and_clearnet_are_handled() {
        let ts = now() - SKEW - 5;
        let nonce = solve("mine", ts);
        assert!(!proven(&header(ts, nonce), "mine", now()));
        let circuit: IpAddr = "fd12::7".parse().unwrap();
        let shared: IpAddr = "fd00::".parse().unwrap();
        assert_eq!(rate_key(circuit, &HeaderMap::new(), "mine"), shared);
        let clearnet: IpAddr = "203.0.113.9".parse().unwrap();
        assert_eq!(rate_key(clearnet, &HeaderMap::new(), "mine"), clearnet);
    }
}
