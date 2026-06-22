//! The shared term compiler used by both typed queries and systems/observers.
//!
//! Input: an ordered list of "slots" (struct fields or function params), each
//! with a declared Zig type. Output: a comptime plan that knows how to (1) fill
//! flecs query terms, and (2) reconstruct each slot's value from an iterator
//! row. Queries and systems differ only in where the slots come from.

const std = @import("std");
const c = @import("c");
const meta = @import("meta.zig");
const terms = @import("terms.zig");
const Entity = @import("entity.zig").Entity;

const Kind = terms.Kind;

pub const Slot = struct {
    /// The declared field/param type (used to reconstruct the slot value).
    Field: type = void,
    kind: Kind,
    Comp: type = void,
    Rel: type = void,
    is_const: bool = false,
    optional: bool = false,
    or_types: []const type = &.{},
    event: @TypeOf(.enum_literal) = .add,
    src_name: [:0]const u8 = "",
    scope_op: terms.ScopeOp = .and_,
    // Assigned by `plan`:
    term_start: i32 = -1,
    data_ord: i32 = -1, // index into the per-row base-pointer cache (-1 = none)
};

fn pointerChild(comptime T: type) ?type {
    const info = @typeInfo(T);
    if (info != .pointer or info.pointer.size != .one) return null;
    return info.pointer.child;
}

fn isConst(comptime Ptr: type) bool {
    return @typeInfo(Ptr).pointer.is_const;
}

fn typesOf(comptime tup: anytype) []const type {
    const fields = @typeInfo(@TypeOf(tup)).@"struct".fields;
    comptime var arr: [fields.len]type = undefined;
    inline for (fields, 0..) |f, i| arr[i] = @field(tup, f.name);
    const final = arr;
    return &final;
}

/// Classify a single declared type into an (unplanned) slot.
pub fn classify(comptime T: type) Slot {
    if (T == Entity) return .{ .Field = T, .kind = .entity };
    if (T == terms.Delta) return .{ .Field = T, .kind = .delta };

    if (terms.kindOf(T)) |k| switch (k) {
        .with => return .{ .Field = T, .kind = .with, .Comp = T.Comp },
        .without => return .{ .Field = T, .kind = .without, .Comp = T.Comp },
        .and_from => return .{ .Field = T, .kind = .and_from, .Comp = T.Comp },
        .or_from => return .{ .Field = T, .kind = .or_from, .Comp = T.Comp },
        .not_from => return .{ .Field = T, .kind = .not_from, .Comp = T.Comp },
        .or_ => return .{ .Field = T, .kind = .or_, .or_types = typesOf(T.Comps) },
        .event => return .{ .Field = T, .kind = .event, .Comp = T.Comp, .event = T.flecs_event },
        .up, .cascade => {
            const Ptr = @FieldType(T, "v");
            return .{ .Field = T, .kind = k, .Rel = T.Rel, .Comp = pointerChild(Ptr).?, .is_const = isConst(Ptr) };
        },
        .singleton => {
            const Ptr = @FieldType(T, "v");
            return .{ .Field = T, .kind = .singleton, .Comp = pointerChild(Ptr).?, .is_const = isConst(Ptr) };
        },
        .from => {
            const Ptr = @FieldType(T, "v");
            return .{ .Field = T, .kind = .from, .Comp = pointerChild(Ptr).?, .is_const = isConst(Ptr), .src_name = T.src_name };
        },
        .scope => return .{ .Field = T, .kind = .scope, .or_types = typesOf(T.Comps), .scope_op = T.scope_op },
        .pair => {
            const Ptr = @FieldType(T, "v");
            return .{ .Field = T, .kind = .pair, .Rel = T.Rel, .Comp = pointerChild(Ptr).?, .is_const = isConst(Ptr) };
        },
        else => {},
    };

    const info = @typeInfo(T);
    if (info == .optional) {
        if (pointerChild(info.optional.child)) |child| {
            return .{ .Field = T, .kind = .data, .Comp = child, .is_const = isConst(info.optional.child), .optional = true };
        }
    }
    if (pointerChild(T)) |child| {
        return .{ .Field = T, .kind = .data, .Comp = child, .is_const = info.pointer.is_const };
    }
    @compileError("type " ++ @typeName(T) ++ " is not a valid query/system term");
}

