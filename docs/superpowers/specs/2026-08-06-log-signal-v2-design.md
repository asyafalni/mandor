# log-signal v2 — curated warn/error digest + per-worker streaming

> Design doc. Branch: `feat/log-signal-v2`. Refines the P3 log streaming shipped
> in v1.10.0. Target release: v1.11.0.

## Problem

mandor's only curated log signal to photon is the **incident bundle**, which
fires on a terminal event (crash / OOM / unhealthy / restart-loop / leak). A
worker that is **healthy but logging warnings and errors produces no incident**,
so mandor stays silent about real trouble. And the v1.10.0 full-log streaming is
a **global** toggle (`[logs] stream`) that, on a flooding "dirty" app, adds a
per-line encode + pipe write and spikes CPU.

Operators want three things: (1) mandor should **proactively surface warn/error
activity** even without a crash — curated, not real-time; (2) full streaming
should be **selectable per worker**, not global; (3) a flooding app must **never
spike mandor's CPU**.

## Design — three tiers of log → photon (all under `photon=`; offline default unchanged)

### Tier 1 — Incidents (unchanged)
Crash/OOM/unhealthy/leak bundles → OTLP `/v1/logs`, durable (spooled, retried).

### Tier 2 — Curated warn/error digest (NEW; default ON when `photon=` is set)
mandor already flags every warn/error line at capture time (`ring.flag_errorish`).
This tier **deduplicates flagged lines by signature** (reusing `summarize`'s
signature logic) into a fixed, bounded per-run table, and **periodically emits a
compact summary** to photon as OTLP logs.

- **Accumulation (supervisor-side, cheap):** for each line already flagged
  warn/error, compute its signature and bump a fixed-size table entry
  `{sig, count, first_ts, last_ts, sample_line, severity}`. Bounded
  (`max_error_sigs`, e.g. 64); on overflow, increment an "other" bucket. O(1) per
  flagged line, zero alloc. Non-flagged (info) lines are untouched.
- **Flush (daemon-shipped):** every `digest_interval` (default **30 s**), and
  **early when any signature's count crosses `digest_threshold`** (default e.g.
  100), the accumulated table is emitted to photon — one OTLP log record per
  signature: body = the sample line, `severity_number` = warn/error,
  attributes `mandor.count`, `mandor.first_ts`, `mandor.last_ts`,
  `service.name` = worker, plus host identity. Then the table resets for the next
  window. Also flushed at shutdown.
- **Flood-proof by construction:** a million identical `ERROR: db timeout` lines
  collapse to ONE record with `count=1_000_000`, sent once per window — never a
  per-line firehose. Under a dirty flooding app, Tier 2 costs O(signatures) per
  window, not O(lines).
- **Default on** when `photon=` is set (it *is* the "tell me about warnings and
  errors" behavior, and it's low-rate/curated — consistent with incidents/metrics
  already shipping). A `[logs] digest = false` knob turns it off;
  `[logs] digest_interval` / `digest_threshold` tune it.

### Tier 3 — Full per-worker streaming (opt-in, redesigned)
Real-time firehose, **selected per worker** (replaces the global `[logs] stream`):
```toml
[worker.api]
stream = true            # only api streams every line
```
Guarded for flood safety by:
- **Per-worker selection** — leave a flooding worker's `stream` off (Tier 2 still
  surfaces its errors).
- **Backpressure shedding (automatic):** when a pipe write to the daemon hits
  `EAGAIN` (daemon behind), `emitLog` flips to a **shed state** and drops
  subsequent lines *before encoding* (a counter bump only) for a short cooldown,
  then probes again. A flood into a backed-up daemon costs ~O(1)/line, not
  encode+write — mandor's streaming CPU **self-caps, no config**.
- **`max_rate`** (global, lines/sec, already drops pre-encode) — optional hard cap.

## Multi-tenancy — service prefix

photon is multi-tenant: several mandor origins (deployments / environments /
tenants) publish to the same photon, and two of them may run a worker with the
same name (e.g. `api`), colliding on `service.name`. A config key adds an origin
**prefix** to `service.name` on **every** OTLP emission so origins stay distinct:

```toml
photon = "…"
service_prefix = "tenant-a-"     # service.name becomes e.g. "tenant-a-api"
```

- Applied in **one place** — a shared `putServiceName` helper the daemon uses in
  every encoder that emits `service.name` (process metrics, incidents, lifecycle,
  streamed logs, the Tier-2 digest). The bare worker name is unchanged everywhere
  else (log `[name]` prefix, `report`, Prometheus label) — the prefix is
  telemetry-only. Default empty = no prefix (unchanged behavior).
- The prefix is threaded to the daemon like the other telemetry config; a tiny
  fixed scratch forms `prefix ++ name` (no alloc). `host.id` (machine-id) already
  distinguishes hosts; the prefix is the service-level tenant tag.

