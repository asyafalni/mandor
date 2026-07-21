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

# Poll up to ~5s for a pid to disappear (lifecycle assertions are eventual,
# not instantaneous — a fixed sleep races under a loaded CI runner).
wait_dead() { local pid=$1 i=0; while kill -0 "$pid" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done; ! kill -0 "$pid" 2>/dev/null; }

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

# 5. default (max_restarts=0): one spawn, failure ends the run
timeout 10 "$MANDOR" "sh -c 'exit 1'" >"$TMP/5" 2>&1
c=$?; n=$(grep -c "spawned" "$TMP/5")
if [ $c -eq 1 ] && [ "$n" -eq 1 ] && grep -q "sh failed, stopping all" "$TMP/5"; then
  ok "default: one spawn, failure ends the run (exit 1)"
else bad "default no-retry" "exit $c, spawns $n"; fi

# 6. max-restarts=-1 retries forever with growing backoff; TERM stops it
"$MANDOR" --max-restarts=-1 "sh -c 'exit 1'" >"$TMP/6" 2>&1 &
mpid=$!
sleep 2
kill -TERM "$mpid" 2>/dev/null
wait "$mpid"; c=$?
n=$(grep -c "spawned" "$TMP/6")
delays=$(grep -o "in [0-9]*ms" "$TMP/6" | head -2 | tr -d "inms " | paste -sd,)
if [ $c -eq 1 ] && [ "$n" -ge 3 ] && [ "$delays" = "200,400" ]; then
  ok "max-restarts=-1: retries with 200/400ms backoff, TERM stops"
else
  bad "infinite retry + backoff" "exit $c, spawns $n, delays [$delays]"
fi

# 7. a CLEAN exit is never retried, even with unlimited retries: exiting 0
# means the worker finished, not that it failed.
timeout 10 "$MANDOR" --max-restarts=-1 "sh -c 'exit 0'" >"$TMP/7" 2>&1
c=$?; n=$(grep -c "spawned" "$TMP/7")
if [ $c -eq 0 ] && [ "$n" -eq 1 ]; then ok "clean exit is never retried"
else bad "clean exit is never retried" "exit $c, spawns $n"; fi

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
if [ $c -eq 2 ] && [ -n "$f" ] && grep -q '"v":7' "$f" \
   && grep -q '"kind":"exit"' "$f" && grep -q '"exit_code":2' "$f" \
   && grep -q '"cause_str":"exit:2"' "$f" \
   && grep -q '"lang":"go"' "$f" \
   && grep -q '"function":"main.crash","file":"/app/main.go","line":10,"in_app":true' "$f" \
   && grep -q '"type":"runtime error"' "$f" \
   && grep -q '"exe":"[^"]*/sh"' "$f" \
   && grep -q 'go panic in main.crash' "$f"; then
  ok "incident bundle v7: structured frames + exception + verdict"
else
  bad "incident bundle v7" "exit $c, file=$f: $(head -c 300 "$f" 2>/dev/null)"
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
cat > "$TMP/ee.toml" <<'TOML'
expected_exit = "7"
workers = ["sh -c 'exit 7'"]
TOML
timeout 10 "$MANDOR" --config="$TMP/ee.toml" >"$TMP/16" 2>&1
c=$?
n=$(ls "$TMP/state16/incidents/" 2>/dev/null | wc -l)
if [ $c -eq 0 ] && [ "$n" -eq 0 ]; then ok "expected-exit treated as clean"
else bad "expected-exit treated as clean" "exit $c, incidents $n"; fi
unset MANDOR_STATE_DIR

# 17. --stop-grace force-kills TERM-ignoring workers
start=$(date +%s)
# A script file, not an inline command: mandor's TOML strings are not
# unescaped, so a literal `"` cannot appear inside one.
printf '#!/bin/bash\ntrap "" TERM\nsleep 30\n' > "$TMP/ignoreterm"
chmod +x "$TMP/ignoreterm"
cat > "$TMP/sg.toml" <<TOML
stop_grace = "1s"
workers = ["$TMP/ignoreterm"]
TOML
"$MANDOR" --config="$TMP/sg.toml" >"$TMP/17" 2>&1 &
mpid=$!
sleep 1
kill -TERM "$mpid"
wait "$mpid"; c=$?
took=$(( $(date +%s) - start ))
if [ $c -eq 137 ] && [ "$took" -le 6 ] && grep -q "stop-grace expired" "$TMP/17"; then
  ok "stop-grace escalates to SIGKILL"
