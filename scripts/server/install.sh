#!/usr/bin/env bash
# Sets up a Pulshade relay on a Debian or Ubuntu server, or updates one. Run as root:
#
#   ./install.sh                          a new relay, with a new onion address
#   ./install.sh --import relay-data.tar  a relay moved from another machine (a tar of data/ and storage.key)
#
# Running it again updates the relay and keeps its data. Afterwards `pulshade-server` runs it: start, stop, status,
# logs, stats, bans and the rest (`pulshade-server help`).
set -euo pipefail

app=/opt/pulshade            # the program, its source and the Rust toolchain
data=/var/lib/pulshade       # handle directory, moderation, account backups, onion keys, admin token
keys=/etc/pulshade           # the storage key, kept apart from the data it seals
user=pulshade
repo=https://github.com/Zeeekz/pulshade.git
unit=/etc/systemd/system/pulshade-relay.service

bold=$'\e[1m'; green=$'\e[32m'; red=$'\e[31m'; yellow=$'\e[33m'; reset=$'\e[0m'
step() { printf '\n%s==> %s%s\n' "$bold" "$*" "$reset"; }
ok()   { printf '%s✓%s %s\n' "$green" "$reset" "$*"; }
warn() { printf '%s!%s %s\n' "$yellow" "$reset" "$*"; }
fail() { printf '%s✗%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  cat <<HELP
Options:
  --import FILE    Bring in a relay's data, a tar of data/ and storage.key (kept onion address, handles, bans).
  --branch NAME    Which branch to fetch when there's no source beside this script (default: main).
  --no-firewall    Leave the firewall alone.
  --public HOST    Also reachable at https://HOST, for people with Tor off. HOST must already point at this
                   server. Kept for later runs; --public off takes it away.
HELP
}

import="" branch=main firewall=true public=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --import) import="${2:-}"; shift 2 ;;
    --branch) branch="${2:-}"; shift 2 ;;
    --no-firewall) firewall=false; shift ;;
    --public) public="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || fail "Run this as root (sudo $0)."
command -v apt-get >/dev/null || fail "This script is for Debian or Ubuntu."
[[ -z "$import" || -f "$import" ]] || fail "No file at $import"
[[ -z "$import" ]] || import="$(readlink -f "$import")"

running() { systemctl is-active --quiet pulshade-relay 2>/dev/null; }
# Whether this relay already had its onion address, so a rerun doesn't call it new.
had_onion=""; [[ -s "$data/pulshade-onion/hostname" ]] && had_onion=1

step "Installing what the build needs"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q build-essential pkg-config libssl-dev curl git ca-certificates python3 ufw unattended-upgrades >/dev/null
# Security updates install themselves.
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
# Tor refuses to work with a badly wrong clock.
timedatectl set-ntp true 2>/dev/null || true
ok "Packages ready"

step "The relay's user and folders"
id "$user" >/dev/null 2>&1 || useradd --system --home-dir "$data" --shell /usr/sbin/nologin "$user"
install -d -m 755 "$app" "$app/bin"
install -d -m 700 -o "$user" -g "$user" "$data" "$keys"
ok "User $user, data in $data"

step "The source"
here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [[ -n "$here" && -f "$here/../../relay/Cargo.toml" ]]; then
  src="$(cd "$here/../.." && pwd)"
  ok "Using the source beside this script ($src)"
else
  src="$app/src"
  if [[ -d "$src/.git" ]]; then
    git -C "$src" fetch -q origin "$branch" && git -C "$src" checkout -q -B "$branch" FETCH_HEAD
  else
    rm -rf "$src" && git clone -q --branch "$branch" "$repo" "$src"
  fi
  ok "Fetched $branch from $repo"
fi

