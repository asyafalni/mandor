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
| `env` | string | `CONFD_<NAME>` | the env var mandor sets to this secret's **fd number**. Override to blend with your app's own env (e.g. `APP_CHANNEL`, `RUNTIME_HANDLE`). Validated `^[A-Z_][A-Z0-9_]*$`; a value colliding with another secret's env → error. |

Multiple `[secret.*]` sections are independent secrets, each with its own value,
`bytes`, `format`, and worker set. A worker may belong to several secrets.

**Env var naming.** By default the fd number lands in `CONFD_<NAME>` — `<NAME>`
uppercased with `-`→`_` (`integration` → `CONFD_INTEGRATION`). `CONFD` reads as
"config fd" (privately: *confidential*) — deliberately unremarkable, so a glance
at a process's environ shows nothing flagged like `SECRET`/`MANDOR`. It carries
only the fd number, never the value; the actual lock is the fd inheritance, not
the name — obscuring the name is defense-in-depth, not the protection. Set `env`
per secret to make it indistinguishable from your app's own config vars. Derived
names that collide (two secrets → the same env var) → hard config error.

## Access model (grants + deny-by-default)

A secret's `workers` list **is** its access grant. mandor can hold many secrets;
each worker receives an fd (and its `CONFD_<NAME>` env var) **only**
for the secrets whose `workers` list names it. Everything else is denied.

```toml
[secret.integration]   # granted to gateway, proxy
workers = ["gateway", "proxy"]
[secret.db-signing]    # granted to gateway only
workers = ["gateway"]
[secret.cron-token]    # granted to cron only
workers = ["cron"]
```

| worker | integration | db-signing | cron-token |
|---|---|---|---|
| `gateway` | ✅ | ✅ | ❌ |
| `proxy` | ✅ | ❌ | ❌ |
| `cron` | ❌ | ❌ | ✅ |

**Denial is structural, not a runtime check.** An ungranted worker gets no env
var and no fd for that secret: the pipe's read end is `O_CLOEXEC` (closed on
every worker's `execve`) and CLOEXEC is cleared *only* for granted workers;
mandor closes its own ends after the fork. So an ungranted worker has no
descriptor to that secret's pipe at all — it cannot read it even by probing fd
numbers, and there is no file/socket/API fallback. Least privilege by
construction; the secret-centric config keeps each secret's full blast radius
visible in one place.

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
4. Sets the secret's env var to `<fd>` in that worker's env — `CONFD_<NAME>` by
   default, or the configured `env` name — the fd **number**, not sensitive.
5. mandor closes **both** ends in the parent after the fork. The child reads the
   buffered value then gets EOF; no other process ever holds the read end.

The secret *value* lives only in mandor's memory (below) and is re-written to a
fresh pipe on each spawn — nothing persistent is created.

See the consumer guide below for reading it from any language.

## Consuming the secret — developer guide (any language)

The contract is language-agnostic, three rules:

1. **Find the fd.** Read the number from env `CONFD_<NAME>` — `<NAME>`
   is the secret name **uppercased** with `-` → `_` (`integration` →
   `CONFD_INTEGRATION`). **Absent var = you were not granted this
   secret** (deny-by-default) — fail/exit; do not proceed without it.
2. **Read it once, at startup, to EOF.** Printable formats (`hex`/`b10`/`b32`/
   `b64`/`b64url`) arrive as a single `\n`-terminated line — strip the trailing
   newline. `raw` arrives as exactly `bytes` binary bytes with **no** newline —
   read to EOF, keep the bytes as-is (don't line-read, don't strip). The pipe
   EOFs after the one value; there is nothing to re-read later.
3. **Close the fd** when done — you only need it at boot.

**POSIX shell (`sh`/`dash`/busybox — e.g. `proxy.sh`):**
```sh
FD="$CONFD_INTEGRATION"
[ -n "$FD" ] || { echo "not granted the 'integration' secret" >&2; exit 1; }
# `<&"$var"` isn't portable in dash, so eval the fd number in:
eval "IFS= read -r SECRET <&$FD"     # bash/zsh can use: IFS= read -r SECRET <&\"$FD\"
eval "exec $FD<&-"                    # close (optional)
```

**Go:**
```go
v := os.Getenv("CONFD_INTEGRATION")
if v == "" { log.Fatal("not granted the 'integration' secret") }
fd, _ := strconv.Atoi(v)
f := os.NewFile(uintptr(fd), "mandor-secret")
raw, _ := io.ReadAll(f) // read to EOF
f.Close()
secret := strings.TrimRight(string(raw), "\n") // omit TrimRight for format="raw"
```

