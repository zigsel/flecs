//! Comptime component reflection & lazy registration.
//!
//! The binding never asks the user to register a component by hand: the first
//! time a Zig type is used as a component, its id is derived from `@typeInfo`
//! and created in the world. Size, alignment, tag-ness and lifecycle hooks are
//! all read off the type. Ids are cached per-type so the same Zig type maps to
//! a stable component entity (and is re-bound with the same id in new worlds).

const std = @import("std");
const c = @import("c");

pub const Id = c.ecs_entity_t;

/// `@hasDecl` that is safe to call on any type (false for non-containers).
pub fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

/// Free memory allocated by flecs. `ecs_os_free` is a function-like macro over a
/// fn-pointer that translate-c can't lower, so we call the OS-api callback.
pub fn osFree(ptr: ?*anyopaque) void {
    c.ecs_os_api.free_.?(ptr);
}

/// Per-type id cache. Each distinct `T` instantiates a fresh static slot. We
/// cache the world too: component ids are world-local, so when the active world
/// changes we must re-register rather than trust a stale id (which may belong to
/// a different component in the new world).
fn Cache(comptime T: type) type {
    return struct {
        comptime {
            _ = T;
        }
        var id: Id = 0;
        var world: ?*c.ecs_world_t = null;
    };
}

// ---- enum-component relationships ----
//
// An enum type `E` becomes an exclusive relationship: each constant is a child
// entity, and `(E, .case)` is stored as a pair. This mirrors flecs' enum
// components without requiring the meta addon.

fn EnumCache(comptime E: type) type {
    const n = @typeInfo(E).@"enum".fields.len;
    return struct {
        var rel: Id = 0;
        var world: ?*c.ecs_world_t = null;
        var cases: [n]Id = [_]Id{0} ** n;
    };
}

/// The relationship id for enum `E`, registered with flecs `EcsEnum` meta (so it
/// is reflectable/serializable) and one constant entity per case. Cached per
/// world. flecs makes enum relationships exclusive automatically.
pub fn enumRel(world: *c.ecs_world_t, comptime E: type) Id {
    const cache = EnumCache(E);
    if (cache.world == world and cache.rel != 0 and c.ecs_is_alive(world, cache.rel)) {
        return cache.rel;
    }
    const rel = id(world, E);
    var desc = std.mem.zeroes(c.ecs_enum_desc_t);
    desc.entity = rel;
    // Match the underlying integer type (size and signedness) to the Zig enum's
    // storage so signed constants round-trip and sizes agree.
    const tag = @typeInfo(E).@"enum".tag_type;
    const unsigned = @typeInfo(tag).int.signedness == .unsigned;
    desc.underlying_type = if (unsigned) switch (@sizeOf(E)) {
        1 => c.FLECS_IDecs_u8_tID_,
        2 => c.FLECS_IDecs_u16_tID_,
        4 => c.FLECS_IDecs_u32_tID_,
        else => c.FLECS_IDecs_u64_tID_,
    } else switch (@sizeOf(E)) {
        1 => c.FLECS_IDecs_i8_tID_,
        2 => c.FLECS_IDecs_i16_tID_,
        4 => c.FLECS_IDecs_i32_tID_,
        else => c.FLECS_IDecs_i64_tID_,
    };
    inline for (@typeInfo(E).@"enum".fields, 0..) |fld, i| {
        desc.constants[i].name = fld.name ++ "";
        if (unsigned) {
            desc.constants[i].value_unsigned = @intFromEnum(@field(E, fld.name));
        } else {
            desc.constants[i].value = @intFromEnum(@field(E, fld.name));
        }
    }
    _ = c.ecs_enum_init(world, &desc);
    // The constants are created as named children of the enum entity.
    inline for (@typeInfo(E).@"enum".fields, 0..) |fld, i| {
        cache.cases[i] = c.ecs_lookup_child(world, rel, fld.name ++ "");
    }
    cache.rel = rel;
    cache.world = world;
    return rel;
}

/// The case entity for a specific enum value.
pub fn enumCase(world: *c.ecs_world_t, value: anytype) Id {
    const E = @TypeOf(value);
    _ = enumRel(world, E);
    const cache = EnumCache(E);
    inline for (@typeInfo(E).@"enum".fields, 0..) |fld, i| {
        if (value == @field(E, fld.name)) return cache.cases[i];
    }
    unreachable;
}

/// The pair id `(E, value)` for adding/matching.
pub fn enumPair(world: *c.ecs_world_t, value: anytype) Id {
    return c.ecs_make_pair(enumRel(world, @TypeOf(value)), enumCase(world, value));
}

