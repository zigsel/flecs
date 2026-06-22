//! Prefabs: shared templates, variants, auto-override, and slots.
const std = @import("std");
const flecs = @import("flecs");

const Position = struct { x: f32, y: f32 };
const Health = struct { hp: u32 };
const Collider = struct { radius: f32 };
const Cooldown = struct { s: f32 };

pub fn main() !void {
    var world = try flecs.World(.{}).init(.{});
    defer world.deinit();

    // A prefab with shared components. `autoOverride(Position)` makes each
    // instance own its Position (rather than sharing the prefab's).
    const Fighter = world.prefab(.{
        .name = "Fighter",
        .with = .{ Health{ .hp = 100 }, Collider{ .radius = 1 }, flecs.autoOverride(Position) },
        .children = .{
            .{ .name = "Gun", .slot = true, .with = .{Cooldown{ .s = 0.2 }} },
        },
    });
    Fighter.set(Position{ .x = 0, .y = 0 });

    // A variant: inherits Fighter, overrides Health.
    const Boss = world.prefab(.{ .name = "Boss", .with = .{ flecs.isA(Fighter), Health{ .hp = 999 } } });

    // Instances inherit shared data; Position is per-instance (auto-overridden).
    const grunt = world.spawn(.{ flecs.isA(Fighter), Position{ .x = 5, .y = 5 } });
    const boss = world.spawn(.{ flecs.isA(Boss), Position{ .x = 9, .y = 9 } });

    std.debug.print("grunt hp={d} (inherited), boss hp={d} (variant)\n", .{ grunt.get(Health).?.hp, boss.get(Health).?.hp });
    std.debug.print("grunt pos.x={d} (its own)\n", .{grunt.get(Position).?.x});

    // Slots: resolve the prefab's named child on the instance.
    const gun_prefab = world.lookup("Fighter.Gun").?;
    const inst = world.spawn(.{flecs.isA(Fighter)});
    const gun = inst.slot(gun_prefab).?;
    std.debug.print("instance's gun cooldown = {d}\n", .{gun.get(Cooldown).?.s});
}