else bad "stop-grace escalates" "exit $c after ${took}s: $(tail -2 "$TMP/17")"; fi

# 18. readiness fd: worker announces, mandor logs it
cat > "$TMP/rf.toml" <<'TOML'
ready_fd = 5
workers = ["bash -c 'sleep 0.3; echo up >&5; sleep 30'"]
TOML
"$MANDOR" --config="$TMP/rf.toml" >"$TMP/18" 2>&1 &
mpid=$!
sleep 1.5
kill -TERM "$mpid"; wait "$mpid" 2>/dev/null
if grep -q "is ready" "$TMP/18"; then ok "readiness fd observed"
else bad "readiness fd" "$(head -4 "$TMP/18")"; fi

# 19. health checks: failing probe -> unhealthy incident with worker alive
export MANDOR_STATE_DIR="$TMP/state19"
cat > "$TMP/hp.toml" <<'TOML'
health_interval = "1s"
health_start_period = "0s"
workers = ["sleep 30"]
[worker.sleep]
health = "/bin/false"
TOML
"$MANDOR" --config="$TMP/hp.toml" >"$TMP/19" 2>&1 &
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

# 20c. release correlation: the same crash across two builds is a regression
export MANDOR_STATE_DIR="$TMP/state20c"
MANDOR_RELEASE=v1.0.0 timeout 10 "$MANDOR" "sh -c 'exit 4'" >/dev/null 2>&1
MANDOR_RELEASE=v1.0.1 timeout 10 "$MANDOR" "sh -c 'exit 4'" >/dev/null 2>&1
newest=$(ls "$TMP/state20c/incidents/"*.json | sort | tail -1)
"$MANDOR" report --incidents >"$TMP/20c" 2>&1
if grep -q '"regressed":true' "$newest" && grep -q '"first_build":"v1.0.0"' "$newest" \
   && grep -q '"last_build":"v1.0.1"' "$newest" && grep -q 'REGRESSED v1.0.0->v1.0.1' "$TMP/20c"; then
  ok "release correlation flags regression across builds"
else bad "release correlation" "bundle=$(grep -o "\"history\":[^}]*}" "$newest") report=$(grep -o 'REGRESSED[^]]*' "$TMP/20c")"; fi
unset MANDOR_STATE_DIR MANDOR_RELEASE

# 21. start_after defers the dependent until the dependency is up
cat > "$TMP/order.toml" <<'TOML'
workers = [
  "bash -c 'sleep 2'",
  "sh -c 'echo B-run; sleep 1'",
]
[worker.sh]
start_after = "bash"
TOML
timeout 15 "$MANDOR" --config="$TMP/order.toml" >"$TMP/21" 2>&1
c=$?
waits=$(grep -n "sh waits for bash" "$TMP/21" | head -1 | cut -d: -f1)
spawn_b=$(grep -n "spawned sh" "$TMP/21" | head -1 | cut -d: -f1)
if [ $c -eq 0 ] && [ -n "$waits" ] && [ -n "$spawn_b" ] && [ "$spawn_b" -gt "$waits" ]; then
  ok "start_after defers dependent start"
else bad "start_after ordering" "exit $c: $(head -6 "$TMP/21")"; fi

# 22. --max-restarts gives up with the worker's exit code
timeout 15 "$MANDOR" --max-restarts=2 "sh -c 'exit 5'" >"$TMP/22" 2>&1
c=$?
n=$(grep -c "spawned" "$TMP/22")
if [ $c -eq 5 ] && [ "$n" -eq 3 ] && grep -q "failed 2 restart(s), stopping all" "$TMP/22"; then
  ok "max-restarts gives up visibly (exit 5 after 3 spawns)"
else bad "max-restarts give-up" "exit $c, spawns $n: $(grep stopping "$TMP/22" | head -1)"; fi

# 23. on-incident hook fires with the bundle path
cat > "$TMP/hook.sh" <<'HOOK'
echo "$1" >> "${HOOK_OUT:-/tmp/hook-out}"
HOOK
chmod +x "$TMP/hook.sh"
export MANDOR_STATE_DIR="$TMP/state23" HOOK_OUT="$TMP/hook-fired"
cat > "$TMP/oi.toml" <<TOML
on_incident = "sh $TMP/hook.sh"
workers = ["sh -c 'exit 4'"]
TOML
timeout 10 "$MANDOR" --config="$TMP/oi.toml" >"$TMP/23" 2>&1
sleep 0.5
if [ -f "$TMP/hook-fired" ] && grep -q "state23/incidents/.*\.json" "$TMP/hook-fired" \
   && [ -f "$(cat "$TMP/hook-fired" | head -1)" ]; then
  ok "on-incident hook receives bundle path"
