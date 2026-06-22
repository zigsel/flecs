//! Custom event emission, shared by `World.emit` and `Stage.enqueue`.

const std = @import("std");
const c = @import("c");
const meta = @import("meta.zig");
const Entity = @import("entity.zig").Entity;

pub const EmitOptions = struct {
    target: Entity,
};

pub fn emit(world: *c.ecs_world_t, value: anytype, opts: EmitOptions, enqueue: bool) void {
    const E = @TypeOf(value);
    var v = value;
    var desc = std.mem.zeroes(c.ecs_event_desc_t);
    desc.event = meta.id(world, E);
    desc.entity = opts.target.id;
    desc.const_param = &v;
    // The event concerns all of the target's components, so any matching
    // observer term fires.
    desc.ids = c.ecs_get_type(world, opts.target.id);
    if (enqueue) c.ecs_enqueue(world, &desc) else c.ecs_emit(world, &desc);
}
