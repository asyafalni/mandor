# Node host metrics + worker name override — design

> **Status:** approved direction, not yet built. Builds on the shipped
> self-sufficient OTLP telemetry (commits 975bd87→8441c1d). Same product
> boundary: everything here rides the opt-in `photon=` key and the long-lived
> relay daemon; the supervision path stays socket-free; offline without the key.

**Goal:** So an operator can watch each supervised process's usage **against the
node's total resources** in photon, mandor emits node-level `system.*` host
metrics (the baseline) to complement the per-worker `process.*` metrics it
already ships. This populates photon's Hosts/Infrastructure view and makes
`photon-agent` unnecessary for mandor-supervised nodes. Plus: a TOML worker
name override, so a `start.sh` wrapper can present as `api`.

## Why this is small

The fine-grained per-process half is **already shipped** — `process.memory.rss`,
`process.cpu.percent`, `process.open_fds`, `process.threads`,
`process.restarts`, one `ResourceMetrics` per worker (`service.name=<worker>`).
The only missing piece is the **node total** as a baseline. This design adds
exactly that: a node host-metrics sampler + a host-scoped OTLP resource.

## Ranking: which process uses the most (a first-class requirement)

"Tell which process is taking more resource than the others" is satisfied by the
combination this design completes — no separate mechanism needed:

- Each worker ships its own `ResourceMetrics` with `service.name=<worker>`, so
  photon can **sort/rank services** by `process.memory.rss` or
  `process.cpu.percent` directly (top-N heaviest worker).
- The new node totals give the **denominator** — each process as a *share of the
  node* (e.g. worker `api` = 40% of node RAM, worker `cron` = 3%), which is what
  turns "who is heaviest" into "who is heaviest *and* how close to the limit."
- mandor already computes this ranking internally where it acts on it: the PSI
  stall detector (`incident.onStall`) blames **the largest live consumer** of
  the pressured resource, and `report --cost` ranks workers by GB-hours /
  core-seconds. The metrics simply expose to photon what mandor already knows.

So this requirement drives no new code beyond the per-worker metrics (shipped)
plus the node baseline (this design) — it is a consequence of both being present.

## Contract (must match photon-agent exactly, or the view stays empty)

Verified against `photon-agent/src/{otlp,sysinfo_sampler}.rs` (2026-07-28).

**Resource attributes (the host identity):** `host.name`, `host.id`, `os.type`.

**Metrics:**

| name | type | unit | attrs |
|---|---|---|---|
| `system.cpu.utilization` | Gauge | `1` | `cpu=total` |
| `system.cpu.logical.count` | Gauge | `{cpu}` | — |
| `system.cpu.load_average.1m` | Gauge | `1` | — |
| `system.memory.usage` | Gauge | `By` | `state=used` / `state=free` |
| `system.memory.limit` | Gauge | `By` | — |
| `system.memory.utilization` | Gauge | `1` | — |
| `system.network.io` | Sum (monotonic, cumulative) | `By` | `device`, `direction=receive/transmit` |
| `system.filesystem.usage` | Gauge | `By` | `mountpoint`, `state=used` |
| `system.filesystem.utilization` | Gauge | `1` | `mountpoint` |

Per-core `system.cpu.utilization{cpu=<n>}` is a follow-on; `cpu=total` populates
the view.

## Node totals — the "total resource on that node"

In a container `/proc/meminfo` and `/proc/stat` report the **node** (physical
host), not the cgroup limit. That is exactly the requested baseline: the host
card shows the node's real capacity, and the per-worker `process.*` metrics sit
under it as the fine-grained slices, so photon can show each process against the
node total. (A cgroup-limit baseline is a cheap future add, not now.)

