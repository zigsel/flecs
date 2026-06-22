//! Process-wide flecs logging controls. flecs logs to stderr; these tune its
//! verbosity and formatting. Levels: -1 errors only (default), 0 warnings,
//! 1..N increasingly verbose tracing.

const std = @import("std");
const c = @import("c");

/// Set the log verbosity level; returns the previous level.
pub fn setLevel(level: i32) i32 {
    return c.ecs_log_set_level(level);
}

/// The current log verbosity level.
pub fn getLevel() i32 {
    return c.ecs_log_get_level();
}

/// Toggle ANSI color in log output; returns the previous setting.
pub fn enableColors(enabled: bool) bool {
    return c.ecs_log_enable_colors(enabled);
}

/// Toggle a wall-clock timestamp on each log line; returns the previous setting.
pub fn enableTimestamp(enabled: bool) bool {
    return c.ecs_log_enable_timestamp(enabled);
}

/// Toggle a since-last-line time delta on each log line; returns the previous
/// setting.
pub fn enableTimeDelta(enabled: bool) bool {
    return c.ecs_log_enable_timedelta(enabled);
}

/// The error code of the last logged error (and clears it). 0 = none.
pub fn lastError() i32 {
    return c.ecs_log_last_error();
}

/// Begin capturing log output instead of printing it (e.g. to assert on errors
/// in tests). `try_only` captures only would-be log calls without side effects.
pub fn startCapture(try_only: bool) void {
    c.ecs_log_start_capture(try_only);
}

/// Stop capturing and return the captured text as an `allocator`-owned slice
/// (caller frees), or null if nothing was captured.
pub fn stopCapture(allocator: std.mem.Allocator) !?[]u8 {
    const s = c.ecs_log_stop_capture();
    if (s == null) return null;
    defer c.ecs_os_api.free_.?(s);
    return try allocator.dupe(u8, std.mem.span(s));
}
