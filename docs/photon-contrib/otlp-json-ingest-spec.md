# photon contribution spec: OTLP/JSON on `POST /v1/logs`

*Written 2026-07-18 from reconnaissance of nevindra/photon@main
(`crates/photon-ingest/src/http.rs`, `mapping.rs`). This is the photon-side
half of docs/INTEGRATION-PHOTON.md — an afternoon of Rust.*

## Why

mandor's built-in relay (`photon = "ip:port"`) POSTs **OTLP/JSON** to
`/v1/logs`. photon's handler currently decodes **protobuf only**
(`decode_export_request` → `prost::Message::decode`), so mandor's payload is
rejected with "invalid OTLP protobuf payload". The OTLP/HTTP spec requires
servers to support both `application/x-protobuf` and `application/json`
(protobuf-JSON mapping), so this change is also spec-compliance, not a
mandor special-case. (mandor's relay already sends
`Authorization: Bearer $PHOTON_TOKEN` — auth needs no photon change.)

## Change (photon-ingest crate)

1. `Cargo.toml`: add `pbjson` + `pbjson-types` (or `serde_json` with the
   `opentelemetry-proto` crate's `with-serde` feature, which generates serde
   impls for `ExportLogsServiceRequest` — check the feature flag first;
   it exists in recent versions as `with-serde`).
2. `http.rs`:
   - In `ingest_logs`, branch on the `Content-Type` header **after** the
     token check, **inside** the in-flight permit (JSON decode is the same
     expensive-work class as protobuf decode):
     ```rust
     let req = match content_type {
         t if t.starts_with("application/json") => decode_export_request_json(&body)?,
         _ => decode_export_request(&body)?, // existing protobuf path
     };
     ```
   - Add the pure sibling of the existing decoder so rejection-before-WAL
     stays unit-testable:
     ```rust
     pub(crate) fn decode_export_request_json(body: &[u8])
         -> Result<ExportLogsServiceRequest, PhotonError>
     ```
3. Everything downstream (`otlp_logs_into_builder`, WAL append, counters,
   backpressure) is unchanged — the mapping layer is already
   payload-agnostic.

## Tests

- Unit: golden OTLP/JSON fixture → `decode_export_request_json` → same
  `LogRecord`s as the protobuf twin. Use mandor's real payload shape:
  resource attrs `service.name`/`service.version`, one LogRecord with
  `severityText`, `body.stringValue`, attr `mandor.bundle` (JSON string).
  A live sample can be generated with:
  `MANDOR_STATE_DIR=/tmp/x mandor "sh -c 'exit 3'"; mandor relay /tmp/x/incidents/*.json 127.0.0.1:4318`
  against a netcat listener.
- Handler: `Content-Type: application/json` happy path (202/200) + malformed
  JSON rejected with 4xx before WAL append (mirror the existing protobuf
  rejection test).

## Optional follow-up (native mandor source)

A `photon-agent` (or new `photon-mandor`) file source watching
`/var/lib/mandor/incidents/*.json` over a shared volume: epoch-ms-named,
atomic-rename, self-pruned at 200 files — built to be tailed. It removes
even the relay hop for co-deployed setups. Bundle schema is versioned
(`"v"`, currently 5) and golden-locked in mandor's `src/spool.zig`; parse
leniently, ignore unknown fields, surface `verdict`, `cause_str`,
`exception.*`, `trace.frames[]` and `history.count` as first-class columns.
