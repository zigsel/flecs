//! Tooling for the web Explorer (flecs.dev/explorer): REST, stats, doc strings,
//! alerts, and metrics. Run this, then open the Explorer to inspect the world.
const std = @import("std");
const flecs = @import("flecs");

const Position = struct { x: f32, y: f32 };
const Health = struct { hp: f32 };

pub fn main() !void {
    var world = try flecs.World(.{}).init(.{});
    defer world.deinit();
    _ = world.reflect(Position);
    _ = world.reflect(Health);

    // Documentation shows up in the Explorer.
    const player = world.entity(.{ .name = "Player" });
    player.setDoc(.{ .brief = "the player-controlled entity" });
    player.set(Position{ .x = 1, .y = 2 });
    player.set(Health{ .hp = 5 });

    _ = world.spawn(.{ Position{ .x = 0, .y = 0 }, Health{ .hp = 100 } });

    // Periodic statistics for the Explorer dashboards.
    world.importStats();

    // An alert flags entities matching a DSL query (everything with Health here;
    // member-value conditions like `$this.Health.hp < 10` also work via the DSL).
    var buf: [96]u8 = undefined;
    const expr = try std.fmt.bufPrintZ(&buf, "{s}", .{world.componentName(Health)});
    _ = world.alert(.{ .expr = expr, .message = "has health", .severity = .warning, .name = "HasHealth" });

    // A metric tracks a member over time.
    _ = world.metric(Health, "hp", .gauge);

    // Serve the REST API. (Use `_ = world.run(.{ .enable_rest = true })` for a
    // real blocking loop; here we just tick a few frames so the example exits.)
    world.enableRest(.{ .port = 27750 });
    var frame: usize = 0;
    while (frame < 5) : (frame += 1) _ = world.progress(1.0 / 60.0);

    std.debug.print("world configured for the Explorer (REST on :27750, stats, alerts, metrics)\n", .{});
    std.debug.print("doc brief for Player: {s}\n", .{player.getDocBrief().?});
}
