# ENV configuration for mandor's deploy-varying keys — design

> Design doc. Target: **v1.12.0**. Lets an ENV-native app (Lenz) configure the
> handful of mandor settings that actually vary per deployment through
> `docker run -e`, overriding a static checked-in `mandor.toml` — deleting the
> ENV→TOML stitching in its `entrypoint.sh`.

## Problem

mandor is configured by 4 CLI flags + a TOML file; nearly every setting is
TOML-only. Lenz (`../lenz`) is natively ENV-configured — its CI deploy jobs pass
everything as `-e`. Today `scripts/entrypoint.sh` has to **generate** a
`mandor.toml`, stitching deploy env vars into TOML keys, and sets a **redundant**
`PHOTON_TOKEN=$PHOTON_OTLP_TOKEN` line because mandor reads a different token var
than Lenz's canonical one.

The config that genuinely varies **per deployment** (what a CI job sets
differently between dev / staging / prod / tenant) is small: the telemetry
**target + auth** and the **origin identity**. Everything else — the worker list,
per-worker sections, the secret store, restart/shutdown policy, health/PSI
thresholds, log/GPU tuning, the metrics endpoint — is fixed by the app and belongs
in a static, checked-in TOML.

**Goal:** those few deploy-varying keys are settable via ENV, ENV overrides the
TOML, and the var names align with what Lenz already sets — so the entrypoint
stops generating TOML and drops its redundant token line.

## Design

### Scope: the deploy-varying keys only

Exactly four keys become ENV-settable — the telemetry target/auth and the origin
identity:

| ENV var | config key | why it varies per deployment |
|---|---|---|
| `PHOTON_OTLP_HTTP_ENDPOINT` | `photon` (endpoint) | a different photon per environment, or none |
| `PHOTON_OTLP_TOKEN` | *(bearer token)* | per-environment ingest token |
| `MANDOR_SERVICE_PREFIX` | `service_prefix` | per-tenant origin tag on `service.name` |
| `MANDOR_STATE_DIR` | `state_dir` | per-deploy spool/state path *(env var already exists)* |

mandor is **OTLP/HTTP-only** (the relay POSTs protobuf over HTTP; no gRPC), so it
reads only the HTTP endpoint. `PHOTON_OTLP_HTTP_ENDPOINT` is Lenz's canonical HTTP
var (a full URL, `http://host:port`); mandor **strips a leading `http://` /
`https://` scheme** to get the bare `host:port` its parser + TOML `photon=` key
expect (a bare `host:port` is accepted too, so both forms work). This removes the
scheme-stripping the Lenz CI does today to derive a separate `PHOTON_OTLP` var. The
gRPC endpoint (`PHOTON_OTLP_GRPC_ENDPOINT`) is the app backend's tracing concern —
mandor does not read it.

**Everything else stays TOML/CLI-only** — it does not vary by deployment and/or
is not sensibly a flat env var: `workers`, `metrics_port`, `max_restarts`,
`backoff_max`, `stop_grace`, `restart_dependents`, `on_incident`,
`health_interval`, `health_start_period`, `psi_mem_pct`, `psi_cpu_pct`,
`expected_exit`, `env_file`, `ready_fd`, all `[logs]` keys (`digest`,
`digest_interval`, `digest_threshold`, `max_rate`), `[gpu] interval`, and every
`[worker.NAME]` / `[secret.NAME]` key.

### Precedence: CLI > ENV > TOML > default

Most-specific-first: an explicit **CLI flag** wins (where one exists —
`--state-dir`), then the **environment** variable, then the **TOML** key, then the
built-in **default**. This is the 12-factor expectation — a static TOML sets a
baseline and the deployment overrides per-`-e`. `MANDOR_STATE_DIR` already exists;
its resolution is brought under this same rule so all four behave identically.

### Naming

- Telemetry **target + auth** use the `PHOTON_OTLP*` family (aligned with Lenz and
  the OTLP ecosystem): **`PHOTON_OTLP_HTTP_ENDPOINT`** (the HTTP endpoint URL) +
  **`PHOTON_OTLP_TOKEN`** (bearer).
