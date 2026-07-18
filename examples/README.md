# mandor examples

Copy a `mandor.toml` next to your binaries and run `mandor` (it auto-loads
`./mandor.toml`), or point at one with `--config=PATH`. Check any config
without running it: `mandor validate --config=PATH`.

| Directory | Shows |
|---|---|
| `web-worker-cron/` | API + worker + cron with start ordering and health-check-driven restart |
| `init-task/` | Oneshot init task (setup/migration/warmup) that must succeed before workers start |
| `photon-observability/` | Auto-forwarding incidents to the [photon](https://github.com/nevindra/photon) sister project, with persistent history |

Every configurable key: [../docs/CONFIG.md](../docs/CONFIG.md).
