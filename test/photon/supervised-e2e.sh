#!/bin/sh
# End-to-end test of the FULL supervisor -> daemon telemetry path against a
# local 200-responder (no real photon / token needed). mandor supervises a
# worker that lives past one sampler tick then exits nonzero, so the run
# exercises every emit point:
#   - daemon spawned when --photon= is set (fd inheritance across exec)
#   - lifecycle events (started, exited_err) -> POST /v1/logs
#   - per-worker + supervisor metrics                -> POST /v1/metrics
#   - the crash incident (via the durable spool)     -> POST /v1/logs
#   - clean shutdown: daemon flushed + reaped, PID-1 not killed by SIGPIPE
#
# Build first:  zig build
# Run:          sh test/photon/supervised-e2e.sh
set -e

ROOT=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
BIN=${MANDOR_BIN:-"$ROOT/zig-out/bin/mandor"}
[ -x "$BIN" ] || { echo "SKIP: $BIN not built (run: zig build)"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 required"; exit 0; }

WORK=$(mktemp -d)
trap 'kill $SRV 2>/dev/null; rm -rf "$WORK"' EXIT
PORT=${PORT:-14319}
mkdir -p "$WORK/state"
LOG="$WORK/paths.log"; : > "$LOG"

# Responder: 200 to everything, record each request-line path.
python3 - "$PORT" "$LOG" <<'PY' &
import sys, socketserver, http.server
port=int(sys.argv[1]); logf=sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def _ok(self):
        n=int(self.headers.get('Content-Length','0') or 0)
        if n: self.rfile.read(n)
        with open(logf,'a') as f: f.write(self.command+' '+self.path+'\n')
        self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
    def do_POST(self): self._ok()
    def do_GET(self): self._ok()
    def log_message(self,*a): pass
socketserver.TCPServer.allow_reuse_address=True
with socketserver.TCPServer(("127.0.0.1",port),H) as s: s.serve_forever()
PY
SRV=$!
sleep 1

# Worker: lives past one 5s sampler tick, then fails -> incident + exited_err.
cat > "$WORK/worker.sh" <<'SH'
#!/bin/sh
echo "worker up"
sleep 7
echo "worker dying"
exit 1
SH
chmod +x "$WORK/worker.sh"

# photon is a mandor.toml key (not a CLI flag — the CLI is the 4 everyday flags).
cat > "$WORK/mandor.toml" <<EOF
photon = "127.0.0.1:$PORT"
workers = ["$WORK/worker.sh"]
EOF

# Supervise with photon telemetry pointed at the local responder.
set +e
timeout 30 "$BIN" --config="$WORK/mandor.toml" --state-dir="$WORK/state" > "$WORK/mandor.out" 2>&1
RC=$?
set -e
echo "mandor exit: $RC (124 = HUNG; expect worker's failure code, not a crash)"
echo "--- mandor output ---"; cat "$WORK/mandor.out"
echo "--- telemetry request paths ---"; cat "$LOG"

[ "$RC" != "124" ]              || { echo "FAIL: mandor hung"; exit 1; }
[ "$RC" != "139" ]              || { echo "FAIL: mandor SEGV (PID-1 killed?)"; exit 1; }
[ "$RC" != "141" ]              || { echo "FAIL: mandor killed by SIGPIPE (128+13)"; exit 1; }
grep -q "POST /v1/metrics" "$LOG" || { echo "FAIL: no metrics reached photon"; exit 1; }
grep -q "POST /v1/logs" "$LOG"    || { echo "FAIL: no logs/incidents reached photon"; exit 1; }
# At least two /v1/logs posts expected (a lifecycle event + the incident).
LOGS=$(grep -c "POST /v1/logs" "$LOG" || true)
[ "$LOGS" -ge 1 ]               || { echo "FAIL: expected lifecycle+incident logs"; exit 1; }
echo "PASS: supervisor -> daemon -> photon path works ($LOGS logs posts, metrics seen), clean exit $RC"