- **`MANDOR_*`** for mandor's own settings — a pattern that already exists
  (`MANDOR_STATE_DIR`), so it's consistent, not new: `MANDOR_SERVICE_PREFIX`,
  `MANDOR_STATE_DIR`.

**One token var.** mandor's current `PHOTON_TOKEN` is **renamed outright** to
`PHOTON_OTLP_TOKEN` (a recent, photon-only var whose sole real consumer is Lenz) —
a clean `PHOTON_OTLP_HTTP_ENDPOINT` + `PHOTON_OTLP_TOKEN` pair matching Lenz
exactly. No alias.

### Offline-by-default is unchanged

photon activates only if `photon` resolves to a value from *some* source
(`PHOTON_OTLP_HTTP_ENDPOINT` env or a TOML `photon=`). With neither, mandor opens
no socket and spawns no relay child. Setting `PHOTON_OTLP_HTTP_ENDPOINT` is as
deliberate an opt-in as writing the key; `PHOTON_OTLP*` is photon-specific, so the
accidental-collision surface is negligible.

### Where it plugs in

- **Global keys (`src/main.zig`):** the config-resolution block already merges
  `file_cfg` (TOML) into `cfg` (defaults + CLI). Insert an **ENV override pass** so
  the final order is CLI > ENV > TOML > default: for `photon` / `service_prefix` /
  `state_dir`, if a CLI flag set it, keep it; else if its env var is set, take (and
  validate) the env value; else the TOML value; else the default. Factor the
  per-key env read + parse into a small **testable helper** so precedence is
  unit-covered without launching the supervisor. Reuse `spawner.findEnv` and the
  existing validators — each env value is validated **exactly like its TOML
  counterpart** (a bad `PHOTON_OTLP_HTTP_ENDPOINT` exits 2 pre-socket via the
  existing endpoint check; an over-64-byte `MANDOR_SERVICE_PREFIX` is rejected).
  The photon value is passed through a small **scheme-strip** normalizer first
  (drop a leading `http://` / `https://`) so a full URL or a bare `host:port` both
  resolve to `host:port`; apply it to the TOML value too so both sources behave
  identically. Env values borrow the process `environ` (stable, zero-alloc).
- **Bearer token (`src/relay.zig`):** the `relay` child reads the token itself via
  `findEnv(environ, "PHOTON_TOKEN")` — in **two** places (the incident-ship `run`
  path ~line 68 and `runDaemon` ~line 1729). Change **both** literals to
  `PHOTON_OTLP_TOKEN`. Unset ⇒ empty (no `Authorization` header — unchanged).

## Companion change: GPU is auto-detected, not configured

`[gpu] enabled` is **removed**. GPU metrics have one correct state: on when the
host has a GPU, off when it doesn't — a toggle for a decision the hardware already
makes. The daemon **probes once at startup** (the existing NVIDIA `nvidia-smi` /
AMD·Intel DRM-sysfs detection): if a GPU is present it samples every `[gpu]
interval`; if not, it **logs once** (`[relay] no GPU detected; GPU metrics off`)
and the GPU timer never arms — a non-GPU host pays **nothing** afterward (no
periodic `nvidia-smi` fork/exec), matching the old default-off cost but
automatically. Detection is **one-time**: the daemon does not re-probe, so a GPU
that appears later needs a restart. Still fail-closed. `[gpu] interval` stays (TOML-only). The
`gpu_enabled` argument threaded to the relay child (`telemetry.spawnDaemon`) is
dropped. Breaking config change: a stale `[gpu] enabled` key becomes a dedicated
migration error (like the removed `restart` keys). GPU sampling stays gated by
`photon=` overall.

## Non-goals

- No ENV for structural/repeated config (`workers`, `[worker.NAME]`,
  `[secret.NAME]`), the metrics endpoint, policy/tuning (`max_restarts`, backoff,
  grace, health, PSI, `[logs]`/`[gpu]` tuning), or `on_incident`. Those stay
  TOML/CLI. This is the YAGNI line: only what a deployment actually varies.
