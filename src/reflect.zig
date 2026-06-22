//! Reflection: derive flecs `EcsStruct` metadata from `@typeInfo`, which unlocks
//! JSON (de)serialization, component values in the Explorer, and constructing
//! components from Flecs Script. Supported field types: bool, the fixed-width
//! ints/floats, enums, fixed-size arrays, nested structs, `[:0]const u8` strings
//! (mapped opaque), plus any type declaring `pub fn flecsRegisterOpaque`. Member
//! units (`flecs_units`) and value ranges (`flecs_ranges`) are applied from decls.

const std = @import("std");
const c = @import("c");
const meta = @import("meta.zig");

fn isPrimitive(comptime T: type) bool {
    return switch (T) {
        bool, u8, u16, u32, u64, usize, i8, i16, i32, i64, isize, f32, f64 => true,
        else => false,
    };
}

/// The builtin primitive component id for a scalar Zig type (runtime extern).
fn primitiveId(comptime T: type) meta.Id {
    return switch (T) {
        bool => c.FLECS_IDecs_bool_tID_,
        u8 => c.FLECS_IDecs_u8_tID_,
        u16 => c.FLECS_IDecs_u16_tID_,
        u32 => c.FLECS_IDecs_u32_tID_,
        u64, usize => c.FLECS_IDecs_u64_tID_,
        i8 => c.FLECS_IDecs_i8_tID_,
        i16 => c.FLECS_IDecs_i16_tID_,
        i32 => c.FLECS_IDecs_i32_tID_,
        i64, isize => c.FLECS_IDecs_i64_tID_,
        f32 => c.FLECS_IDecs_f32_tID_,
        f64 => c.FLECS_IDecs_f64_tID_,
        else => unreachable,
    };
}

fn ArrayCache(comptime FT: type) type {
    return struct {
        comptime {
            _ = FT;
        }
        var id_: meta.Id = 0;
        var world: ?*c.ecs_world_t = null;
    };
}

/// Register a fixed-size array meta type `[N]Elem` (idempotent per world).
fn arrayTypeId(world: *c.ecs_world_t, comptime FT: type) meta.Id {
    const cache = ArrayCache(FT);
    if (cache.world == world and cache.id_ != 0) return cache.id_;
    const info = @typeInfo(FT).array;
    var desc = std.mem.zeroes(c.ecs_array_desc_t);
    desc.type = memberTypeId(world, info.child);
    desc.count = @intCast(info.len);
    const aid = c.ecs_array_init(world, &desc);
    cache.id_ = aid;
    cache.world = world;
    return aid;
}

/// Is `T` a sentinel-terminated `[:0]const u8` string slice?
fn isZigString(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer or info.pointer.size != .slice) return false;
    return info.pointer.child == u8 and info.pointer.sentinel() != null;
}

var string_opaque_id: meta.Id = 0;
var string_opaque_world: ?*c.ecs_world_t = null;

fn serializeString(ser: [*c]const c.ecs_serializer_t, src: ?*const anyopaque) callconv(.c) c_int {
    const slice: *const [:0]const u8 = @ptrCast(@alignCast(src));
    const cstr: [*c]const u8 = slice.ptr;
    return ser.*.value.?(ser, c.FLECS_IDecs_string_tID_, @ptrCast(&cstr));
}

/// Register an opaque type for `[:0]const u8` that serializes as a flecs string.
fn stringOpaqueId(world: *c.ecs_world_t) meta.Id {
    if (string_opaque_world == world and string_opaque_id != 0) return string_opaque_id;
    var cdesc = std.mem.zeroes(c.ecs_component_desc_t);
    var edesc = std.mem.zeroes(c.ecs_entity_desc_t);
    edesc.name = "ZigString";
    edesc.sep = "";
    cdesc.entity = c.ecs_entity_init(world, &edesc);
    cdesc.type.size = @sizeOf([:0]const u8);
    cdesc.type.alignment = @alignOf([:0]const u8);
    const e = c.ecs_component_init(world, &cdesc);

    var od = std.mem.zeroes(c.ecs_opaque_desc_t);
    od.entity = e;
    od.type.as_type = c.FLECS_IDecs_string_tID_;
    od.type.serialize = serializeString;
    _ = c.ecs_opaque_init(world, &od);

    string_opaque_id = e;
    string_opaque_world = world;
    return e;
}

