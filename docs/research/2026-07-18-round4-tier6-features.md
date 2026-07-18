# Round-4 supervisor feature research — Tier 6 candidates

*2026-07-18. Fresh territory only (rounds 1–3 exhausted the mainstream):
OpenWrt procd / finit, preforking app-server masters, Linux security
primitives at exec, PSI, core-dump capture, JSON supervisor logging, cgroup
freezer. Verdict: two candidates clear the bar, one B-tier, one already
essentially shipped; everything else rejects. Both strong picks are
extensions of existing subsystems (the /proc+cgroup sampler; the uid:gid
drop path) — which is why they survive where net-new subsystems wouldn't.*

## Ranked candidates

| # | Feature | Cx | Value | Rationale | Demand proof |
|---|---------|----|-------|-----------|--------------|
| 35 | PSI stall sampling (cgroup v2 `memory/cpu/io.pressure`) as a detector signal | S | ●●●○ | Catches CPU-throttle and I/O-stall — a class mandor is blind to today — and flags memory distress earlier/more reliably than RSS slope. Pure sampler+cgroup extension, cgroup-v2-native, zero worker cooperation | https://docs.kernel.org/accounting/psi.html · https://lwn.net/Articles/759658/ |
| 36 | `no_new_privs` + capability bounding-set drop at exec | S | ●●●○ | Companion to the uid:gid drop we already do — `no_new_privs` closes the setuid re-escalation hole that dropping uid alone leaves open; per-worker cap drop is finer than a container-wide flag. A prctl/capset handful, no libcap dep | https://oneuptime.com/blog/post/2026-01-16-docker-drop-capabilities/view (CVE-2019-5736) |
| 37 | JSON supervisor-event log (`--log-format=json`) | S | ●●○○ | mandor's own meta-events (spawn/exit/restart/incident) as JSON lines for Loki/Datadog. Reuses the bundle JSON builder. Supervisor events ONLY — never wrap worker stdout (would mangle multiline traces) | https://grafana.com/docs/alloy/latest/reference/components/loki/loki.process/ |
| 38 | `RLIMIT_CORE` in bundle (core_dumped flag already shipped v0.5) | XS | ●○○○ | We already record `core_dumped`; only the core-size-limit detail is new. Marginal | — |

## Confirmed rejects

- **Full core-dump capture into the spool** — `core_pattern` is host-global,
  not namespaced; a container PID-1 can't set it, and dumps are 100s of MB.
  Take only the `core_dumped` flag (already shipped).
- **SIGHUP live reload of mandor.toml** — anti-container: immutable
  deployments redeploy, not reload; live reconciliation on the PID-1
  critical path is where a bug kills the container. VM/host-init feature.
- **read-only rootfs / mount-ns / tmpfs isolation** — the runtime does it
  better (`--read-only`, `--tmpfs`, k8s `readOnlyRootFilesystem`);
  per-worker would need mount namespaces + CAP_SYS_ADMIN. Document instead.
- **seccomp profiles** — per-workload BPF tuning = heavy config vs the
  zero-config mandate; `--security-opt seccomp=` at the runtime is superior.
- **cgroup freezer pause/resume** — needs a live control-plane IPC mandor
  lacks; overlaps `docker pause`; only helps hangs, not crashes.
- **Hang detection via wchan/stack sampling** — can't tell "blocked in
  epoll doing its job" from "deadlocked" without app knowledge → false
  restarts, violates the reliability mandate. Health checks already cover it.
- **Preforking rolling restart / USR2 socket-preserving upgrade / TTIN-TTOU
  scaling** — wrong process model (mandor supervises heterogeneous *named*
  workers, not an identical pool behind a shared socket); the valuable part
  (socket handoff) requires worker cooperation → hard reject.
- **finit/procd condition graph** — `start_after` + readiness + health
  gating already cover container ordering; a richer condition namespace is
  router/embedded-boot machinery, config surface for little container payoff.

## Design sketches (top two)

**PSI sampling (35).** The sampler already opens the worker cgroup for OOM
detection; also read `memory/cpu/io.pressure` (or `/proc/pressure/*` sans
cgroup), scan the `some avg60=` float (fixed scan, no regex). Two flat knobs
`psi_mem_pct`/`psi_cpu_pct` (default off) → new detector cause
`stall:memory|cpu|io` when `avg60` exceeds threshold across N samples; add a
`psi` field to `stats_timeline` (bundle schema → v6). Stronger leak/OOM
signal than RSS slope, plus a genuinely new throttle/thrash verdict.

**no_new_privs + cap-drop (36).** Slot into the post-fork/pre-exec user-drop
code. After setgid/setuid, `prctl(PR_SET_NO_NEW_PRIVS, 1)` unconditionally
when a user is dropped (strictly safer). Add flat `cap_drop = ["NET_RAW", …]`
(or `= "all"` + `cap_keep`), via `PR_CAPBSET_DROP` over a small static
name→bit table (no libcap, keeps the no-deps rule). Direct syscalls, a few
hundred bytes, zero cooperation; composes with runtime hardening.

**Bottom line:** four rounds in, the well is nearly dry — these two survive
only because they deepen existing strengths (forensic detection; security
drop). A fifth round is not worth running.
