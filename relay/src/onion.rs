//! The relay as an onion service, hosted by Arti inside the relay itself. Apps reach it over Tor at its
//! `.onion` address, so nobody learns where it runs and no exit node sees the traffic. The keys live in
//! `pulshade-onion/` next to the directory file, so the address stays the same across restarts.
//!
//! Onion traffic has no IP address. Each client circuit gets a made-up one instead (random, in fd00::/8), so
//! rate limits count each circuit on its own rather than everyone together.

use std::io::Read;
use std::net::{Ipv6Addr, SocketAddr};
use std::path::{Path, PathBuf};

use arti_client::config::TorClientConfigBuilder;
use arti_client::{DataStream, TorClient};
use axum::Router;
use axum::serve::{Listener, ListenerExt};
use futures_util::StreamExt;
use safelog::DisplayRedacted;
use tokio::sync::mpsc;
use tor_cell::relaycell::msg::{Connected, End};
use tor_hsservice::config::OnionServiceConfigBuilder;
use tor_hsservice::{RendRequest, StreamRequest};
use tor_proto::stream::IncomingStreamRequest;

/// Where the onion service keeps its keys and Tor state, and writes its address (`hostname`).
pub fn folder(directory_path: &Path) -> PathBuf {
    directory_path.with_file_name("pulshade-onion")
}

/// Starts the onion service and serves `app` on it until the relay stops. Returns once it's published.
pub async fn serve(app: Router, folder: PathBuf) -> Result<String, String> {
    let fail = |what: &str, e: &dyn std::fmt::Display| format!("{what}: {e}");
    let config = TorClientConfigBuilder::from_directories(folder.join("state"), folder.join("cache"))
        .build()
        .map_err(|e| fail("config", &e))?;
    let client = TorClient::create_bootstrapped(config).await.map_err(|e| fail("Tor", &e))?;
    let service = OnionServiceConfigBuilder::default()
        .nickname("pulshade".parse().expect("valid nickname"))
        .build()
        .map_err(|e| fail("onion config", &e))?;
    let (running, requests) = client
        .launch_onion_service(service)
        .map_err(|e| fail("onion service", &e))?
        .ok_or("onion service disabled")?;
    let address = running.onion_address().ok_or("no onion address")?.display_unredacted().to_string();
    let _ = std::fs::write(folder.join("hostname"), format!("{address}\n"));

    let (sender, receiver) = mpsc::channel(64);
    tokio::spawn(async move {
        // Keep the client and the service alive for as long as requests come in.
        let _keep = (client, running);
        requests.for_each_concurrent(None, |request| circuit(request, sender.clone())).await;
    });
    tokio::spawn(async move {
        let listener = Circuits(receiver).tap_io(|_| {});
        let _ = axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>()).await;
    });
    Ok(address)
}

/// One client's rendezvous circuit: every stream on it is an HTTP connection to port 80, from one made-up address.
async fn circuit(request: RendRequest, sender: mpsc::Sender<(DataStream, SocketAddr)>) {
    let Ok(streams) = request.accept().await else { return };
    let address = SocketAddr::new(made_up_address().into(), 80);
    streams
        .for_each_concurrent(None, |stream: StreamRequest| {
            let sender = sender.clone();
            async move {
                let port = match stream.request() {
                    IncomingStreamRequest::Begin(begin) => begin.port(),
                    _ => 0,
                };
                if port != 80 {
                    let _ = stream.reject(End::new_misc()).await;
                    return;
                }
                if let Ok(data) = stream.accept(Connected::new_empty()).await {
                    let _ = sender.send((data, address)).await;
                }
            }
        })
        .await;
}

fn made_up_address() -> Ipv6Addr {
    let mut raw = [0u8; 16];
    std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut raw)).expect("no randomness");
    raw[0] = 0xfd;
    Ipv6Addr::from(raw)
}

/// Streams from the onion service, as connections for the web server.
struct Circuits(mpsc::Receiver<(DataStream, SocketAddr)>);

impl Listener for Circuits {
    type Io = DataStream;
    type Addr = SocketAddr;

    async fn accept(&mut self) -> (DataStream, SocketAddr) {
        match self.0.recv().await {
            Some(next) => next,
            None => std::future::pending().await,
        }
    }

    fn local_addr(&self) -> std::io::Result<SocketAddr> {
        Ok(SocketAddr::new(Ipv6Addr::LOCALHOST.into(), 80))
    }
}
