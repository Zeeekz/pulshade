//! Operator tools. The only way in is the token in `admin.token`, a file only the relay's own machine can read:
//! `pulshade-server` sends it there, and the Pulshade Admin app on the operator's Mac reaches it over SSH. No app
//! account can run any of this. Nothing here can read messages: the relay never holds anything readable.

use crate::directory::Directory;
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

#[derive(Deserialize)]
pub struct AdminRequest {
    pub action: String,
    #[serde(default)]
    pub arg: String,
}

/// Counts the relay can see without looking inside anything.
pub struct Traffic {
    pub mailboxes: usize,
    pub waiting: usize,
    pub uptime_secs: u64,
    /// Calls in progress right now.
    pub calls: usize,
}

/// Whether the request carries the token from `admin.token`.
pub fn authorised(token: Option<&str>, expected_token: &str) -> bool {
    // Compare digests so the check takes the same time however much of the token matches.
    token.is_some_and(|token| !expected_token.is_empty() && Sha256::digest(token.as_bytes()) == Sha256::digest(expected_token.as_bytes()))
}

fn handle_arg(arg: &str) -> Result<String, String> {
    let h = arg.trim().trim_start_matches('@').to_lowercase();
    if crate::directory::valid_handle(&h) { Ok(h) } else { Err(format!("not a valid handle: {arg}")) }
}

fn profile_summary(blob: &str) -> Value {
    B64.decode(blob).ok()
        .and_then(|raw| serde_json::from_slice::<Value>(&raw).ok())
        .map(|p| json!({ "name": p.get("name"), "bio": p.get("bio") }))
        .unwrap_or(Value::Null)
}

/// Carries out one action. Errors come back as a message for the person running it.
pub fn run(dir: &mut Directory, req: &AdminRequest, traffic: Traffic) -> Result<Value, String> {
    let arg = req.arg.trim();
    match req.action.as_str() {
        "stats" => Ok(json!({
            "handles": dir.count(),
            "bannedHandles": dir.moderation.banned_handles.len(),
            "bannedAccounts": dir.moderation.banned_keys.len(),
            "reserved": dir.moderation.reserved.len(),
            "held": dir.held_count(),
            "mailboxes": traffic.mailboxes,
            "waiting": traffic.waiting,
            "uptimeSeconds": traffic.uptime_secs,
            "calls": traffic.calls,
            "reportsSetUp": dir.moderation.report_inbox.is_some(),
        })),
        "handles" => Ok(json!(dir.handles().into_iter().map(|(h, e)| json!({
            "handle": h, "key": e.key, "updated": e.updated, "profile": profile_summary(&e.blob),
        })).collect::<Vec<_>>())),
        "lookup" => {
            let h = handle_arg(arg)?;
            let entry = dir.get(&h);
            Ok(json!({
                "handle": h,
                "listed": entry.is_some(),
                "key": entry.as_ref().map(|e| e.key.clone()),
                "profile": entry.as_ref().map(|e| profile_summary(&e.blob)),
                "banned": dir.moderation.banned_handles.contains(&h),
                "accountBanned": entry.as_ref().is_some_and(|e| dir.moderation.banned_keys.contains(&e.key)),
                "reserved": dir.is_reserved(&h),
                "held": dir.is_held(&h),
                "retired": dir.is_retired(&h),
            }))
        }
        "lists" => Ok(json!({
            "bannedHandles": dir.moderation.banned_handles,
            "bannedAccounts": dir.moderation.banned_keys,
            "reserved": dir.moderation.reserved,
        })),
        "remove" => {
            let h = handle_arg(arg)?;
            if dir.take_down(&h) { Ok(json!({ "removed": h })) } else { Err(format!("@{h} isn't listed")) }
        }
        "free" => {
            let h = handle_arg(arg)?;
            if dir.free(&h) { Ok(json!({ "freed": h })) } else { Err(format!("@{h} isn't held")) }
        }
        "give" => {
            // `@name KEY`: only that account may claim the name for the next three months.
            let (h, key) = arg.split_once(char::is_whitespace).ok_or("Give the handle and the account's key")?;
            let h = handle_arg(h)?;
            dir.give(&h, key.trim()).map_err(|_| "That isn't an account key".to_string())?;
            Ok(json!({ "given": h }))
        }
        "announcements" => Ok(json!(dir.announcements())),
        "announce" => {
            // Signed by the admin app: `{ "id", "text", "date", "sig" }`.
            let a: crate::directory::Announcement = serde_json::from_str(arg).map_err(|_| "That isn't an announcement".to_string())?;
            let id = a.id.clone();
            dir.announce(a)?;
            Ok(json!({ "announced": id }))
        }
        "unannounce" => {
            if dir.unannounce(arg) { Ok(json!({ "unannounced": arg })) } else { Err("No such announcement".into()) }
        }
        "ban-handle" => {
            let h = handle_arg(arg)?;
            dir.ban_handle(&h);
            Ok(json!({ "banned": h }))
        }
        "unban-handle" => {
            let h = handle_arg(arg)?;
            if dir.unban_handle(&h) { Ok(json!({ "unbanned": h })) } else { Err(format!("@{h} wasn't banned")) }
        }
        "ban-account" => {
            // By handle, or by the account's public key.
            let key = if arg.starts_with('@') || crate::directory::valid_handle(arg) {
                let h = handle_arg(arg)?;
                dir.get(&h).map(|e| e.key).ok_or(format!("@{h} isn't listed"))?
            } else {
                arg.to_string()
            };
            if dir.creator() == Some(key.as_str()) {
                return Err("That's the creator account".into());
            }
            let gone = dir.ban_key(&key);
            Ok(json!({ "bannedAccount": key, "removedHandles": gone }))
        }
        "unban-account" => {
            if dir.unban_key(arg) { Ok(json!({ "unbanned": arg })) } else { Err("That account wasn't banned".into()) }
        }
        "reserve" => {
            let h = handle_arg(arg)?;
            dir.reserve(&h);
            Ok(json!({ "reserved": h }))
        }
        "unreserve" => {
            let h = handle_arg(arg)?;
            if dir.unreserve(&h) { Ok(json!({ "unreserved": h })) } else { Err(format!("@{h} wasn't on the reserved list")) }
        }
        "set-report-inbox" => {
            let inbox: Value = serde_json::from_str(arg).map_err(|_| "not a report inbox".to_string())?;
            let ok = ["sendID", "agreementKey", "signingKey"].iter().all(|k| inbox.get(k).and_then(Value::as_str).is_some());
            if !ok { return Err("not a report inbox".into()) }
            dir.set_report_inbox(Some(inbox));
            Ok(json!({ "reportsSetUp": true }))
        }
        other => Err(format!("unknown action: {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_token_gets_in() {
        let token = "secret-token";
        assert!(authorised(Some(token), token));
        assert!(!authorised(Some("guess"), token));
        assert!(!authorised(None, token), "a signature from any account no longer counts");
        assert!(!authorised(Some(""), ""), "an empty token never matches");
    }
}
