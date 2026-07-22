#!/usr/bin/env bash
# End-to-end: does a real incident survive the whole path into a real photon?
#
#   bash test/photon/e2e.sh                  # needs photon:latest built locally
#   ENGINE=docker bash test/photon/e2e.sh
#
# Everything else in the suite verifies mandor's half against a listener we
# wrote, which only proves the bytes match *our reading* of photon. This runs
# the actual collector, and drives it the way a user would: the `photon` config
# key, auto-forwarding on a real crash, over a container network.
#
# Both sides run in containers on purpose. mandor is a Linux binary and podman
# may live on a different host (a Windows box runs podman.exe while the
# toolchain is under WSL), so shelling out to ./zig-out/bin/mandor is not
# portable — and containers are how this is deployed anyway.
set -u

ENGINE=${ENGINE:-podman}
PHOTON_IMAGE=${PHOTON_IMAGE:-photon:latest}
TOKEN=${PHOTON_INGEST_TOKEN:-e2e-ingest-token}
SECRET=${PHOTON_SESSION_SECRET:-e2e-session-secret-at-least-32-bytes-long}
NET=mandor-photon-net
PHOTON=mandor-photon-e2e
APP=mandor-photon-app
APP_IMAGE=mandor-photon-app:latest
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

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
"$ENGINE" image exists "$PHOTON_IMAGE" 2>/dev/null || \
  skip "$PHOTON_IMAGE not built (clone nevindra/photon and \`$ENGINE build -t photon:latest .\`)"

cleanup() {
  "$ENGINE" rm -f "$APP" "$PHOTON" >/dev/null 2>&1 || true
  "$ENGINE" network rm -f "$NET" >/dev/null 2>&1 || true
  rm -f "$HERE/mandor" "$HERE/app/mandor" "$HERE/app/mandor.toml" "$HERE/appbuild.log"
  rm -rf "$HERE/out"
}
# Clear leftovers from an interrupted run *before* staging anything, or the
# staged binary is deleted out from under the build.
cleanup
trap cleanup EXIT

# A static musl mandor for the app container. MANDOR_MUSL supplies a prebuilt
# one where the toolchain and the engine are in different environments.
if [ -n "${MANDOR_MUSL:-}" ]; then
  [ -f "$MANDOR_MUSL" ] || skip "MANDOR_MUSL=$MANDOR_MUSL not found"
  cp "$MANDOR_MUSL" "$HERE/mandor"
else
  ZIG=${ZIG:-zig}
  command -v "$ZIG" >/dev/null 2>&1 || skip "no zig and no MANDOR_MUSL"
  (cd "$ROOT" && "$ZIG" build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe -Dstrip=true -p "$HERE/out") \
    || skip "cross build failed"
  cp "$HERE/out/bin/mandor" "$HERE/mandor"
fi

"$ENGINE" network create "$NET" >/dev/null 2>&1 || true

"$ENGINE" run -d --name "$PHOTON" --network "$NET" \
  -e PHOTON_INGEST_TOKEN="$TOKEN" \
  -e PHOTON_SESSION_SECRET="$SECRET" \
  -p 18080:8080 \
  "$PHOTON_IMAGE" >/dev/null 2>&1 || { bad "photon start" "container would not start"; exit 1; }

# Wait for readiness rather than sleeping: a fixed sleep races a cold start,
# and this suite has been bitten by that twice.
ready=""
for _ in $(seq 1 120); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://127.0.0.1:18080/api/login" -X POST \
          -H 'content-type: application/json' -d '{}' 2>/dev/null)
  case "$code" in 4*|2*) ready=1; break;; esac
  sleep 1
done
[ -n "$ready" ] || { bad "photon ready" "no API after 120s: $("$ENGINE" logs "$PHOTON" 2>&1 | tail -3)"; exit 1; }
ok "photon is up"

