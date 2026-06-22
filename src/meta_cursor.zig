//! Runtime field-by-field reflection over a component value (`ecs_meta_cursor`).
//!
//! A cursor walks a reflected type's members/elements and reads or writes them
//! by name/index without compile-time knowledge of the layout - the building
//! block for property editors, custom deserializers, and scripting glue. For
//! whole-value (de)serialization prefer `world.toJson`/`fromJson`; reach for a
//! cursor when you need to touch individual fields dynamically.
//!
//!     var v: Transform = undefined;
//!     var cur = world.metaCursor(Transform, &v);
//!     try cur.push();                       // enter the struct
//!     try cur.member("x");  try cur.set(@as(f32, 1));
//!     try cur.member("y");  try cur.set(@as(f32, 2));
//!     try cur.pop();

const std = @import("std");
const c = @import("c");
const meta = @import("meta.zig");
const Entity = @import("entity.zig").Entity;

pub const Error = error{MetaOpFailed};

fn check(rc: c_int) Error!void {
    if (rc != 0) return Error.MetaOpFailed;
}

pub const MetaCursor = struct {
    world: *c.ecs_world_t,
    cur: c.ecs_meta_cursor_t,

    const Self = @This();

    // ---- navigation ----

    /// Descend into the current struct/collection field.
    pub fn push(self: *Self) Error!void {
        return check(c.ecs_meta_push(&self.cur));
    }
    /// Ascend out of the current struct/collection.
    pub fn pop(self: *Self) Error!void {
        return check(c.ecs_meta_pop(&self.cur));
    }
    /// Advance to the next member/element in the current scope.
    pub fn next(self: *Self) Error!void {
        return check(c.ecs_meta_next(&self.cur));
    }
    /// Move to member `name` of the current struct.
    pub fn member(self: *Self, name: [*:0]const u8) Error!void {
        return check(c.ecs_meta_member(&self.cur, name));
    }
    /// Move to a nested member by dotted path, e.g. `"position.x"`.
    pub fn dotMember(self: *Self, name: [*:0]const u8) Error!void {
        return check(c.ecs_meta_dotmember(&self.cur, name));
    }
    /// Move to element `index` of the current collection.
    pub fn elem(self: *Self, index: i32) Error!void {
        return check(c.ecs_meta_elem(&self.cur, index));
    }

    // ---- write ----

    /// Set the current field from a Zig value: bool, any int/float, a
    /// `flecs.Entity`, or a sentinel-terminated string (`[:0]const u8` /
    /// `[*:0]const u8`). The flecs meta layer coerces to the field's real type.
    pub fn set(self: *Self, value: anytype) Error!void {
        const V = @TypeOf(value);
        if (V == Entity) return check(c.ecs_meta_set_entity(&self.cur, value.id));
        return switch (@typeInfo(V)) {
            .bool => check(c.ecs_meta_set_bool(&self.cur, value)),
            .int => |i| if (i.signedness == .signed)
                check(c.ecs_meta_set_int(&self.cur, @intCast(value)))
            else
                check(c.ecs_meta_set_uint(&self.cur, @intCast(value))),
            .comptime_int => check(c.ecs_meta_set_int(&self.cur, value)),
            .float, .comptime_float => check(c.ecs_meta_set_float(&self.cur, value)),
            .pointer => check(c.ecs_meta_set_string(&self.cur, stringPtr(value))),
            else => @compileError("MetaCursor.set: unsupported type " ++ @typeName(V)),
        };
    }

    /// Set the current field to a raw id (e.g. an entity or pair).
    pub fn setId(self: *Self, id: meta.Id) Error!void {
        return check(c.ecs_meta_set_id(&self.cur, id));
    }
    /// Set the current field to null (for opaque/optional members).
    pub fn setNull(self: *Self) Error!void {
        return check(c.ecs_meta_set_null(&self.cur));
    }

    // ---- read ----

    pub fn getBool(self: *const Self) bool {
        return c.ecs_meta_get_bool(&self.cur);
    }
    pub fn getInt(self: *const Self) i64 {
        return c.ecs_meta_get_int(&self.cur);
    }
    pub fn getUint(self: *const Self) u64 {
        return c.ecs_meta_get_uint(&self.cur);
    }
    pub fn getFloat(self: *const Self) f64 {
        return c.ecs_meta_get_float(&self.cur);
    }
    pub fn getString(self: *const Self) ?[]const u8 {
        const s = c.ecs_meta_get_string(&self.cur);
        return if (s == null) null else std.mem.span(s);
    }
    pub fn getEntity(self: *const Self) ?Entity {
        const e = c.ecs_meta_get_entity(&self.cur);
        return if (e == 0) null else Entity.init(self.world, e);
    }

    /// Pointer to the current field's storage (for direct access).
    pub fn ptr(self: *Self) ?*anyopaque {
        return c.ecs_meta_get_ptr(&self.cur);
    }

    // ---- introspection ----

    /// Whether the current field is an array/vector (push-able as a collection).
    pub fn isCollection(self: *const Self) bool {
        return c.ecs_meta_is_collection(&self.cur);
    }
    /// The type entity of the current field.
    pub fn typeId(self: *const Self) ?Entity {
        const t = c.ecs_meta_get_type(&self.cur);
        return if (t == 0) null else Entity.init(self.world, t);
    }
};

/// Coerce a Zig string value to a C string pointer (sentinel-terminated forms).
fn stringPtr(value: anytype) [*:0]const u8 {
    const V = @TypeOf(value);
    const info = @typeInfo(V).pointer;
    if (info.size == .slice) return value.ptr; // [:0]const u8
    return value; // [*:0]const u8
}
