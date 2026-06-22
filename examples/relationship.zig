//! Relationships: pairs, hierarchy, wildcards, transitivity, and enum components.
const std = @import("std");
const flecs = @import("flecs");

const Likes = struct {};
const Owes = struct { gold: u32 };
const LocatedIn = struct {};
const Team = enum { red, blue, green };

pub fn main() !void {
    var world = try flecs.World(.{}).init(.{});
    defer world.deinit();

    const alice = world.entity(.{ .name = "Alice" });
    const bob = world.entity(.{ .name = "Bob" });
    const carol = world.entity(.{ .name = "Carol" });

    // plain pair, and a pair carrying data
    alice.addPair(Likes, bob);
    alice.setPair(Owes{ .gold = 30 }, bob);
    std.debug.print("Alice owes Bob {d} gold; likes anyone={}\n", .{ alice.getPair(Owes, bob).?.gold, alice.hasRelation(Likes) });

    // iterate all targets of a relationship
    alice.addPair(Likes, carol);
    var likes = alice.targets(Likes);
    std.debug.print("Alice likes: ", .{});
    while (likes.next()) |t| std.debug.print("{s} ", .{t.name().?});
    std.debug.print("\n", .{});

    // hierarchy: parent / children
    const squad = world.entity(.{ .name = "Squad" });
    _ = world.entity(.{ .name = "A", .parent = squad });
    _ = world.entity(.{ .name = "B", .parent = squad });
    var kids = squad.children();
    var n: usize = 0;
    while (kids.next()) |_| n += 1;
    std.debug.print("Squad has {d} children\n", .{n});

    // transitive relationship: SF -> CA -> USA, query "in USA" finds both
    _ = world.component(LocatedIn, .{ .transitive = true });
    const usa = world.entity(.{ .name = "USA" });
    const ca = world.entity(.{ .name = "CA" });
    const sf = world.entity(.{ .name = "SF" });
    ca.addPair(LocatedIn, usa);
    sf.addPair(LocatedIn, ca);
    var buf: [64]u8 = undefined;
    const expr = try std.fmt.bufPrintZ(&buf, "({s}, USA)", .{world.componentName(LocatedIn)});
    var q = try world.queryExpr(expr);
    defer q.deinit();
    var in_usa: usize = 0;
    var it = q.iter();
    defer it.deinit();
    while (it.next()) |_| in_usa += 1;
    std.debug.print("located in USA (transitively): {d}\n", .{in_usa});

    // enum component: exclusive (Team, .case) pair
    alice.addEnum(Team.red);
    alice.addEnum(Team.blue); // replaces red
    std.debug.print("Alice's team: {s}\n", .{@tagName(alice.getEnum(Team).?)});
}
