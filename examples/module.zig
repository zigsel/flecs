//! Modules (reusable Zig containers) and extensions (a module + a namespace
//! grafted onto the world type).
const std = @import("std");
const flecs = @import("flecs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

// A module is just a Zig container with an optional `init`.
const physics = struct {
    pub const Gravity = struct {
        g: f32 = 9.81,
        pub const flecs_traits: flecs.Traits = .{ .singleton = true };
    };
    pub fn integrate(dt: flecs.Delta, pos: *Position, vel: *Velocity, grav: flecs.Singleton(*const Gravity)) void {
        vel.y -= grav.v.g * dt.s;
        pos.y += vel.y * dt.s;
    }
    pub fn init(world: anytype) !void {
        world.set(Gravity{});
        _ = world.system(.on_update, integrate);
    }
};

// An extension is a module + an Api(World) namespace + Options. State lives in
// the world; the API is reached through `world.ext(spatial)`.
const spatial = struct {
    pub const Options = struct { cell: f32 = 16.0 };
    const Grid = struct {
        cell: f32,
        count: u32 = 0,
        pub const flecs_traits: flecs.Traits = .{ .singleton = true };
    };
    pub fn init(world: anytype, opts: Options) !void {
        world.set(Grid{ .cell = opts.cell });
        _ = world.observe(reindex);
    }
    fn reindex(_: flecs.OnSet(Position), _: flecs.Entity, g: *Grid) void {
        g.count += 1;
    }
    pub fn Api(comptime W: type) type {
        return struct {
            world: *W,
            pub fn cellSize(self: @This()) f32 {
                return self.world.get(Grid).?.cell;
            }
            pub fn indexed(self: @This()) u32 {
                return self.world.get(Grid).?.count;
            }
        };
    }
};

pub fn main() !void {
    // Extensions are listed at the type level; options are passed at init.
    var world = try flecs.World(.{ .ext = .{spatial} }).initExt(.{}, .{spatial.Options{ .cell = 32.0 }});
    defer world.deinit();
    try world.import(physics);

    const e = world.spawn(.{ Position{ .x = 0, .y = 100 }, Velocity{ .x = 0, .y = 0 } });
    _ = world.spawn(.{Position{ .x = 5, .y = 5 }});
    _ = world.progress(1.0);

    std.debug.print("physics: y after gravity = {d:.2}\n", .{e.get(Position).?.y});
    std.debug.print("spatial: cell={d}, indexed {d} entities\n", .{ world.ext(spatial).cellSize(), world.ext(spatial).indexed() });
}
