#!/bin/zsh
# Runs the mutation fuzzer over every parser that takes bytes or text from another person or the relay.
#
#   ./scripts/fuzz.sh                 60 seconds
#   ./scripts/fuzz.sh 600             ten minutes
#
# Swift's compiler driver does not support libFuzzer's `-sanitize=fuzzer`, so this is a deterministic mutation
# fuzzer rather than coverage-guided. It is built with AddressSanitizer, which is what makes it useful: a bad
# parse that traps or reads out of bounds stops the run instead of waiting for a test case.
set -euo pipefail
cd "$(dirname "$0")/.."

seconds=${1:-60}
if [[ ! -d tor/build/PulshadeTor.xcframework ]]; then
  echo "Build the Tor bridge first: ./scripts/build-tor.sh" >&2
  exit 1
fi

PULSHADE_FUZZ_SECONDS="$seconds" swift test --sanitize=address --filter MutationFuzzerTests
