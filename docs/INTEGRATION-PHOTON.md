# mandor × photon — integration design

[photon](https://github.com/nevindra/photon) is mandor's sister project: an
OTEL-native, single-binary observability platform (logs, traces, metrics,
APM, uptime) in Rust. mandor is a PID-1 supervisor that *produces* exactly
the signals photon *displays*. This doc defines how mandor tells its story
to photon — without breaking mandor's product boundary (the free binary
never phones home; its only network surface is the optional local metrics
endpoint).

## The three story channels

### 1. Metrics — works today, zero code

mandor serves Prometheus text on `--metrics=PORT` (127.0.0.1). photon accepts
Prometheus `remote_write`. Any standard agent bridges the two, or photon can
scrape directly when co-deployed:

```
mandor --metrics=9464  ──scrape──▶  photon (remote_write sink / collector)
```

Exposed series (stable names): `mandor_worker_up`,
`mandor_worker_restarts_total`, `mandor_worker_rss_kilobytes`,
`mandor_worker_cpu_percent`, `mandor_worker_fds`, `mandor_worker_threads`,
`mandor_incidents_total` — all labeled `worker="name"`.

photon's uptime checker can also probe the metrics port itself: mandor
answering = supervisor alive; `mandor_worker_up == 0` = worker down.

### 2. Worker logs — works today via any OTLP collector

mandor multiplexes worker output to its own stdout/stderr with `[name]`
prefixes; every line is also wall-clock timestamped in the capture ring.
Container runtimes already collect stdout — an OTEL collector (or photon's
own future file/stdout receiver) forwards it. No mandor change required;
`service.name` can be derived from the `[name]` prefix.

### 3. Incidents — the real story; needs one v0.8 feature

The incident bundle (schema v7, versioned contract in `src/spool.zig`) is a
ready-made OTEL *event*: structured cause, exception type/message, stack
frames with `file:line`/`in_app` (Sentry vocabulary), deduplicated log tail,
stats timeline, release/build-id, and recurrence history — now including
release correlation (`history.builds` / `first_build` / `last_build` /
`regressed`) so photon can group incidents by build and highlight crashes
that survived a deploy. The delivery mechanism is ROADMAP #19, the
**on-incident hook**:

```toml
photon = "127.0.0.1:4318"   # that's the whole integration
```

One config key. When set, mandor forwards every incident bundle to photon's
OTLP/HTTP logs endpoint as **OTLP protobuf** (`application/x-protobuf`), by
fire-and-forget re-exec of its own invisible `mandor relay` subcommand — the
supervision path never touches a socket, and without the key mandor is fully
offline. `--photon=ip:port` works on the CLI too. Auth: set `PHOTON_TOKEN` in
the environment and the relay sends `Authorization: Bearer …`. The generic
`on_incident` hook remains for custom tooling and the premium sidecar.

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
`ip:port` exits 2 before any socket work; there is no name resolution.

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
> **Not yet confirmed end to end.** photon's release publishes
> `photon-agent-linux-x86_64` only, not the ingest server, so running the pair
> means building `photon-ingest` from Rust source. mandor's half is verified;
> the handshake against a live photon is not.

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

## What we need, concretely

1. **mandor v0.8 #19 — `on_incident` hook** (XS, already top of Tier 4).
   The single missing primitive on our side.
2. **Contract freeze docs** — this file + schema versioning discipline
   (already enforced by golden fixture tests). photon developers code
   against `"v"` and get told loudly when it bumps.
3. **photon-side (sister's homework, ~an afternoon each):**
   a. `photon-relay` shim (static musl binary, <100 lines: read file, POST
      OTLP/HTTP to localhost:4318) — or —
   b. a native "mandor spool" source in photon: watch
      `/var/lib/mandor/incidents/` (shared volume), import new `*.json`.
      The spool dir is append-only, atomic-rename, self-pruning — built to
      be watched (it is the premium sidecar's interface too).
4. **Shared conventions** — both projects honor `MANDOR_RELEASE` /
   `GIT_SHA` env for release correlation, so photon can group incidents by
   deploy the same way the LLM agent does.

## Deployment sketch (docker-compose)

```yaml
services:
  app:
    image: my-app            # ENTRYPOINT ["/mandor", "--metrics=9464", ...]
    volumes: [mandor-state:/var/lib/mandor]
  photon:
    image: photon
    ports: ["8080:8080"]
    volumes: [mandor-state:/var/lib/mandor:ro]   # spool watcher path (3b)
volumes:
  mandor-state:
```

## Non-goals

- mandor will not speak OTLP natively (size + offline boundary; the hook
  externalizes that choice).
- No photon-specific code in mandor's core — everything above rides on
  generic, versioned contracts (metrics names, spool schema, hook argv).
