//! Pipelines & scheduling: builtin phases, custom phases, and shared tick sources.
const std = @import("std");
const flecs = @import("flecs");

const Position = struct { x: f32, y: f32 };

var log: [8]u8 = undefined;
var log_len: usize = 0;
fn record(ch: u8) void {
    log[log_len] = ch;
    log_len += 1;
}

fn aiSys(_: *Position) void {
    record('a');
}
fn moveSys(_: *Position) void {
    record('m');
}

var slow_ticks: u32 = 0;
fn slowSys(_: *Position) void {
    slow_ticks += 1;
}

pub fn main() !void {
    var world = try flecs.World(.{}).init(.{});
    defer world.deinit();
    _ = world.spawn(.{Position{ .x = 0, .y = 0 }});

    // Custom phases form a dependency chain: ai runs before movement.
    const ai = world.phase(.pre_update);
    const movement = world.phaseAfter(ai);
    _ = world.systemIn(movement, moveSys); // registered first...
    _ = world.systemIn(ai, aiSys); // ...but ai runs earlier
    _ = world.progress(0.0);
    std.debug.print("phase order: {s} (ai before movement)\n", .{log[0..log_len]});

    // Shared tick source: a system runs only when the timer ticks.
    const timer = world.timer(10.0); // every 10s
    const s = world.system(.on_update, slowSys);
    world.setTickSource(s, timer);
    _ = world.progress(0.1); // timer hasn't elapsed
    _ = world.progress(0.1);
    std.debug.print("slow system ran {d} times in 0.2s (timer = 10s)\n", .{slow_ticks});
}
