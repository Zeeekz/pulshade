#!/bin/zsh
# Runs the checks that can run on this machine: the test suite (including the delivery-chaos and
# parser-robustness suites), then the same suite under the address, undefined and thread sanitizers.
#
#   ./scripts/verify.sh                     everything
#   ./scripts/verify.sh --quick             just the test suite
#   ./scripts/verify.sh --filter DeliveryChaosTests
#
# Tests that need a relay live in the full tree, not every copy. If they are absent this script refuses to
# call a non-relay run "all checks passed": pass --allow-no-relay when that is genuinely all that is here.
#
# The app links the Tor bridge, so the binary is built first if it isn't there yet.
set -euo pipefail
cd "$(dirname "$0")/.."

quick=""
allow_no_relay=""
args=()
for arg in "$@"; do
  case "$arg" in
    --quick) quick=1 ;;
    --allow-no-relay) allow_no_relay=1 ;;
    *) args+=("$arg") ;;
  esac
done

if ! grep -rqE '(struct|enum|final class) RelayFlowTests' Tests/PulshadeTests 2>/dev/null; then
  echo "Warning: the relay test suite is not in this tree. These results cover only tests that need no relay."
  if [[ -z "$allow_no_relay" ]]; then
    echo "Pass --allow-no-relay to run them anyway; this script will not report them as complete."
    exit 2
  fi
fi

if [[ ! -d tor/build/PulshadeTor.xcframework ]]; then
  echo "Tor isn't built yet; running scripts/build-tor.sh (takes a few minutes)."
  ./scripts/build-tor.sh
fi

echo "== tests =="
swift test "${args[@]}"

if [[ -n "$quick" ]]; then
  exit 0
fi

# Sanitizers are separate runs: thread and address can't be combined.
echo "== address + undefined sanitizers =="
swift test --sanitize=address --sanitize=undefined "${args[@]}"

echo "== thread sanitizer =="
swift test --sanitize=thread "${args[@]}"

if [[ -n "$allow_no_relay" ]]; then
  echo "All checks passed for the non-relay suite (the relay suite is not in this tree)."
else
  echo "All checks passed."
fi
