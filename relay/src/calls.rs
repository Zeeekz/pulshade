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

/// Packets waiting to go out to one device: about five seconds of audio. A device that stops reading loses what
/// comes after that instead of having the relay keep it all.
const MAX_WAITING: usize = 256;

type Peer = (u64, mpsc::Sender<Message>);

/// Queues a packet for a device, or drops it when the device has fallen too far behind. The last place is kept
/// free for the close that ends the call.
fn pass(sender: &mpsc::Sender<Message>, packet: Message) -> bool {
    sender.capacity() > 1 && sender.try_send(packet).is_ok()
}

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
        let (tx, mut rx) = mpsc::channel(MAX_WAITING);
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
                                pass(sender, Message::Binary(bytes.clone()));
                            }
                        }
                    }
                }
                Message::Close(_) => break,
                _ => {}
            }
        }
        // Leaving ends the call for both.
        let others: Vec<mpsc::Sender<Message>> = {
            let mut rooms = self.rooms.lock().unwrap();
            let others = rooms.remove(&room).unwrap_or_default();
            others.into_iter().filter(|(other, _)| *other != id).map(|(_, s)| s).collect()
        };
        for sender in others {
            let _ = sender.try_send(Message::Close(None));
        }
        writer.abort();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A device that never reads can't make the relay hold more than a few seconds of the other's audio.
    #[test]
    fn a_device_that_stops_reading_loses_packets_instead_of_filling_memory() {
        let (tx, mut rx) = mpsc::channel(MAX_WAITING);
        let packet = || Message::Binary(vec![7u8; 100].into());
        let queued = (0..10 * MAX_WAITING).filter(|_| pass(&tx, packet())).count();
        assert_eq!(queued, MAX_WAITING - 1, "the rest are dropped");
        assert!(tx.try_send(Message::Close(None)).is_ok(), "there is still room to end the call");
        assert!(tx.try_send(Message::Close(None)).is_err(), "and no more than that");
        // Once it reads again, packets flow again.
        assert!(rx.try_recv().is_ok() && rx.try_recv().is_ok());
        assert!(pass(&tx, packet()));
    }
}
