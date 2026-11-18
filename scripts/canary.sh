#!/bin/zsh
# The delivery counter: simulated phones message each other through a throwaway relay that crashes now and then, and
# every message is counted (lost, shown twice, never ticked). Settings, all optional:
#   CANARY_PHONES (5)  CANARY_MINUTES (10)  CANARY_DRAIN_MINUTES (5)  CANARY_SEND_SECONDS (20 per phone)
#   CANARY_CRASH_MINUTES (4)  CANARY_RELAUNCH_MINUTES (5)  CANARY_SLEEP_MINUTES (3)  CANARY_RESEND_GAPS (8,20,45,90,180)
#   CANARY_DETACH_MINUTES (6, accounts only)
# The report is printed and written to CANARY_REPORT (default build/canary-<time>.txt).
set -euo pipefail
cd "$(dirname "$0")/.."
(cd relay && cargo build --release -q)
mkdir -p build
# Vaults without the Secure Enclave: its key only works while the Mac is unlocked, and a long run outlasts the screen lock
# (the 2026-11-16 two-hour run lost most messages to apps that could not reopen while the display was off).
export PULSHADE_NO_ENCLAVE=1
export CANARY_REPORT=${CANARY_REPORT:-$PWD/build/canary-$(date +%Y%m%d-%H%M%S).txt}
# CANARY_SUITE=accounts runs the groups / linked device / persona / Detach counter instead. CANARY_SCRATCH gives the
# build a folder of its own, so a second counter can run while another holds the usual one.
suite=CanaryTests; flag=PULSHADE_CANARY
[[ ${CANARY_SUITE:-} == accounts ]] && { suite=CanaryAccountsTests; flag=PULSHADE_CANARY_ACCOUNTS; }
scratch=(); [[ -n ${CANARY_SCRATCH:-} ]] && scratch=(--scratch-path "$CANARY_SCRATCH")
log=build/canary-${CANARY_SUITE:-messages}-last.log
env $flag=1 swift test "${scratch[@]}" --filter $suite >"$log" 2>&1 || true
grep -E '^(CANARY|  )|error:|✘|✔' "$log" | grep -v warning | tail -60
echo "report: $CANARY_REPORT"
