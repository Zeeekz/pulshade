//! Live call rooms. Two devices that both know a room's random id meet here and pass each other sealed
//! audio packets as they arrive. The relay can't open them: the key travels end-to-end inside the
//! call's set-up messages, never through here. Rooms live in memory and vanish when the call ends.

use axum::extract::ws::{Message, WebSocket};
use futures_util::{SinkExt, StreamExt};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};
use tokio::sync::mpsc;

/// A sealed 20 ms audio packet is about 100 bytes; anything far bigger isn't a call.
pub const MAX_FRAME: usize = 4096;
const IDLE: std::time::Duration = std::time::Duration::from_secs(20);

type Peer = (u64, mpsc::UnboundedSender<Message>);

#[derive(Default)]
pub struct Rooms {
    rooms: Mutex<HashMap<String, Vec<Peer>>>,
    next: Mutex<u64>,
}

pub fn valid_room(room: &str) -> bool {
    room.len() == 64 && room.chars().all(|c| c.is_ascii_hexdigit())
}

impl Rooms {
    pub fn active(&self) -> usize {
        self.rooms.lock().unwrap().len()
    }

    /// Joins a room, passes packets to the other device until either side leaves, then closes both.
    pub async fn join(self: Arc<Self>, room: String, socket: WebSocket) {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let id = {
            let mut next = self.next.lock().unwrap();
            *next += 1;
            *next
        };
        {
            let mut rooms = self.rooms.lock().unwrap();
            let peers = rooms.entry(room.clone()).or_default();
            // Two to a call: a third device gets nothing.
            if peers.len() >= 2 {
                return;
            }
            peers.push((id, tx));
        }
        let (mut sink, mut stream) = socket.split();
        let writer = tokio::spawn(async move {
            while let Some(message) = rx.recv().await {
                let closing = matches!(message, Message::Close(_));
                if sink.send(message).await.is_err() || closing {
                    break;
                }
            }
        });
        // A device that goes quiet for this long has gone (audio flows every 20 ms, hellos every 250).
        while let Ok(Some(Ok(message))) = tokio::time::timeout(IDLE, stream.next()).await {
            match message {
                Message::Binary(bytes) if bytes.len() <= MAX_FRAME => {
                    let rooms = self.rooms.lock().unwrap();
                    if let Some(peers) = rooms.get(&room) {
                        for (other, sender) in peers {
                            if *other != id {
                                let _ = sender.send(Message::Binary(bytes.clone()));
                            }
                        }
                    }
                }
                Message::Close(_) => break,
                _ => {}
            }
        }
        // Leaving ends the call for both.
        let others: Vec<mpsc::UnboundedSender<Message>> = {
            let mut rooms = self.rooms.lock().unwrap();
            let others = rooms.remove(&room).unwrap_or_default();
            others.into_iter().filter(|(other, _)| *other != id).map(|(_, s)| s).collect()
        };
        for sender in others {
            let _ = sender.send(Message::Close(None));
        }
        writer.abort();
    }
}
