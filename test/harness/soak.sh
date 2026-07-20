#!/usr/bin/env bash
# Soak test: does mandor hold steady state under sustained load?
#
#   zig build && bash test/harness/soak.sh
#   SOAK_SECONDS=1800 bash test/harness/soak.sh    # deep local run
#
# README claims "zero allocations in steady state" and near-zero idle cost.
# Nothing else verifies that. This runs a workload that touches every path
# which could leak — capture/ring, sampler, restart+backoff, incident spool,
# history, cost profiles, health probes, the metrics listener — and asserts
# mandor's own RSS, fd count, and thread count stay flat while it does.
#
# Fixed buffers are lazily faulted in, so RSS legitimately climbs early. The
# first WARMUP_PCT of samples is discarded and flatness is asserted only on
# the remainder.
set -u
# A stray SIGPIPE must never take down the soak itself (see the metrics scrape).
trap '' PIPE

MANDOR=${MANDOR:-zig-out/bin/mandor}
SOAK_SECONDS=${SOAK_SECONDS:-120}
SAMPLE_EVERY=${SAMPLE_EVERY:-2}
WARMUP_PCT=${WARMUP_PCT:-40}
# Steady-state RSS drift budget. Generous enough for allocator/page noise,
# far tighter than any real leak: a 1 KB/s leak would blow this in seconds.
RSS_DRIFT_KB=${RSS_DRIFT_KB:-256}
# Distinct from run_tests.sh (19464) so a soak and the harness can run at once.
METRICS_PORT=${METRICS_PORT:-19465}

TMP=$(mktemp -d)
STATE="$TMP/state"
mkdir -p "$STATE"
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1 — $2"; }

