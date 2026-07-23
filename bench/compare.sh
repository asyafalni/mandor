#!/usr/bin/env bash
# mandor vs tini / dumb-init / s6 / supervisord, on the dimensions that matter
# for a PID-1 supervisor, all in one Alpine image so the comparison is fair —
# same kernel, same libc.
#
#   bash bench/compare.sh
#   ENGINE=docker bash bench/compare.sh
#
# Skips cleanly when no engine is present. Numbers are printed, not committed:
# they depend on the machine, and the point is a reproducible method, not a
# frozen leaderboard.
set -u

ENGINE=${ENGINE:-podman}
IMAGE=mandor-bench:latest
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

command -v "$ENGINE" >/dev/null 2>&1 || { echo "SKIP: $ENGINE not installed"; exit 0; }
"$ENGINE" info >/dev/null 2>&1 || { echo "SKIP: $ENGINE not running"; exit 0; }

if [ -n "${MANDOR_MUSL:-}" ]; then
  [ -f "$MANDOR_MUSL" ] || { echo "SKIP: MANDOR_MUSL=$MANDOR_MUSL not found"; exit 0; }
  cp "$MANDOR_MUSL" "$HERE/mandor"
else
  ZIG=${ZIG:-zig}
  command -v "$ZIG" >/dev/null 2>&1 || { echo "SKIP: no zig and no MANDOR_MUSL"; exit 0; }
  (cd "$ROOT" && "$ZIG" build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe -Dstrip=true -p "$HERE/out") \
    || { echo "SKIP: cross build failed"; exit 0; }
  cp "$HERE/out/bin/mandor" "$HERE/mandor"
fi
trap 'rm -f "$HERE/mandor"; rm -rf "$HERE/out"' EXIT

"$ENGINE" build -q -t "$IMAGE" "$HERE" >/dev/null || { echo "image build failed"; exit 1; }

# ---- deployable footprint -------------------------------------------------
# Single-binary size alone flatters s6 (a 63-binary suite) and misreports
# supervisord (a Python script needing the interpreter). Report what actually
# has to ship.
echo "== deployable footprint =="
"$ENGINE" run --rm "$IMAGE" -c '
  m=$(stat -c%s /usr/bin/mandor)
  printf "  %-12s %8s B   single static binary, no runtime\n" mandor "$m"
  printf "  %-12s %8s B   single static binary (reap+signal only)\n" tini "$(stat -c%s /sbin/tini)"
  printf "  %-12s %8s B   single static binary (reap+signal only)\n" dumb-init "$(stat -c%s /usr/bin/dumb-init)"
  s6=$(du -cb /bin/s6-* 2>/dev/null | tail -1 | cut -f1)
  printf "  %-12s %8s B   63-binary suite (not one file)\n" s6 "$s6"
  py=$(du -sb /usr/lib/python3.12 2>/dev/null | cut -f1)
  printf "  %-12s %8s B   Python script + interpreter\n" supervisord "$py"
'

# ---- idle RSS: PID 1 watching one sleeping worker ------------------------
# The claim behind "near-zero idle cost". Only the tools that run a bare
# command as PID 1 without a config tree are directly comparable here; s6 and
# supervisord need a service directory, out of scope for this quick pass.
echo
echo "== idle RSS as PID 1 watching one worker (KB, 3s settle) =="
idle_rss() {
  local name="$1" launch="$2"
  local cid
  cid=$("$ENGINE" run -d "$IMAGE" -c "$launch" 2>/dev/null)
  [ -z "$cid" ] && { printf "  %-12s (failed to start)\n" "$name"; return; }
  sleep 3
  local rss
  rss=$("$ENGINE" exec "$cid" sh -c "awk '/VmRSS/{print \$2}' /proc/1/status" 2>/dev/null)
  printf "  %-12s %6s\n" "$name" "${rss:-?}"
  "$ENGINE" rm -f "$cid" >/dev/null 2>&1
}
idle_rss mandor    "exec /usr/bin/mandor '/workload.sh'"
idle_rss tini      "exec /sbin/tini -- /workload.sh"
idle_rss dumb-init "exec /usr/bin/dumb-init /workload.sh"

# ---- signal-forwarding latency: TERM to PID 1 -> worker sees it ----------
# The core PID-1 job. Worker stamps ns on ready and on TERM; we send TERM and
# read the gap from its output. Median of several, in the same container.
echo
echo "== TERM forwarding latency, PID 1 -> worker (ms, best of 5) =="
sig_latency() {
  local name="$1" launch="$2"
  local best=""
  for _ in 1 2 3 4 5; do
    local out
    out=$("$ENGINE" run --rm "$IMAGE" -c "
      $launch >/tmp/o 2>&1 &
      sp=\$!
      for _ in \$(seq 1 400); do grep -q worker-ready /tmp/o 2>/dev/null && break; sleep 0.005; done
      sent=\$(date +%s%N)
      kill -TERM \$sp 2>/dev/null
      for _ in \$(seq 1 400); do grep -q worker-term /tmp/o 2>/dev/null && break; sleep 0.005; done
      # mandor prefixes captured output with [name], which shifts columns; the
      # timestamp is always the last field, so read \$NF not \$2.
      seen=\$(grep worker-term /tmp/o | awk '{print \$NF}')
      [ -n \"\$seen\" ] && echo \$(( (seen - sent) / 1000000 ))
    " 2>/dev/null)
    case "$out" in ''|*[!0-9-]*) continue;; esac
    if [ -z "$best" ] || [ "$out" -lt "$best" ]; then best="$out"; fi
  done
  printf "  %-12s %6s\n" "$name" "${best:-?}"
}
sig_latency mandor    "exec /usr/bin/mandor '/workload.sh'"
sig_latency tini      "exec /sbin/tini -- /workload.sh"
sig_latency dumb-init "exec /usr/bin/dumb-init /workload.sh"

echo
echo "Method and interpretation: bench/README.md. s6 and supervisord are"
echo "compared on footprint only here; their runtime needs a service tree."