/// Reverse-map a matched case entity back to the enum value.
pub fn enumValue(world: *c.ecs_world_t, comptime E: type, case_id: Id) ?E {
    _ = enumRel(world, E);
    const cache = EnumCache(E);
    inline for (@typeInfo(E).@"enum".fields, 0..) |fld, i| {
        if (case_id == cache.cases[i]) return @field(E, fld.name);
    }
    return null;
}

/// A zero-sized struct is a tag (no data, no storage).
pub fn isTag(comptime T: type) bool {
    return @sizeOf(T) == 0;
}

/// Per-component configuration declared on the type as
/// `pub const flecs_traits: flecs.Traits = .{ ... };` - the same exhaustive set
/// as `world.component`'s config.
pub const Traits = Config;

/// Cleanup policy actions (what happens to entities/instances on delete).
pub const CleanupAction = enum { remove, delete, panic };

pub const Cleanup = struct {
    /// Applied to entities holding this id when the id is deleted.
    on_delete: ?CleanupAction = null,
    /// Applied to entities with `(this, target)` when `target` is deleted.
    on_delete_target: ?CleanupAction = null,
};

/// Full component configuration. Pass to `world.component(T, .{...})`, or declare
/// it on the type as `pub const flecs_traits: flecs.Traits = .{ ... };`. Every
/// flecs component trait is a field here - exhaustive and discoverable.
pub const Config = struct {
    storage: enum { default, sparse, dont_fragment } = .default,
    exclusive: bool = false,
    can_toggle: bool = false,
    traversable: bool = false,
    symmetric: bool = false,
    final: bool = false,
    /// `(R, a)` + `(a, b)` implies `(R, b)` in queries.
    transitive: bool = false,
    /// `(R, a)` implies `(R, a)` holds for `a` itself (`a R a`).
    reflexive: bool = false,
    /// The relationship cannot form cycles (enables some traversal opts).
    acyclic: bool = false,
    /// Inherited components can themselves be inherited from.
    inheritable: bool = false,
    /// Mark as relationship-only / target-only / a trait component.
    relationship: bool = false,
    target: bool = false,
    trait: bool = false,
    /// Treat a pair with this as relationship as a tag (no data) even if the
    /// component has data.
    pair_is_tag: bool = false,
    /// Constrain pair targets to be members of this enum/scope (OneOf).
    one_of: ?type = null,
    /// Auto-add this component whenever the configured one is added (With).
    with: ?type = null,
    /// How instances inherit this component from prefabs (IsA).
    on_instantiate: enum { default, override, inherit, dont_inherit } = .default,
    cleanup: Cleanup = .{},
    singleton: bool = false,
};

fn cleanupActionId(a: CleanupAction) Id {
    return switch (a) {
        .remove => c.EcsRemove,
        .delete => c.EcsDelete,
        .panic => c.EcsPanic,
    };
}

/// Register `T` (if needed) and apply the given configuration as flecs traits.
/// Must be called before instances of `T` are created.
pub fn configure(world: *c.ecs_world_t, comptime T: type, comptime cfg: Config) Id {
    const cid = id(world, T);
    applyConfig(world, cid, cfg);
    return cid;
}