fn isValueBearing(k: Kind) bool {
    return switch (k) {
        .data, .up, .cascade, .singleton, .pair, .from => true,
        else => false,
    };
}

fn termCount(s: Slot) i32 {
    return switch (s.kind) {
        .with, .without, .data, .up, .cascade, .singleton, .pair, .and_from, .or_from, .not_from, .from => 1,
        .or_ => @intCast(s.or_types.len),
        .scope => @intCast(2 + s.or_types.len), // ScopeOpen + inner + ScopeClose
        else => 0, // entity, delta, event, payload
    };
}

/// Assign term indices and data ordinals.
pub fn plan(comptime slots: []const Slot) []const Slot {
    comptime var out: [slots.len]Slot = undefined;
    comptime var term: i32 = 0;
    comptime var data: i32 = 0;
    inline for (slots, 0..) |s, i| {
        var p = s;
        const tc = termCount(s);
        if (tc > 0) {
            p.term_start = term;
            term += tc;
        }
        if (isValueBearing(s.kind)) {
            p.data_ord = data;
            data += 1;
        }
        out[i] = p;
    }
    const final = out;
    return &final;
}

/// Total number of flecs terms the planned slots occupy (sum of per-slot term
/// counts). This is the first free index in the term array - use it to append
/// extra terms rather than scanning for a zero id (a `Scope` open/close term has
/// `id == 0` and would be falsely treated as empty).
pub fn termTotal(comptime slots: []const Slot) usize {
    comptime var n: usize = 0;
    inline for (slots) |s| n += @intCast(termCount(s));
    return n;
}

/// Number of value-bearing slots (size of the base-pointer cache).
pub fn dataCount(comptime slots: []const Slot) usize {
    comptime var n: usize = 0;
    inline for (slots) |s| {
        if (isValueBearing(s.kind)) n += 1;
    }
    return n;
}

/// Write all terms for the planned slots into `terms_ptr` (a query desc's term
/// array). Component ids are resolved against `world`.
pub fn fillTerms(comptime slots: []const Slot, world: *c.ecs_world_t, terms_ptr: [*]c.ecs_term_t) void {
    inline for (slots) |s| {
        if (s.term_start < 0) continue;
        const start: usize = @intCast(s.term_start);
        switch (s.kind) {
            .data => {
                var t = &terms_ptr[start];
                t.id = meta.id(world, s.Comp);
                t.inout = if (s.is_const) c.EcsIn else c.EcsInOut;
                if (s.optional) t.oper = c.EcsOptional;
            },
            .with => {
                var t = &terms_ptr[start];
                t.id = meta.id(world, s.Comp);
                t.inout = c.EcsInOutNone;
            },
            .without => {
                var t = &terms_ptr[start];
                t.id = meta.id(world, s.Comp);
                t.inout = c.EcsInOutNone;
                t.oper = c.EcsNot;
            },
            .and_from, .or_from, .not_from => {
                var t = &terms_ptr[start];
                t.id = meta.id(world, s.Comp);
                t.inout = c.EcsInOutNone;
                t.oper = switch (s.kind) {
                    .and_from => c.EcsAndFrom,
                    .or_from => c.EcsOrFrom,
                    .not_from => c.EcsNotFrom,
                    else => unreachable,
                };
            },
            .or_ => {
                inline for (s.or_types, 0..) |Ty, j| {
                    var t = &terms_ptr[start + j];
                    t.id = meta.id(world, Ty);
                    t.inout = c.EcsInOutNone;
                    if (j + 1 < s.or_types.len) t.oper = c.EcsOr;
                }
            },
            .singleton => {
                var t = &terms_ptr[start];
                const cid = meta.id(world, s.Comp);
                t.id = cid;
                t.inout = if (s.is_const) c.EcsIn else c.EcsInOut;
                t.src.id = cid | c.EcsIsEntity;
            },
            .up => {
                var t = &terms_ptr[start];
                t.id = meta.id(world, s.Comp);
                t.inout = if (s.is_const) c.EcsIn else c.EcsInOut;
                t.trav = meta.id(world, s.Rel);
                t.src.id = c.EcsUp;
            },
            .cascade => {
                var t = &terms_ptr[start];
                t.id = meta.id(world, s.Comp);
                t.inout = if (s.is_const) c.EcsIn else c.EcsInOut;
                t.trav = meta.id(world, s.Rel);
                t.src.id = c.EcsCascade;
            },
            .pair => {
                var t = &terms_ptr[start];
                t.id = c.ecs_make_pair(meta.id(world, s.Rel), c.EcsWildcard);
                t.inout = if (s.is_const) c.EcsIn else c.EcsInOut;
            },
            .from => {
                var t = &terms_ptr[start];
                t.id = meta.id(world, s.Comp);
                t.inout = if (s.is_const) c.EcsIn else c.EcsInOut;
                const src = c.ecs_lookup(world, s.src_name.ptr);
                std.debug.assert(src != 0); // From("name", ...): no entity named `name`
                t.src.id = src | c.EcsIsEntity;
            },
            .scope => {
                // ScopeOpen (carries the group operator), inner And terms, ScopeClose.
                var open = &terms_ptr[start];
                open.first.id = c.EcsScopeOpen;
                open.src.id = c.EcsIsEntity;
                open.inout = c.EcsInOutNone;
                open.oper = switch (s.scope_op) {
                    .and_ => c.EcsAnd,
                    .not => c.EcsNot,
                    .optional => c.EcsOptional,
                };
                inline for (s.or_types, 0..) |Ty, j| {
                    var t = &terms_ptr[start + 1 + j];
                    t.id = meta.id(world, Ty);
                    t.inout = c.EcsInOutNone;
                }
                var close = &terms_ptr[start + 1 + s.or_types.len];
                close.first.id = c.EcsScopeClose;
                close.src.id = c.EcsIsEntity;
                close.inout = c.EcsInOutNone;
            },
            else => {},
        }
    }
}