/// The flecs *meta* type id for a Zig type `T` (the builtin primitive id for a
/// scalar, the registered `EcsStruct`/enum/array id otherwise). This is the id
/// to give flecs when it needs to know a value's layout - e.g. a script var.
pub fn metaId(world: *c.ecs_world_t, comptime T: type) meta.Id {
    return memberTypeId(world, T);
}

/// Member type id for field type `FT` in `world`. Handles primitives, nested
/// structs, enums (`EcsEnum` meta), fixed-size arrays, `[:0]const u8` strings
/// (opaque), and any type declaring `pub fn flecsRegisterOpaque(world) Id`.
fn memberTypeId(world: *c.ecs_world_t, comptime FT: type) meta.Id {
    if (comptime isPrimitive(FT)) return primitiveId(FT);
    if (comptime isZigString(FT)) return stringOpaqueId(world);
    if (comptime meta.hasDecl(FT, "flecsRegisterOpaque")) return FT.flecsRegisterOpaque(world);
    switch (@typeInfo(FT)) {
        .@"struct" => return register(world, FT),
        .@"enum" => return meta.enumRel(world, FT),
        .array => return arrayTypeId(world, FT),
        else => @compileError("reflect: unsupported field type " ++ @typeName(FT)),
    }
}

/// Register `EcsStruct` metadata for `T` (idempotent per world). Returns the
/// component id.
pub fn register(world: *c.ecs_world_t, comptime T: type) meta.Id {
    const cid = meta.id(world, T);
    // Verify the meta actually exists in *this* world (pointer equality alone is
    // unsafe - a freed world's address can be reused for a new world).
    if (c.ecs_has_id(world, cid, c.FLECS_IDEcsStructID_)) return cid;

    if (@typeInfo(T) != .@"struct") @compileError("reflect: " ++ @typeName(T) ++ " is not a struct");
    const fields = @typeInfo(T).@"struct".fields;

    // Units declared on the type (`pub const flecs_units = .{ .x = units.Meters }`)
    // are applied per member; importing the units module makes them resolvable.
    const has_units = @hasDecl(T, "flecs_units");
    if (has_units) @import("addons.zig").importUnits(world);

    var desc = std.mem.zeroes(c.ecs_struct_desc_t);
    desc.entity = cid;
    inline for (fields, 0..) |f, i| {
        desc.members[i].name = f.name ++ "";
        desc.members[i].type = memberTypeId(world, f.type);
        desc.members[i].offset = @intCast(@offsetOf(T, f.name));
        desc.members[i].use_offset = true;
        if (has_units and @hasField(@TypeOf(T.flecs_units), f.name)) {
            desc.members[i].unit = @field(T.flecs_units, f.name)();
        }
    }
    _ = c.ecs_struct_init(world, &desc);

    // Value ranges declared on the type (`pub const flecs_ranges = .{ .hp =
    // .{ .min = 0, .max = 100 } }`) are applied per member after registration.
    if (@hasDecl(T, "flecs_ranges")) {
        inline for (fields) |f| {
            if (@hasField(@TypeOf(T.flecs_ranges), f.name)) {
                const rng = @field(T.flecs_ranges, f.name);
                const member = c.ecs_lookup_child(world, cid, f.name ++ "");
                if (member != 0) {
                    var mr = std.mem.zeroes(c.EcsMemberRanges);
                    mr.value.min = rng.min;
                    mr.value.max = rng.max;
                    _ = c.ecs_set_id(world, member, c.FLECS_IDEcsMemberRangesID_, @sizeOf(c.EcsMemberRanges), &mr);
                }
            }
        }
    }
    return cid;
}

/// Serialize a component value to a JSON string (caller owns via `freeJson`).
pub fn ptrToJson(world: *c.ecs_world_t, comptime T: type, value: *const T) ?[]u8 {
    const cid = register(world, T);
    const s = c.ecs_ptr_to_json(world, cid, value);
    if (s == null) return null;
    return std.mem.span(s);
}

/// Parse JSON into a component value.
pub fn ptrFromJson(world: *c.ecs_world_t, comptime T: type, out: *T, json: [*:0]const u8) bool {
    const cid = register(world, T);
    return c.ecs_ptr_from_json(world, cid, out, json, null) != null;
}

pub fn freeJson(s: []u8) void {
    meta.osFree(@ptrCast(s.ptr));
}
