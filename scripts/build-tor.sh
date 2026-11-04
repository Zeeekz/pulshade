#!/bin/zsh
# Builds Tor (Arti, from tor/) for the Mac, the iPhone and the iPhone simulator, into
# tor/build/PulshadeTor.xcframework. The Mac app, the tests and the iPhone app all link it.
# The first build takes a few minutes; later ones only redo what changed.
set -euo pipefail
cd "$(dirname "$0")/../tor"

targets=(aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim)
installed=$(rustup target list --installed)
for target in $targets; do
    [[ $installed == *$target* ]] || rustup target add $target
done

export MACOSX_DEPLOYMENT_TARGET=26.0 IPHONEOS_DEPLOYMENT_TARGET=26.0
# Rust keeps source paths in the library for its error messages; without this they'd carry the home folder's name.
export RUSTFLAGS="--remap-path-prefix=$HOME=~ --remap-path-prefix=$PWD=tor"
for target in $targets; do
    cargo build --release -q --target $target
done

# The pluggable transports for bridges (pt/, Tor Project's lyrebird, in Go), built for each target and joined
# to Tor's library, since iOS won't let the app run them as programs of their own.
command -v go >/dev/null || { echo "Bridges need Go: brew install go"; exit 1; }
mkdir -p build/pt
for target in $targets; do
    case $target in
        aarch64-apple-darwin) goos=darwin sdk=macosx flags="-mmacosx-version-min=26.0" ;;
        aarch64-apple-ios) goos=ios sdk=iphoneos flags="-miphoneos-version-min=26.0" ;;
        aarch64-apple-ios-sim) goos=ios sdk=iphonesimulator flags="-target arm64-apple-ios26.0-simulator" ;;
    esac
    sysroot=$(xcrun --sdk $sdk --show-sdk-path)
    (cd pt && GOOS=$goos GOARCH=arm64 CGO_ENABLED=1 CC="$(xcrun --sdk $sdk -f clang)" \
        CGO_CFLAGS="-isysroot $sysroot -arch arm64 $flags" CGO_LDFLAGS="-isysroot $sysroot -arch arm64 $flags" \
        go build -buildmode=c-archive -trimpath -ldflags=-s -o ../build/pt/$target.a .)
    libtool -static -o build/pt/$target-joined.a target/$target/release/libpulshade_tor.a build/pt/$target.a 2>/dev/null
done

out=build/PulshadeTor.xcframework
rm -rf $out
xcodebuild -create-xcframework \
    $(for target in $targets; do echo -library build/pt/$target-joined.a -headers include; done) \
    -output $out >/dev/null
echo "Built tor/$out"
