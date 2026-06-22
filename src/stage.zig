//! A command target inside a run-system. flecs makes the in-system world a
//! stage: structural changes (add/remove/set/destroy) made through it are
//! automatically deferred and merged at the next sync point. No separate
//! "Commands" type is needed - this is flecs' native deferral.

const c = @import("c");
const meta = @import("meta.zig");
const Entity = @import("entity.zig").Entity;
const events = @import("events.zig");

pub const Stage = struct {
    pub const flecs_stage = true;

    world: *c.ecs_world_t,

    const Self = @This();

    /// Create a new (deferred) entity.
    pub fn new(self: Self) Entity {
        return Entity.init(self.world, c.ecs_new(self.world));
    }

    pub fn add(self: Self, e: Entity, comptime T: type) void {
        c.ecs_add_id(self.world, e.id, meta.id(self.world, T));
    }

    pub fn remove(self: Self, e: Entity, comptime T: type) void {
        c.ecs_remove_id(self.world, e.id, meta.id(self.world, T));
    }

    pub fn set(self: Self, e: Entity, value: anytype) void {
        const T = @TypeOf(value);
        var v = value;
        _ = c.ecs_set_id(self.world, e.id, meta.id(self.world, T), @sizeOf(T), &v);
    }

    pub fn destroy(self: Self, e: Entity) void {
        c.ecs_delete(self.world, e.id);
    }

    /// Enqueue a custom event (delivered at the next sync point).
    pub fn enqueue(self: Self, value: anytype, opts: events.EmitOptions) void {
        events.emit(self.world, value, opts, true);
    }

    /// Explicitly defer a block (rarely needed inside systems, which already
    /// run deferred, but handy for ad-hoc batching).
    pub fn deferBegin(self: Self) void {
        _ = c.ecs_defer_begin(self.world);
    }
    pub fn deferEnd(self: Self) void {
        _ = c.ecs_defer_end(self.world);
    }
};