/// Fetch per-table base pointers for every value-bearing slot. `it.query` is
/// used to resolve field indices (works for both queries and systems).
pub fn cacheBases(comptime slots: []const Slot, it: *c.ecs_iter_t) [dataCount(slots)]?[*]u8 {
    var bases: [dataCount(slots)]?[*]u8 = undefined;
    inline for (slots) |s| {
        if (comptime !isValueBearing(s.kind)) continue;
        const fi = it.query.*.terms[@intCast(s.term_start)].field_index;
        const ptr = c.ecs_field_w_size(it, @sizeOf(s.Comp), fi);
        bases[@intCast(s.data_ord)] = if (ptr == null) null else @ptrCast(@alignCast(ptr));
    }
    return bases;
}

/// Reconstruct the value for slot `s` at row `i` of the current table.
pub inline fn value(comptime s: Slot, it: *c.ecs_iter_t, bases: anytype, i: usize) s.Field {
    switch (s.kind) {
        .entity => return Entity.init(it.world.?, it.entities[i]),
        .delta => return .{ .s = it.delta_time },
        .with, .without, .or_, .and_from, .or_from, .not_from, .scope, .event => return .{},
        .payload => return @ptrCast(@alignCast(it.param.?)),
        .data => {
            const base = bases[@intCast(s.data_ord)];
            if (s.optional) {
                return if (base) |b| @ptrCast(@alignCast(b + i * @sizeOf(s.Comp))) else null;
            }
            return @ptrCast(@alignCast(base.? + i * @sizeOf(s.Comp)));
        },
        .up, .cascade, .singleton, .from => {
            // Shared field: a single instance for the whole table.
            const base = bases[@intCast(s.data_ord)];
            return .{ .v = @ptrCast(@alignCast(base.?)) };
        },
        .pair => {
            const base = bases[@intCast(s.data_ord)];
            const fi = it.query.*.terms[@intCast(s.term_start)].field_index;
            const matched = c.ecs_field_id(it, fi);
            const target = c.ecs_pair_second(it.real_world.?, matched);
            return .{
                .v = @ptrCast(@alignCast(base.? + i * @sizeOf(s.Comp))),
                .target = Entity.init(it.world.?, target),
            };
        },
    }
}
