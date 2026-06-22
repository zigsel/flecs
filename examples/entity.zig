//! Entity lifecycle: create, name, look up, read/write components, clone, clear.
const std = @import("std");
const flecs = @import("flecs");

const Position = struct { x: f32, y: f32 };
const Health = struct { hp: i32 };
const Active = struct {}; // zero-size -> tag

pub fn main() !void {
    var world = try flecs.World(.{}).init(.{});
    defer world.deinit();

    // anonymous vs named
    const anon = world.new();
    const player = world.entity(.{ .name = "Player" });

    // add / set / get / ensure / has
    anon.add(Active);
    player.set(Position{ .x = 1, .y = 2 });
    player.set(Health{ .hp = 100 });
    player.ensure(Health).hp += 50; // mutate in place
    std.debug.print("Player hp={d}, has Active={}\n", .{ player.get(Health).?.hp, player.has(Active) });

    // emplace: get raw storage and construct in place (no zero-fill)
    const turret = world.new();
    turret.emplace(Position).* = .{ .x = 3, .y = 4 };

    // a cached ref is the fast path for reading one component repeatedly
    var hp_ref = player.ref(Health);
    std.debug.print("via ref: hp={d}\n", .{hp_ref.get().?.hp});

    // named lookup, hierarchy via path + depth
    const gun = world.entity(.{ .name = "Gun", .parent = player });
    std.debug.print("lookup 'Player.Gun' -> {d} (gun depth={d})\n", .{ world.lookup("Player.Gun").?.id, gun.depth(flecs.ChildOf) });

    // clone (with values), then mutate the copy independently
    const clone = player.clone(true);
    clone.set(Health{ .hp = 1 });
    std.debug.print("clone hp={d}, original hp={d}\n", .{ clone.get(Health).?.hp, player.get(Health).?.hp });

    // remove / clear / destroy / liveness
    player.remove(Health);
    std.debug.print("after remove: player has Health={}\n", .{player.has(Health)});
    anon.clear(); // strip components, keep alive
    std.debug.print("after clear: anon alive={}, has Active={}\n", .{ anon.isAlive(), anon.has(Active) });
    gun.destroy();
    std.debug.print("after destroy: gun alive={}, existed={}\n", .{ gun.isAlive(), gun.exists() });
}