step "Building the relay (the first build takes a while)"
export RUSTUP_HOME="$app/rustup" CARGO_HOME="$app/cargo"
# Kept as installed on later runs: a new Rust would mean recompiling everything, half an hour on a small server.
if [[ ! -x "$CARGO_HOME/bin/cargo" ]]; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y -q --profile minimal --default-toolchain stable --no-modify-path >/dev/null
fi
# Small servers run out of memory compiling Tor. Then the relay is stopped (so none of its memory can reach swap)
# and a swap file is lent to the compiler, then erased.
mem_kb=$(awk '/^MemTotal/ {print $2}' /proc/meminfo)
swap_kb=$(awk '/^SwapTotal/ {print $2}' /proc/meminfo)
build_swap=""
if (( mem_kb < 3000000 )); then
  export CARGO_BUILD_JOBS=1
  if (( swap_kb == 0 )); then
    running && { systemctl stop pulshade-relay; warn "Relay stopped while it builds (small server)"; }
    build_swap=/pulshade-build.swap
    fallocate -l 3G "$build_swap" && chmod 600 "$build_swap" && mkswap -q "$build_swap" && swapon "$build_swap" \
      || { rm -f "$build_swap"; build_swap=""; warn "Couldn't add build swap; the build may run out of memory"; }
  fi
fi
cleanup_swap() { [[ -z "$build_swap" ]] || { swapoff "$build_swap" 2>/dev/null; rm -f "$build_swap"; }; }
trap cleanup_swap EXIT
"$CARGO_HOME/bin/cargo" build -q --release --locked --manifest-path "$src/relay/Cargo.toml" --target-dir "$app/target" \
  || fail "The relay didn't build"
cleanup_swap; build_swap=""
# Copied in beside, then swapped in, so a running relay is never overwritten mid-run.
install -m 755 "$app/target/release/pulshade-relay" "$app/bin/.pulshade-relay.new"
mv -f "$app/bin/.pulshade-relay.new" "$app/bin/pulshade-relay"
install -m 755 "$src/scripts/server/pulshade-server" /usr/local/bin/pulshade-server
install -m 755 "$src/scripts/server/pulshade-mod-gate" /usr/local/bin/pulshade-mod-gate
[[ "$src" == "$app/src" ]] || { rm -rf "$app/src" && mkdir -p "$app/src" && cp -a "$src/relay" "$src/scripts" "$app/src/"; rm -rf "$app/src/relay/target"; }
ok "Built"

if [[ -n "$import" ]]; then
  step "Bringing in the relay's data"
  bundle="$(mktemp -d)"
  tar -C "$bundle" -xf "$import"
  [[ -f "$bundle/storage.key" && -d "$bundle/data" ]] || { rm -rf "$bundle"; fail "$import isn't a relay's data (a tar of data/ and storage.key)"; }
  running && systemctl stop pulshade-relay
  stamp=$(date +%Y-%m-%d_%H-%M-%S)
  if [[ -n "$(ls -A "$data")" ]]; then
    mv "$data" "$data.before-import-$stamp" && install -d -m 700 -o "$user" -g "$user" "$data"
    warn "What was here is in $data.before-import-$stamp"
  fi
  [[ -f "$keys/storage.key" ]] && mv "$keys/storage.key" "$keys/storage.key.before-import-$stamp"
  cp -a "$bundle/data/." "$data/"
  install -m 600 -o "$user" -g "$user" "$bundle/storage.key" "$keys/storage.key"
  find "$bundle" "$import" -type f -exec shred -u {} + 2>/dev/null || rm -rf "$bundle" "$import"
  rm -rf "$bundle"
  ok "Imported, and the copy you sent erased"
fi

step "The storage key"
if [[ ! -f "$keys/storage.key" ]]; then
  od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$keys/storage.key"
  ok "Made a new one at $keys/storage.key"
else
  ok "Keeping $keys/storage.key"
fi
chown -R "$user:$user" "$data" "$keys" && chmod 700 "$data" "$keys" && chmod 600 "$keys/storage.key"
[[ -f "$data/creator.key" ]] || warn "No creator.key in $data: your creator account has no admin powers until you put it there."
[[ -f "$data/pet.key" ]] || warn "No pet.key in $data: eggs can't hatch and collectibles can't be gifted until you put it there."

step "The background service"
cat > "$unit" <<UNIT
[Unit]
Description=Pulshade relay
After=network-online.target
Wants=network-online.target

