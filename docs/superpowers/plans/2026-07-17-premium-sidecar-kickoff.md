# mandor premium sidecar — kickoff plan (separate repo)

Per CLAUDE.md: premium logic lives OUTSIDE this binary. New repo (suggest
`asyafalni/mandor-sidecar`); the spool dir JSON + on_incident hook are the
ONLY interfaces to the core.

## Product

Watches mandor's incident spool → ships bundles to the relay → AI root-cause
→ optional repo access → auto-fix PR. Free core stays offline forever.

## Architecture decisions (carried from today's research)

- **Ingestion, two modes:** (a) `on_incident = ["/mandor-relay"]` push (bundle
  path argv — instant, no polling); (b) spool-dir scan on start for backlog
  (files are epoch-ms-named, atomic-renamed, self-pruned at 200).
- **Bundle contract:** schema v5, versioned (`"v"`), golden-locked in core.
  Sidecar must accept v>=2 and skip unknown fields.
- **Language:** Rust (rustls for TLS — the reason the core can't do this) or
  Go; decide at kickoff. Static musl build, same distro-agnostic story.
- **Relay protocol:** POST bundle JSON + license token over HTTPS; relay does
  LLM orchestration server-side (bundle → localization via structured frames
  file:line/in_app + exception.type — the ablation-proven levers → repo
  checkout → fix → PR). `build.release`/`elf_build_id` drive suspect-commit
  ranking (~70% of outages are changes; Meta gets 42% RCA from diff ranking
  alone).
- **photon co-integration:** same binary can double as the photon relay
  (OTLP/HTTP POST to localhost:4318) — see docs/INTEGRATION-PHOTON.md
  mapping table. One shim, two backends, config-selected.
- **Never in scope:** reading worker source from the container; repo access
  happens relay-side via the user's granted GitHub app permissions.

## Core-repo follow-ups (this repo, small)

- Size diet when the 500 KB gate nears: custom panic handler to drop
  std.debug's DWARF/ELF/flate machinery (~100 KB in .text/.rodata today);
  BSS is already free.
- Alpine aports APKBUILD + Debian ITP once the sidecar launches (adoption
  driver).

## MVP milestones

1. `mandor-relay` binary: hook-mode + backlog scan, POST to configurable
   endpoint (photon OTLP mapping first — free-tier visible value, no relay
   service needed yet).
2. Relay service + license check + LLM loop (server-side).
3. PR authoring: repo checkout, fix generation constrained to
   `trace.frames[in_app]` files, test-run gate, PR with bundle-linked
   explanation.
