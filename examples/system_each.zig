//! Systems: plain functions, phases, options, struct-form, and stateful systems.
const std = @import("std");
const flecs = @import("flecs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Active = struct {};

// Bare-function each-system (sugar for the common, config-free case).
fn move(dt: flecs.Delta, pos: *Position, vel: *const Velocity, _: flecs.With(Active)) void {
    pos.x += vel.x * dt.s;
    pos.y += vel.y * dt.s;
}

// Struct-form system: the method is the query, decls are the config.
const Friction = struct {
    pub const phase = .on_update;
    pub fn each(vel: *Velocity) void {
        vel.x *= 0.99;
        vel.y *= 0.99;
    }
};

// Stateful system: the instance persists and arrives as the *Self first param
// (Zig's answer to a capturing closure).
const Counter = struct {
    frames: u32 = 0,
    pub const phase = .on_store;
    pub fn each(self: *@This(), _: *const Position) void {
        self.frames += 1;
    }
};

pub fn main() !void {
    var world = try flecs.World(.{}).init(.{});
    defer world.deinit();

    const e = world.spawn(.{ Position{ .x = 0, .y = 0 }, Velocity{ .x = 10, .y = 0 }, Active });

    _ = world.system(.on_update, move); // bare function
    _ = world.add(Friction); // struct form
    const counter = world.add(Counter{}); // stateful instance

    var frame: usize = 0;
    while (frame < 3) : (frame += 1) _ = world.progress(1.0);

    const p = e.get(Position).?;
    std.debug.print("pos after 3 frames: ({d:.2}, {d:.2})\n", .{ p.x, p.y });

    // Registration returns the system Entity, so you can disable it.
    counter.enable(false);
    _ = world.progress(1.0);
    std.debug.print("counter system disabled - no further ticks\n", .{});
}
