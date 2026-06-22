//! Components: plain data, tags, singletons, traits, and lifecycle hooks - all
//! configured by *declarations on the type*.
const std = @import("std");
const flecs = @import("flecs");

// Plain data component.
const Position = struct { x: f32, y: f32 };

// A singleton: one instance per world, declared on the type.
const Gravity = struct {
    g: f32 = 9.81,
    pub const flecs_traits: flecs.Traits = .{ .singleton = true };
};

// Lifecycle hooks as declarations: fire automatically on the component's events.
var hook_log: [8]u8 = undefined;
var hook_len: usize = 0;
const Resource = struct {
    handle: u32,
    pub fn onAdd(_: *Resource) void {
        hook_log[hook_len] = 'A';
        hook_len += 1;
    }
    pub fn onSet(self: *Resource, _: flecs.Entity) void {
        _ = self;
        hook_log[hook_len] = 'S';
        hook_len += 1;
    }
    pub fn onRemove(_: *Resource) void {
        hook_log[hook_len] = 'R';
        hook_len += 1;
    }
};

pub fn main() !void {
    var world = try flecs.World(.{}).init(.{});
    defer world.deinit();

    // Singleton: set/get at the world level.
    world.set(Gravity{});
    std.debug.print("gravity = {d}\n", .{world.get(Gravity).?.g});

    // Explicit trait config (optional - only when you need non-default storage).
    const Likes = struct {};
    _ = world.component(Likes, .{ .storage = .sparse, .exclusive = true });

    // Hooks fire as the component is added/set/removed.
    hook_len = 0;
    const e = world.spawn(.{Resource{ .handle = 1 }}); // onAdd, onSet
    e.remove(Resource); // onRemove
    std.debug.print("hook order: {s}\n", .{hook_log[0..hook_len]});

    _ = world.spawn(.{Position{ .x = 0, .y = 0 }});
    std.debug.print("entities with Position: {d}\n", .{world.count(Position)});
}
