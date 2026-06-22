//! Multithreaded systems using flecs' built-in worker threads. Entities are
//! sharded across threads; each entity is independent so the result is correct.
const std = @import("std");
const flecs = @import("flecs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

fn move(pos: *Position, vel: *const Velocity) void {
    pos.x += vel.x;
    pos.y += vel.y;
}

pub fn main() !void {
    // 4 persistent worker threads for the pipeline.
    var world = try flecs.World(.{}).init(.{ .threads = 4 });
    defer world.deinit();

    const n = 100_000;
    const positions = try std.heap.page_allocator.alloc(Position, n);
    defer std.heap.page_allocator.free(positions);
    for (positions) |*p| p.* = .{ .x = 0, .y = 0 };

    _ = world.spawnMany(n, .{
        .pos = @as([]const Position, positions),
        .vel = Velocity{ .x = 1, .y = 1 },
    });

    // `.multi_threaded` shards this system's entities across the workers.
    _ = world.systemOpts(.on_update, move, .{ .multi_threaded = true });

    var frame: usize = 0;
    while (frame < 10) : (frame += 1) _ = world.progress(1.0);

    var q = try world.query(struct { p: *const Position });
    defer q.deinit();
    var ok: usize = 0;
    var it = q.iter();
    defer it.deinit();
    while (it.next()) |row| {
        if (row.p.x == 10 and row.p.y == 10) ok += 1;
    }
    std.debug.print("{d}/{d} entities correct after 10 multithreaded frames\n", .{ ok, n });
}
