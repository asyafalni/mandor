# mandor × photon — integration design

[photon](https://github.com/nevindra/photon) is mandor's sister project (at
v1.5.0): an OTEL-native, single-binary observability platform (logs, traces,
metrics, APM, uptime) in Rust, with an Infrastructure / Hosts view — including a
per-host Processes table — that mandor populates. mandor is a PID-1 supervisor
that *produces* exactly the signals photon *displays*. This doc defines how
mandor tells its story to photon — without breaking mandor's product boundary
(the free binary never phones home unless the operator opts in with `photon=`,
and even then the supervision path itself opens no socket).

> **Self-sufficient as of the OTLP-telemetry work.** When `photon=` is set,
> mandor ships **incidents, per-process/supervisor metrics, node/host metrics,
> optional GPU metrics, and process-lifecycle events** to photon directly as
> OTLP — **no collector in the container is required** for any of them. A single
> long-lived `mandor relay --daemon` child owns the socket (watches the incident
> spool, drains a non-blocking telemetry pipe, and samples the node on its own
> timer); the supervision path never touches a socket. Because mandor now pushes
> node and GPU metrics itself, one mandor with the host mounted in **supersedes
> photon's standalone `photon-agent`**. By default mandor still *curates* — it
> does **not** ship raw per-line worker logs and never ships traces, so log
> content reaches photon inside incident bundles (their flagged log-tail
> summary). Full per-line log streaming exists but is strictly opt-in
> (`[logs] stream`, see channel 2). The Prometheus `--metrics` endpoint remains a
> local pull option; it is **no longer required** to get metrics into photon.

## The story channels

### 1. Metrics — native OTLP push when `photon=` is set

**With `photon=` set, mandor pushes OTLP metrics itself** (`/v1/metrics`, via the
relay daemon) — no collector needed. Three resource scopes, all carrying the SAME
`host.name`/`host.id` so photon's Infrastructure / Hosts view groups them under
one node:

- **Per-process + supervisor.** One `ResourceMetrics` per worker
  (`service.name=<worker>`) with OTel-semconv `process.memory.usage`,
  `process.cpu.utilization`, `process.unix.file_descriptor.count`,
  `process.thread.count` gauges and a `process.restarts` monotonic sum; plus one
  `service.name="mandor"` supervisor self-metric. Each worker resource also
  carries `host.name`, so a worker is attributable to its node (photon's per-host
  Processes table). Sampled on the /proc cadence (5s), delivered best-effort over
  a non-blocking pipe — dropped under backpressure so telemetry never stalls
  supervision.
- **Node / host.** One host-scoped resource (`host.name`/`host.id`/`os.type`)
  with `system.cpu.utilization` (`cpu=total` + per-core `cpu=<n>`),
  `system.cpu.logical.count`, `system.cpu.load_average.{1m,5m,15m}`,
  `system.memory.{usage,limit,utilization}`, `system.paging.usage` (swap),
  `system.network.io` (per-interface × direction),
  `system.filesystem.{usage,utilization}` (per-mount), `system.disk.io`
  (per-device), plus mandor-extension gauges `system.uptime` and
  `system.cpu.temperature`. Sampled **inside the daemon** (its own /proc + statfs
  reads on a 5s timer) — the supervision path carries none of it. Emitted
  automatically whenever `photon=` is set; there is no separate toggle.
- **GPU** (opt-in `[gpu] enabled`, daemon-side, default 15s).
  `system.gpu.{utilization,memory.usage,memory.utilization,temperature,power}`
  per GPU (`gpu`, `gpu.name`). NVIDIA via an `nvidia-smi` shell-out (mandor is
  static/libc-free, so it cannot dlopen NVML); AMD/Intel via DRM sysfs.
  Fail-closed — no GPU, no `nvidia-smi`, or any error ⇒ nothing shipped, no
  effect on anything else.

Config specifics live in [CONFIG.md](CONFIG.md); the whole telemetry surface is
`photon=` plus the small `[gpu]` / `[logs]` sections.

**The Prometheus `--metrics=PORT` endpoint (127.0.0.1) is a separate, local pull
option**, unrelated to the photon push path above. photon ingests by push only —
OTLP to `/v1/metrics` or Prometheus `remote_write` to `/api/v1/write`, no scraper
— so if you want a *third party* to pull mandor's Prometheus series you still put
a collector between them; you just no longer need one to reach photon. Exposed
series (stable names): `mandor_worker_up`, `mandor_worker_restarts_total`,
`mandor_worker_rss_kilobytes`, `mandor_worker_cpu_percent`, `mandor_worker_fds`,
`mandor_worker_threads`, `mandor_incidents_total` — all labeled `worker="name"`.
photon's uptime checker can also probe the metrics port: mandor answering =
supervisor alive; `mandor_worker_up == 0` = worker down.

### 2. Worker logs — curated by default, full streaming opt-in

