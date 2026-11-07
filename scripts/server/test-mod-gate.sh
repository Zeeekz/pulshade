#!/usr/bin/env bash
# Tests pulshade-mod-gate against a stand-in relay on this machine: what a moderator may do, and what is refused.
# Run it with ./scripts/server/test-mod-gate.sh. It needs python3 and curl, and uses a temporary folder.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pulshade-gate.XXXXXX")
trap 'kill $relay 2>/dev/null; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/data" "$tmp/keys" "$tmp/bin"
# Linux's flock and sha256sum, stood in for where they're missing (macOS).
command -v flock >/dev/null || printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/flock"
command -v sha256sum >/dev/null || printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > "$tmp/bin/sha256sum"
chmod +x "$tmp/bin/"* 2>/dev/null
export PATH="$tmp/bin:$PATH" PULSHADE_DATA="$tmp/data" PULSHADE_KEYS="$tmp/keys" PULSHADE_RELAY_URL=http://127.0.0.1:7899
printf 'test-token' > "$tmp/data/admin.token"

cat > "$tmp/relay.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        if self.path == "/v1/admin":
            if self.headers.get("x-pulshade-admin-token") != "test-token":
                self.send_response(403); self.end_headers(); return
            out = {"action": body.get("action"), "arg": body.get("arg")}
        elif self.path == "/v1/fetch": out = {"items": [], "asked": body.get("keys")}
        else: out = {"acked": body.get("acks")}
        data = json.dumps(out).encode()
        self.send_response(200); self.send_header("content-type", "application/json"); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", 7899), H).serve_forever()
PY
python3 "$tmp/relay.py" & relay=$!
for _ in $(seq 50); do curl -s -m 1 -o /dev/null -X POST http://127.0.0.1:7899/x && break; sleep 0.1; done

pass=0; failed=0
check() { # check "what" expected-substring command...
  local what="$1" want="$2"; shift 2
  local out; out=$("$@" 2>&1); local code=$?
  if [[ "$want" == REFUSED ]]; then
    [[ $code -ne 0 ]] && { pass=$((pass+1)); return; }
  elif [[ "$out" == *"$want"* && $code -eq 0 ]]; then pass=$((pass+1)); return; fi
  failed=$((failed+1)); echo "FAIL: $what (exit $code): $out"
}
gate() { "$here/pulshade-mod-gate" "$@"; }
b64() { printf '%s' "$1" | base64; }

check "bans a handle"            '"action": "ban-handle"' gate ana "json ban-handle $(b64 @nova)"
check "bans with the app's prefix" '"arg": "@nova"'       gate ana "pulshade-server json ban-handle $(b64 @nova)"
check "looks up a handle"        '"action": "lookup"'     gate ana "json lookup $(b64 nova)"
check "reads stats"              '"action": "stats"'      gate ana "json stats"
check "bans an account by key"   '"action": "ban-account"' gate ana "json ban-account $(b64 'AbC123+/aBc123AbC123+/aBc123AbC123+/aBc12=')"
check "no collectibles"          REFUSED gate ana "json give-collectible $(b64 x)"
check "no announcing"            REFUSED gate ana "json announce $(b64 x)"
check "no reserving"             REFUSED gate ana "json reserve $(b64 nova)"
check "no setting the inbox"     REFUSED gate ana "json set-report-inbox $(b64 x)"
check "no reset"                 REFUSED gate ana "json reset-collectibles $(b64 everyone)"
check "no restart"               REFUSED gate ana "restart"
check "no backup"                REFUSED gate ana "backup"
check "no shell"                 REFUSED gate ana "bash -c id"
check "no injected argument"     REFUSED gate ana "json ban-handle $(b64 'nova"; id')"
check "no space in argument"     REFUSED gate ana "json lookup $(b64 'nova other')"
check "needs a handle to ban"    REFUSED gate ana "json ban-handle"
check "a bad name is refused"    REFUSED gate "../x" "json stats"
check "no reports before set up" REFUSED gate ana "reports-fetch"
printf '%s' "$(printf 'ab%.0s' {1..32})" > "$tmp/keys/mod-reports.key"
check "fetches reports"          '"asked"' gate ana "reports-fetch"
check "acks reports"             '"ok":true' gate ana "reports-ack 3 4"
check "ack takes ids only"       REFUSED gate ana "reports-ack 3;id"
check "cases start empty"        '"etag":"none"' gate ana "cases-get"
first=$(printf 'c2VhbGVk' | gate ana "cases-put none")
[[ "$first" == *'"ok":true'* ]] && pass=$((pass+1)) || { failed=$((failed+1)); echo "FAIL: first put: $first"; }
etag=$(sed -E 's/.*"etag":"([0-9a-f]+)".*/\1/' <<<"$first")
check "a stale put conflicts"    '"conflict":true' bash -c "printf 'b3RoZXI=' | '$here/pulshade-mod-gate' bob 'cases-put none'"
check "a current put works"      '"ok":true' bash -c "printf 'bmV3ZXI=' | '$here/pulshade-mod-gate' bob 'cases-put $etag'"
check "cases come back"          '"blob":"bmV3ZXI="' gate ana "cases-get"
check "put refuses odd data"     REFUSED bash -c "printf 'not base64!' | '$here/pulshade-mod-gate' ana 'cases-put none'"
grep -q "ana ban-handle @nova" "$tmp/data/mod/log" && pass=$((pass+1)) || { failed=$((failed+1)); echo "FAIL: ban wasn't logged"; }
grep -q "bob updated the report list" "$tmp/data/mod/log" && pass=$((pass+1)) || { failed=$((failed+1)); echo "FAIL: put wasn't logged"; }
grep -q "refused" "$tmp/data/mod/log" && pass=$((pass+1)) || { failed=$((failed+1)); echo "FAIL: refusal wasn't logged"; }

check "a moderator can't reset the list" REFUSED gate ana "cases-reset"
[[ -f "$tmp/data/mod/cases.b64.prev" ]] && pass=$((pass+1)) || { failed=$((failed+1)); echo "FAIL: the old list wasn't kept"; }
check "the operator can reset it" '"ok":true' gate owner "cases-reset"
check "the list starts again"    '"etag":"none"' gate ana "cases-get"
# One moderator can't use up the relay's admin allowance for everyone.
for _ in $(seq 100); do printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" busy lookup nova >> "$tmp/data/mod/log"; done
check "a busy moderator is slowed" REFUSED gate busy "json stats"
check "others are not"           '"action": "stats"' gate ana "json stats"

echo "$pass passed, $failed failed"
[[ $failed -eq 0 ]]