**TypeScript / Node:**
```ts
import { readFileSync, closeSync } from "node:fs";
const v = process.env.CONFD_INTEGRATION;
if (!v) throw new Error("not granted the 'integration' secret");
const fd = Number(v);
const buf = readFileSync(fd);                       // reads the pipe to EOF
closeSync(fd);
const secret = buf.toString("utf8").replace(/\n$/, ""); // for "raw", keep `buf`
```

**Python:**
```python
v = os.environ.get("CONFD_INTEGRATION")
if not v: raise SystemExit("not granted the 'integration' secret")
with os.fdopen(int(v), "rb", closefd=True) as f:
    secret = f.read().rstrip(b"\n")   # for format="raw", keep f.read() as-is
```

**Any other language:** get the integer fd from the env var, `read()` that file
descriptor to EOF, strip a trailing `\n` for printable formats. That's all —
it's an ordinary inherited pipe.

**Keeping it out of your own environ:** reading via the fd does *not* put the
secret in your environ. If you then `export` it (as `proxy.sh` did for
`envsubst`), it re-enters *your* process's environ — avoid that where you can by
passing the value in-process (or piping the fd straight into the tool that needs
it) rather than exporting.

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
reading is its own exposure: for a secret you keep server-side, avoid re-exporting
it into your own environ (pass it in-process, or pipe the fd straight into the
tool that needs it). For a secret you deliberately ship client-side — like the
`proxy.sh` case that folds it into a browser-served `config.js` — re-`export`-ing
for `envsubst` is correct and the value is public to SPA users by design; see the
migration section's caveat. Either way, mandor's job is the **server-side**
channel up to handoff.

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

Config: `[secret.integration] workers = ["gateway", "proxy"]`, `format = "hex"`.

`proxy.sh` (nginx FE) — replace the file-wait block (current lines 17–33) with an
fd read; **everything downstream (`export` → `envsubst` → `config.js` →
`window.ENV`) is unchanged, so the SPA digests the value identically:**

```sh
# BEFORE: SECRET_FILE=/run/integration-lock/secret; poll for it; cat + export.
# AFTER — mandor delivers it on a private fd; no file, no poll, no generator.
if [ -z "$CONFD_INTEGRATION" ]; then
    echo "ERROR: CONFD_INTEGRATION not set (not granted the integration secret); exiting" >&2
    exit 1                       # same failure behavior as today -> mandor restarts the container
fi
# proxy.sh is /bin/sh (dash/busybox): `<&"$var"` is not portable, so eval the fd number in.
eval "IFS= read -r VITE_INTEGRATION_SIGNATURE_SECRET <&$CONFD_INTEGRATION"
export VITE_INTEGRATION_SIGNATURE_SECRET

# envsubst -> config.js (window.ENV) below is UNCHANGED; the SPA sees the same value.
```

The BE gateway lists in the same secret's `workers`, so it reads the **identical**
mandor-generated value from **its** `CONFD_INTEGRATION` fd and signs with it —
BE-signs / SPA-verifies stays consistent — and drops its old
generate-and-write-file code.

**Caveat — the SPA case intentionally exposes this value to browsers.** `proxy.sh`
folds `VITE_INTEGRATION_SIGNATURE_SECRET` into the nginx-served `config.js`
(`window.ENV`), so any SPA end user can read it via DevTools. That is true today
and unchanged here. mandor's fd channel protects the **server-side** handoff (no
other container process, env, or disk snoop can grab it) — which is the stated
threat — but it cannot hide a value the app deliberately ships to the browser.
Because this value *is* going to the browser, the FE re-`export` above is correct
(the "don't re-export / feed straight into envsubst" advice in the consumer guide
applies to secrets you do **not** ship client-side; it does not apply here). If
hiding the value from end users were also a goal, that is a different
architecture (keep it server-side; the SPA calls the BE, which uses it
internally) — out of scope for this store.

## Testing

- **Unit:** config parse (each key, defaults, every rejection path); each
  encoder's length/alphabet (hex 2×, b32 unpadded uppercase, b64 padded, b64url
  unpadded url-safe, raw exact bytes); `b10` digit count == `bytes`, digits only,
  and a statistical check that the rejection sampler doesn't skew (many draws,
  each digit 0–9 appears).
- **Harness (integration):** a designated worker reads its fd and echoes the
  length/charset — assert it matches the configured format; **two** workers in
  one secret receive the **identical** value; a **non-designated** worker has
  **no** `CONFD_*` in its environ; a worker **restart** re-delivers
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
