#!/bin/zsh
# Archives Pulshade for iPhone and uploads it to App Store Connect (TestFlight).
#   ./scripts/testflight.sh <build number>     e.g. ./scripts/testflight.sh 2
# Every upload needs a build number higher than the last one. The version stays MARKETING_VERSION in project.yml.
# Needs: your Apple ID signed in to Xcode (Settings > Accounts), and the app created in App Store Connect.
set -euo pipefail
cd "$(dirname "$0")/.."

build=${1:?Give the build number, higher than the last upload: ./scripts/testflight.sh 2}
[[ -f ios/Local.xcconfig ]] || { echo "Put your signing team in ios/Local.xcconfig: DEVELOPMENT_TEAM = <team id>"; exit 1; }

# Friends' phones use the same relay the install script points a phone at.
relay="http://$(cat relay/pulshade-onion/hostname 2>/dev/null)"
[[ "$relay" != "http://" ]] || { echo "No relay/pulshade-onion/hostname: the build would have no relay to reach."; exit 1; }

# A release must carry the relay's certificate pin and direct address: an empty one would ship a build that can't
# check, or can't reach, the relay.
pin="${PULSHADE_RELAY_PIN:-$(cat relay/relay-pin 2>/dev/null)}"
direct="${PULSHADE_RELAY_DIRECT:-$(cat relay/direct-address 2>/dev/null)}"
[[ -n "$pin" ]] || { echo "No relay pin (relay/relay-pin or PULSHADE_RELAY_PIN): refusing to upload a release without it."; exit 1; }
[[ -n "$direct" ]] || { echo "No direct address (relay/direct-address or PULSHADE_RELAY_DIRECT): refusing to upload a release without it."; exit 1; }

out=build/testflight
rm -rf "$out"; mkdir -p "$out"

# PULSHADE_SKIP_TOR_BUILD=1 uses Tor as last built, when tor/ hasn't changed since.
[[ -n ${PULSHADE_SKIP_TOR_BUILD:-} ]] || ./scripts/build-tor.sh
xcodegen generate >/dev/null

xcodebuild -project Pulshade.xcodeproj -scheme PulshadeiOS -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$out/Pulshade.xcarchive" -derivedDataPath ios/build \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build" \
  PULSHADE_RELAY="$relay" PULSHADE_RELAY_DIRECT="$direct" \
  PULSHADE_RELAY_PIN="$pin" \
  PULSHADE_ADMIN_KEY="$(cat relay/admin-key.pub 2>/dev/null)" PULSHADE_PET_KEY="$(cat relay/pet-key.pub 2>/dev/null)" \
  archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"

# Nothing that names you may leave this Mac: check the app before it goes up. It looks for your home folder, your
# account name, and any words you list one per line in ios/name-check.txt (kept out of git).
app="$out/Pulshade.xcarchive/Products/Applications/Pulshade.app"
names="/Users/"
[[ -n "${USER:-}" ]] && names="$names|(^|[^a-z])${USER}([^a-z]|$)"
[[ -f ios/name-check.txt ]] && names="$names|$(grep -v '^$' ios/name-check.txt | paste -sd '|' -)"
# The whole app, not just its program: its property lists, assets and anything else in the bundle. Not its signing,
# though: the certificate and provisioning profile carry the developer account's name, which an individual account
# can't avoid and TestFlight shows anyway, and Apple re-signs the app and drops the profile before testers get it.
# So the check runs on a copy with those taken out.
check="$out/name-check/Pulshade.app"
rm -rf "$out/name-check"; mkdir -p "$out/name-check"; ditto "$app" "$check"
# Every signing profile, the notification helper's inside PlugIns too: they name the developer account, not the build.
find "$check" -name embedded.mobileprovision -delete
find "$check" -name _CodeSignature -type d -prune -exec rm -rf {} +
find "$check" -type f -print0 | while IFS= read -r -d '' f; do
  file -b "$f" | grep -q '^Mach-O' && codesign --remove-signature "$f" 2>/dev/null || true
done
found=$(grep -rlaiE "$names" "$check" 2>/dev/null | sed "s#$check/##" || true)
rm -rf "$out/name-check"
if [[ -n "$found" ]]; then
  echo "Found your name or home folder inside the app, in these files. Not uploading:"
  print -r -- "$found"
  exit 1
fi

cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' ios/Local.xcconfig)</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><false/>
</dict></plist>
PLIST

xcodebuild -exportArchive -archivePath "$out/Pulshade.xcarchive" -exportOptionsPlist "$out/ExportOptions.plist" \
  -exportPath "$out/export" -allowProvisioningUpdates | grep -E "error:|EXPORT (SUCCEEDED|FAILED)|Upload"
echo "Uploaded build $build. It shows in App Store Connect > TestFlight after Apple finishes processing (a few minutes)."