# The app image: mandor as PID 1, configured to auto-forward incidents. This is
# the documented integration (one config key), not a hand-run relay.
APPDIR="$HERE/app"
cp "$HERE/mandor" "$APPDIR/mandor"
# Address photon by container NAME, not IP. compose and Kubernetes resolve
# services by name, and mandor rejected that outright until it learned to
# resolve -- so this line is the regression test for that fix.
sed "s/PHOTON_HOST/$PHOTON/" "$APPDIR/mandor.toml.in" > "$APPDIR/mandor.toml"
if ! "$ENGINE" build -t "$APP_IMAGE" "$APPDIR" >"$HERE/appbuild.log" 2>&1; then
  bad "app image" "build failed: $(tail -3 "$HERE/appbuild.log")"
  exit 1
fi
ok "built the app image (mandor + photon key)"

# Crash a worker under mandor; the photon key forwards the incident by itself.
app_out=$("$ENGINE" run --rm --name "$APP" --network "$NET" \
  -e PHOTON_TOKEN="$TOKEN" -e MANDOR_RELEASE="api@9.9.9" \
  "$APP_IMAGE" 2>&1)
if echo "$app_out" | grep -q "exited with code 3"; then
  ok "mandor supervised the crash and wrote an incident"
else
  bad "incident produced" "$(echo "$app_out" | tail -3)"
fi
# Absence of an error is not evidence: when the endpoint was rejected outright,
# this check passed while nothing had been sent at all. Require positive proof
# that mandor accepted the endpoint and wrote an incident, then that no
# delivery error followed.
if echo "$app_out" | grep -qiE "invalid photon endpoint|bad photon endpoint"; then
  bad "relay attempted delivery" "mandor rejected the endpoint: $(echo "$app_out" | grep -i 'photon endpoint' | head -1)"
elif echo "$app_out" | grep -qiE "rejected the payload|never answered|cannot read bundle|refusing to ship"; then
  bad "relay attempted delivery" "relay reported: $(echo "$app_out" | grep -iE 'rejected|never answered|refusing' | head -2)"
elif echo "$app_out" | grep -q "incident"; then
  ok "relay attempted delivery with no error reported"
else
  bad "relay attempted delivery" "no incident line in output: $(echo "$app_out" | tail -3)"
fi

# A silent relay is not proof. Query the incident back through photon's own API.
#
# photon buffers through a WAL, so a record is not queryable the instant it is
# accepted -- poll rather than sleep. A fixed 5s wait here reported "0 rows"
# for an incident that had ingested perfectly and appeared at ~25s.
# /api/search sits behind a signed session cookie (only /api/login and the
# first-run /api/setup are open), so bootstrap a user and carry the cookie —
# without this the query 401s and looks like an ingest failure.
JAR=$(mktemp)
curl -fsS -m 10 -X POST "http://127.0.0.1:18080/api/setup" \
  -H 'content-type: application/json' \
  -d '{"username":"e2e","password":"e2e-password-123"}' >/dev/null 2>&1
login=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -c "$JAR" -X POST "http://127.0.0.1:18080/api/login" \
  -H 'content-type: application/json' \
  -d '{"username":"e2e","password":"e2e-password-123"}' 2>/dev/null)
if [ "$login" != "200" ]; then
  bad "incident is queryable" "login failed (http $login) — cannot reach /api/search"
else
  now=$(date +%s)
  win_start=$(( (now - 7200) * 1000000000 ))
  win_end=$(( (now + 7200) * 1000000000 ))
  found=""
  for _ in $(seq 1 30); do
    found=$(curl -fsS -m 15 -b "$JAR" -X POST "http://127.0.0.1:18080/api/search" \
      -H 'content-type: application/json' \
      -d "{\"start_ts_nanos\":\"$win_start\",\"end_ts_nanos\":\"$win_end\",\"limit\":50}" 2>/dev/null)
    echo "$found" | grep -q "mandor.bundle" && break
    sleep 2
  done
  if [ -z "$found" ]; then
    bad "incident is queryable" "search returned nothing ($ENGINE logs $PHOTON)"
  elif echo "$found" | grep -q "mandor.bundle"; then
    ok "incident is queryable in photon (mandor.bundle present)"
  else
    bad "incident is queryable" "no mandor record in results: $(echo "$found" | head -c 400)"
  fi
fi
rm -f "$JAR"

echo
echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
