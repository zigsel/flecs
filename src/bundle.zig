//! Spawn-bundle items: values you can drop into a `world.spawn(.{...})` (or a
//! prefab's `.with` list) beyond plain component values and tag types. Each
//! carries a `flecs_apply` marker that `world.applyItem` dispatches on.

const meta = @import("meta.zig");
const Entity = @import("entity.zig").Entity;

/// Inherit from a base entity/prefab (adds an `IsA` pair).
pub fn isA(base: Entity) IsAItem {
    return .{ .target = base.id };
}
pub const IsAItem = struct {
    pub const flecs_apply = .isa;
    target: meta.Id,
};

/// Mark `T` to be copied onto each instance at instantiation time, rather than
/// shared from the prefab (`ecs_auto_override`). Use in a prefab's `.with` list.
pub fn autoOverride(comptime T: type) type {
    return struct {
        pub const flecs_apply = .auto_override;
        pub const Comp = T;
    };
}

/// Parent this entity under `parent`.
pub fn childOf(parent: Entity) ChildOfItem {
    return .{ .target = parent.id };
}
pub const ChildOfItem = struct {
    pub const flecs_apply = .child_of;
    target: meta.Id,
};

/// Add a relationship pair `(R, target)`.
pub fn pair(comptime R: type, target: Entity) PairItem(R) {
    return .{ .target = target.id };
}
fn PairItem(comptime R: type) type {
    return struct {
        pub const flecs_apply = .pair;
        pub const Rel = R;
        target: meta.Id,
    };
}

/// The `flecs_apply` marker of a bundle item, if any.
pub fn applyKind(comptime T: type) ?@TypeOf(.enum_literal) {
    return if (meta.hasDecl(T, "flecs_apply")) T.flecs_apply else null;
}