else bad "on-incident hook" "$(cat "$TMP/hook-fired" 2>/dev/null)"; fi
unset MANDOR_STATE_DIR HOOK_OUT

# 24. health start-period: early failures don't count
cat > "$TMP/hs.toml" <<'TOML'
health_interval = "1s"
health_start_period = "1m"
workers = ["sleep 30"]
[worker.sleep]
health = "/bin/false"
TOML
"$MANDOR" --config="$TMP/hs.toml" >"$TMP/24" 2>&1 &
mpid=$!
sleep 5
kill -TERM "$mpid"; wait "$mpid" 2>/dev/null
if ! grep -q "health check failed" "$TMP/24"; then ok "start-period grace suppresses early probe failures"
else bad "start-period grace" "$(grep "health check" "$TMP/24" | head -2)"; fi

# 25. per-worker env + cwd from TOML
cat > "$TMP/ec.toml" <<'TOML'
workers = ["sh -c 'echo got=$FOO at=$PWD'"]
[worker.sh]
env = ["FOO=bar"]
cwd = "/tmp"
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
[worker.sh]
oneshot = true
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
[worker.sh]
oneshot = true
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
[worker.sh]
user = "12345:12345"
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
[worker.sh]
oom_score_adj = 500
TOML
timeout 10 "$MANDOR" --config="$TMP/oom.toml" >"$TMP/29" 2>&1
if grep -q "^\[sh\] 500$" "$TMP/29"; then ok "oom_score_adj applied to worker"
else bad "oom_score_adj" "$(grep '\[sh\]' "$TMP/29")"; fi

# 30. dead worker's grandchildren are swept (no strays across restarts)
timeout 10 "$MANDOR" "bash -c 'sleep 30 & echo BGPID=\$!; exit 0'" >"$TMP/30" 2>&1
bg=$(grep -o "BGPID=[0-9]*" "$TMP/30" | cut -d= -f2)
if [ -n "$bg" ] && wait_dead "$bg"; then ok "grandchildren swept on worker death"
else bad "grandchild sweep" "bg=$bg still=$(kill -0 "$bg" 2>/dev/null && echo alive)"; fi

# 31. workers die if the supervisor is SIGKILLed (PDEATHSIG, non-PID-1 safety)
"$MANDOR" "sleep 30" >"$TMP/31" 2>&1 &
mpid=$!
sleep 1
wpid=$(grep -o "spawned sleep (pid [0-9]*)" "$TMP/31" | grep -o "[0-9]*")
kill -9 "$mpid" 2>/dev/null; wait "$mpid" 2>/dev/null
if [ -n "$wpid" ] && wait_dead "$wpid"; then ok "PDEATHSIG kills workers when supervisor dies"
else bad "PDEATHSIG" "wpid=$wpid $(kill -0 "$wpid" 2>/dev/null && echo alive)"; kill "$wpid" 2>/dev/null; fi

# 32. max_lifetime recycles the worker (planned, not a failure)
cat > "$TMP/rec.toml" <<'TOML'
workers = ["sleep 30"]
[worker.sleep]
max_lifetime = "1s"
TOML
"$MANDOR" --config="$TMP/rec.toml" >"$TMP/32" 2>&1 &
mpid=$!
sleep 8
kill -TERM "$mpid"; wait "$mpid" 2>/dev/null
n=$(grep -c "spawned sleep" "$TMP/32")
if grep -q "recycling sleep: max lifetime" "$TMP/32" && [ "$n" -ge 2 ]; then
  ok "max_lifetime recycles worker ($n spawns)"
else bad "recycle" "spawns=$n $(grep recycl "$TMP/32" | head -1)"; fi

