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

out=build/testflight
rm -rf "$out"; mkdir -p "$out"

./scripts/build-tor.sh
xcodegen generate >/dev/null

xcodebuild -project Pulshade.xcodeproj -scheme PulshadeiOS -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$out/Pulshade.xcarchive" -derivedDataPath ios/build \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build" \
  PULSHADE_RELAY="$relay" PULSHADE_RELAY_DIRECT="${PULSHADE_RELAY_DIRECT:-$(cat relay/direct-address 2>/dev/null)}" \
  PULSHADE_RELAY_PIN="${PULSHADE_RELAY_PIN:-$(cat relay/relay-pin 2>/dev/null)}" \
  PULSHADE_ADMIN_KEY="$(cat relay/admin-key.pub 2>/dev/null)" PULSHADE_PET_KEY="$(cat relay/pet-key.pub 2>/dev/null)" \
  archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"

# Nothing that names you may leave this Mac: check the app before it goes up. It looks for your home folder, your
# account name, and any words you list one per line in ios/name-check.txt (kept out of git).
app="$out/Pulshade.xcarchive/Products/Applications/Pulshade.app"
names="/Users/|(^|[^a-z])${USER}([^a-z]|$)"
[[ -f ios/name-check.txt ]] && names="$names|$(grep -v '^$' ios/name-check.txt | paste -sd '|' -)"
if { strings -a "$app/Pulshade" | grep -i -E "$names"; } >/dev/null; then
  echo "Found your name or home folder inside the app. Not uploading:"
  strings -a "$app/Pulshade" | grep -i -E "$names" | head
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
