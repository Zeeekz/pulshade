#!/bin/zsh
# Runs every test, including the ones that talk to a relay. They get their own throwaway relay on a free port
# (so tests running in other checkouts at the same time don't share it), with its own handle list, so your real relay and its handles are never touched.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/pulshade-test.XXXXXX")
port=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
(cd relay && cargo build --release -q)
[[ -n ${PULSHADE_SKIP_TOR_BUILD:-} ]] || ./scripts/build-tor.sh >/dev/null
(cd "$scratch" && PULSHADE_ONION=0 PULSHADE_STORAGE_KEY=$(openssl rand -hex 32) PULSHADE_BIND=127.0.0.1:$port PULSHADE_DIRECTORY="$scratch/directory.json" \
    "$OLDPWD/relay/target/release/pulshade-relay" 2>/dev/null) &
relay=$!
trap 'kill $relay 2>/dev/null; rm -rf "$scratch"' EXIT
for _ in {1..50}; do curl -sf http://127.0.0.1:$port/v1/health >/dev/null && break; sleep 0.1; done
(cd relay && cargo test --release -q)
PULSHADE_RELAY_TEST=1 PULSHADE_TEST_RELAY=http://127.0.0.1:$port PULSHADE_TEST_DIR="$scratch" swift test "$@"