# 33. per-worker expected_exit: a non-zero code declared successful for one
# worker must not end the run (and must not apply to the others)
cat > "$TMP/ov.toml" <<'TOML'
workers = ["sh -c 'exit 2'", "sleep 3"]
[worker.sh]
expected_exit = "2"
TOML
timeout 15 "$MANDOR" --config="$TMP/ov.toml" >"$TMP/33" 2>&1
c=$?
# exit 2 is declared success for sh, so the run continues to sleep's end.
if [ $c -eq 0 ] && ! grep -q "failed, stopping all" "$TMP/33"; then
  ok "per-worker expected_exit keeps a non-zero exit from ending the run"
else bad "per-worker expected_exit" "exit $c: $(grep -E 'stopping|exited' "$TMP/33" | head -2)"; fi

# 33b. and it must NOT leak to other workers: the same code from a worker
# without the override still ends the run.
cat > "$TMP/ov2.toml" <<'TOML'
workers = ["sleep 3", "sh -c 'exit 2'"]
[worker.sleep]
expected_exit = "2"
TOML
timeout 15 "$MANDOR" --config="$TMP/ov2.toml" >"$TMP/33b" 2>&1
c=$?
if [ $c -eq 2 ] && grep -q "sh failed, stopping all" "$TMP/33b"; then
  ok "per-worker expected_exit does not leak to other workers"
else bad "expected_exit scoping" "exit $c: $(grep -E 'stopping' "$TMP/33b" | head -1)"; fi

# 34. termination-log death rattle (root only — CI containers)
if [ "$(id -u)" -eq 0 ]; then
  touch /dev/termination-log
  export MANDOR_STATE_DIR="$TMP/state34"
  timeout 10 "$MANDOR" "sh -c 'exit 3'" >/dev/null 2>&1
  if grep -q "mandor: sh exit:3" /dev/termination-log; then ok "termination-log written"
  else bad "termination-log" "$(cat /dev/termination-log)"; fi
  rm -f /dev/termination-log; unset MANDOR_STATE_DIR
else
  echo "skip termination-log (not root)"
fi

# 35. env_file loads globals into every worker
printf "# comment\nFOO=from-envfile\n" > "$TMP/app.env"
cat > "$TMP/ef.toml" <<TOML
workers = ["sh -c 'echo got=\$FOO'"]
env_file = "$TMP/app.env"
TOML
timeout 10 "$MANDOR" --config="$TMP/ef.toml" >"$TMP/35" 2>&1
if grep -q "got=from-envfile" "$TMP/35"; then ok "env_file applied"
else bad "env_file" "$(grep got= "$TMP/35")"; fi

# 36. essential worker exit stops the fleet with its code
cat > "$TMP/es.toml" <<'TOML'
workers = [
  "sh -c 'sleep 0.5; exit 6'",
  "sleep 30",
]
TOML
start=$(date +%s)
timeout 15 "$MANDOR" --config="$TMP/es.toml" >"$TMP/36" 2>&1
c=$?; took=$(( $(date +%s) - start ))
if [ $c -eq 6 ] && [ "$took" -le 5 ] && grep -q "sh failed, stopping all" "$TMP/36"; then
  ok "essential-by-default: a failure stops the fleet (exit 6 in ${took}s)"
else bad "essential" "exit $c after ${took}s: $(tail -2 "$TMP/36")"; fi

# 37. TTY color prefixes (needs util-linux script to fake a tty)
if command -v script >/dev/null 2>&1; then
  script -qec "\"$MANDOR\" \"sh -c 'echo colored'\"" /dev/null >"$TMP/37" 2>&1
  if grep -q $'\x1b\[3[1-6]m\[sh\]' "$TMP/37"; then ok "TTY color prefixes"
  else bad "TTY colors" "$(head -c 120 "$TMP/37" | od -c | head -2)"; fi
else
  echo "skip TTY colors (no script cmd)"
fi

# 38. restart_dependents: dependency restart recycles the dependent
cat > "$TMP/rd.toml" <<'TOML'
max_restarts = -1
restart_dependents = true
backoff_max = "300ms"
workers = [
  "sh -c 'sleep 1; exit 1'",
  "sleep 30",
]
[worker.sleep]
start_after = "sh"
TOML
"$MANDOR" --config="$TMP/rd.toml" >"$TMP/38" 2>&1 &
mpid=$!
sleep 5
kill -TERM "$mpid"; wait "$mpid" 2>/dev/null
if grep -q "restarting sleep with its dependency sh" "$TMP/38" \
   && [ "$(grep -c 'spawned sleep' "$TMP/38")" -ge 2 ]; then
  ok "restart_dependents recycles dependents"
