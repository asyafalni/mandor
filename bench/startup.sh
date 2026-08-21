#!/usr/bin/env bash
# Startup + spawn/reap cost as a function of worker count.
#
#   zig build && bash bench/startup.sh
#
# The two unmeasured cost paths — boot→all-workers-spawned latency, and the
# per-restart fork/exec/reap cost of a crashloop — are the SAME spawn() path, so
# one measurement gives both. We time mandor start→exit with N workers that each
# `exit 0` (clean exits are never retried, so mandor spawns all N, reaps them,
# and exits): the intercept at N=1 is mandor's own boot overhead, and the slope
# per added worker is the per-spawn+reap cost = the per-restart cost. Best of 5
# to cut VM scheduling noise. This is deployable-shape (fork+exec+pipes+reap),
# not a synthetic microbench.
set -u
MANDOR=${MANDOR:-zig-out/bin/mandor}
REPS=${REPS:-5}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/state"
# Worker: /bin/true — a direct binary that exits 0 immediately, so the measured
# per-worker cost is mandor's spawn+reap path (fork/exec/pipes/dup2/waitpid), not
# a shell interpreter's startup. mandor dedups the repeated basename (true,
# true-2, …), so N copies is a valid N-worker set.
now_ms() { date +%s%3N; }

run_n() {
  local n=$1 workers="" i
  for i in $(seq 0 $((n - 1))); do
    workers="$workers\"/bin/true\", "
  done
  printf 'max_restarts = 0\nstate_dir = "%s"\nworkers = [%s]\n' "$TMP/state" "${workers%, }" > "$TMP/n.toml"
  local best=999999 rep t0 t1 d
  for rep in $(seq 1 "$REPS"); do
    t0=$(now_ms)
    "$MANDOR" --config="$TMP/n.toml" >/dev/null 2>&1
    t1=$(now_ms)
    d=$((t1 - t0))
    [ "$d" -lt "$best" ] && best=$d
  done
  echo "$best"
}

echo "startup + spawn/reap, best of $REPS runs (ms), $MANDOR"
l1=$(run_n 1)
l16=$(run_n 16)
l32=$(run_n 32)
l64=$(run_n 64)
printf '  N=1    %3s ms\n  N=16   %3s ms\n  N=32   %3s ms\n  N=64   %3s ms\n' "$l1" "$l16" "$l32" "$l64"
# Slope over the 1..64 span = per-worker spawn+reap cost (also the per-restart cost).
awk -v a="$l1" -v b="$l64" 'BEGIN{ printf "  per-worker (slope 1->64): %.3f ms/worker\n", (b-a)/63 }'
