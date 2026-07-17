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

# 11. crash with a go-style panic spools an incident bundle
cat > "$TMP/crash_go.sh" <<'CRASH'
echo "booting fine"
printf 'panic: runtime error: nil deref\n\ngoroutine 1 [running]:\nmain.crash(0x0)\n\t/app/main.go:10 +0x18\nmain.main()\n\t/app/main.go:4 +0x1c\n' >&2
exit 2
CRASH
export MANDOR_STATE_DIR="$TMP/state2"
timeout 10 "$MANDOR" "sh $TMP/crash_go.sh" >"$TMP/11" 2>&1
c=$?
f=$(ls "$TMP/state2/incidents/"*.json 2>/dev/null | head -1)
if [ $c -eq 2 ] && [ -n "$f" ] && grep -q '"v":5' "$f" \
   && grep -q '"kind":"exit"' "$f" && grep -q '"exit_code":2' "$f" \
   && grep -q '"cause_str":"exit:2"' "$f" \
   && grep -q '"lang":"go"' "$f" \
   && grep -q '"function":"main.crash","file":"/app/main.go","line":10,"in_app":true' "$f" \
   && grep -q '"type":"runtime error"' "$f" \
   && grep -q '"exe":"[^"]*/sh"' "$f" \
   && grep -q 'go panic in main.crash' "$f"; then
  ok "incident bundle v4: structured frames + exception + verdict"
else
  bad "incident bundle v4" "exit $c, file=$f: $(head -c 300 "$f" 2>/dev/null)"
fi
unset MANDOR_STATE_DIR

# 12. USR1 is forwarded (dumb-init parity)
marker_usr1="$TMP/got_usr1"
"$MANDOR" "bash -c 'trap \"touch $marker_usr1\" USR1; trap \"exit 0\" TERM; while true; do sleep 1; done'" >"$TMP/12" 2>&1 &
mpid=$!
sleep 1
kill -USR1 "$mpid"
sleep 1
kill -TERM "$mpid"
wait "$mpid"; c=$?
if [ $c -eq 0 ] && [ -f "$marker_usr1" ]; then ok "USR1 forwarded to workers"
else bad "USR1 forwarded" "exit $c, marker $([ -f "$marker_usr1" ] && echo yes || echo no)"; fi

# 13. signals reach grandchildren via process groups
m1="$TMP/gc_parent"; m2="$TMP/gc_child"
cat > "$TMP/gc.sh" <<GCEOF
(trap 'touch $m2; exit 0' TERM; sleep 30 & wait \$!) &
trap 'touch $m1; exit 0' TERM
sleep 30 & wait \$!
GCEOF
"$MANDOR" "bash $TMP/gc.sh" >"$TMP/13" 2>&1 &
mpid=$!
sleep 1
kill -TERM "$mpid"
wait "$mpid" 2>/dev/null
sleep 0.5
if [ -f "$m1" ] && [ -f "$m2" ]; then ok "TERM reaches grandchildren (process group)"
else bad "TERM reaches grandchildren" "parent=$([ -f $m1 ] && echo y || echo n) child=$([ -f $m2 ] && echo y || echo n)"; fi

# 14. mandor.toml supplies workers and policy; CLI still wins
cat > "$TMP/m.toml" <<'TOML'
restart = "never"
workers = [
  "sh -c 'exit 4'",
]
TOML
timeout 10 "$MANDOR" --config="$TMP/m.toml" >"$TMP/14" 2>&1
c=$?
if [ $c -eq 4 ] && [ "$(grep -c spawned "$TMP/14")" -eq 1 ]; then ok "config file supplies workers"
else bad "config file supplies workers" "exit $c: $(head -3 "$TMP/14")"; fi