else bad "restart_dependents" "$(grep -E 'restarting|spawned sleep' "$TMP/38" | head -4)"; fi

# 39. pre_stop runs before TERM on graceful shutdown
m="$TMP/drained"
cat > "$TMP/ps.toml" <<TOML
workers = ["bash -c 'trap exit TERM; while true; do sleep 1; done'"]
expected_exit = "143"
[worker.bash]
pre_stop = "sh -c 'sleep 0.3; touch $m'"
TOML
"$MANDOR" --config="$TMP/ps.toml" >"$TMP/39" 2>&1 &
mpid=$!
sleep 1
kill -TERM "$mpid"; wait "$mpid"; c=$?
if [ $c -eq 0 ] && [ -f "$m" ] && grep -q "running pre_stop for bash" "$TMP/39"; then
  ok "pre_stop drains before TERM"
else bad "pre_stop" "exit $c marker=$([ -f $m ] && echo y || echo n): $(tail -2 "$TMP/39")"; fi

# 40. validate: clean config passes, typo'd worker reference fails
printf "workers=[\"sh -c true\"]\n" > "$TMP/v-ok.toml"
"$MANDOR" validate --config="$TMP/v-ok.toml" >/dev/null 2>&1
[ $? -eq 0 ] && ok "validate accepts a sound config" || bad "validate ok" "rc=$?"
printf "workers=[\"sh -c true\"]\nhealth=[\"nope=/bin/true\"]\n" > "$TMP/v-bad.toml"
"$MANDOR" validate --config="$TMP/v-bad.toml" >/dev/null 2>&1
[ $? -ne 0 ] && ok "validate rejects unknown worker reference" || bad "validate typo" "rc=0"

# 41. report --incident=N dumps one bundle as raw JSON
export MANDOR_STATE_DIR="$TMP/state41"
timeout 10 "$MANDOR" "sh -c 'exit 3'" >/dev/null 2>&1
"$MANDOR" report --incident=1 >"$TMP/41" 2>&1
if head -c1 "$TMP/41" | grep -q '{' && grep -q '"cause_str":"exit:3"' "$TMP/41"; then
  ok "report --incident=N dumps raw bundle"
else bad "report --incident" "$(head -c80 "$TMP/41")"; fi
"$MANDOR" report --incident=99 >/dev/null 2>&1
[ $? -ne 0 ] && ok "report --incident rejects out-of-range" || bad "incident range" "rc=0"
unset MANDOR_STATE_DIR

# 44. cap_drop + no_new_privs: worker cannot regain privs (root only)
if [ "$(id -u)" -eq 0 ]; then
  cat > "$TMP/cap.toml" <<'TOML'
workers = ["sh -c 'cat /proc/self/status | grep NoNewPrivs'"]
[worker.sh]
user = "12345:12345"
cap_drop = ["sh=all"]
TOML
  timeout 10 "$MANDOR" --config="$TMP/cap.toml" >"$TMP/44" 2>&1
  if grep -q "NoNewPrivs:.*1" "$TMP/44"; then ok "no_new_privs set after user+cap_drop"
  else bad "no_new_privs" "$(grep NoNewPrivs "$TMP/44")"; fi
else
  echo "skip cap_drop/no_new_privs (not root)"
fi

# 45. PSI fields present in the incident bundle stats timeline (schema v7).
# Worker lives past the first 5s sample so stats_timeline is populated.
export MANDOR_STATE_DIR="$TMP/state45"
timeout 12 "$MANDOR" "sh -c 'sleep 6; exit 3'" >/dev/null 2>&1
f=$(ls "$TMP/state45/incidents/"*.json 2>/dev/null | head -1)
if [ -n "$f" ] && grep -q '"v":7' "$f" && grep -q '"psi_mem"' "$f" && grep -q '"core":' "$f"; then
  ok "bundle v7 carries psi_mem + limits.core"
else bad "psi/core in bundle" "$(head -c 200 "$f" 2>/dev/null)"; fi
unset MANDOR_STATE_DIR

