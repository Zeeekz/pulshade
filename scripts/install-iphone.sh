#!/bin/zsh
# Builds Pulshade for your connected iPhone and installs it.
# The phone is pointed at the relay on this Mac: its onion address once it has one,
# otherwise its Wi-Fi address (start that with: PULSHADE_BIND=0.0.0.0:7878 ./scripts/run-relay.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

device=${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /available|connected/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)}
[[ -n "$device" ]] || { echo "No iPhone found. Connect and unlock it, then try again."; exit 1; }
ip=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)
relay="http://$ip:7878"
[[ -f relay/pulshade-onion/hostname ]] && relay="http://$(cat relay/pulshade-onion/hostname)"

[[ -f ios/Local.xcconfig ]] || { echo "Put your signing team in ios/Local.xcconfig: DEVELOPMENT_TEAM = <team id>"; exit 1; }
[[ -n ${PULSHADE_SKIP_TOR_BUILD:-} ]] || # PULSHADE_SKIP_TOR_BUILD=1 uses Tor as last built, when tor/ hasn't changed since.
[[ -n ${PULSHADE_SKIP_TOR_BUILD:-} ]] || ./scripts/build-tor.sh
xcodegen generate >/dev/null
xcodebuild -project Pulshade.xcodeproj -scheme PulshadeiOS -destination "id=$device" -derivedDataPath ios/build \
  -allowProvisioningUpdates PULSHADE_RELAY="$relay" PULSHADE_RELAY_DIRECT="${PULSHADE_RELAY_DIRECT:-$(cat relay/direct-address 2>/dev/null)}" PULSHADE_RELAY_PIN="${PULSHADE_RELAY_PIN:-$(cat relay/relay-pin 2>/dev/null)}" PULSHADE_ADMIN_KEY="$(cat relay/admin-key.pub 2>/dev/null)" PULSHADE_PET_KEY="$(cat relay/pet-key.pub 2>/dev/null)" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
xcrun devicectl device install app --device "$device" ios/build/Build/Products/Debug-iphoneos/Pulshade.app >/dev/null
echo "Installed on $device, using the relay at $relay"
