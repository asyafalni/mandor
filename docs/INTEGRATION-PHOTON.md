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

The incident bundle (schema v5, versioned contract in `src/spool.zig`) is a
ready-made OTEL *event*: structured cause, exception type/message, stack
frames with `file:line`/`in_app` (Sentry vocabulary), deduplicated log tail,
stats timeline, release/build-id, recurrence history. The delivery mechanism
is ROADMAP #19, the **on-incident hook**:

```toml
on_incident = ["/photon-relay"]   # exec'd with the bundle path appended
```

`photon-relay` is a tiny static shim (candidate: ship in photon's repo, or a
shared `mandor-contrib` repo) that POSTs the bundle to photon's OTLP/HTTP
logs endpoint on localhost. mandor's core stays offline; the user opts into
the bridge by installing the shim. The premium sidecar uses the same hook.

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