- No gRPC: mandor is OTLP/HTTP-only, so it reads only `PHOTON_OTLP_HTTP_ENDPOINT`,
  never `PHOTON_OTLP_GRPC_ENDPOINT` (the app backend's tracing var).
- No back-compat alias for `PHOTON_TOKEN` — renamed outright.

## Lenz payoff

`scripts/entrypoint.sh` today generates the photon line + `[logs]` section
(lines 157–169) and emits `digest = true`. After this change:

- the whole `if [ -n "$PHOTON_OTLP" ] …` block is **deleted** — mandor reads
  `PHOTON_OTLP_HTTP_ENDPOINT` + `PHOTON_OTLP_TOKEN` directly (both already exist);
- `[logs] digest = true` is dropped (default when photon is on);
- the CI's `PHOTON_OTLP` derivation (gitlab-ci line 308 scheme-strip + the line-321
  `-e PHOTON_OTLP`) is **removed** — mandor strips the scheme itself;
- the CI's redundant `-e PHOTON_TOKEN=$PHOTON_OTLP_TOKEN` (gitlab-ci line 322) is
  removed — mandor reads `PHOTON_OTLP_TOKEN`;
- the deploy adds `-e MANDOR_SERVICE_PREFIX="${APP_NAME}-"`, so workers report as
  `raisa-gateway-nb-<name>` / `-rc-<name>` — no `service.name` collisions across
  deployments in the shared photon;
- the generated TOML shrinks to the **static** structure (workers + `[worker.*]` +
  `[secret.*]`), its only remaining dynamic part the feature-conditional worker
  list — genuine business logic, not mandor-config plumbing.

## README config table

Add a **Config keys** table (in the README, linked from CONFIG.md) listing every
config key with columns **key · TOML · CLI flag · ENV var** — the four env-settable
keys show their var, all others a blank ENV cell, making the boundary explicit at a
glance. `docs/CONFIG.md` and `docs/INTEGRATION-PHOTON.md` get the same annotations.
CHANGELOG entry calls out the two breaking changes (the `PHOTON_TOKEN` →
`PHOTON_OTLP_TOKEN` rename, and the `[gpu] enabled` removal).

## Testing

- **Unit (env-resolution helper):** each of `photon` / `service_prefix` /
  `state_dir` comes from its env var when the TOML omits it; **ENV overrides a
  present TOML value**; a CLI flag still overrides ENV (`--state-dir`); neither
  source ⇒ default (offline for photon); a malformed `PHOTON_OTLP_HTTP_ENDPOINT` is
  rejected exactly like a malformed TOML `photon=` (exit 2, no socket); an
  over-64-byte `MANDOR_SERVICE_PREFIX` is rejected like the TOML value.
- **Scheme-strip (unit):** `http://h:9`, `https://h:9`, and bare `h:9` all
  normalize to `h:9`; a value with no scheme is untouched.
- **Token (`relay.zig`):** the bearer resolves from `PHOTON_OTLP_TOKEN`; empty when
  unset (no auth header).
- **GPU auto-detect:** with no GPU present the daemon arms no GPU timer and emits
  no GPU datapoints (fail-closed); a stale `[gpu] enabled` key is a dedicated
  migration error. Present-GPU path stays covered by the existing gpu tests.
- fmt / `zig build test` green; size + config-surface gates unaffected (env vars
  aren't TOML rows; the net TOML key change is `-1` for `[gpu] enabled`); mutation
  each new guard.

## Constraints (motto governs)

Stability: env reads are startup-path only (never the supervision loop), total (a
missing var is `null`), zero-alloc (slices borrow `environ`), no
`unreachable`/panic. Simplicity: a **tight, bounded** surface — four deploy-varying
keys, aligned names, a discoverability table — plus a net *reduction* in config
keys (`[gpu] enabled` removed). Offline-by-default preserved exactly.