## Config surface changes (breaking vs v1.10.0 — done while fresh)

| v1.10.0 | v1.11.0 |
|---|---|
| `[logs] stream = true` (global) | **removed** → per-worker `[worker.NAME] stream = true` |
| `[logs] max_rate` | kept (global hard cap for Tier 3) |
| — | `[logs] digest` (bool, default true), `digest_interval` (dur, 30s), `digest_threshold` (int) |
| — | `service_prefix` (string, default "") — tenant/origin tag on `service.name` |

Keep the 4-flag CLI rule (all TOML). Config-surface budget bumped for the net key
change (removed `stream`; added `digest`/`digest_interval`/`digest_threshold`).

## Architecture / placement

- **Accumulation runs in the supervisor** (the flags are already computed at
  capture): a fixed-size signature table, updated only for warn/error lines. This
  is where dedup collapses a flood *before* anything crosses to the daemon.
- **Emission runs from the daemon** on its timer (like node metrics): the
  supervisor periodically hands the daemon the digest snapshot over the telemetry
  pipe (one small message per window — NOT per line), the daemon encodes
  `buildOtlpLogs`-style and POSTs. Off PID-1's shipping path.
  - (Alternative if simpler: supervisor builds the digest snapshot and emits it
    as a single frame the daemon forwards. The key property: one message per
    window, never per line.)
- **Signature logic:** reuse `summarize.signature` / the existing compaction
  normalization (digit-insensitive) so the digest groups the same way incidents
  do.

## Constraints (motto governs)

- **Stability first:** no `unreachable`/panic on the capture/supervision path.
  Tier 2 accumulation is O(1)/flagged-line, fixed table, zero alloc. Tier 3
  shedding never blocks. All drops counted, never spooled (only incidents are
  durable).
- **Flood-proof:** Tier 2 dedups pre-emission; Tier 3 sheds under backpressure.
  A dirty flooding app must not spike PID-1 CPU.
- **Curate by default:** Tier 2 (curated) is the default; Tier 3 (firehose) is
  opt-in per worker. Offline-by-default: no `photon=` ⇒ none of it.
- Static musl, `<500KB`, config-surface gate, size gate.

## Phasing (tasks)

0. **Service prefix (multi-tenancy)** — `service_prefix` config threaded to the
   daemon; a shared `putServiceName` helper used by EVERY encoder that emits
   `service.name` (process metrics, incident, lifecycle, streamed logs). Default
   "" = unchanged. Unit (prefixed name in each encoder via protoWalk) + mutation.
   Done first so the Tier-2/Tier-3 emitters inherit it.
1. **Tier 3 → per-worker `stream`** (refactor v1.10.0 global toggle): `[worker.NAME] stream`, `Worker.stream`, supervisor gates `emitLog` per worker; remove `[logs] stream`; keep `max_rate`. Docs + harness (per-worker on/off).
2. **Backpressure shedding** in `emitLog`: EAGAIN → shed state, pre-encode drop + cooldown/probe, counter. Unit + soak-style flood test (no CPU spike, drops counted).
3. **Tier 2 accumulator**: signature table (`{sig,count,first,last,sample,sev}`, bounded), fed by warn/error-flagged lines in the capture path; reuse `summarize.signature`. Unit tests (dedup, count, overflow bucket). Mutation.
4. **Tier 2 emission**: periodic (30s) + threshold early-flush → OTLP logs digest via the daemon; default-on when `photon=`; `[logs] digest*` config. Unit (OTLP shape/protoWalk) + wire.
5. **Docs + gates + live**: CONFIG.md (the tier model + config table), config-surface budget, CHANGELOG; harness e2e (digest appears in photon for a warn/error-logging worker with NO crash; a flood collapses to a deduped digest; per-worker stream on/off; backpressure drops without spiking). Live-verify against photon v1.5.0.

## Testing

- Unit: signature accumulation (dedup/count/overflow), digest OTLP shape (protoWalk),
  per-worker stream gate, backpressure shed state machine, config parsing.
- Harness: (a) a worker emitting warn/error lines but **not crashing** → a digest
  with the right signatures+counts reaches photon; (b) a **flood** of identical
  errors → one digest record, `count` high, mandor CPU flat; (c) `[worker.x] stream`
  → x's lines stream, others don't; (d) streaming a flood at a dead/slow endpoint →
  drops counted, CPU flat (backpressure).
- Live: verify Tier 2 digest + Tier 3 per-worker stream against photon v1.5.0.
- Mutation each task; fmt/test/exe green; size + config-surface gates.

## Non-goals
- No log parsing/indexing (photon's job). No changing what counts as warn/error
  (the existing capture flag). No per-worker `max_rate` (global suffices for now).
- Tier 2 is a *digest*, not a searchable log store — for full logs, use Tier 3.
