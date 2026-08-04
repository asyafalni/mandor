# App Shared Secret Store — design

> **Status:** design, approved direction — not yet built. A per-container-session
> secret that mandor mints at boot and delivers only to designated workers over a
> non-ENV, non-disk channel, locked structurally against everything else.

**Goal:** let workers on the same mandor share a boot-time secret without it ever
appearing in ENV (`/proc/<pid>/environ`), argv (`/proc/<pid>/cmdline`), or on
disk — replacing the current file-drop hack (`/run/integration-lock/secret` in
`scripts/proxy.sh`, readable by anyone who can stat the path). mandor generates
the secret; only the designated workers can obtain it; it is renewed each
container session and unobtainable by any other process.

## Motivating example

`proxy.sh` today: the gateway (BE) generates a signing secret at boot, writes it
to a shared file; the nginx (FE) polls for the file and reads it. Two warts: the
secret lives on a readable path, and the BE needs generation logic. With this
feature mandor mints the secret and hands it to both workers over private fds —
no file, no generator, no polling.

## Configuration (`mandor.toml`)

Mirrors the existing `[worker.NAME]` convention:

```toml
[secret.integration]
workers = ["gateway", "proxy"]     # required: the designated set

[secret.otp]
workers = ["gateway"]
bytes   = 6
format  = "b10"                    # a 6-digit numeric code
```

| key | type | default | meaning |
|---|---|---|---|
| `workers` | string list | — (required) | which workers receive this secret. Every name must be a defined worker (else hard config error). Empty list → error. |
| `bytes` | int | `32` | length knob (see per-format below). Range **1–4096**; out of range → error. |
| `format` | string | `"hex"` | one of `hex` \| `b10` \| `b32` \| `b64` \| `b64url` \| `raw`. Unknown → error. |

Multiple `[secret.*]` sections are independent secrets, each with its own value,
`bytes`, `format`, and worker set. A worker may belong to several secrets.

Secret names: `[a-z0-9-]` (lowercase); uppercased + `-`→`_` for the env var
(`integration` → `MANDOR_SECRET_FD_INTEGRATION`). A name that collides with
another after this mapping → hard config error.

## Formats

All values from a single CSPRNG draw (`getrandom`). Printable formats are written
as one `\n`-terminated line so a shell `read` gets a clean value; `raw` is the
bytes then EOF.

| format | output | `bytes` means | encoding |
|---|---|---|---|
| `hex` | lowercase, 2 chars/byte | entropy bytes | base16 |
| `b32` | `A–Z 2–7`, **no padding** | entropy bytes | RFC 4648 base32 |
| `b64` | `A–Z a–z 0–9 + /`, `=` padded | entropy bytes | RFC 4648 §4 |
| `b64url` | `A–Z a–z 0–9 - _`, no padding | entropy bytes | RFC 4648 §5 |
| `b10` | decimal digits `0–9` | **digit count** | uniform digits |
| `raw` | the raw bytes (no newline) | entropy bytes | none |

**`bytes` is entropy bytes for every format EXCEPT `b10`, where it is the number
of digits** (digits-per-byte is fractional, and what a `b10` user wants is an
exact-length code like a 6-digit PIN).

**`b10` must be unbiased:** each digit is drawn by rejection sampling — take a
random byte, use `byte % 10` only when `byte < 250` (the largest multiple of 10
≤ 255), else draw again. A naive `byte % 10` would over-represent digits 0–5.

**`raw` caveat:** binary; a shell cannot `read` it (may contain NUL/newlines).
It exists for binary consumers that read the fd to EOF. `hex` is the default
precisely because the consumers are usually `sh`.

## Delivery — inherited pipe fd (per spawn)

For each designated worker, on **every (re)spawn**:

1. mandor `pipe2(O_CLOEXEC)` a fresh pipe.
2. Writes the encoded secret (`<value>\n`, or raw bytes for `raw`) to the write
   end — ≤ a few KB, far under `PIPE_BUF`, so it never blocks.
3. Spawns the worker; in the child (pre-`execve`) mandor **clears `FD_CLOEXEC` on
   the read end only**, so exactly this worker inherits it (the `keep_fd` trick
   the telemetry daemon already uses, generalized to a *list* of fds — a worker
   in N secrets keeps N read ends).
4. Sets `MANDOR_SECRET_FD_<NAME>=<fd>` in that worker's env — the fd **number**,
   which is not sensitive.
5. mandor closes **both** ends in the parent after the fork. The child reads the
   buffered value then gets EOF; no other process ever holds the read end.

The secret *value* lives only in mandor's memory (below) and is re-written to a
fresh pipe on each spawn — nothing persistent is created.

Consumer (shell): `IFS= read -r SECRET <&"$MANDOR_SECRET_FD_INTEGRATION"`.

## Lifecycle & the "lock" (structural, not a state machine)