By default mandor does **not** ship raw per-line logs: it multiplexes worker
output to its own stdout/stderr with `[name]` prefixes (each line wall-clock
timestamped in the capture ring), and log *content* reaches photon only inside
incident bundles (the flagged log-tail summary). A container runtime or OTEL
collector can still forward mandor's stdout independently.

Set `[logs] stream = true` (requires `photon=`) to also stream every worker
stdout/stderr line to photon's `/v1/logs` as OTLP logs — one `service.name` per
worker, the line as the log `body`, stderr/severity flagged, same host identity
as the metrics. This is the **ephemeral, best-effort** tier: streamed lines ride
the same non-blocking pipe as metrics, are **dropped under backpressure** (and by
the `[logs] max_rate` lines/sec cap), and are **never spooled or retried** —
incidents are the only durable tier. Full logs can carry secrets and are a lot of
egress, so streaming is deliberately opt-in and rate-limitable. Traces are never
shipped either way.

### 3. Incidents — the real story; shipped and durable

The incident bundle (schema v7, versioned contract in `src/spool.zig`) is a
ready-made OTEL *event*: structured cause, exception type/message, stack
frames with `file:line`/`in_app` (Sentry vocabulary), deduplicated log tail,
stats timeline, release/build-id, and recurrence history — now including
release correlation (`history.builds` / `first_build` / `last_build` /
`regressed`) so photon can group incidents by build and highlight crashes
that survived a deploy. Delivery is the **`photon=` key** (built on the
`on_incident` primitive, ROADMAP #19):

```toml
photon = "127.0.0.1:4318"   # that's the whole integration
```

One config key. When set, mandor forwards every incident bundle to photon's
OTLP/HTTP logs endpoint as **OTLP protobuf** (`application/x-protobuf`). It no
longer re-execs `mandor relay` once per incident: instead a single long-lived
`mandor relay --daemon` child is spawned when `photon=` is set, **watches the
incident spool**, and ships each new bundle itself — so a crash loop spawns one
child, not one relay per crash, and a bundle that fails to send is retried from
the durable spool rather than lost. The supervision path never touches a socket,
and without the key mandor is fully offline. `photon` is a `mandor.toml` key,
not a CLI flag — the everyday CLI stays at four flags (`--config` loads the
TOML). Auth: set `PHOTON_TOKEN` in the environment and the relay sends
`Authorization: Bearer …`. The generic `on_incident` hook remains for custom
tooling and the premium sidecar (a separate, per-incident detached process).

Protobuf rather than JSON because OTLP/HTTP makes protobuf the mandatory
encoding and JSON the optional one: the relay therefore works with any
conformant collector, not just those that implemented both. The encoder is
hand-rolled (~120 lines of varints and length-delimited fields) so the
no-dependency rule holds.

The relay refuses rather than ships a payload it cannot vouch for, and says
which on stderr: a bundle over 256KB (`refusing to ship a truncated
incident` — a clipped incident stored forever is worse than a missing one),
and a bundle whose JSON string escapes are broken (`malformed JSON string
escape`, which means the file was truncated mid-write or hand-edited). A bad
endpoint exits 2 before any socket work.

The endpoint may be `ip:port` **or** `hostname:port` — names go through
`/etc/hosts` first, then DNS, which is what makes `photon = "photon:4318"`
work under compose and Kubernetes. mandor is libc-free, so there is no
`getaddrinfo`: the query is ~90 lines over UDP, with std's pure `DnsResponse`
parser doing the answer walk and name decompression. `search` domains from
`resolv.conf` are not applied — a bare name that resolves only through a search
suffix will not be found.

Delivery is bounded and any 2xx counts as accepted. Every blocking socket call
times out after 10s: the relay is spawned fire-and-forget and never waited on,
so a collector that accepts the connection and then stalls would otherwise
strand one process per incident — and incidents fire per restart, so a crash
loop would strand one per crash. A timeout says so explicitly rather than
reporting a rejection. `202 Accepted` is treated as success, not failure.

> **Status: unblocked as of mandor v1.6.0 — mandor now sends OTLP protobuf.**
>
> For three months this said "blocked, the fix is photon-side". It was the
> wrong conclusion: photon accepts what the OTLP/HTTP spec makes mandatory
> (`application/x-protobuf`), and mandor was sending the encoding servers may
> optionally support. mandor was the side that could change, and changing it
> is the better default anyway — a protobuf relay works with photon **and**
> with every collector that never implemented JSON, which is most of them.
>
> Verified against a fresh clone of photon `main` (`c393269`, after v1.4.0 on
> 2026-07-21): `ingest_logs` calls `decode_export_request` — protobuf — and
> `mapping.rs` reads `resource_logs → resource/scope_logs → log_records`, with
> `service.name` arriving via resource attributes. That is exactly the shape
> `relay.zig` now emits, checked by two independent decoders (a Zig reader in
> the unit tests, a Python one in harness case 65 reading off a real socket).
>
> **Confirmed end to end 2026-07-22.** photon built from source
> (`podman build`, its own Dockerfile — the published release ships
> `photon-agent` only, not the ingest server), then a real crash supervised by
> mandor as PID 1, forwarded by the `photon` key over a container network:
>
> ```
> /api/services  -> ["sh"]
> /api/storage   -> logs: total_rows 1, bytes 7022
> /api/search    -> mandor.bundle with the full schema-v7 incident
> ```
>
> photon promoted `service.name` to its own column and stored the whole bundle,
> `PHOTON_TOKEN` redacted in the captured env. Reproduce with
> `bash test/photon/e2e.sh`.
>
> **Two limitations the live run exposed — both fixed in v1.6.2**, and neither
> was visible from reading the code:
>
> 1. **`photon = "hostname:4318"` used to be rejected**, because the key took a
>    literal `ip:port`. compose and Kubernetes address services by *name*, which
>    is exactly what the deployment sketch below shows — so that sketch could
>    not be written as documented. mandor now resolves names via `/etc/hosts`
>    then DNS. Known limit: `search` domains in `resolv.conf` are not applied,
>    so a bare name that only resolves through a search suffix will fail.
> 2. **A forward could be killed mid-flight.** The relay is a detached child and
>    mandor exits as soon as a fatal crash ends the run — as PID 1, that took
>    the relay with it, losing the incident that explained the crash. Nothing
>    reported it, because the spawn itself had succeeded. Shutdown now waits up
>    to 2s for in-flight forwards and says so if any are still running.

**Historical note (2026-07-18 → 2026-07-22):** the original recon framed this
as a photon-side gap and specced an afternoon of Rust to add OTLP/JSON ingest
([docs/photon-contrib/otlp-json-ingest-spec.md](photon-contrib/otlp-json-ingest-spec.md)).
That spec is still valid and still worth doing — the OTLP spec does require
servers to accept JSON — but it is no longer a prerequisite for this
integration, and mandor no longer waits on it.

**Proposed OTLP mapping** (for the shim / photon-side importer):

| bundle field | OTLP LogRecord |
|---|---|
| `ts` | `time_unix_nano` |
| `cause.kind` + `verdict` | `body` |
| severity | `ERROR` (exit/signal/oom/unhealthy), `WARN` (leak/restart-loop) |
| `process.name` | resource attr `service.name` |
| `process.build.release` / `elf_build_id` | resource attrs `service.version`, `build.id` |
| `exception.type` / `message` | attrs `exception.type`, `exception.message` (OTEL semconv) |
| `trace.frames` | attr `exception.stacktrace` (rendered) |
| whole bundle | attr `mandor.bundle` (JSON string, schema-versioned) |

### 4. Process-lifecycle events — OTLP logs alongside incidents

The relay daemon also emits process-lifecycle events to `/v1/logs`: `started`,
`exited` (ok / error / OOM), `restarting` (with backoff), and `unhealthy`.
Best-effort over the same non-blocking pipe as metrics — so photon shows a
worker's timeline (start → restart → crash) next to its metrics and any incident
bundle, all under the same host identity.

## What we need, concretely — done

The integration is complete on mandor's side and confirmed end to end (below);
this section is kept as the contract record.

1. **`on_incident` hook / `photon=` key** — SHIPPED (ROADMAP #19). The relay
   daemon builds on it to push incidents, metrics, host/GPU metrics, and
   lifecycle events as OTLP.
2. **Contract freeze docs** — this file + schema versioning discipline
   (enforced by golden fixture tests). photon developers code against `"v"`
   and get told loudly when it bumps.
3. **photon-side** — photon ingests OTLP protobuf on `/v1/{logs,metrics}`
   directly; no shim is required. The `/var/lib/mandor/incidents/` spool
   (append-only, atomic-rename, self-pruning) remains available as an
   alternative "watch the shared volume" source, and is the premium sidecar's
   interface.
4. **Shared conventions** — both projects honor `MANDOR_RELEASE` /
   `GIT_SHA` env for release correlation, so photon can group incidents by
   deploy the same way the LLM agent does.

## Deployment sketch (docker-compose)

```yaml
services:
  app:
    image: my-app            # ENTRYPOINT ["/mandor", "--config=/mandor.toml"]
    volumes: [mandor-state:/var/lib/mandor]
    # photon = "photon:4318" in mandor.toml pushes incidents, per-process +
    # host (+ opt-in GPU) metrics, and lifecycle events directly — no collector.
  photon:
    image: ghcr.io/nevindra/photon:latest
    ports: ["8080:8080"]
    volumes: [mandor-state:/var/lib/mandor:ro]   # optional spool-watcher path
volumes:
  mandor-state:
```

To have this mandor also report the **host** (superseding `photon-agent`), mount
`/proc`, `/sys`, `/etc/machine-id` (and `/dev/nvidia*` + `nvidia-smi` for GPU)
into the `app` container — node-exporter style, additive to supervising its
workers.

## Non-goals

- No raw log streaming by default and no traces ever — mandor curates
  (incidents + metrics + lifecycle); full per-line streaming is strictly opt-in.
- No photon-specific code in mandor's core — everything above rides on
  generic, versioned contracts (OTLP semconv, metrics names, spool schema,
  hook argv).
