#!/usr/bin/env bash
# End-to-end: does a real incident survive the whole path into a real photon?
#
#   bash test/photon/e2e.sh                 # builds photon from a clone if needed
#   PHOTON_SRC=/path/to/photon bash test/photon/e2e.sh
#
# Everything else in the suite verifies mandor's half against a listener we
# wrote. This runs the actual collector, so the contract is checked against the
# implementation rather than against our reading of it. It is the difference
# between "the bytes look right" and "photon stored the incident".
#
# Skips cleanly when no engine or no photon source is available;
# MANDOR_REQUIRE_ENGINE=1 turns that into a failure for CI.
set -u

ENGINE=${ENGINE:-podman}
IMAGE=${PHOTON_IMAGE:-photon:latest}
TOKEN=${PHOTON_INGEST_TOKEN:-e2e-ingest-token}
SECRET=${PHOTON_SESSION_SECRET:-e2e-session-secret-at-least-32-bytes-long}
NAME=mandor-photon-e2e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
MANDOR=${MANDOR:-$ROOT/zig-out/bin/mandor}

pass=0 fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1 — $2"; return 0; }
skip() {
  if [ -n "${MANDOR_REQUIRE_ENGINE:-}" ]; then
    echo "FAIL $1 — MANDOR_REQUIRE_ENGINE is set, refusing to skip"; exit 1
  fi
  echo "SKIP: $1"; exit 0
}

command -v "$ENGINE" >/dev/null 2>&1 || skip "$ENGINE not installed"
"$ENGINE" info >/dev/null 2>&1 || skip "$ENGINE not running"
"$ENGINE" image exists "$IMAGE" 2>/dev/null || skip "$IMAGE not built (see docs/INTEGRATION-PHOTON.md)"
[ -x "$MANDOR" ] || skip "no mandor binary at $MANDOR"

cleanup() { "$ENGINE" rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

"$ENGINE" run -d --name "$NAME" \
  -e PHOTON_INGEST_TOKEN="$TOKEN" \
  -e PHOTON_SESSION_SECRET="$SECRET" \
  -p 14318:4318 -p 18080:8080 \
  "$IMAGE" >/dev/null 2>&1 || { bad "photon start" "container would not start"; exit 1; }

# Wait for the OTLP listener rather than sleeping: a fixed sleep races a cold
# start, and this suite has been bitten by that twice already.
ready=""
for _ in $(seq 1 90); do
  if curl -fsS -o /dev/null -m 2 "http://127.0.0.1:18080/healthz" 2>/dev/null \
     || curl -sS -o /dev/null -m 2 "http://127.0.0.1:14318/v1/logs" 2>/dev/null; then
    ready=1; break
  fi
  sleep 1
done
[ -n "$ready" ] || { bad "photon ready" "no response after 90s: $("$ENGINE" logs "$NAME" 2>&1 | tail -3)"; exit 1; }
ok "photon is listening"

# Produce a genuine bundle by crashing a worker under mandor, rather than
# hand-writing one: the point is to exercise the real spool output.
STATE=$(mktemp -d)
MANDOR_STATE_DIR="$STATE" MANDOR_RELEASE="api@9.9.9" \
  timeout 20 "$MANDOR" "sh -c 'echo boom >&2; exit 3'" >/dev/null 2>&1
bundle=$(ls "$STATE"/incidents/*.json 2>/dev/null | head -1)
if [ -z "$bundle" ]; then bad "incident produced" "nothing in $STATE/incidents"; exit 1; fi
ok "mandor wrote a real incident bundle"

# The relay hop, exactly as `photon = "ip:port"` invokes it.
out=$(PHOTON_TOKEN="$TOKEN" "$MANDOR" relay "$bundle" "127.0.0.1:14318" 2>&1); rc=$?
if [ $rc -eq 0 ]; then
  ok "photon accepted the OTLP protobuf payload"
else
  bad "photon accepted payload" "exit $rc: $out"
fi

# A 2xx only proves the decode worked. Query it back to prove the record was
# actually stored with the fields an operator would look for.
#
# /api/search sits behind a signed photon_session cookie (only /api/login and
# the first-run /api/setup are open), so bootstrap a user, log in, and carry
# the cookie. Without this the query 401s and looks like an ingest failure.
sleep 3
JAR=$(mktemp)
curl -fsS -m 10 -X POST "http://127.0.0.1:18080/api/setup" \
  -H 'content-type: application/json' \
  -d '{"username":"e2e","password":"e2e-password-123"}' >/dev/null 2>&1
login=$(curl -fsS -m 10 -c "$JAR" -X POST "http://127.0.0.1:18080/api/login" \
  -H 'content-type: application/json' \
  -d '{"username":"e2e","password":"e2e-password-123"}' -w '%{http_code}' -o /dev/null 2>/dev/null)
if [ "$login" != "200" ]; then
  bad "incident is queryable" "login failed (http $login) — cannot reach /api/search"
else
  now=$(date +%s)
  start_ns=$(( (now - 3600) * 1000000000 ))
  end_ns=$(( (now + 3600) * 1000000000 ))
  found=$(curl -fsS -m 15 -b "$JAR" -X POST "http://127.0.0.1:18080/api/search" \
    -H 'content-type: application/json' \
    -d "{\"start_ts_nanos\":\"$start_ns\",\"end_ts_nanos\":\"$end_ns\",\"limit\":50}" 2>/dev/null)
  if [ -z "$found" ]; then
    bad "incident is queryable" "search returned nothing ($ENGINE logs $NAME)"
  elif echo "$found" | grep -q "mandor.bundle"; then
    ok "incident is queryable in photon (mandor.bundle attribute present)"
  else
    bad "incident is queryable" "search returned no mandor record: $(echo "$found" | head -c 300)"
  fi
fi
rm -f "$JAR"

echo
echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
