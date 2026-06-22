//! Advanced query operators: Or, traversal, fixed source, sort, scopes, pairs,
//! and the untyped DSL escape hatch.
const std = @import("std");
const flecs = @import("flecs");

const Position = struct { x: f32, y: f32 };
const ZIndex = struct { v: i32 };
const Gravity = struct { g: f32 };
const Ship = struct {};
const Asteroid = struct {};
const Frozen = struct {};
const Dead = struct {};

pub fn main() !void {
    var world = try flecs.World(.{}).init(.{});
    defer world.deinit();

    // --- Or: match either tag ---
    _ = world.spawn(.{ Position{ .x = 0, .y = 0 }, Ship });
    _ = world.spawn(.{ Position{ .x = 0, .y = 0 }, Asteroid });
    var orq = try world.query(struct {
        _p: *const Position,
        _k: flecs.Or(.{ Ship, Asteroid }),
    });
    defer orq.deinit();
    var hits: usize = 0;
    var oi = orq.iter();
    defer oi.deinit();
    while (oi.next()) |_| hits += 1;
    std.debug.print("Ship-or-Asteroid: {d}\n", .{hits});

    // --- Sort + fixed source (read shared config from a named entity) ---
    world.entity(.{ .name = "Config" }).set(Gravity{ .g = 9.81 });
    _ = world.spawn(.{ZIndex{ .v = 3 }});
    _ = world.spawn(.{ZIndex{ .v = 1 }});
    _ = world.spawn(.{ZIndex{ .v = 2 }});
    var sq = try world.query(struct {
        z: *const ZIndex,
        cfg: flecs.From("Config", *const Gravity), // same instance for every row
        pub const sort = flecs.ascBy(ZIndex, .v);
    });
    defer sq.deinit();
    std.debug.print("z ascending: ", .{});
    var g: f32 = 0;
    var si = sq.iter();
    defer si.deinit();
    while (si.next()) |row| {
        g = row.cfg.v.g;
        std.debug.print("{d} ", .{row.z.v});
    }
    std.debug.print("(shared g={d})\n", .{g});

    // --- Up traversal: read a component from an ancestor ---
    const parent = world.entity(.{ .name = "Parent" });
    parent.set(Position{ .x = 100, .y = 0 });
    _ = world.entity(.{ .name = "Child", .parent = parent }).set(ZIndex{ .v = 0 });
    var uq = try world.query(struct {
        _z: *const ZIndex,
        parent_pos: flecs.Up(flecs.ChildOf, *const Position),
    });
    defer uq.deinit();
    var ui = uq.iter();
    defer ui.deinit();
    while (ui.next()) |row| std.debug.print("child sees parent.x = {d}\n", .{row.parent_pos.v.x});

    // --- Scope: !{ Frozen AND Dead } ---
    _ = world.spawn(.{ Position{ .x = 0, .y = 0 }, Frozen, Dead }); // excluded
    var scq = try world.query(struct {
        _p: *const Position,
        _g: flecs.Scope(.not, .{ Frozen, Dead }),
    });
    defer scq.deinit();
    var sc: usize = 0;
    var sci = scq.iter();
    defer sci.deinit();
    while (sci.next()) |_| sc += 1;
    std.debug.print("not(Frozen and Dead): {d}\n", .{sc});

    // --- Untyped DSL escape hatch (member-value / runtime-built queries) ---
    var buf: [64]u8 = undefined;
    const expr = try std.fmt.bufPrintZ(&buf, "{s}", .{world.componentName(Ship)});
    var dq = try world.queryExpr(expr);
    defer dq.deinit();
    var dn: usize = 0;
    var di = dq.iter();
    defer di.deinit();
    while (di.next()) |_| dn += 1;
    std.debug.print("queryExpr(\"Ship\"): {d}\n", .{dn});

    // --- Named query variables: constrain a `$var` before iterating ---
    const Likes = struct {};
    const bob = world.entity(.{ .name = "Bob" });
    world.entity(.{ .name = "Ann" }).addPair(Likes, bob);
    world.entity(.{ .name = "Cy" }).addPair(Likes, bob);
    var vbuf: [64]u8 = undefined;
    const vexpr = try std.fmt.bufPrintZ(&vbuf, "({s}, $friend)", .{world.componentName(Likes)});
    var vq = try world.queryExpr(vexpr);
    defer vq.deinit();
    const friend = vq.findVar("friend").?;
    var vi = vq.iter();
    defer vi.deinit();
    vi.setVar(friend, bob); // bind $friend = Bob, match only those who like Bob
    var vn: usize = 0;
    while (vi.next()) |_| vn += 1;
    std.debug.print("entities that like Bob: {d}\n", .{vn});
}
