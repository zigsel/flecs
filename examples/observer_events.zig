//! Observers (reactions to component events) and custom events with payloads.
const std = @import("std");
const flecs = @import("flecs");

const Position = struct { x: f32, y: f32 };
const Health = struct { hp: i32 };

// Builtin-event observer: the marker selects the event, the rest is a query.
// OnSet fires once the value is assigned, so the Position is meaningful here.
fn onSpawn(_: flecs.OnSet(Position), e: flecs.Entity, p: *const Position) void {
    std.debug.print("spawned {d} at ({d}, {d})\n", .{ e.id, p.x, p.y });
}

// Custom event with a payload: the `*const Damage` param is the event data,
// the other params (`*Health`) are matched on the target entity.
const Damage = struct { amount: i32, crit: bool };
fn onHit(_: flecs.OnEvent(Damage), hp: *Health, dmg: *const Damage) void {
    hp.hp -= if (dmg.crit) dmg.amount * 2 else dmg.amount;
}

// Monitor: fires when an entity *starts or stops* matching the query.
var monitor_hits: u32 = 0;
fn onAlive(_: flecs.Entity, _: *const Health) void {
    monitor_hits += 1;
}

pub fn main() !void {
    var world = try flecs.World(.{}).init(.{});
    defer world.deinit();

    _ = world.observe(onSpawn);
    _ = world.observe(onHit);
    _ = world.observeOpts(onAlive, .{ .monitor = true });

    const e = world.spawn(.{ Position{ .x = 3, .y = 4 }, Health{ .hp = 100 } });

    // emit fires observers synchronously, right now.
    world.emit(Damage{ .amount = 10, .crit = true }, .{ .target = e });
    std.debug.print("hp after crit-10: {d}\n", .{e.get(Health).?.hp});

    e.destroy(); // monitor fires again (stopped matching)
    std.debug.print("monitor fired {d} times (enter + exit)\n", .{monitor_hits});
}
