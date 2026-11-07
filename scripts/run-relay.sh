#!/bin/zsh
# Runs the relay on this Mac. Set PULSHADE_BIND=0.0.0.0:7878 to let other devices on your network reach it.
set -euo pipefail
cd "$(dirname "$0")/../relay"
cargo run --release
