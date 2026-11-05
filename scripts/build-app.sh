#!/bin/zsh
# Builds Pulshade.app into ./build. Pass "debug" for a faster, unoptimised build.
# PULSHADE_SIGN=adhoc signs it with no identity at all, for builds that leave this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

config=${1:-release}
[[ -n ${PULSHADE_SKIP_TOR_BUILD:-} ]] || # PULSHADE_SKIP_TOR_BUILD=1 uses Tor as last built, when tor/ hasn't changed since.
[[ -n ${PULSHADE_SKIP_TOR_BUILD:-} ]] || ./scripts/build-tor.sh
swift build -c "$config"
bin="$(swift build -c "$config" --show-bin-path)/Pulshade"

# Every build gets a higher number than the last, so the updater knows which is newer.
build_number=${PULSHADE_BUILD:-$(date -u +%Y%m%d%H%M)}

app=build/Pulshade.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Pulshade"
# Debug symbols name the folders it was built in, the home folder among them. Crash reports don't need them.
strip -S -x "$app/Contents/MacOS/Pulshade"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/PrivacyInfo.xcprivacy "$app/Contents/Resources/PrivacyInfo.xcprivacy"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PULSHADE</string>
    <key>CFBundleDisplayName</key><string>PULSHADE</string>
    <key>CFBundleIdentifier</key><string>app.pulshade.mac</string>
    <key>CFBundleExecutable</key><string>Pulshade</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>$build_number</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Built by Zeekz</string>
    <key>ITSAppUsesNonExemptEncryption</key><true/>
    <key>NSCameraUsageDescription</key><string>Scan codes to link your devices, add friends and verify them, and take photos and videos for stories. Frames are never saved.</string>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>app.pulshade.link</string>
        <key>CFBundleURLSchemes</key><array><string>pulshade</string></array>
    </dict></array>
    <key>NSMicrophoneUsageDescription</key><string>Record voice notes, videos and make calls. Audio is encrypted before it leaves your Mac.</string>
    <key>NSRequiresAquaSystemAppearance</key><false/>
    <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
    <key>PulshadeRelay</key><string>$(sed 's|^|http://|' relay/pulshade-onion/hostname 2>/dev/null)</string>
    <key>PulshadeRelayDirect</key><string>${PULSHADE_RELAY_DIRECT:-$(cat relay/direct-address 2>/dev/null)}</string>
    <key>PulshadeRelayPin</key><string>${PULSHADE_RELAY_PIN:-$(cat relay/relay-pin 2>/dev/null)}</string>
    <key>PulshadeAdminKey</key><string>$(cat relay/admin-key.pub 2>/dev/null)</string>
    <key>PulshadePetKey</key><string>$(cat relay/pet-key.pub 2>/dev/null)</string>
    <key>PulshadeReleaseKey</key><string>$(cat relay/release.pub 2>/dev/null)</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
        <key>NSExceptionDomains</key>
        <dict>
            <key>onion</key>
            <dict>
                <key>NSIncludesSubdomains</key><true/>
                <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
PLIST

# Signed with your development certificate when there is one, so the Keychain still knows Pulshade after
# a rebuild (an ad-hoc signature changes every build, and the Keychain would ask again each time).
identity=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')
[[ "${PULSHADE_SIGN:-}" == adhoc ]] && identity=""
codesign --force --sign "${identity:--}" "$app" >/dev/null
echo "Built $app"