- **Generated once per container session**, at first use, into a fixed buffer
  that mandor `mlock`s (never swapped) and holds for the life of the process.
- **Re-delivered** to any *designated* worker each time it (re)spawns — restarts
  included — so a crashed FE that mandor restarts gets the same session secret
  back. This is why the value persists rather than being wiped after boot.
- **Locked by construction:** the *only* path to the value is push-at-spawn to
  the designated set. There is no fetch API, no file, no CLI, no way to add a
  worker to a secret after startup. A non-designated worker, or anything spawned
  later, therefore has no path to it — ever. That satisfies "once the designated
  workers have it, no other process can access it" without a lock flag.
- **Renewed only on container restart** (a new mandor process → a new
  `getrandom`), matching the per-`docker run` requirement.
- At mandor exit the buffer is best-effort `memset`-wiped (process death frees it
  regardless).

**Security posture tradeoff (recorded):** persisting the value for restart
re-delivery means it stays resident in mandor's (PID-1) memory, readable only via
`/proc/1/mem` by root — who can already read any process's memory. We accept this
in exchange for restart resilience; the alternative (wipe-after-boot) was
rejected because a one-shot secret dying on the first worker crash would force a
full container restart, defeating mandor's purpose.

## Security boundary (honest)

mandor guarantees the secret is in **no** process's environ, argv, or on disk at
handoff, and that only designated workers can obtain it. What a worker does after
reading is its own exposure: `proxy.sh` today does
`export VITE_INTEGRATION_SIGNATURE_SECRET=…`, which puts it back into that
worker's *own* environ (and a served `config.js`). The migration note shows a
no-`export` `envsubst` pattern that keeps it out of the FE's environ.

## Error handling (fail-closed, mandor discipline)

- `getrandom` or `pipe2`/`fcntl` failure → mandor logs and does **not** fabricate
  or reuse a value; the affected worker's read gets EOF/empty and fails its own
  check (exactly `proxy.sh`'s existing "missing → exit 1 → mandor restarts").
- Config validation is a hard startup error: unknown worker in `workers`, empty
  `workers`, `bytes` out of 1–4096, unknown `format`, name/env collision.
- No `unreachable`, no panic. Arithmetic on sizes saturates. Secret handling is
  off the supervision hot path (only touched at spawn). No new dependency
  (getrandom is a raw syscall; hex/base32/base64 are hand-rolled table encoders).

## `proxy.sh` migration (before → after)

```sh
# BEFORE — BE generates + writes a file; FE polls + reads it:
#   SECRET_FILE=/run/integration-lock/secret
#   while [ ! -f "$SECRET_FILE" ]; do sleep 1; done
#   export VITE_INTEGRATION_SIGNATURE_SECRET="$(cat "$SECRET_FILE")"

# AFTER — mandor delivers it on a private fd; no file, no poll, no generator:
IFS= read -r VITE_INTEGRATION_SIGNATURE_SECRET <&"$MANDOR_SECRET_FD_INTEGRATION"
export VITE_INTEGRATION_SIGNATURE_SECRET
# (or, to keep it out of the FE's environ, feed the fd straight into envsubst.)
```
The BE gateway drops its generation/file-write and reads the same fd.

## Testing

- **Unit:** config parse (each key, defaults, every rejection path); each
  encoder's length/alphabet (hex 2×, b32 unpadded uppercase, b64 padded, b64url
  unpadded url-safe, raw exact bytes); `b10` digit count == `bytes`, digits only,
  and a statistical check that the rejection sampler doesn't skew (many draws,
  each digit 0–9 appears).
- **Harness (integration):** a designated worker reads its fd and echoes the
  length/charset — assert it matches the configured format; **two** workers in
  one secret receive the **identical** value; a **non-designated** worker has
  **no** `MANDOR_SECRET_FD_*` in its environ; a worker **restart** re-delivers
  the **same** value; **two mandor runs** yield **different** values; the
  `getrandom`/pipe failure path fails closed (worker sees EOF, exits).
- **Mutation:** break the `b10` rejection bound (250 → 256) and confirm the
  skew test fails; drop the CLOEXEC-clear and confirm the "non-designated worker
  has no secret fd" / "designated worker can read" invariant flips.

## Non-goals

- No asymmetric **keypair** generation (RSA/ed25519/PEM) — this store is random
  symmetric bytes; keypairs are a separate feature.
- No runtime fetch API, no post-startup membership changes, no persistence across
  container restarts (per-session is the point).
- No CLI flag — `[secret.*]` is TOML-only, keeping the everyday CLI at 4 flags.

## Size / boundary

A small `secret.zig` (getrandom + the encoders + per-spawn pipe) plus config
parsing and a generalized multi-`keep_fd` in the spawn path. Estimated a few KB;
well under the 500 KB budget. Offline (no network); ReleaseSafe.
