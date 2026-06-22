//! Typed queries: named rows, access via pointer-ness, filters, and both
//! per-entity and per-table (SoA) iteration.
const std = @import("std");
const flecs = @import("flecs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Frozen = struct {};

pub fn main() !void {
    var world = try flecs.World(.{}).init(.{});
    defer world.deinit();

    _ = world.spawn(.{ Position{ .x = 0, .y = 0 }, Velocity{ .x = 1, .y = 1 } });
    _ = world.spawn(.{ Position{ .x = 5, .y = 5 }, Velocity{ .x = 2, .y = 0 } });
    _ = world.spawn(.{ Position{ .x = 9, .y = 9 }, Velocity{ .x = 9, .y = 9 }, Frozen });
    _ = world.spawn(.{Position{ .x = -1, .y = -1 }}); // no Velocity

    const Speed = struct { mult: f32 };

    // The row struct *is* the query - declare it inline. `*T` = read/write,
    // `*const T` = read, `?*const T` = optional, `Without` = filter.
    var q = try world.query(struct {
        e: flecs.Entity,
        pos: *Position,
        vel: *const Velocity,
        speed: ?*const Speed,
        _awake: flecs.Without(Frozen),
    });
    defer q.deinit();

    // per-entity iteration. `defer it.deinit()` is the leak-safe idiom (early
    // break is fine; a full drain makes deinit a no-op).
    var it = q.iter();
    defer it.deinit();
    while (it.next()) |row| {
        const m: f32 = if (row.speed) |s| s.mult else 1;
        row.pos.x += row.vel.x * m;
        std.debug.print("entity {d}: pos=({d}, {d})\n", .{ row.e.id, row.pos.x, row.pos.y });
    }

    // per-table iteration: data fields become slices for cache-friendly loops.
    var t = q.tableIter();
    while (t.next()) |tab| {
        for (tab.pos, tab.vel) |*p, v| p.y += v.y;
    }

    // tuple form: positional rows, no named struct needed.
    var tq = try world.query(.{ *const Position, *const Velocity });
    defer tq.deinit();
    var n: usize = 0;
    var ti = tq.iter();
    defer ti.deinit();
    while (ti.next()) |_| n += 1;
    std.debug.print("non-frozen movers: {d}\n", .{n});
}
