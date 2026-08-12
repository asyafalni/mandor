//! Pure resolution of mandor's deploy-varying config from ENV/TOML sources.
//! No syscalls, no allocation — the caller supplies the already-read values.
//! Precedence: ENV > TOML > default (no deploy-varying key has a CLI flag). See
//! docs/superpowers/specs/2026-08-10-env-config-deploy-varying-keys-design.md.

const std = @import("std");

/// A non-empty env value, or null. `spawner.findEnv` returns a non-null EMPTY
/// slice for a set-but-empty variable (`FOO=`), which is extremely common from
/// compose `${X:-}` expansion or a cleared `-e FOO=`. An empty value must NOT
/// count as configured: it may not activate telemetry and may not override a
/// TOML value. Treating it as unset is what makes both correct.
fn presentEnv(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len > 0) s else null;
}

/// Drop a leading `http://` / `https://` so a full URL or a bare `host:port`
/// both reduce to `host:port` (mandor's endpoint parser + TOML `photon=` want
/// bare host:port; mandor is OTLP/HTTP-only so the scheme is redundant).
pub fn stripScheme(s: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, "http://")) return s["http://".len..];
    if (std.mem.startsWith(u8, s, "https://")) return s["https://".len..];
    return s;
}

/// Resolve the photon endpoint with ENV > TOML precedence, scheme-stripped.
/// There is no `--photon` CLI flag (it moved to TOML), so ENV is the top source.
/// An empty env var is ignored (does not override TOML, does not activate).
/// null (no source set) ⇒ offline. Validation (host:port) happens downstream in
/// supervisor.run via parseHostPort — same path a TOML value takes.
pub fn resolvePhoton(env_v: ?[]const u8, toml_v: ?[]const u8) ?[]const u8 {
    const raw = presentEnv(env_v) orelse toml_v orelse return null;
    return stripScheme(raw);
}

/// Resolve service_prefix with ENV > TOML precedence; the default is "" (no
/// prefix). An empty env var is ignored so it can't wipe a TOML tenant tag.
/// Length is validated by the caller (cli.max_service_prefix).
pub fn resolveServicePrefix(env_v: ?[]const u8, toml_v: ?[]const u8) []const u8 {
    return presentEnv(env_v) orelse toml_v orelse "";
}

const testing = std.testing;

test "stripScheme drops http/https, leaves bare host:port" {
    try testing.expectEqualStrings("h:9", stripScheme("http://h:9"));
    try testing.expectEqualStrings("h:9", stripScheme("https://h:9"));
    try testing.expectEqualStrings("h:9", stripScheme("h:9"));
    try testing.expectEqualStrings("", stripScheme(""));
    // Only a leading scheme is stripped; an embedded one is left alone.
    try testing.expectEqualStrings("a/http://b", stripScheme("a/http://b"));
}

test "resolvePhoton: ENV > TOML, scheme-stripped, empty ignored, null when none" {
    // ENV wins over TOML; scheme stripped.
    try testing.expectEqualStrings("e:1", resolvePhoton("http://e:1", "t:2").?);
    // TOML used when no ENV.
    try testing.expectEqualStrings("t:2", resolvePhoton(null, "t:2").?);
    // An EMPTY env var must NOT override TOML (compose `${X:-}` case).
    try testing.expectEqualStrings("t:2", resolvePhoton("", "t:2").?);
    // An empty env var with no TOML stays offline (null), not "" (non-null).
    try testing.expect(resolvePhoton("", null) == null);
    // None set ⇒ null (offline).
    try testing.expect(resolvePhoton(null, null) == null);
}

test "resolveServicePrefix: ENV > TOML > empty, empty env ignored" {
    try testing.expectEqualStrings("e-", resolveServicePrefix("e-", "t-"));
    try testing.expectEqualStrings("t-", resolveServicePrefix(null, "t-"));
    // An EMPTY env var must NOT wipe the TOML tenant prefix.
    try testing.expectEqualStrings("t-", resolveServicePrefix("", "t-"));
    try testing.expectEqualStrings("", resolveServicePrefix(null, null));
}