# 46. cost report: a worker sampled over time yields a cost profile.
# cost.json flushes on shutdown (or the 30s tick), so query after graceful stop.
export MANDOR_STATE_DIR="$TMP/state46"
"$MANDOR" "sh -c 'sleep 30'" >/dev/null 2>&1 &
mpid=$!
sleep 7    # >1 sample tick (5s) so the profile has a sample
kill -TERM "$mpid" 2>/dev/null; wait "$mpid" 2>/dev/null
"$MANDOR" report --cost >"$TMP/46" 2>&1; rc=$?
if [ $rc -eq 0 ] && grep -q "^sh " "$TMP/46" && grep -q "right-sizing suggestions" "$TMP/46" \
   && grep -q '"core_ms"' "$TMP/state46/cost.json"; then
  ok "cost report renders profile + suggestions"
else bad "cost report" "rc=$rc: $(head -4 "$TMP/46") | json=$(head -c 80 "$TMP/state46/cost.json" 2>/dev/null)"; fi

# 47. cost profile accumulates across supervisor restarts (idle sleeper)
"$MANDOR" "sh -c 'sleep 30'" >/dev/null 2>&1 &
mpid=$!; sleep 7; kill -TERM "$mpid" 2>/dev/null; wait "$mpid" 2>/dev/null
n2=$("$MANDOR" report --cost --json 2>/dev/null | grep -o '"idle_n":[0-9]*' | head -1 | grep -o '[0-9]*$')
if [ -n "$n2" ] && [ "$n2" -ge 2 ]; then ok "cost profile persists across restarts (idle_n=$n2)"
else bad "cost persistence" "idle_n=$n2"; fi
unset MANDOR_STATE_DIR

# 48. shift-report digest is emitted at shutdown (whole-run summary)
export MANDOR_STATE_DIR="$TMP/state48"
out=$(timeout 10 "$MANDOR" "sh -c 'exit 0'" "sh -c 'exit 2'" 2>&1)
if echo "$out" | grep -q "shift report — 2 worker(s)" \
   && echo "$out" | grep -qE "exit 2, 0 restart\(s\)"; then
  ok "shift report digest at shutdown"
else bad "shift report digest" "$(echo "$out" | tail -4)"; fi
unset MANDOR_STATE_DIR

# 49. corrupt state files must not stop the supervisor. These are the
# real-world form of the overflow traps fixed in 1.0.1/1.0.2: mandor's own
# persisted state is untrusted input, and it is read on the startup path.
export MANDOR_STATE_DIR="$TMP/state49"
mkdir -p "$MANDOR_STATE_DIR"
printf '{"v":2,"entries":[{"sig":"ffffffffffffffff","first":18446744073709551615,"last":18446744073709551615,"count":18446744073709551615,"builds":4294967295,"fb":"x","lb":"y"}]}' \
  >"$MANDOR_STATE_DIR/history.json"
printf '{"v":1,"workers":[{"name":"sh","idle_n":4294967295,"active_n":4294967295,"core_ms":18446744073709551615,"rss_kb_ms":18446744073709551615,"peak_rss_kb":18446744073709551615,"rss_idle":[4294967295,4294967295],"cpu_active":[4294967295]}]}' \
  >"$MANDOR_STATE_DIR/cost.json"
out=$(timeout 20 "$MANDOR" "sh -c 'exit 3'" 2>&1); c=$?
if [ $c -eq 3 ] && echo "$out" | grep -q "shift report"; then
  ok "corrupt history/cost state files do not kill the supervisor"
else bad "corrupt state files" "exit $c: $(echo "$out" | tail -3)"; fi

# 50. and `report` must survive reading them back
if timeout 10 "$MANDOR" report --cost >"$TMP/50" 2>&1 && timeout 10 "$MANDOR" report --incidents >>"$TMP/50" 2>&1; then
  ok "report survives corrupt state files"
else bad "report survives corrupt state files" "$(tail -3 "$TMP/50")"; fi

# 51. truncated / garbage state files (partial write, disk full)
printf '{"v":2,"entries":[{"sig":"ff' >"$MANDOR_STATE_DIR/history.json"
head -c 300 /dev/urandom >"$MANDOR_STATE_DIR/cost.json"
timeout 20 "$MANDOR" "sh -c 'exit 5'" >"$TMP/51" 2>&1; c=$?
if [ $c -eq 5 ]; then ok "truncated/garbage state files tolerated"
else bad "truncated state files" "exit $c: $(tail -3 "$TMP/51")"; fi
unset MANDOR_STATE_DIR

