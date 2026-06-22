//! Spawn bundles: build a whole entity in one declarative call, name & reuse
//! bundles, and bulk-spawn with SoA data.
const std = @import("std");
const flecs = @import("flecs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { hp: u32 };
const Likes = struct {};
const Active = struct {};

pub fn main() !void {
    var world = try flecs.World(.{}).init(.{});
    defer world.deinit();

    const parent = world.entity(.{ .name = "Parent" });
    const bob = world.entity(.{ .name = "Bob" });

    // One call: component values, tags, parenting, and a relationship pair.
    const e = world.spawn(.{
        Position{ .x = 1, .y = 2 },
        Active,
        flecs.childOf(parent),
        flecs.pair(Likes, bob),
    });
    std.debug.print("e parented to {s}, likes Bob={}\n", .{ e.parent().?.name().?, e.hasPair(Likes, bob) });

    // Name a bundle once, reuse it, extend with `++`.
    const Enemy = flecs.bundle(.{ Position{ .x = 0, .y = 0 }, Velocity{ .x = 1, .y = 0 }, Active });
    _ = world.spawn(Enemy);
    const boss = world.spawn(Enemy ++ .{Health{ .hp = 999 }});
    std.debug.print("boss has Active={}, hp={d}\n", .{ boss.has(Active), boss.get(Health).?.hp });

    // Bulk-spawn N entities in one table op: per-entity slices + broadcast values.
    const positions = [_]Position{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 } };
    const ids = world.spawnMany(3, .{
        .pos = @as([]const Position, &positions),
        .vel = Velocity{ .x = 9, .y = 9 }, // broadcast to all 3
        .active = Active, // tag on all 3
    });
    std.debug.print("bulk-spawned {d} entities\n", .{ids.len});
}
