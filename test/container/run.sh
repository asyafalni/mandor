#!/usr/bin/env bash
# Real PID-1 semantics only appear inside a container (CLAUDE.md): outside one,
# mandor is an ordinary process, nothing is reparented to it, and the
# process-group behaviour it relies on is not exercised. The rest of the suite
# runs on the host, so these cases cover what the host cannot.
#
#   bash test/container/run.sh              # podman (default) or docker
#   ENGINE=docker bash test/container/run.sh
set -u

ENGINE=${ENGINE:-podman}
IMAGE=${IMAGE:-mandor-pid1test}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

command -v "$ENGINE" >/dev/null 2>&1 || { echo "SKIP: $ENGINE not installed"; exit 0; }
"$ENGINE" info >/dev/null 2>&1 || { echo "SKIP: $ENGINE not running"; exit 0; }

pass=0 fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1 — $2"; return 0; }

# The container needs a static musl binary. MANDOR_MUSL lets a caller supply
# one that is already built — useful where the toolchain and the container
# engine live in different environments (a Windows dev box builds under WSL
# but runs podman.exe on the host). CI has both in one place and just builds.
if [ -n "${MANDOR_MUSL:-}" ]; then
  [ -f "$MANDOR_MUSL" ] || { echo "SKIP: MANDOR_MUSL=$MANDOR_MUSL not found"; exit 0; }
  cp "$MANDOR_MUSL" "$HERE/mandor"
else
  # Build to its own prefix so it can never clobber zig-out/bin/mandor: a cross
  # build once overwrote the host binary and a whole round of timings ended up
  # measuring a failed exec.
  ZIG=${ZIG:-zig}
  echo "building x86_64-linux-musl binary..."
  (cd "$ROOT" && "$ZIG" build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe -Dstrip=true -p "$HERE/out") \
    || { echo "SKIP: cross build failed"; exit 0; }
  cp "$HERE/out/bin/mandor" "$HERE/mandor"
fi
trap 'rm -f "$HERE/mandor"; rm -rf "$HERE/out"' EXIT

"$ENGINE" build -t "$IMAGE" "$HERE" >/dev/null 2>&1 || { bad "image build" "see $ENGINE build output"; exit 1; }

# 1. mandor really is PID 1 and the worker hangs off it.
out=$("$ENGINE" run --rm "$IMAGE" "sh /t/pid1.sh" 2>&1)
if echo "$out" | grep -q "ppid=1"; then
  ok "runs as PID 1"
else bad "pid1 identity" "$(echo "$out" | grep -E 'pid|ppid' | tr '\n' ' ')"; fi

# 2. Orphans are adopted AND released. This is the guarantee the whole class of
# tool exists for: a process whose parent dies is handed to PID 1, and a PID 1
# that does not reap it leaves a zombie occupying a slot forever.
#
# Five at once, so a single lucky reap cannot pass for a working loop. The
# check runs while mandor is still supervising, which is what proves reaping
# happens continuously rather than only at shutdown.
out=$("$ENGINE" run --rm "$IMAGE" "sh /t/orphan.sh" 2>&1)
adopted=$(echo "$out" | grep -c "ppid=1")
if [ "$adopted" -eq 5 ] && echo "$out" | grep -q "zombies=0"; then
  ok "orphans are adopted by PID 1 and reaped (5/5, no zombies)"
else bad "orphan adoption + reaping" \
  "adopted=$adopted/5, $(echo "$out" | grep -E 'zombies|pid1-children' | tr '\n' ' ')"; fi

# 2. A grandchild's own TERM handler must run to completion. This is the v1.5.1
# case: the leader exits promptly on TERM, and the post-death process-group
# sweep used to KILL the grandchild mid-drain.
"$ENGINE" rm -f mandor-gctest >/dev/null 2>&1
"$ENGINE" run -d --name mandor-gctest "$IMAGE" "sh /t/gc.sh" >/dev/null 2>&1
for _ in $(seq 1 50); do
  "$ENGINE" logs mandor-gctest 2>&1 | grep -q "grandchild-ready" && break
  sleep 0.2
done
"$ENGINE" stop -t 10 mandor-gctest >/dev/null 2>&1
logs=$("$ENGINE" logs mandor-gctest 2>&1)
code=$("$ENGINE" inspect mandor-gctest --format '{{.State.ExitCode}}' 2>/dev/null)
"$ENGINE" rm -f mandor-gctest >/dev/null 2>&1
if echo "$logs" | grep -q "grandchild-drained" && [ "$code" = "0" ]; then
  ok "grandchild TERM handler drains under real PID 1"
else bad "grandchild drain" "exit=$code: $(echo "$logs" | tail -3 | tr '\n' ' ')"; fi

# 3-5. Exit-code contract, which is how the orchestrator learns what happened.
"$ENGINE" run --rm "$IMAGE" "sh -c 'exit 7'" >/dev/null 2>&1
c=$?; [ "$c" = "7" ] && ok "worker exit code propagates (7)" || bad "exit propagation" "got $c"

"$ENGINE" run --rm "$IMAGE" "sh /t/segv.sh" >/dev/null 2>&1
c=$?; [ "$c" = "139" ] && ok "signal death maps to 128+N (139)" || bad "signal exit" "got $c"

"$ENGINE" run --rm "$IMAGE" "definitely-not-a-binary-xyz" >/dev/null 2>&1
c=$?; [ "$c" = "127" ] && ok "exec failure maps to 127" || bad "exec failure" "got $c"

echo
echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