# 52. an unwritable state dir must degrade, not abort: supervision outranks
# bookkeeping (PID 1 must not die because a volume is read-only).
export MANDOR_STATE_DIR="$TMP/state52"
mkdir -p "$MANDOR_STATE_DIR"; chmod 500 "$MANDOR_STATE_DIR"
timeout 20 "$MANDOR" "sh -c 'exit 4'" >"$TMP/52" 2>&1; c=$?
chmod 700 "$MANDOR_STATE_DIR"
if [ $c -eq 4 ]; then ok "read-only state dir degrades without aborting"
else bad "read-only state dir" "exit $c: $(tail -3 "$TMP/52")"; fi
unset MANDOR_STATE_DIR

# 53/54. worker-table boundary: the table is a fixed [64], so exactly-full
# must work and one-over must be rejected cleanly rather than overrun it.
export MANDOR_STATE_DIR="$TMP/state53"
args=(); for _ in $(seq 1 64); do args+=("sh -c 'exit 0'"); done
timeout 60 "$MANDOR" "${args[@]}" >"$TMP/53" 2>&1; c=$?
n=$(grep -c "spawned" "$TMP/53")
if [ $c -eq 0 ] && [ "$n" -eq 64 ]; then ok "64 workers (table exactly full) supervise cleanly"
else bad "64 workers" "exit $c, spawns $n"; fi

args+=("sh -c 'exit 0'")   # 65th
timeout 30 "$MANDOR" "${args[@]}" >"$TMP/54" 2>&1; c=$?
if [ $c -ne 0 ] && [ $c -ne 139 ] && grep -qi "worker" "$TMP/54"; then
  ok "65 workers rejected cleanly (no overrun)"
else bad "65 workers rejected" "exit $c: $(head -2 "$TMP/54")"; fi
unset MANDOR_STATE_DIR

# 55. a health-kill is a failure whatever code the worker reports. Without
# this, expected_exit="143" (the usual graceful-shutdown code) turned a hung
# worker into a successful run — mandor detected the hang and reported success.
cat > "$TMP/hk.toml" <<'TOML'
workers = ["sh -c 'trap \"exit 143\" TERM; while true; do sleep 0.2; done'"]
expected_exit = "143"
health_interval = "1s"
health_start_period = "1s"
[worker.sh]
health = "/bin/false"
TOML
timeout 20 "$MANDOR" --config="$TMP/hk.toml" >"$TMP/55" 2>&1
c=$?
if [ $c -ne 0 ] && grep -q "unhealthy, sending SIGTERM" "$TMP/55" && grep -q "stopping all" "$TMP/55"; then
  ok "health-kill counts as a failure despite expected_exit"
else bad "health-kill vs expected_exit" "exit $c: $(grep -E 'unhealthy|stopping' "$TMP/55" | head -2)"; fi

# 56. a slow crash loop still escalates. fail_streak resets after 10s of
# uptime, so max_restarts alone can never catch a worker crashing every 11s;
# the restart-loop detector has to end the run instead of only logging.
timeout 30 "$MANDOR" --max-restarts=-1 "sh -c 'exit 1'" >"$TMP/56" 2>&1
c=$?
if [ $c -eq 1 ] && grep -q "is in a restart loop, stopping all" "$TMP/56"; then
  ok "restart loop escalates even with unlimited retries"
else bad "restart-loop escalation" "exit $c: $(grep -E 'restart loop|stopping' "$TMP/56" | head -2)"; fi

# 57. contradictory config stops startup instead of being ignored
cat > "$TMP/os2.toml" <<'TOML'
workers = ["sh -c 'exit 0'"]
[worker.sh]
oneshot = true
essential = false
TOML
timeout 10 "$MANDOR" --config="$TMP/os2.toml" >"$TMP/57" 2>&1
c=$?
if [ $c -eq 2 ] && grep -q "meaningless on a oneshot" "$TMP/57"; then
  ok "essential on a oneshot is rejected, not ignored"
else bad "oneshot+essential" "exit $c: $(head -2 "$TMP/57")"; fi

# 58. removed flags/keys say what to use instead
timeout 10 "$MANDOR" --restart=on-failure "sh -c 'exit 0'" >"$TMP/58a" 2>&1
a=$?
printf 'workers = ["sh -c \x27exit 0\x27"]\nrestart_on_unhealthy = true\n' > "$TMP/rm.toml"
timeout 10 "$MANDOR" --config="$TMP/rm.toml" >"$TMP/58b" 2>&1
b=$?
if [ $a -eq 2 ] && grep -q "use --max-restarts=N" "$TMP/58a" \
   && [ $b -eq 2 ] && grep -q "always acted on" "$TMP/58b"; then
  ok "removed flag/key errors name the replacement"
