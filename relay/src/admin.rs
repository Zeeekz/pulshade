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
    /// How much memory the waiting mail takes.
    pub waiting_bytes: usize,
    pub uptime_secs: u64,
    /// Calls in progress right now.
    pub calls: usize,
}

/// Whether the request carries the token from `admin.token`.
pub fn authorised(token: Option<&str>, expected_token: &str) -> bool {
    // Compare digests so the check takes the same time however much of the token matches.
    token.is_some_and(|token| !expected_token.is_empty() && Sha256::digest(token.as_bytes()) == Sha256::digest(expected_token.as_bytes()))
}

/// Reads `drop-mail`'s argument: an age such as `90m`, `48h` or `3d`, then optionally `big` to leave short mail
/// alone. An age is always asked for, so nothing is dropped by a slip of the hand.
pub fn drop_mail_arg(arg: &str) -> Result<(std::time::Duration, bool), String> {
    let usage = "give an age such as 90m, 48h or 3d, then optionally: big";
    let mut words = arg.split_whitespace();
    let age = words.next().ok_or(usage)?;
    let unit = match age.chars().last() { Some('m') => 60, Some('h') => 3600, Some('d') => 86_400, _ => return Err(usage.into()) };
    let count: u64 = age[..age.len() - 1].parse().map_err(|_| usage)?;
    if count == 0 || count > 10_000 { return Err(usage.into()) }
    let big_only = match words.next() { None => false, Some("big") => true, Some(_) => return Err(usage.into()) };
    if words.next().is_some() { return Err(usage.into()) }
    Ok((std::time::Duration::from_secs(count * unit), big_only))
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
            "waitingBytes": traffic.waiting_bytes,
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
        // What has happened to handles and when, never who: `after N` for what's newer, a handle for just its own.
        "handle-history" => Ok(json!(dir.history(arg))),
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
        "collectibles" => Ok(json!(dir.given())),
        "collectible-limits" => Ok(json!({ "default": crate::directory::DEFAULT_PER_ITEM, "most": crate::directory::MOST_PER_ITEM, "limits": dir.limits() })),
        "set-collectible-limit" => {
            // `item amount`: how many of it there can be.
            let (item, amount) = arg.split_once(char::is_whitespace).ok_or("Give the item and how many")?;
            let amount: u32 = amount.trim().parse().map_err(|_| "That isn't a number".to_string())?;
            dir.set_limit(item.trim(), amount)?;
            Ok(json!({ "item": item.trim(), "limit": amount }))
        }
        "reset-collectibles" => {
            // Spelled out, so it can't happen by accident.
            if arg != "everyone" { return Err("Say whose: everyone".into()); }
            Ok(json!({ "reset": dir.reset_collectibles() }))
        }
        "collectibles-of" => {
            // By handle, or by the account's public key.
            let key = if arg.starts_with('@') || crate::directory::valid_handle(arg) {
                let h = handle_arg(arg)?;
                dir.get(&h).map(|e| e.key).ok_or(format!("@{h} isn't listed"))?
            } else {
                arg.to_string()
            };
            Ok(json!(dir.grants_of(&key)))
        }
        "take-collectible" => {
            // `item serial`, as the panel shows it.
            let (item, serial) = arg.split_once(char::is_whitespace).ok_or("Give the item and its number")?;
            let serial: u32 = serial.trim().trim_start_matches('#').parse().map_err(|_| "That isn't a number".to_string())?;
            if dir.take_collectible(item, serial) { Ok(json!({ "taken": item, "serial": serial })) }
            else { Err(format!("No {item} #{serial} to take back")) }
        }
        "mod-accounts" => Ok(json!(dir.moderation.mods)),
        "add-mod-account" => {
            // By handle, or by the account's public key.
            let key = if arg.starts_with('@') || crate::directory::valid_handle(arg) {
                let h = handle_arg(arg)?;
                dir.get(&h).map(|e| e.key).ok_or(format!("@{h} isn't listed"))?
            } else {
                arg.to_string()
            };
            dir.add_mod_account(&key)?;
            Ok(json!({ "moderator": key }))
        }
        "remove-mod-account" => {
            let key = if arg.starts_with('@') || crate::directory::valid_handle(arg) {
                let h = handle_arg(arg)?;
                dir.get(&h).map(|e| e.key).ok_or(format!("@{h} isn't listed"))?
            } else {
                arg.to_string()
            };
            match dir.remove_mod_account(&key) {
                Some(taken) => Ok(json!({ "removed": key, "guardiansTakenBack": taken })),
                None => Err("That account isn't a moderator".into()),
            }
        }
        "eggs" => Ok(json!(dir.eggs())),
        "egg-kinds" => Ok(json!(crate::directory::EGG_KINDS.iter().map(|k| json!({
            "name": k.name,
            "seconds": k.seconds,
            "inside": k.inside.iter().map(|(item, chance)| json!({ "item": item, "chance": chance })).collect::<Vec<_>>(),
        })).collect::<Vec<_>>())),
        "give-egg" => {
            // `@handle-or-key kind`: an egg that its owner starts hatching, and the relay opens when it's ready.
            let (who, kind) = arg.split_once(char::is_whitespace).ok_or("Give the account and the kind of egg")?;
            let who = who.trim();
            let key = if who.starts_with('@') || crate::directory::valid_handle(who) {
                let h = handle_arg(who)?;
                dir.get(&h).map(|e| e.key).ok_or(format!("@{h} isn't listed"))?
            } else {
                who.to_string()
            };
            let id = dir.give_egg(&key, kind.trim())?;
            Ok(json!({ "egg": id, "kind": kind.trim() }))
        }
        "give-collectible" => {
            // The grant, signed by the creator's app: `{ "item", "serial", "owner", "sig" }`.
            let grant: crate::directory::Grant = serde_json::from_str(arg).map_err(|_| "That isn't a collectible".to_string())?;
            let (item, serial) = (grant.item.clone(), grant.serial);
            dir.give_collectible(grant)?;
            Ok(json!({ "item": item, "serial": serial }))
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
        "claims" => Ok(json!(dir.claims().into_iter().map(|c| {
            let to = dir.claimed_by(&c.item, c.serial);
            json!({ "item": c.item, "serial": c.serial, "to": to })
        }).collect::<Vec<_>>())),
        "reissue" => {
            // Signed by the admin app for the account that claimed it: `{ "item", "serial", "owner", "sig" }`.
            let grant: crate::directory::Grant = serde_json::from_str(arg).map_err(|_| "That isn't a collectible".to_string())?;
            let (item, serial) = (grant.item.clone(), grant.serial);
            dir.reissue(grant)?;
            Ok(json!({ "item": item, "serial": serial }))
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
        "giveaways" => Ok(json!(dir.giveaways().iter().map(|g| json!({
            "id": g.id, "item": g.item, "opens": g.opens, "closes": g.closes, "max": g.max,
            "claimed": g.claims.len(), "waiting": g.claims.iter().filter(|c| !c.done).count(),
        })).collect::<Vec<_>>())),
        "add-giveaway" => {
            // `{ "id", "item", "hash", "opens", "closes", "max" }`: the code only as a hash.
            let g: crate::directory::Giveaway = serde_json::from_str(arg).map_err(|_| "That isn't a giveaway".to_string())?;
            let id = g.id.clone();
            dir.add_giveaway(g)?;
            Ok(json!({ "added": id }))
        }
        "remove-giveaway" => {
            if dir.remove_giveaway(arg) { Ok(json!({ "removed": arg })) } else { Err("No such giveaway".into()) }
        }
        "giveaways-waiting" => Ok(json!(dir.giveaways_waiting().into_iter()
            .map(|(id, item, key)| json!({ "giveaway": id, "item": item, "key": key })).collect::<Vec<_>>())),
        "give-giveaway" => {
            // Signed by the admin app: `{ "giveaway", "grant": { "item", "serial", "owner", "sig" } }`.
            let v: Value = serde_json::from_str(arg).map_err(|_| "That isn't a giveaway grant".to_string())?;
            let id = v.get("giveaway").and_then(Value::as_str).ok_or("Which giveaway?")?.to_string();
            let grant: crate::directory::Grant = serde_json::from_value(v.get("grant").cloned().unwrap_or(Value::Null))
                .map_err(|_| "That isn't a collectible".to_string())?;
            let (item, serial) = (grant.item.clone(), grant.serial);
            dir.give_giveaway(&id, grant)?;
            Ok(json!({ "item": item, "serial": serial }))
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
    fn drop_mail_wants_an_age_and_nothing_odd() {
        let hour = std::time::Duration::from_secs(3600);
        assert_eq!(drop_mail_arg("48h"), Ok((48 * hour, false)));
        assert_eq!(drop_mail_arg(" 3d  big "), Ok((72 * hour, true)));
        assert_eq!(drop_mail_arg("90m"), Ok((hour * 3 / 2, false)));
        for bad in ["", "big", "0h", "48", "h", "-2h", "2w", "48h small", "48h big more", "99999d", "4\u{e9}"] {
            assert!(drop_mail_arg(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn only_the_token_gets_in() {
        let token = "secret-token";
        assert!(authorised(Some(token), token));
        assert!(!authorised(Some("guess"), token));
        assert!(!authorised(None, token), "a signature from any account no longer counts");
        assert!(!authorised(Some(""), ""), "an empty token never matches");
    }
}