fn applyConfig(world: *c.ecs_world_t, cid: Id, comptime cfg: Config) void {
    const add = struct {
        fn one(w: *c.ecs_world_t, e: Id, trait: Id) void {
            c.ecs_add_id(w, e, trait);
        }
        fn pair(w: *c.ecs_world_t, e: Id, rel: Id, tgt: Id) void {
            c.ecs_add_id(w, e, c.ecs_make_pair(rel, tgt));
        }
    };
    switch (cfg.storage) {
        .default => {},
        .sparse => add.one(world, cid, c.EcsSparse),
        .dont_fragment => add.one(world, cid, c.EcsDontFragment),
    }
    if (cfg.exclusive) add.one(world, cid, c.EcsExclusive);
    if (cfg.can_toggle) add.one(world, cid, c.EcsCanToggle);
    if (cfg.traversable) add.one(world, cid, c.EcsTraversable);
    if (cfg.symmetric) add.one(world, cid, c.EcsSymmetric);
    if (cfg.final) add.one(world, cid, c.EcsFinal);
    if (cfg.transitive) add.one(world, cid, c.EcsTransitive);
    if (cfg.reflexive) add.one(world, cid, c.EcsReflexive);
    if (cfg.acyclic) add.one(world, cid, c.EcsAcyclic);
    if (cfg.inheritable) add.one(world, cid, c.EcsInheritable);
    if (cfg.relationship) add.one(world, cid, c.EcsRelationship);
    if (cfg.target) add.one(world, cid, c.EcsTarget);
    if (cfg.trait) add.one(world, cid, c.EcsTrait);
    if (cfg.pair_is_tag) add.one(world, cid, c.EcsPairIsTag);
    if (cfg.singleton) add.one(world, cid, c.EcsSingleton);
    if (cfg.one_of) |O| add.pair(world, cid, c.EcsOneOf, id(world, O));
    if (cfg.with) |W| add.pair(world, cid, c.EcsWith, id(world, W));
    switch (cfg.on_instantiate) {
        .default => {},
        .override => add.pair(world, cid, c.EcsOnInstantiate, c.EcsOverride),
        .inherit => add.pair(world, cid, c.EcsOnInstantiate, c.EcsInherit),
        .dont_inherit => add.pair(world, cid, c.EcsOnInstantiate, c.EcsDontInherit),
    }
    if (cfg.cleanup.on_delete) |a| add.pair(world, cid, c.EcsOnDelete, cleanupActionId(a));
    if (cfg.cleanup.on_delete_target) |a| add.pair(world, cid, c.EcsOnDeleteTarget, cleanupActionId(a));
}

/// Generate an `ecs_iter_action_t` that calls `func(*T, Entity)` for each row.
/// Used for the on_add/on_set/on_remove component hooks.
fn hookAction(comptime T: type, comptime func: anytype) c.ecs_iter_action_t {
    return struct {
        fn cb(it_ptr: [*c]c.ecs_iter_t) callconv(.c) void {
            const it = &it_ptr[0];
            const arr: [*]T = @ptrCast(@alignCast(c.ecs_field_w_size(it, @sizeOf(T), 0)));
            const params = @typeInfo(@TypeOf(func)).@"fn".params;
            var i: usize = 0;
            while (i < @as(usize, @intCast(it.count))) : (i += 1) {
                if (params.len == 1) {
                    func(&arr[i]);
                } else {
                    func(&arr[i], @import("entity.zig").Entity.init(it.world.?, it.entities[i]));
                }
            }
        }
    }.cb;
}

/// True only when `T` declares an `init` shaped exactly like the ctor hook -
/// `pub fn init(*T) void`. This avoids capturing the common value-returning
/// convenience constructor (`pub fn init(...) T`) as a hook.
fn isCtorHook(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "init")) return false;
    const info = @typeInfo(@TypeOf(T.init));
    if (info != .@"fn") return false;
    const f = info.@"fn";
    return f.params.len == 1 and f.params[0].type == *T and f.return_type == void;
}

/// Build the type hooks for `T` from its declarations:
/// - `pub fn init(*T) void`                -> constructor (runs on add/ensure)
/// - `pub fn deinit(*T) void`              -> destructor
/// - `pub fn copy(*const T) T`             -> copy hook (else memcpy)
/// - `pub fn onAdd(*T[, Entity]) void`     -> on_add component hook
/// - `pub fn onSet(*T[, Entity]) void`     -> on_set component hook
/// - `pub fn onRemove(*T[, Entity]) void`  -> on_remove component hook
fn hooksFor(comptime T: type) c.ecs_type_hooks_t {
    var hooks = std.mem.zeroes(c.ecs_type_hooks_t);
    if (isTag(T)) return hooks;

    // Constructor: zero the fresh storage (flecs' default baseline), then run the
    // user's `init` so partial initialization is still safe.
    if (comptime isCtorHook(T)) {
        const Tramp = struct {
            fn ctor(ptr: ?*anyopaque, count: i32, ti: [*c]const c.ecs_type_info_t) callconv(.c) void {
                _ = ti;
                const n: usize = @intCast(count);
                @memset(@as([*]u8, @ptrCast(ptr.?))[0 .. n * @sizeOf(T)], 0);
                const items: [*]T = @ptrCast(@alignCast(ptr));
                var i: usize = 0;
                while (i < n) : (i += 1) items[i].init();
            }
        };
        hooks.ctor = Tramp.ctor;
    }

    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "onAdd")) hooks.on_add = hookAction(T, T.onAdd);
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "onSet")) hooks.on_set = hookAction(T, T.onSet);
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "onRemove")) hooks.on_remove = hookAction(T, T.onRemove);
    // on_replace is opt-in: declaring it disables get_mut/ensure for the type.
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "onReplace")) hooks.on_replace = hookAction(T, T.onReplace);

    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "deinit")) {
        const Tramp = struct {
            fn dtor(ptr: ?*anyopaque, count: i32, ti: [*c]const c.ecs_type_info_t) callconv(.c) void {
                _ = ti;
                const items: [*]T = @ptrCast(@alignCast(ptr));
                var i: usize = 0;
                while (i < @as(usize, @intCast(count))) : (i += 1) items[i].deinit();
            }
        };
        hooks.dtor = Tramp.dtor;
    }

    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "copy")) {
        const Tramp = struct {
            fn cp(dst: ?*anyopaque, src: ?*const anyopaque, count: i32, ti: [*c]const c.ecs_type_info_t) callconv(.c) void {
                _ = ti;
                const d: [*]T = @ptrCast(@alignCast(dst));
                const s: [*]const T = @ptrCast(@alignCast(src));
                var i: usize = 0;
                while (i < @as(usize, @intCast(count))) : (i += 1) d[i] = s[i].copy();
            }
        };
        hooks.copy = Tramp.cp;
    }

    return hooks;
}

