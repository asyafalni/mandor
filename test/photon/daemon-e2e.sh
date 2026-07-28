#!/bin/sh
# End-to-end test for the long-lived relay daemon (`mandor relay --daemon`)
# against a LOCAL 200-responder — no real photon or ingest token needed, so it
# runs anywhere. Two cases:
#   1. Happy path: a spooled incident is shipped to POST /v1/logs, a framed
#      metric on the pipe is shipped to POST /v1/metrics, and pipe EOF makes the
#      daemon flush and exit 0.
#   2. Backpressure: with photon unreachable, the daemon must NOT hang or crash,
#      and the durable incident bundle must survive (it is retried, never dropped).
#
# Build first:  zig build         (produces zig-out/bin/mandor)
# Run:          sh test/photon/daemon-e2e.sh
set -e

ROOT=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
BIN=${MANDOR_BIN:-"$ROOT/zig-out/bin/mandor"}
[ -x "$BIN" ] || { echo "SKIP: $BIN not built (run: zig build)"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 required for the responder"; exit 0; }

WORK=$(mktemp -d)
trap 'kill $SRV 2>/dev/null; rm -rf "$WORK"' EXIT
PORT=${PORT:-14318}

# ---- case 1: happy path -----------------------------------------------------
mkdir -p "$WORK/state/incidents"
LOG="$WORK/paths.log"; : > "$LOG"
cat > "$WORK/state/incidents/1700000000000-api-1.json" <<'JSON'
{"v":7,"name":"api","cmd":"./api","kind":"signal","cause":"signal:SIGSEGV","verdict":"segfault in handler","release":"v1.2.3","logs_tail":["boom"]}
JSON

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
sleep 1  # let the responder bind (setup, not a race in the code under test)

python3 - > "$WORK/frame.bin" <<'PY'
import struct, sys
name=b"api"
payload=bytes([len(name)])+name+struct.pack("<QHHHIQ", 1000,50,10,4,2, 1700000000000000000)
sys.stdout.buffer.write(bytes([1])+struct.pack("<H", len(payload))+payload)
PY

set +e
timeout 15 "$BIN" relay --daemon 127.0.0.1:$PORT "$WORK/state" 0 < "$WORK/frame.bin"
RC=$?
set -e
echo "case1 daemon exit: $RC"; cat "$LOG"
grep -q "POST /v1/logs" "$LOG"    || { echo "FAIL case1: incident not shipped to /v1/logs"; exit 1; }
grep -q "POST /v1/metrics" "$LOG" || { echo "FAIL case1: metric not shipped to /v1/metrics"; exit 1; }
[ "$RC" = "0" ]                   || { echo "FAIL case1: daemon did not exit 0 on EOF (got $RC)"; exit 1; }
echo "PASS case1: daemon shipped incident + metric and exited cleanly"

# ---- case 2: backpressure (photon unreachable) ------------------------------
BUNDLE="$WORK/state/incidents/1700000000000-api-1.json"
set +e
timeout 15 "$BIN" relay --daemon 127.0.0.1:9 "$WORK/state" 0 < /dev/null
RC=$?
set -e
echo "case2 daemon exit: $RC (124 = hung)"
[ "$RC" != "124" ] || { echo "FAIL case2: daemon hung against a dead endpoint"; exit 1; }
[ "$RC" = "0" ]    || { echo "FAIL case2: expected clean exit 0 on EOF, got $RC"; exit 1; }
[ -f "$BUNDLE" ]   || { echo "FAIL case2: incident bundle dropped under backpressure"; exit 1; }
echo "PASS case2: no hang, clean exit, incident bundle preserved for retry"

echo "ALL PASS"
