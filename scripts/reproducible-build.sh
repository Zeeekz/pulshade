#!/bin/zsh
# Builds the Mac app twice with identical inputs and compares the results. A third party can run this on their
# own machine and a release they built to check that it matches.
#
#   ./scripts/reproducible-build.sh            debug build (works without a relay)
#   ./scripts/reproducible-build.sh release    needs relay/, admin-key.pub and relay-pin
#
# What is compared: the executable (with its signature removed, since an ad-hoc signature is not part of the
# code) and the generated Info.plist. The signed bundle and the Tor xcframework are built separately.
set -euo pipefail
cd "$(dirname "$0")/.."

config=${1:-debug}
if [[ ! -d tor/build/PulshadeTor.xcframework ]]; then
  echo "Build the Tor bridge first: ./scripts/build-tor.sh" >&2
  exit 1
fi

# Same inputs for both builds. The build number would otherwise be the current minute.
export PULSHADE_SKIP_TOR_BUILD=1
export PULSHADE_SIGN=adhoc
export PULSHADE_BUILD="${PULSHADE_BUILD:-1}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

build() {
  ./scripts/build-app.sh "$config" >/dev/null
  cp build/Pulshade.app/Contents/MacOS/Pulshade "$tmp/$1"
  cp build/Pulshade.app/Contents/Info.plist "$tmp/$1.plist"
  codesign --remove-signature "$tmp/$1" 2>/dev/null || true
}

echo "Building twice with the same inputs..."
build one
build two

if cmp -s "$tmp/one" "$tmp/two" && cmp -s "$tmp/one.plist" "$tmp/two.plist"; then
  echo "Reproducible: both builds produced the same executable and Info.plist."
  shasum -a 256 "$tmp/one" | sed 's| .*|  (executable)|'
else
  echo "Not reproducible: the two builds differ." >&2
  shasum -a 256 "$tmp/one" "$tmp/two"
  exit 1
fi
