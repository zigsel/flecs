//! Flecs Script: construct entities from text, once or as a managed (reloadable)
//! scene. Reflected components can be built by name.
const std = @import("std");
const flecs = @import("flecs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

pub fn main() !void {
    var world = try flecs.World(.{}).init(.{});
    defer world.deinit();

    // Components must be reflected so the script engine can build them.
    _ = world.reflect(Position);
    _ = world.reflect(Velocity);

    // Run once: creates the declared entities. Component values are positional.
    try world.script(
        \\Turret {
        \\  Position: {10, 20}
        \\  Velocity: {1, 0}
        \\}
        \\Wall {
        \\  Position: {0, 0}
        \\}
    );

    const turret = world.lookup("Turret").?;
    std.debug.print("Turret at ({d}, {d}), vel.x={d}\n", .{
        turret.get(Position).?.x,
        turret.get(Position).?.y,
        turret.get(Velocity).?.x,
    });

    // Managed script: a named, reloadable scene entity. Delete it to remove its
    // content; re-run loadScript with the same name to reload.
    const scene = try world.loadScript("level1",
        \\Gate { Position: {5, 5} }
    );
    std.debug.print("managed scene alive={}, Gate.x={d}\n", .{ scene.isAlive(), world.lookup("Gate").?.get(Position).?.x });

    // scriptWith: bind Zig values into the script as `$vars`, so positions (and
    // anything else) can be computed at runtime instead of hard-coded.
    try world.scriptWith(
        \\Spawn { Position: {$x, $y} }
    , .{ .x = @as(f32, 42), .y = @as(f32, 7) });
    const spawn = world.lookup("Spawn").?;
    std.debug.print("Spawn (from bound vars) at ({d}, {d})\n", .{ spawn.get(Position).?.x, spawn.get(Position).?.y });
}
