//! Run-systems: drive your own iteration with Query/Stage/Res params - for
//! multi-query work, nested loops, and deferred structural change.
const std = @import("std");
const flecs = @import("flecs");

const Position = struct { x: f32, y: f32 };
const Collider = struct { radius: f32 };
const Ship = struct {};
const Asteroid = struct {};
const Score = struct { points: u32 };

// One run-system per frame: every ship checked against every asteroid. Entities
// are destroyed through the Stage (deferred to the sync point), and the Score
// singleton is mutated through ResMut.
fn collide(
    ships: flecs.Query(struct { e: flecs.Entity, pos: *const Position, col: *const Collider, _s: flecs.With(Ship) }),
    rocks: flecs.Query(struct { pos: *const Position, col: *const Collider, _a: flecs.With(Asteroid) }),
    score: flecs.ResMut(Score),
    stage: flecs.Stage,
) void {
    var si = ships.iter();
    defer si.deinit();
    while (si.next()) |s| {
        var ri = rocks.iter();
        defer ri.deinit();
        while (ri.next()) |r| {
            const dx = s.pos.x - r.pos.x;
            const dy = s.pos.y - r.pos.y;
            const reach = s.col.radius + r.col.radius;
            if (dx * dx + dy * dy < reach * reach) {
                stage.destroy(s.e); // deferred
                score.v.points += 10;
            }
        }
    }
}

pub fn main() !void {
    var world = try flecs.World(.{}).init(.{});
    defer world.deinit();

    world.set(Score{ .points = 0 });
    _ = world.spawn(.{ Position{ .x = 0, .y = 0 }, Collider{ .radius = 1 }, Ship });
    _ = world.spawn(.{ Position{ .x = 0.5, .y = 0 }, Collider{ .radius = 1 }, Asteroid }); // hit
    _ = world.spawn(.{ Position{ .x = 50, .y = 0 }, Collider{ .radius = 1 }, Asteroid }); // miss

    _ = world.system(.on_update, collide);
    _ = world.progress(0.016);

    std.debug.print("score after collisions: {d}\n", .{world.get(Score).?.points});
    std.debug.print("ships remaining: {d}\n", .{world.count(Ship)});
}
