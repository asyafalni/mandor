//! Pure resolution of mandor's deploy-varying config from CLI/ENV/TOML sources.
//! No syscalls, no allocation — the caller supplies the already-read values.
//! Precedence: CLI > ENV > TOML > default. See
//! docs/superpowers/specs/2026-08-10-env-config-deploy-varying-keys-design.md.

const std = @import("std");

/// Drop a leading `http://` / `https://` so a full URL or a bare `host:port`
/// both reduce to `host:port` (mandor's endpoint parser + TOML `photon=` want
/// bare host:port; mandor is OTLP/HTTP-only so the scheme is redundant).
pub fn stripScheme(s: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, "http://")) return s["http://".len..];
    if (std.mem.startsWith(u8, s, "https://")) return s["https://".len..];
    return s;
}

/// Resolve the photon endpoint with CLI > ENV > TOML precedence, scheme-stripped.
/// null (no source set) ⇒ offline. Validation (host:port) happens downstream in
/// supervisor.run via parseHostPort — same path a TOML value takes.
pub fn resolvePhoton(cli_v: ?[]const u8, env_v: ?[]const u8, toml_v: ?[]const u8) ?[]const u8 {
    const raw = cli_v orelse env_v orelse toml_v orelse return null;
    return stripScheme(raw);
}

/// Resolve service_prefix with ENV > TOML precedence (no CLI flag exists); the
/// default is "" (no prefix). Length is validated by the caller (cli.max_service_prefix).
pub fn resolveServicePrefix(env_v: ?[]const u8, toml_v: ?[]const u8) []const u8 {
    return env_v orelse toml_v orelse "";
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

test "resolvePhoton: CLI > ENV > TOML, scheme-stripped, null when none" {
    // ENV wins over TOML; scheme stripped.
    try testing.expectEqualStrings("e:1", resolvePhoton(null, "http://e:1", "t:2").?);
    // CLI wins over ENV.
    try testing.expectEqualStrings("c:1", resolvePhoton("c:1", "e:1", "t:2").?);
    // TOML used when no CLI/ENV.
    try testing.expectEqualStrings("t:2", resolvePhoton(null, null, "t:2").?);
    // None set ⇒ null (offline).
    try testing.expect(resolvePhoton(null, null, null) == null);
}

test "resolveServicePrefix: ENV > TOML > empty" {
    try testing.expectEqualStrings("e-", resolveServicePrefix("e-", "t-"));
    try testing.expectEqualStrings("t-", resolveServicePrefix(null, "t-"));
    try testing.expectEqualStrings("", resolveServicePrefix(null, null));
}