# 15. metrics endpoint serves prometheus text
"$MANDOR" --metrics=19464 "sh -c 'sleep 6'" >"$TMP/15sup" 2>&1 &
mpid=$!
sleep 1
body=$(curl -s --max-time 3 http://127.0.0.1:19464/metrics 2>&1)
kill -TERM "$mpid" 2>/dev/null; wait "$mpid" 2>/dev/null
if echo "$body" | grep -q 'mandor_worker_up{worker="sh"} 1' && echo "$body" | grep -q 'mandor_incidents_total 0'; then
  ok "metrics endpoint serves prometheus text"
else bad "metrics endpoint" "$(echo "$body" | head -3)"; fi

# 15b. repeated log lines are compacted in the bundle
cat > "$TMP/spam.sh" <<'SPAM'
i=0
while [ $i -lt 50 ]; do
  echo "error: request $i timed out" >&2
  i=$((i+1))
done
echo "unique final message" >&2
exit 3
SPAM
export MANDOR_STATE_DIR="$TMP/state15b"
timeout 10 "$MANDOR" "sh $TMP/spam.sh" >"$TMP/15b" 2>&1
c=$?
f=$(ls "$TMP/state15b/incidents/"*.json 2>/dev/null | head -1)
reps=$(grep -o '"repeat":50' "$f" 2>/dev/null | head -1)
entries=$(grep -o '"line":' "$f" 2>/dev/null | wc -l)
if [ $c -eq 3 ] && [ "$reps" = '"repeat":50' ] && [ "$entries" -le 3 ]; then
  ok "log compaction: 51 lines -> $entries entries, repeat:50"
else bad "log compaction" "exit $c, entries=$entries, reps=[$reps]"; fi
unset MANDOR_STATE_DIR

# 16. --expected-exit: listed code behaves like success (exit 0, no incident)
export MANDOR_STATE_DIR="$TMP/state16"
timeout 10 "$MANDOR" --expected-exit=7 "sh -c 'exit 7'" >"$TMP/16" 2>&1
c=$?
n=$(ls "$TMP/state16/incidents/" 2>/dev/null | wc -l)
if [ $c -eq 0 ] && [ "$n" -eq 0 ]; then ok "expected-exit treated as clean"
else bad "expected-exit treated as clean" "exit $c, incidents $n"; fi
unset MANDOR_STATE_DIR

# 17. --stop-grace force-kills TERM-ignoring workers
start=$(date +%s)
"$MANDOR" --stop-grace=1s "bash -c 'trap \"\" TERM; sleep 30'" >"$TMP/17" 2>&1 &
mpid=$!
sleep 1
kill -TERM "$mpid"
wait "$mpid"; c=$?
took=$(( $(date +%s) - start ))
if [ $c -eq 137 ] && [ "$took" -le 6 ] && grep -q "stop-grace expired" "$TMP/17"; then
  ok "stop-grace escalates to SIGKILL"
else bad "stop-grace escalates" "exit $c after ${took}s: $(tail -2 "$TMP/17")"; fi

# 18. readiness fd: worker announces, mandor logs it
"$MANDOR" --ready-fd=5 "bash -c 'sleep 0.3; echo up >&5; sleep 30'" >"$TMP/18" 2>&1 &
mpid=$!
sleep 1.5
kill -TERM "$mpid"; wait "$mpid" 2>/dev/null
if grep -q "is ready" "$TMP/18"; then ok "readiness fd observed"
else bad "readiness fd" "$(head -4 "$TMP/18")"; fi

# 19. health checks: failing probe -> unhealthy incident with worker alive
export MANDOR_STATE_DIR="$TMP/state19"
"$MANDOR" --health='sleep=/bin/false' --health-interval=1s --health-start-period=0s "sleep 30" >"$TMP/19" 2>&1 &
mpid=$!
sleep 6
f=$(ls "$TMP/state19/incidents/"*.json 2>/dev/null | head -1)
kill -TERM "$mpid"; wait "$mpid" 2>/dev/null
if [ -n "$f" ] && grep -q '"kind":"unhealthy"' "$f" && grep -q 'alive but unhealthy' "$f" \
   && grep -q '"ready":false' "$f"; then
  ok "failing health probe spools unhealthy incident"
else bad "health probe incident" "file=$f $(head -c 200 "$f" 2>/dev/null) log: $(tail -3 "$TMP/19")"; fi
unset MANDOR_STATE_DIR

# 20. incident history survives supervisor restarts; report --incidents recalls it
export MANDOR_STATE_DIR="$TMP/state20"
timeout 10 "$MANDOR" "sh -c 'exit 3'" >/dev/null 2>&1
timeout 10 "$MANDOR" "sh -c 'kill -SEGV \$\$'" >/dev/null 2>&1
"$MANDOR" report --incidents >"$TMP/20" 2>&1
if grep -q "2 incident(s)" "$TMP/20" && grep -q "exit:3" "$TMP/20" && grep -q "signal:SIGSEGV" "$TMP/20"; then
  ok "incident history recall across restarts"
else bad "incident history recall" "$(cat "$TMP/20" | head -5)"; fi
# same crash again in a THIRD supervisor run: persistent count reaches 2
timeout 10 "$MANDOR" "sh -c 'exit 3'" >/dev/null 2>&1
newest=$(ls "$TMP/state20/incidents/"*.json | sort | tail -1)
if grep -q '"count":2' "$newest"; then ok "recurrence count survives supervisor restarts"
else bad "recurrence count persistence" "$(grep -o "\"history\":[^}]*}" "$newest")"; fi
unset MANDOR_STATE_DIR