else bad "teaching errors" "a=$a b=$b: $(head -1 "$TMP/58a"); $(head -1 "$TMP/58b")"; fi

# 59. the startup plan is printed, and stays quiet for a simple config
timeout 10 "$MANDOR" "sh -c 'exit 0'" >"$TMP/59" 2>&1
lines=$(grep -c "^\[mandor\]   " "$TMP/59" || true)
if grep -q "1 worker(s) | a failure ends the run (max_restarts=0)" "$TMP/59"; then
  ok "startup plan states the lifecycle in one line"
else bad "startup plan" "$(head -2 "$TMP/59")"; fi

# 61. abandoning a non-essential worker must be announced. It opted out of
# ending the run, not out of being reported — silently ceasing to restart it
# is the same invisible degradation everywhere else in this release removes.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 1\n' >"$TMP/bin/bad"; printf '#!/bin/sh\nsleep 300\n' >"$TMP/bin/live"
chmod +x "$TMP/bin/bad" "$TMP/bin/live"
cat > "$TMP/ne.toml" <<TOML
max_restarts = -1
backoff_max = "200ms"
workers = ["$TMP/bin/bad", "$TMP/bin/live"]
[worker.bad]
essential = false
TOML
timeout 15 "$MANDOR" --config="$TMP/ne.toml" >"$TMP/61" 2>&1
c=$?
if [ $c -eq 124 ] && grep -q "bad is in a restart loop, not restarting it (essential = false)" "$TMP/61"; then
  ok "abandoning a non-essential worker is announced, run continues"
else bad "non-essential give-up" "exit $c: $(grep -E 'restart loop|stopping' "$TMP/61" | tail -1)"; fi

# 62. recycling is a planned restart, not a failure — it must not trip
# essential-by-default and take the container down.
printf '#!/bin/sh\nA=$(head -c 2000000 /dev/zero | tr \\0 x)\nsleep 30\n' >"$TMP/bin/hog"
chmod +x "$TMP/bin/hog"
cat > "$TMP/rc.toml" <<TOML
max_restarts = -1
workers = ["$TMP/bin/hog"]
[worker.hog]
max_rss_mb = 1
TOML
timeout 14 "$MANDOR" --config="$TMP/rc.toml" >"$TMP/62" 2>&1
c=$?
n=$(grep -c "recycling hog" "$TMP/62")
if [ $c -eq 124 ] && [ "$n" -ge 1 ] && ! grep -q "stopping all" "$TMP/62"; then
  ok "recycling does not trip essential-by-default ($n recycles)"
else bad "recycle vs essential" "exit $c, recycles $n: $(grep stopping "$TMP/62" | head -1)"; fi

# 63. once every essential worker has finished, sidecars are stopped and the
# run ends — otherwise a never-exiting sidecar keeps the container alive with
# no real work left. The exit code is the essential workers' outcome, not the
# 143 from the TERM mandor sends the sidecar itself.
printf '#!/bin/sh\nsleep 1\nexit 0\n' >"$TMP/bin/job"
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$TMP/bin/side"
chmod +x "$TMP/bin/job" "$TMP/bin/side"
cat > "$TMP/es43.toml" <<TOML
workers = ["$TMP/bin/job", "$TMP/bin/side"]
[worker.side]
essential = false
TOML
timeout 15 "$MANDOR" --config="$TMP/es43.toml" >"$TMP/63" 2>&1
c=$?
if [ $c -eq 0 ] && grep -q "all essential workers finished; stopping the rest" "$TMP/63"; then
  ok "finished essential workers end the run (exit 0, sidecar stopped)"
else bad "essential-finished exit" "exit $c: $(grep -E 'all essential|killed' "$TMP/63" | head -2)"; fi

# 64. ...but a fleet with no essential worker at all must keep supervising,
# not exit instantly on the same condition.
cat > "$TMP/es44.toml" <<TOML
workers = ["$TMP/bin/side"]
[worker.side]
essential = false
TOML
timeout 6 "$MANDOR" --config="$TMP/es44.toml" >"$TMP/64" 2>&1
c=$?
if [ $c -eq 124 ]; then ok "a fleet with no essential worker keeps supervising"
else bad "no-essential fleet" "exit $c (expected 124)"; fi

echo
echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