cleanup() { [ -n "${mpid:-}" ] && kill -KILL "$mpid" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

echo "soak: ${SOAK_SECONDS}s, sampling every ${SAMPLE_EVERY}s, warmup ${WARMUP_PCT}%"

# Workload, chosen so every suspect path stays hot. Real scripts rather than
# inline `sh -c`, so each worker gets a distinct name (mandor names workers
# after the basename of argv0 — three `sh -c` workers would all be "sh").
#   spam    — capture hot path + ring eviction, at full rate
#   flap    — restart + backoff + incident spool + history + retention pruning
#   steady  — sampler and cost profiling on a long-lived process
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nwhile :; do echo "spam line with padding to exercise the ring buffer"; done\n' >"$TMP/bin/spam"
printf '#!/bin/sh\nexit 7\n' >"$TMP/bin/flap"
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$TMP/bin/steady"
chmod +x "$TMP/bin/spam" "$TMP/bin/flap" "$TMP/bin/steady"

"$MANDOR" --restart=on-failure --backoff-max=200ms \
  --state-dir="$STATE" --metrics="$METRICS_PORT" \
  --health="steady=/bin/true" --health-interval=5s \
  "$TMP/bin/spam" "$TMP/bin/flap" "$TMP/bin/steady" \
  >/dev/null 2>&1 &
mpid=$!

sleep 3
if ! kill -0 "$mpid" 2>/dev/null; then
  echo "FAIL soak — mandor died during startup"; exit 1
fi

rss_of()     { awk '/^VmRSS:/{print $2}' "/proc/$1/status" 2>/dev/null; }
threads_of() { awk '/^Threads:/{print $2}' "/proc/$1/status" 2>/dev/null; }
fds_of()     { ls "/proc/$1/fd" 2>/dev/null | wc -l; }

samples=$((SOAK_SECONDS / SAMPLE_EVERY))
[ "$samples" -lt 5 ] && samples=5
rss_list=() fd_list=() thr_list=()

for i in $(seq 1 "$samples"); do
  sleep "$SAMPLE_EVERY"
  if ! kill -0 "$mpid" 2>/dev/null; then
    echo "FAIL soak — mandor died at sample $i/$samples"; exit 1
  fi
  rss_list+=("$(rss_of "$mpid")")
  fd_list+=("$(fds_of "$mpid")")
  thr_list+=("$(threads_of "$mpid")")
  # Scrape metrics periodically: exercises accept/read/write on the listener.
  # In a subshell, because the endpoint closes the connection after responding
  # and a write that loses that race raises SIGPIPE — which would kill this
  # script outright (exit 141) rather than just failing the scrape. Rare per
  # attempt, near-certain over a 30-minute run.
  if [ $((i % 5)) -eq 0 ]; then
    (
      exec 3<>"/dev/tcp/127.0.0.1/$METRICS_PORT" || exit 0
      printf 'GET /metrics HTTP/1.0\r\n\r\n' >&3 || exit 0
      cat <&3 >/dev/null || exit 0
    ) 2>/dev/null || true
  fi
done

# ---- analysis -------------------------------------------------------------
skip=$(( samples * WARMUP_PCT / 100 ))
[ "$skip" -lt 1 ] && skip=1

rss_min=999999999 rss_max=0 fd_max=0 fd_min=999999 thr_first="" fd_first="" fd_last=""
for i in $(seq "$skip" $((samples - 1))); do
  r=${rss_list[$i]:-0}; f=${fd_list[$i]:-0}; t=${thr_list[$i]:-0}
  [ -z "$r" ] && continue
  [ "$r" -lt "$rss_min" ] && rss_min=$r
  [ "$r" -gt "$rss_max" ] && rss_max=$r
  [ "$f" -gt "$fd_max" ] && fd_max=$f
  [ "$f" -lt "$fd_min" ] && fd_min=$f
  [ -z "$fd_first" ] && fd_first=$f
  fd_last=$f
  [ -z "$thr_first" ] && thr_first=$t
  [ "$t" != "$thr_first" ] && thr_drift=1
done

drift=$((rss_max - rss_min))
echo "  steady-state RSS ${rss_min}-${rss_max} KB (drift ${drift} KB, budget ${RSS_DRIFT_KB})"
echo "  fds ${fd_min}-${fd_max}, threads ${thr_first}"

if [ "$drift" -le "$RSS_DRIFT_KB" ]; then
  ok "RSS flat in steady state (${drift} KB drift)"
else
  bad "RSS flat in steady state" "drifted ${drift} KB over $((samples - skip)) samples"
fi

# Compare first vs last rather than max vs min: a health probe forks and
# briefly holds pipes, so an unlucky sample sees a transient spike. A real
# leak grows monotonically, which start-to-end catches and a spike does not.
if [ $((fd_last - fd_first)) -le 2 ]; then
  ok "no fd growth (${fd_first} -> ${fd_last}, range ${fd_min}..${fd_max})"
else
  bad "no fd growth" "fds grew ${fd_first} -> ${fd_last} (range ${fd_min}..${fd_max})"
fi

if [ "${thr_drift:-0}" = "0" ] && [ "${thr_first:-0}" = "1" ]; then
  ok "single-threaded throughout"
else
  bad "single-threaded throughout" "threads=${thr_first}, drift=${thr_drift:-0}"
fi

# Spool retention must bound disk too, not just memory.
n_inc=$(ls "$STATE/incidents" 2>/dev/null | wc -l)
if [ "$n_inc" -le 200 ]; then
  ok "incident spool bounded by retention ($n_inc files)"
else
  bad "incident spool bounded by retention" "$n_inc files > 200"
fi

# Still responsive after the beating?
if MANDOR_STATE_DIR="$STATE" timeout 10 "$MANDOR" report >"$TMP/report" 2>&1 &&
   grep -q "steady" "$TMP/report"; then
  ok "report still works after soak"
else
  bad "report still works after soak" "$(head -2 "$TMP/report" 2>/dev/null)"
fi

# And it must still shut down cleanly rather than needing a KILL.
kill -TERM "$mpid" 2>/dev/null
for _ in $(seq 1 100); do kill -0 "$mpid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$mpid" 2>/dev/null; then
  bad "clean shutdown after soak" "still alive 10s after TERM"
else
  ok "clean shutdown after soak"
fi
mpid=""

echo
echo "soak passed $pass, failed $fail"
[ "$fail" -eq 0 ]
