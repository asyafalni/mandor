#!/bin/sh
# End-to-end test that mandor ships NODE host metrics (system.* + host.name) to
# /v1/metrics, against a local 200-responder that captures request bodies. The
# OTLP metric names are plaintext length-delimited strings inside the protobuf,
# so we grep the raw body for them. Worker lives past one 5s sampler tick so a
# host sample is emitted.
#
# Build first:  zig build
# Run:          sh test/photon/host-metrics-e2e.sh
set -e
ROOT=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
BIN=${MANDOR_BIN:-"$ROOT/zig-out/bin/mandor"}
[ -x "$BIN" ] || { echo "SKIP: $BIN not built (run: zig build)"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 required"; exit 0; }

WORK=$(mktemp -d); PORT=${PORT:-14320}
trap 'kill $SRV 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/state"; BODIES="$WORK/bodies"; : > "$BODIES"

# Responder: 200 to all; append each POST's raw body (binary) to $BODIES.
python3 - "$PORT" "$BODIES" <<'PY' &
import sys, socketserver, http.server
port=int(sys.argv[1]); bf=sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n=int(self.headers.get('Content-Length','0') or 0)
        body=self.rfile.read(n) if n else b''
        with open(bf,'ab') as f: f.write(b'\n=== '+self.path.encode()+b' ===\n'+body)
        self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
    def log_message(self,*a): pass
socketserver.TCPServer.allow_reuse_address=True
with socketserver.TCPServer(("127.0.0.1",port),H) as s: s.serve_forever()
PY
SRV=$!
sleep 1

cat > "$WORK/worker.sh" <<'SH'
#!/bin/sh
echo up; sleep 7; echo done; exit 0
SH
chmod +x "$WORK/worker.sh"
cat > "$WORK/mandor.toml" <<EOF
photon = "127.0.0.1:$PORT"
workers = ["$WORK/worker.sh"]
EOF

set +e
timeout 30 "$BIN" --config="$WORK/mandor.toml" --state-dir="$WORK/state" >"$WORK/out" 2>&1
RC=$?
set -e
echo "mandor exit: $RC"

# The metric names are ASCII inside the protobuf body.
grep -qa "system.memory.usage" "$BODIES" || { echo "FAIL: system.memory.usage not shipped"; exit 1; }
grep -qa "system.cpu.utilization" "$BODIES" || { echo "FAIL: system.cpu.utilization not shipped"; exit 1; }
grep -qa "system.network.io" "$BODIES" || { echo "FAIL: system.network.io not shipped"; exit 1; }
grep -qa "host.name" "$BODIES" || { echo "FAIL: host.name resource attr not shipped"; exit 1; }
echo "PASS: node host metrics (system.* + host.name) shipped to /v1/metrics"
