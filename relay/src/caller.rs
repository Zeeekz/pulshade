//! Who a request came from, for rate limits and the anonymity report. People with Tor off reach the relay through
//! the HTTPS proxy on the same server, so their connections all come from 127.0.0.1 and the address the proxy passes
//! on in `X-Forwarded-For` counts instead. Only a proxy on this machine is believed: the header is ignored on any
//! other connection, onion ones included.

use axum::{
    extract::{ConnectInfo, FromRequestParts},
    http::{HeaderMap, StatusCode, request::Parts},
};
use std::net::{IpAddr, SocketAddr};

pub struct Caller(pub IpAddr);

impl<S: Send + Sync> FromRequestParts<S> for Caller {
    type Rejection = StatusCode;

    async fn from_request_parts(parts: &mut Parts, _: &S) -> Result<Self, Self::Rejection> {
        let ConnectInfo(addr) = parts.extensions.get::<ConnectInfo<SocketAddr>>().copied()
            .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;
        Ok(Caller(address(addr.ip(), &parts.headers)))
    }
}

/// The proxy's own entry is the last one in the header; anything before it the client could have written itself.
pub fn address(peer: IpAddr, headers: &HeaderMap) -> IpAddr {
    if !peer.is_loopback() {
        return peer;
    }
    headers.get("x-forwarded-for")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.rsplit(',').next())
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(peer)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn forwarded(value: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert("x-forwarded-for", value.parse().unwrap());
        headers
    }

    #[test]
    fn believes_only_the_proxy_on_this_machine() {
        let local: IpAddr = "127.0.0.1".parse().unwrap();
        let outside: IpAddr = "203.0.113.9".parse().unwrap();
        let onion: IpAddr = "fd00::1".parse().unwrap();
        assert_eq!(address(local, &forwarded("198.51.100.7")), "198.51.100.7".parse::<IpAddr>().unwrap());
        // A client can put anything in front; the proxy's entry is the last.
        assert_eq!(address(local, &forwarded("10.0.0.1, 198.51.100.7")), "198.51.100.7".parse::<IpAddr>().unwrap());
        assert_eq!(address(outside, &forwarded("198.51.100.7")), outside);
        assert_eq!(address(onion, &forwarded("198.51.100.7")), onion);
        assert_eq!(address(local, &HeaderMap::new()), local);
        assert_eq!(address(local, &forwarded("not an address")), local);
    }
}