[Service]
User=$user
Group=$user
WorkingDirectory=$data
ExecStart=$app/bin/pulshade-relay
# Reachable only over its onion address: nothing listens on the internet.
Environment=PULSHADE_BIND=127.0.0.1:7878
Environment=PULSHADE_DIRECTORY=$data/pulshade-directory.json
Environment=PULSHADE_STORAGE_KEY_FILE=$keys/storage.key
Restart=always
RestartSec=5
LimitCORE=0
UMask=0077
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ReadWritePaths=$data
ReadOnlyPaths=$keys
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
CapabilityBoundingSet=
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable -q pulshade-relay
systemctl restart pulshade-relay
ok "Running, and starts again whenever the server does"

if $firewall; then
  step "The firewall"
  ssh_port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')
  if ufw allow "${ssh_port:-22}/tcp" >/dev/null && ufw default deny incoming >/dev/null \
     && ufw default allow outgoing >/dev/null && ufw --force enable >/dev/null; then
    ok "Only SSH (port ${ssh_port:-22}) comes in; the relay needs no open ports"
  else
    warn "Couldn't set up the firewall here (some VPS types don't allow it); use your provider's firewall instead"
  fi
fi

if awk 'NR > 1 && $1 !~ /^\/dev\/(dm-|zram)/ {found = 1} END {exit !found}' /proc/swaps; then
  warn "This server swaps to an unencrypted disk, so the relay's memory could land on it. Turn swap off, or encrypt it."
fi

# The public address, for people with Tor off: Caddy, from Ubuntu's own packages, takes HTTPS on 443 (with a
# certificate from Let's Encrypt) and hands it to the relay. No access or request error logs, so it keeps no record
# of who connects.
public_file="$keys/public-host"
[[ -n "$public" ]] || public=$(cat "$public_file" 2>/dev/null || true)
if [[ "$public" == off ]]; then
  step "The public address"
  rm -f "$public_file"
  if systemctl is-active --quiet caddy 2>/dev/null; then systemctl disable --now -q caddy; fi
  if ufw status 2>/dev/null | grep -q "Status: active"; then ufw delete allow 80/tcp >/dev/null 2>&1; ufw delete allow 443/tcp >/dev/null 2>&1; fi
  ok "Off: only reachable over Tor"
elif [[ -n "$public" ]]; then
  step "The public address"
  [[ "$public" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || fail "$public isn't a host name"
  apt-get install -y -q caddy >/dev/null
  cat > /etc/caddy/Caddyfile <<CADDY
{
	admin off
	# Request errors (a failed proxy, a dropped connection) name the client's address; certificate logs stay.
	log default {
		exclude http.log http.handlers
	}
}

$public {
	reverse_proxy 127.0.0.1:7878
	header -Server
}
CADDY
  answering=false
  if ufw status 2>/dev/null | grep -q "Status: active"; then ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null; fi
  systemctl enable -q caddy
  systemctl restart caddy
  printf '%s\n' "$public" > "$public_file"
  for _ in {1..45}; do
    curl -sf -m 5 --resolve "$public:443:127.0.0.1" "https://$public/v1/health" >/dev/null && { answering=true; break; }
    sleep 2
  done
  if $answering; then
    ok "https://$public (for people with Tor off)"
  else
    warn "https://$public isn't answering yet. Check $public points at this server; Caddy keeps trying (journalctl -u caddy)."
  fi
fi

step "Publishing the onion address"
for _ in $(seq 1 90); do
  [[ -s "$data/pulshade-onion/hostname" ]] && curl -sf -m 2 http://127.0.0.1:7878/v1/health >/dev/null && break
  sleep 2
done
if [[ -s "$data/pulshade-onion/hostname" ]]; then
  ok "http://$(cat "$data/pulshade-onion/hostname")"
  [[ -n "$import" || -n "$had_onion" ]] || warn "A new address: apps reach it only once they're rebuilt with it."
  printf '\nReachable over Tor in a few minutes. %spulshade-server help%s lists what you can do.\n' "$bold" "$reset"
else
  warn "Not published yet. Check with: pulshade-server status, or pulshade-server logs"
fi
