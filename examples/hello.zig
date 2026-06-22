//! The 30-second intro: a world, an entity, one system, the frame loop.
const std = @import("std");
const flecs = @import("flecs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

// A system is a plain function - its signature *is* the query.
fn move(dt: flecs.Delta, pos: *Position, vel: *const Velocity) void {
    pos.x += vel.x * dt.s;
    pos.y += vel.y * dt.s;
}

pub fn main() !void {
    var world = try flecs.World(.{}).init(.{});
    defer world.deinit();

    const e = world.spawn(.{ Position{ .x = 0, .y = 0 }, Velocity{ .x = 1, .y = 2 } });
    _ = world.system(.on_update, move);

    var frame: usize = 0;
    while (frame < 60) : (frame += 1) _ = world.progress(1.0 / 60.0);

    const p = e.get(Position).?;
    std.debug.print("after 1 second: pos = ({d:.2}, {d:.2})\n", .{ p.x, p.y });
}
