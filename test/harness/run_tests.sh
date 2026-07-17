#!/usr/bin/env bash
# Integration tests for mandor v0.1 (Linux). Usage:
#   zig build && bash test/harness/run_tests.sh
# Real PID-1 semantics are only exercised in a container; these cover the
# supervisor contract itself.
set -u

MANDOR=${MANDOR:-zig-out/bin/mandor}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0

ok()   { pass=$((pass+1)); echo "ok   $1"; }
bad()  { fail=$((fail+1)); echo "FAIL $1 — $2"; }

# 1. all workers clean -> exit 0
timeout 10 "$MANDOR" "sh -c 'exit 0'" "sh -c 'exit 0'" >"$TMP/1" 2>&1
[ $? -eq 0 ] && ok "clean workers exit 0" || bad "clean workers exit 0" "exit $?"

# 2. worst exit code propagates
timeout 10 "$MANDOR" "sh -c 'exit 3'" "sh -c 'exit 0'" >"$TMP/2" 2>&1
c=$?; [ $c -eq 3 ] && ok "worst code propagates" || bad "worst code propagates" "exit $c"

# 3. signal death -> 128+11
timeout 10 "$MANDOR" "sh -c 'kill -SEGV \$\$'" >"$TMP/3" 2>&1
c=$?; [ $c -eq 139 ] && ok "segv maps to 139" || bad "segv maps to 139" "exit $c"

# 4. exec failure -> 127
timeout 10 "$MANDOR" "definitely-not-a-binary-xyz" >"$TMP/4" 2>&1
c=$?; [ $c -eq 127 ] && ok "exec failure maps to 127" || bad "exec failure maps to 127" "exit $c"

# 5. --restart=never spawns exactly once
timeout 10 "$MANDOR" --restart=never "sh -c 'exit 1'" >"$TMP/5" 2>&1
c=$?; n=$(grep -c "spawned" "$TMP/5")
if [ $c -eq 1 ] && [ "$n" -eq 1 ]; then ok "never policy: one spawn, exit 1"
else bad "never policy: one spawn, exit 1" "exit $c, spawns $n"; fi

# 6. --restart=on-failure restarts with growing backoff; TERM stops it
"$MANDOR" --restart=on-failure "sh -c 'exit 1'" >"$TMP/6" 2>&1 &
mpid=$!
sleep 2
kill -TERM "$mpid" 2>/dev/null
wait "$mpid"; c=$?
n=$(grep -c "spawned" "$TMP/6")
delays=$(grep -o "in [0-9]*ms" "$TMP/6" | head -2 | tr -d "inms " | paste -sd,)
if [ $c -eq 1 ] && [ "$n" -ge 3 ] && [ "$delays" = "200,400" ]; then
  ok "on-failure: restarts, 200/400ms backoff, TERM stops"
else
  bad "on-failure restarts+backoff" "exit $c, spawns $n, delays [$delays]"
fi

# 7. stable-for-10s NOT required for this test: --restart=always restarts clean exits too
"$MANDOR" --restart=always "sh -c 'exit 0'" >"$TMP/7" 2>&1 &
mpid=$!
sleep 1
kill -TERM "$mpid" 2>/dev/null
wait "$mpid"; c=$?
n=$(grep -c "spawned" "$TMP/7")
if [ $c -eq 0 ] && [ "$n" -ge 2 ]; then ok "always policy restarts clean exit"
else bad "always policy restarts clean exit" "exit $c, spawns $n"; fi

# 8. SIGTERM is forwarded to live workers
marker="$TMP/got_term"
"$MANDOR" "bash -c 'trap \"touch $marker; exit 0\" TERM; sleep 30 & wait \$!'" >"$TMP/8" 2>&1 &
mpid=$!
sleep 1
kill -TERM "$mpid" 2>/dev/null
wait "$mpid"; c=$?
if [ $c -eq 0 ] && [ -f "$marker" ]; then ok "TERM forwarded to workers"
else bad "TERM forwarded to workers" "exit $c, marker $([ -f "$marker" ] && echo yes || echo no)"; fi

# 9. worker output is captured and [name]-prefixed
timeout 10 "$MANDOR" "sh -c 'echo hello-out; echo oops >&2'" >"$TMP/9" 2>&1
if grep -q "^\[sh\] hello-out$" "$TMP/9" && grep -q "^\[sh\] oops$" "$TMP/9"; then
  ok "output captured with [name] prefix"
else bad "output captured with [name] prefix" "$(cat "$TMP/9" | head -5)"; fi

# 10. state file + report subcommand
export MANDOR_STATE_DIR="$TMP/state"
"$MANDOR" "sh -c 'sleep 7'" >"$TMP/10sup" 2>&1 &
mpid=$!
sleep 6
"$MANDOR" report >"$TMP/10rep" 2>&1; rc_h=$?
"$MANDOR" report --json >"$TMP/10json" 2>&1; rc_j=$?
kill -TERM "$mpid" 2>/dev/null; wait "$mpid" 2>/dev/null
if [ $rc_h -eq 0 ] && [ $rc_j -eq 0 ] && grep -q "^sh " "$TMP/10rep" && grep -q "\"v\":1" "$TMP/10json"; then
  ok "report human + json from state file"
else bad "report human + json" "rc_h=$rc_h rc_j=$rc_j $(head -3 "$TMP/10rep")"; fi
unset MANDOR_STATE_DIR

echo
echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