**Data sources (libc-free, `/proc` + syscalls — mandor's existing toolkit):**

| metric | source |
|---|---|
| `system.memory.{usage,limit,utilization}` | `/proc/meminfo`: `MemTotal` (limit), `MemTotal-MemAvailable` (used), ratio (util) |
| `system.cpu.utilization` (total) | `/proc/stat` `cpu` line: `1 - (idle+iowait)Δ / totalΔ` between ticks |
| `system.cpu.logical.count` | count of `cpuN` lines in `/proc/stat` |
| `system.cpu.load_average.1m` | `/proc/loadavg` field 1 |
| `system.network.io` | `/proc/net/dev` per interface, rx/tx bytes → monotonic sum |
| `system.filesystem.{usage,utilization}` | `statfs("/")` (v1); real mounts from `/proc/mounts` (follow-on) |
| `host.name` | `/proc/sys/kernel/hostname` (or `HOSTNAME` env) |
| `host.id` | `/etc/machine-id`, fallback `/proc/sys/kernel/random/boot_id` |
| `os.type` | constant `"linux"` |

CPU utilization and network io need a **previous sample** to delta against; the
sampler keeps one prior reading (fixed struct, no alloc). First tick emits no
CPU util (or 0) — same as the per-worker cpu%.

## How it rides existing rails

- A **host sampler** runs on the existing 5 s sampler tick (`runSamplerTick`),
  after the per-worker loop. Fixed prior-reading struct; zero allocation.
- The daemon gains a **host-scoped OTLP metrics** path: the existing
  `buildOtlpMetrics` generalizes to `(resource_attrs, metrics)` so one code path
  emits both the per-worker `service.name` resource and the host
  `host.name/host.id/os.type` resource. New frame kind `host_sample` (or reuse a
  compact host struct) over the same non-blocking pipe.
- **On by default** when `photon=` is set (one key, full story). TOML
  `telemetry.host = false` disables it (advanced, TOML-only — CLI stays 4 flags).
- Cadence, drop policy, priority: identical to the shipped metrics path
  (best-effort, dropped under backpressure; incidents remain durable/priority).

## Size & boundary

New: `/proc/meminfo`, `/proc/stat`, `/proc/loadavg`, `/proc/net/dev`, `statfs`
readers (line-oriented `std.mem` scanning, no regex, saturating arithmetic on
untrusted `/proc` bytes — the v1.0.x rule) + the host OTLP resource. Estimate a
few KB; still far under the 500 KB gate. Same offline-by-default boundary.

## Worker name override (separate, small)

Today the worker name is the command basename (`spawner.setName`), extension
included — `start.sh` → `start.sh`. Add an optional per-worker TOML key:

```toml
workers = ["./start.sh --serve", "./worker"]

[worker."start.sh"]      # section keyed by the DERIVED name
name = "api"             # overrides the display/telemetry name -> "api"
```

- `name` is validated like a derived name (neutralized for the Prometheus sink,
  length-capped, deduped if it collides). Empty/invalid → hard config error
  (configs are small; a typo should stop startup).
- The override flows everywhere the derived name does: log prefixes, `report`,
  Prometheus labels, incident `service.name`, lifecycle events, and per-worker
  metrics — one assignment at name-resolution time, so no call site changes.
- CLI stays 4 flags; this is TOML-only, consistent with "simplicity is a
  feature."

## Non-goals

- No GPU metrics (mandor is not a GPU agent; photon-agent's domain).
- No per-core CPU or multi-mount filesystem in v1 (follow-ons; `cpu=total` +
  root fs populate the view).
- No cgroup-limit baseline in v1 (node totals are the requested baseline).
- No node-vs-container ambiguity knob — node totals from `/proc`, per the goal.

## Open questions

1. `host.name` when multiple mandors run on one node: each reports the same node
   hostname → photon merges them into one host with all processes (arguably
   correct for "processes on this node"). If per-container separation is ever
   wanted, switch `host.name` to the container hostname. Default: node hostname.
2. Filesystem scope in v1: root `/` only, or enumerate real mounts from
   `/proc/mounts`? Recommend root-only first.
