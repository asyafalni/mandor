//! The OTLP messages mandor sends, as plain structs that `nilo_proto` encodes.
//!
//! Only the fields mandor writes are declared: protobuf skips a field a type
//! does not name, so this is a subset of opentelemetry-proto (common/v1,
//! resource/v1, logs/v1, metrics/v1), not a copy of it. Field numbers are
//! upstream's; the `wire` table on each type is the whole schema.
//!
//! Encoding is `proto.encodeInto` into the relay's fixed body buffer: no
//! allocator, and a message that does not fit is `error.NoSpaceLeft` before a
//! byte is written. Fields go out in number order and zero scalars are omitted
//! (proto3), so a value of 0 that matters must sit in a oneof, where presence
//! is explicit — which is how OTLP already declares AnyValue and a data
//! point's value.

const proto = @import("nilo_proto");

// ------------------------------------------------------------ common/v1

pub const AnyValue = struct {
    pub const wire = .{};
    value: ?Value = null,

    pub const Value = union(enum) {
        pub const wire = .{ .string_value = 1, .int_value = 3 };
        string_value: []const u8,
        int_value: i64,
    };

    pub fn str(s: []const u8) AnyValue {
        return .{ .value = .{ .string_value = s } };
    }

    pub fn int(v: i64) AnyValue {
        return .{ .value = .{ .int_value = v } };
    }
};

pub const KeyValue = struct {
    pub const wire = .{ .key = 1, .value = 2 };
    key: []const u8 = "",
    value: ?AnyValue = null,

    pub fn str(k: []const u8, v: []const u8) KeyValue {
        return .{ .key = k, .value = AnyValue.str(v) };
    }

    pub fn int(k: []const u8, v: i64) KeyValue {
        return .{ .key = k, .value = AnyValue.int(v) };
    }
};

pub const Resource = struct {
    pub const wire = .{ .attributes = 1 };
    attributes: []const KeyValue = &.{},
};

// ------------------------------------------------------------ logs/v1

/// OTLP SeverityNumber. INFO for routine lifecycle, WARN for recoverable
/// trouble, ERROR for a failed/killed worker or an incident.
pub const Severity = enum(i32) {
    unspecified = 0,
    info = 9,
    warn = 13,
    err = 17,
    _,
};

pub const LogRecord = struct {
    pub const wire = .{
        .time_unix_nano = .{ 1, .fixed64 },
        .severity_number = 2,
        .severity_text = 3,
        .body = 5,
        .attributes = 6,
        .observed_time_unix_nano = .{ 11, .fixed64 },
    };
    time_unix_nano: u64 = 0,
    severity_number: Severity = .unspecified,
    severity_text: []const u8 = "",
    body: ?AnyValue = null,
    attributes: []const KeyValue = &.{},
    observed_time_unix_nano: u64 = 0,
};

pub const ScopeLogs = struct {
    pub const wire = .{ .log_records = 2 };
    log_records: []const LogRecord = &.{},
};

pub const ResourceLogs = struct {
    pub const wire = .{ .resource = 1, .scope_logs = 2 };
    resource: ?Resource = null,
    scope_logs: []const ScopeLogs = &.{},
};

/// ExportLogsServiceRequest, the body of a POST to /v1/logs.
pub const LogsRequest = struct {
    pub const wire = .{ .resource_logs = 1 };
    resource_logs: []const ResourceLogs = &.{},
};

// ------------------------------------------------------------ metrics/v1

pub const NumberDataPoint = struct {
    pub const wire = .{ .time_unix_nano = .{ 3, .fixed64 }, .attributes = 7 };
    time_unix_nano: u64 = 0,
    value: ?Value = null,
    attributes: []const KeyValue = &.{},

    pub const Value = union(enum) {
        pub const wire = .{ .as_double = 4, .as_int = .{ 6, .sfixed64 } };
        as_double: f64,
        as_int: i64,
    };
};

pub const Gauge = struct {
    pub const wire = .{ .data_points = 1 };
    data_points: []const NumberDataPoint = &.{},
};

pub const Temporality = enum(i32) { unspecified = 0, delta = 1, cumulative = 2, _ };

pub const Sum = struct {
    pub const wire = .{ .data_points = 1, .aggregation_temporality = 2, .is_monotonic = 3 };
    data_points: []const NumberDataPoint = &.{},
    aggregation_temporality: Temporality = .unspecified,
    is_monotonic: bool = false,
};

pub const Metric = struct {
    pub const wire = .{ .name = 1, .unit = 3 };
    name: []const u8 = "",
    unit: []const u8 = "",
    data: ?Data = null,

    pub const Data = union(enum) {
        pub const wire = .{ .gauge = 5, .sum = 7 };
        gauge: Gauge,
        sum: Sum,
    };
};

pub const ScopeMetrics = struct {
    pub const wire = .{ .metrics = 2 };
    metrics: []const Metric = &.{},
};

pub const ResourceMetrics = struct {
    pub const wire = .{ .resource = 1, .scope_metrics = 2 };
    resource: ?Resource = null,
    scope_metrics: []const ScopeMetrics = &.{},
};

/// ExportMetricsServiceRequest, the body of a POST to /v1/metrics.
pub const MetricsRequest = struct {
    pub const wire = .{ .resource_metrics = 1 };
    resource_metrics: []const ResourceMetrics = &.{},
};

// ------------------------------------------------------------ batching

/// Encode one ResourceLogs as a one-entry LogsRequest into `buf`.
///
/// A repeated field is its entries written one after another, so N one-entry
/// requests laid end to end ARE the N-entry request, byte for byte. That lets
/// every batch encoder fill the body buffer record by record and stop at the
/// first that does not fit, with no array of N messages held anywhere.
pub fn appendLogs(buf: []u8, rl: ResourceLogs) error{NoSpaceLeft}![]u8 {
    return proto.encodeInto(LogsRequest, buf, .{ .resource_logs = &.{rl} });
}

/// The metrics sibling of `appendLogs`.
pub fn appendMetrics(buf: []u8, rm: ResourceMetrics) error{NoSpaceLeft}![]u8 {
    return proto.encodeInto(MetricsRequest, buf, .{ .resource_metrics = &.{rm} });
}