# 21. start_after defers the dependent until the dependency is up
cat > "$TMP/order.toml" <<'TOML'
workers = [
  "bash -c 'sleep 2'",
  "sh -c 'echo B-run; sleep 1'",
]
start_after = ["sh=bash"]
TOML
timeout 15 "$MANDOR" --config="$TMP/order.toml" >"$TMP/21" 2>&1
c=$?
waits=$(grep -n "sh waits for bash" "$TMP/21" | head -1 | cut -d: -f1)
spawn_b=$(grep -n "spawned sh" "$TMP/21" | head -1 | cut -d: -f1)
if [ $c -eq 0 ] && [ -n "$waits" ] && [ -n "$spawn_b" ] && [ "$spawn_b" -gt "$waits" ]; then
  ok "start_after defers dependent start"
else bad "start_after ordering" "exit $c: $(head -6 "$TMP/21")"; fi

# 22. --max-restarts gives up with the worker's exit code
timeout 15 "$MANDOR" --restart=always --max-restarts=2 "sh -c 'exit 5'" >"$TMP/22" 2>&1
c=$?
n=$(grep -c "spawned" "$TMP/22")
if [ $c -eq 5 ] && [ "$n" -eq 3 ] && grep -q "giving up" "$TMP/22"; then
  ok "max-restarts gives up visibly (exit 5 after 3 spawns)"
else bad "max-restarts give-up" "exit $c, spawns $n"; fi

# 23. on-incident hook fires with the bundle path
cat > "$TMP/hook.sh" <<'HOOK'
echo "$1" >> "${HOOK_OUT:-/tmp/hook-out}"
HOOK
chmod +x "$TMP/hook.sh"
export MANDOR_STATE_DIR="$TMP/state23" HOOK_OUT="$TMP/hook-fired"
timeout 10 "$MANDOR" --on-incident="sh $TMP/hook.sh" "sh -c 'exit 4'" >"$TMP/23" 2>&1
sleep 0.5
if [ -f "$TMP/hook-fired" ] && grep -q "state23/incidents/.*\.json" "$TMP/hook-fired" \
   && [ -f "$(cat "$TMP/hook-fired" | head -1)" ]; then
  ok "on-incident hook receives bundle path"
else bad "on-incident hook" "$(cat "$TMP/hook-fired" 2>/dev/null)"; fi
unset MANDOR_STATE_DIR HOOK_OUT

# 24. health start-period: early failures don't count
"$MANDOR" --health='sleep=/bin/false' --health-interval=1s --health-start-period=1m "sleep 30" >"$TMP/24" 2>&1 &
mpid=$!
sleep 5
kill -TERM "$mpid"; wait "$mpid" 2>/dev/null
if ! grep -q "health check failed" "$TMP/24"; then ok "start-period grace suppresses early probe failures"
else bad "start-period grace" "$(grep "health check" "$TMP/24" | head -2)"; fi

# 25. per-worker env + cwd from TOML
cat > "$TMP/ec.toml" <<'TOML'
workers = ["sh -c 'echo got=$FOO at=$PWD'"]
env = ["sh=FOO=bar"]
cwd = ["sh=/tmp"]
TOML
timeout 10 "$MANDOR" --config="$TMP/ec.toml" >"$TMP/25" 2>&1
if grep -q "got=bar at=/tmp" "$TMP/25"; then ok "per-worker env and cwd applied"
else bad "per-worker env/cwd" "$(grep got= "$TMP/25")"; fi