/// The raw Zig type name, used as the component's flecs *symbol* (unique key).
pub fn typeName(comptime T: type) [*:0]const u8 {
    return @typeName(T) ++ "";
}

/// A DSL/JSON/Script-friendly flecs *name*: the type's *simple* name (the last
/// `.`-separated segment of its qualified name), sanitized to a flat identifier.
/// Override with `pub const flecs_name = "Foo";` on the type. Components sharing
/// a simple name collide - qualify with `flecs_name` if that happens.
pub fn safeName(comptime T: type) [*:0]const u8 {
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "flecs_name")) return T.flecs_name ++ "";
    const raw = @typeName(T);
    // take the segment after the last '.'
    comptime var start: usize = 0;
    inline for (raw, 0..) |ch, i| {
        if (ch == '.') start = i + 1;
    }
    const seg = raw[start..];
    comptime var buf: [seg.len:0]u8 = undefined;
    inline for (seg, 0..) |ch, i| {
        buf[i] = switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '_' => ch,
            else => '_',
        };
    }
    const final = buf;
    return &final;
}

/// Look up or lazily register the component id for `T` in `world`.
pub fn id(world: *c.ecs_world_t, comptime T: type) Id {
    // Builtin relationships resolve to flecs' own ids.
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "flecs_builtin")) {
        return switch (T.flecs_builtin) {
            .child_of => c.EcsChildOf,
            .is_a => c.EcsIsA,
            else => @compileError("unknown builtin"),
        };
    }
    return idImpl(world, T);
}

fn symbolMatches(world: *c.ecs_world_t, e: Id, sym: [*:0]const u8) bool {
    if (!c.ecs_is_alive(world, e)) return false;
    const got = c.ecs_get_symbol(world, e);
    if (got == null) return false;
    return std.mem.orderZ(u8, got, sym) == .eq;
}

fn idImpl(world: *c.ecs_world_t, comptime T: type) Id {
    const cache = Cache(T);
    const sym = typeName(T);

    // Fast path: cached id, still valid for *this* world. The symbol check
    // defends against world-pointer reuse (a freed world's address handed to a
    // fresh world) where the cached id would otherwise be a different component.
    if (cache.id != 0 and cache.world == world and symbolMatches(world, cache.id, sym)) {
        return cache.id;
    }

    // Authoritative lookup by symbol (handles a new world reusing this type).
    var e = c.ecs_lookup_symbol(world, sym, false, false);
    if (e == 0) {
        var desc = std.mem.zeroes(c.ecs_component_desc_t);
        var edesc = std.mem.zeroes(c.ecs_entity_desc_t);
        edesc.name = safeName(T);
        edesc.sep = ""; // name is already a single flat identifier
        edesc.symbol = sym;
        edesc.use_low_id = true;
        desc.entity = c.ecs_entity_init(world, &edesc);
        if (!isTag(T)) {
            desc.type.size = @sizeOf(T);
            desc.type.alignment = @alignOf(T);
            desc.type.hooks = hooksFor(T);
        }
        e = c.ecs_component_init(world, &desc);
        // Apply any `pub const flecs_traits` configuration declared on the type.
        if (@typeInfo(T) == .@"struct" and @hasDecl(T, "flecs_traits")) {
            applyConfig(world, e, T.flecs_traits);
        }
    }

    cache.id = e;
    cache.world = world;
    return e;
}
