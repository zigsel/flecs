//! Optional flecs addons: meta extras (units, bitmask), alerts, metrics, the App
//! run-loop, and whole-world / query-result JSON. Thin, idiomatic wrappers over
//! the corresponding flecs descriptors.

const std = @import("std");
const c = @import("c");
const meta = @import("meta.zig");
const Entity = @import("entity.zig").Entity;

fn dupJson(s: [*c]u8, allocator: std.mem.Allocator) ![]u8 {
    if (s == null) return error.SerializeFailed;
    defer meta.osFree(@ptrCast(s));
    return allocator.dupe(u8, std.mem.span(s));
}

/// Serialize the whole world to JSON (entities + reflected component values).
pub fn worldToJson(world: *c.ecs_world_t, allocator: std.mem.Allocator) ![]u8 {
    return dupJson(c.ecs_world_to_json(world, null), allocator);
}

/// Serialize a query's results to JSON (one fresh iteration).
pub fn iterToJson(world: *c.ecs_world_t, q: *c.ecs_query_t, allocator: std.mem.Allocator) ![]u8 {
    var it = c.ecs_query_iter(world, q);
    return dupJson(c.ecs_iter_to_json(&it, null), allocator);
}

/// Import the units module (mass, length, time, … unit entities for meta).
pub fn importUnits(world: *c.ecs_world_t) void {
    c.FlecsUnitsImport(world);
}

/// Register a Zig enum whose values are bit flags as a flecs bitmask meta type.
pub fn bitmask(world: *c.ecs_world_t, comptime E: type) meta.Id {
    const cid = meta.id(world, E);
    var desc = std.mem.zeroes(c.ecs_bitmask_desc_t);
    desc.entity = cid;
    inline for (@typeInfo(E).@"enum".fields, 0..) |fld, i| {
        desc.constants[i].name = fld.name ++ "";
        desc.constants[i].value = @intFromEnum(@field(E, fld.name));
    }
    return c.ecs_bitmask_init(world, &desc);
}

pub const Severity = enum { info, warning, @"error" };

fn severityId(s: Severity) meta.Id {
    return switch (s) {
        .info => c.EcsAlertInfo,
        .warning => c.EcsAlertWarning,
        .@"error" => c.EcsAlertError,
    };
}

pub const AlertOptions = struct {
    /// Query DSL: entities matching this raise the alert.
    expr: [*:0]const u8,
    message: ?[*:0]const u8 = null,
    severity: Severity = .@"error",
    name: ?[*:0]const u8 = null,
};

/// Import a module function while preserving the current scope (the module
/// import sets scope to itself and, called directly, doesn't restore it).
fn importScoped(world: *c.ecs_world_t, comptime f: fn (*c.ecs_world_t) callconv(.c) void) void {
    const prev = c.ecs_get_scope(world);
    f(world);
    _ = c.ecs_set_scope(world, prev);
}

/// Create an alert that flags entities matching `expr` (requires the alerts &
/// stats addons; surfaced in the Explorer).
pub fn alert(world: *c.ecs_world_t, opts: AlertOptions) Entity {
    importScoped(world, c.FlecsAlertsImport);
    var desc = std.mem.zeroes(c.ecs_alert_desc_t);
    desc.query.expr = opts.expr;
    desc.message = opts.message;
    desc.severity = severityId(opts.severity);
    var edesc = std.mem.zeroes(c.ecs_entity_desc_t);
    edesc.name = opts.name;
    desc.entity = c.ecs_entity_init(world, &edesc);
    return Entity.init(world, c.ecs_alert_init(world, &desc));
}

pub const MetricKind = enum { gauge, counter, counter_increment };

fn metricKindId(k: MetricKind) meta.Id {
    return switch (k) {
        .gauge => c.EcsGauge,
        .counter => c.EcsCounter,
        .counter_increment => c.EcsCounterIncrement,
    };
}

/// Track a component member as a metric over time (requires the metrics addon).
pub fn metric(world: *c.ecs_world_t, comptime T: type, member: [*:0]const u8, kind: MetricKind) Entity {
    importScoped(world, c.FlecsMetricsImport);
    var desc = std.mem.zeroes(c.ecs_metric_desc_t);
    var edesc = std.mem.zeroes(c.ecs_entity_desc_t);
    desc.entity = c.ecs_entity_init(world, &edesc);
    desc.id = meta.id(world, T);
    desc.dotmember = member;
    desc.kind = metricKindId(kind);
    return Entity.init(world, c.ecs_metric_init(world, &desc));
}

pub const RunOptions = struct {
    target_fps: f32 = 0,
    threads: i32 = 0,
    frames: i32 = 0,
    enable_rest: bool = false,
    enable_stats: bool = false,
    port: u16 = 0,
};

/// Run the managed application main loop (`ecs_app_run`): calls `progress` until
/// quit (or `frames`), pacing to `target_fps`. Returns the app exit code.
pub fn run(world: *c.ecs_world_t, opts: RunOptions) i32 {
    var desc = std.mem.zeroes(c.ecs_app_desc_t);
    desc.target_fps = opts.target_fps;
    desc.threads = opts.threads;
    desc.frames = opts.frames;
    desc.enable_rest = opts.enable_rest;
    desc.enable_stats = opts.enable_stats;
    desc.port = opts.port;
    return c.ecs_app_run(world, &desc);
}
