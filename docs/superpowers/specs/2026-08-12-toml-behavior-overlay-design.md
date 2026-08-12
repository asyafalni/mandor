# mandor: TOML as a name-keyed behavior overlay over the CLI-chosen worker set

> Design doc. Target: **v1.13.0**. Lets an operator ship a **static, immutable,
> never-rewritten** `mandor.toml` that declares *behavior* for the full set of
> *possible* workers, and choose the *actual* worker set — with per-deployment
> command lines — on the CLI. No per-boot config templating.

## Headline principle

**The CLI-spawned worker set is the source of truth. The TOML is a behavior
overlay matched by name.** A `[worker.NAME]` section — or a `[secret.*]` worker
reference — for a worker the final CLI did *not* spawn is a **no-op**: silently
ignored (a warning is fine), never an error, and never itself a reason to spawn
anything.

**Separation of concerns:** the worker *command line* — the executable and its
params — lives **only** on the CLI. The TOML is keyed by worker name and holds
**no** command or arguments; it only overlays *behavior* (`name`, `stream`,
`[logs] digest`, `[secret.*]` grants, and the other per-worker keys).

### Matching rule

For a run the active worker set is whatever the CLI spawns (or, if the CLI gives
none, the TOML `workers = […]`). Then:

- **spawned worker ∩ has TOML section** → the section's `name` / `stream` / etc. apply.
- **TOML section with no spawned worker** → ignored (warn, don't fail). *TOML never spawns.*
- **spawned worker with no TOML section** → runs with defaults (basename as name, no stream).

## Use case

mandor runs as PID 1 in a Docker image; the set of workers varies per container
start (feature flags → CLI args): `gateway` + `proxy` always, `pmtiles` only in
offline-map mode, `visionaire-hub` only for one client build. The command lines
(with per-deployment params) are built at startup. The operator wants:

```dockerfile
COPY mandor.toml /etc/mandor.toml         # static, immutable, never rewritten
exec mandor --config=/etc/mandor.toml -- \
     ./gateway.sh ./proxy.sh [./pmtiles.sh] [./visionaire-hub.sh]
```

where `mandor.toml` statically declares `[logs] digest`, the four `[worker.*]`
sections, and the `[secret.*]` grant — mandor applies each to whichever of those
workers the CLI actually launched and ignores the rest.

## Current architecture (why it's blocked today)

Two gaps force per-boot templating:

- **Gap 1 — orphan `[worker.NAME]` sections hard-fail `validate`.** `applyConfig`
  already only *warns* on an unknown worker ref (`run` tolerates it), but
  `supervisor.validate` then hard-fails: `if (setup_warnings > 0)` →
  `"config invalid: N unknown worker reference(s)"` (supervisor.zig ~233). The
  entrypoint runs `mandor validate` before `exec`, so that blocks boot.
- **Gap 2 — secrets resolve at parse time against the TOML worker list.**
  `config.parse` → `resolveSecrets` maps each `[secret.*]` worker *name* to an
  *index* in the TOML's `workers` list with `matchWorker(...) orelse return
  error.BadValue` (config.zig). And `main.zig` explicitly **refuses** CLI workers
  + secrets together ("`[secret.*]` requires workers defined in the config file,
  not on the CLI", main.zig ~247) — because indices resolved against the TOML
  list would point at the wrong process once CLI workers replace them (a silent
  mis-grant). So a `[secret.*]` grant naming a CLI-only worker fails `config.parse`
  outright, before the CLI `--` args are merged — which is why `validate --
  <cmds>` can't see them (it reports `invalid config file: bad value`).

## Design

Three changes make the headline principle real.

### 1. Defer secret resolution to *after* the CLI/TOML worker merge

`config.parse` **stops** resolving secret worker-names to indices. It keeps the
name references it already stashes in `FileConfig.secret_refs`, and keeps the
parse-time checks that do **not** need the worker set (see §3). A **new resolver**
runs after `main.zig` finalizes `cfg.commands` (CLI `--` args, else TOML
`workers=`), mapping each grant's names against **that final set**, using the same
`names`-derived basenames the supervisor spawns under. This is what makes both
`run` **and** `validate` resolve `[secret.*]` (and, transitively, everything) against
the CLI workers.

- New function in `config.zig`, e.g. `resolveSecretGrants(secrets, secret_refs,
  commands) void` (pure; no ParseError), called from `main.zig` immediately after
  `cfg.commands` is finalized (after the `if (cfg.commands.len == 0) cfg.commands
  = file_cfg.commands;` line). It rewrites each `SecretDef.workers` to the indices
  of the *present* listed workers.
- Because resolution is now by name against the final set, the stale-index
  mis-grant that motivated the refusal **cannot occur** — allowing the mix is safe,
  not merely permitted.

### 2. Secret grants never hard-error — graceful, deny-by-default

Resolution changes `orelse return error.BadValue` → **skip the absent worker**.
A secret is delivered to exactly the intersection of *(listed workers)* ∩
*(present workers)*:

- a listed worker not in the active set is simply not granted (no error);
- if the intersection is empty — **including an explicit `workers = []`** — the
  secret is **inert** (minted for nobody), with at most a one-line warning. The
  old parse-time `workers_len == 0 → BadValue` check is **removed**.

Deny-by-default is preserved and arguably tightened: skip-on-absent is strictly
more restrictive, and grant-by-name against the actual set is exact — no worker
ever receives a secret it is not listed for.

The `main.zig` "secrets require config-file workers, not the CLI" refusal (~247)
is **removed**.

### 3. `validate` tolerates orphan worker references

Drop the `setup_warnings > 0 → return 1` hard-fail in `supervisor.validate`.
Orphan `[worker.NAME]` / `[secret.*]` references stay **warnings** ("no worker
named X — ignored"), so one static superset TOML validates against any CLI
subset. `validate` still fails on *real* errors: TOML syntax, dependency cycles,
`bad value` (a malformed key), too-many-workers, etc.

### What stays a hard error (the only secret error left)

**Two secrets resolving to the same env var name** (both would write `CONFD_X` —
a clobber). This is unrelated to worker presence and has no sensible graceful
behavior, so `resolveSecrets`' env-collision check is kept (moved into the parse-
time set, since it is name-based and needs no worker set). Empty-`workers` and
unknown-worker are no longer errors.

### Precedence & guarantees (unchanged)

- **CLI worker set wins.** If both a TOML `workers=` and CLI `--` args are given,
  the CLI set is used and the TOML `workers=` is ignored. TOML `workers=` remains
  supported as the fallback when the CLI gives none.
- **Command line is CLI-only.** There is no `command`/`args` key in
  `[worker.NAME]`, and this design adds none. The TOML overlays behavior only.
- **Nothing spawns from the TOML.** A `[worker.NAME]` / `[secret.*]` reference
  never causes a worker to exist.

## Backward compatibility

Purely loosening — **no previously-valid config changes behavior**. Configs that
put `workers=` in the TOML alongside secrets keep working byte-for-byte. Things
that used to hard-fail (orphan sections, `workers = []`, CLI-workers-with-secrets)
now succeed. The only capability *lost* is `validate` catching a typo'd section
name — the accepted tradeoff (a superset TOML can't distinguish a typo from an
intentionally-not-spawned worker; that's the operator's responsibility).

## Where it plugs in

- `src/config.zig` — remove the index resolution + `workers_len==0` check from
  `resolveSecrets` (or split it): `config.parse` no longer resolves grants to
  indices (keeps `secret_refs` names + the env-collision check). Add the pure
  post-merge resolver.
- `src/main.zig` — remove the CLI-workers+secrets refusal (~247–250); after
  `cfg.commands` is finalized, call the new resolver with `cfg.commands`.
- `src/supervisor.zig` — `validate`: drop the `setup_warnings > 0 → return 1`
  block; keep the informative per-ref warnings emitted by `applyConfig`.

## Testing

- **Unit (`config.zig`):**
  - `config.parse` **succeeds** on a TOML with `[secret.*]` referencing names not
    in a (possibly empty) TOML `workers=` — it no longer resolves indices there.
  - the resolver maps a grant to only the **present** listed workers; an absent
    listed worker is skipped; an all-absent / `workers = []` grant resolves to
    **zero** recipients (inert), no error.
  - two secrets sharing an env name still error (`BadValue`) at parse.
- **Unit / behavior (`supervisor`):** `validate` returns 0 for a config whose
  `[worker.*]` sections name workers absent from `cfg.commands` (orphans tolerated);
  still returns non-zero for a real error (e.g. a dependency cycle).
- **Harness e2e (`test/harness/run_tests.sh`):** a **static** superset TOML
  (`[worker."a"] name=… stream=true`, `[worker."b"]…`, `[secret.s] workers=["a","b"]`)
  run with the CLI spawning only a subset (`-- a`) →
  (a) `mandor validate --config=… -- a` exits 0;
  (b) the spawned worker gets its overlaid name/stream;
  (c) the secret reaches the present worker and NOT the absent one (assert the
  absent worker's env grant never appears);
  (d) the orphan `[worker."b"]` section produces a warning, not a failure.
- fmt / `zig build test` green; size + config-surface gates unaffected (no new
  keys); mutation each new guard.

## Constraints (motto governs)

Stability: resolution is startup-path only, total (a missing worker is just
skipped), zero-alloc beyond the existing fixed config buffers, no
`unreachable`/panic. Simplicity: this *removes* config surface and error paths
(no new keys, three checks deleted). Deny-by-default and the offline guarantee are
untouched. Bump to **v1.13.0**.