# 26. oneshot completes before workers start
cat > "$TMP/os.toml" <<'TOML'
workers = [
  "sh -c 'echo migrate-done'",
  "sh -c 'echo app-run'",
]
oneshot = ["sh"]
TOML
timeout 10 "$MANDOR" --config="$TMP/os.toml" >"$TMP/26" 2>&1
c=$?
mig=$(grep -n "migrate-done" "$TMP/26" | head -1 | cut -d: -f1)
app=$(grep -n "spawned sh-2" "$TMP/26" | head -1 | cut -d: -f1)
if [ $c -eq 0 ] && [ -n "$mig" ] && [ -n "$app" ] && [ "$app" -gt "$mig" ]; then
  ok "oneshot gates worker start"
else bad "oneshot ordering" "exit $c mig=$mig app=$app: $(head -6 "$TMP/26")"; fi

# 27. failed oneshot aborts startup with its code
cat > "$TMP/osf.toml" <<'TOML'
workers = [
  "sh -c 'exit 7'",
  "sleep 30",
]
oneshot = ["sh"]
TOML
timeout 10 "$MANDOR" --config="$TMP/osf.toml" >"$TMP/27" 2>&1
c=$?
if [ $c -eq 7 ] && ! grep -q "spawned sleep" "$TMP/27" && grep -q "init task sh failed" "$TMP/27"; then
  ok "failed oneshot aborts with its exit code"
else bad "failed oneshot abort" "exit $c: $(head -5 "$TMP/27")"; fi

# 28. per-worker privilege drop (root only — runs in CI containers)
if [ "$(id -u)" -eq 0 ]; then
  cat > "$TMP/u.toml" <<'TOML'
workers = ["sh -c 'id -u; id -g'"]
user = ["sh=12345:12345"]
TOML
  timeout 10 "$MANDOR" --config="$TMP/u.toml" >"$TMP/28" 2>&1
  if grep -q "^\[sh\] 12345$" "$TMP/28" && [ "$(grep -c '\[sh\] 12345' "$TMP/28")" -eq 2 ]; then
    ok "privilege drop to uid:gid"
  else bad "privilege drop" "$(grep '\[sh\]' "$TMP/28")"; fi
else
  echo "skip privilege drop (not root)"
fi

# 29. oom_score_adj applied (positive values need no privileges)
cat > "$TMP/oom.toml" <<'TOML'
workers = ["sh -c 'cat /proc/self/oom_score_adj'"]
oom_score_adj = ["sh=500"]
TOML
timeout 10 "$MANDOR" --config="$TMP/oom.toml" >"$TMP/29" 2>&1
if grep -q "^\[sh\] 500$" "$TMP/29"; then ok "oom_score_adj applied to worker"
else bad "oom_score_adj" "$(grep '\[sh\]' "$TMP/29")"; fi

# 30. dead worker's grandchildren are swept (no strays across restarts)
timeout 10 "$MANDOR" "bash -c 'sleep 30 & echo BGPID=\$!; exit 0'" >"$TMP/30" 2>&1
bg=$(grep -o "BGPID=[0-9]*" "$TMP/30" | cut -d= -f2)
sleep 0.5
if [ -n "$bg" ] && ! kill -0 "$bg" 2>/dev/null; then ok "grandchildren swept on worker death"
else bad "grandchild sweep" "bg=$bg still=$(kill -0 "$bg" 2>/dev/null && echo alive)"; fi

# 31. workers die if the supervisor is SIGKILLed (PDEATHSIG, non-PID-1 safety)
"$MANDOR" "sleep 30" >"$TMP/31" 2>&1 &
mpid=$!
sleep 1
wpid=$(grep -o "spawned sleep (pid [0-9]*)" "$TMP/31" | grep -o "[0-9]*")
kill -9 "$mpid" 2>/dev/null; wait "$mpid" 2>/dev/null
sleep 0.5
if [ -n "$wpid" ] && ! kill -0 "$wpid" 2>/dev/null; then ok "PDEATHSIG kills workers when supervisor dies"
else bad "PDEATHSIG" "wpid=$wpid $(kill -0 "$wpid" 2>/dev/null && echo alive)"; kill "$wpid" 2>/dev/null; fi

echo
echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
