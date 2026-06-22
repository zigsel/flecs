//! Query/system/observer term wrappers, plus the query-ordering specs. These are
//! semantics-free comptime markers: a slot's *type* encodes which flecs term(s)
//! it lowers to. Pointer-ness encodes access (`*T` inout, `*const T` in, `?*`
//! optional); wrapper types encode the operator set (With/Without/Or/Up/…).
//!
//! Value-bearing wrappers expose the matched data through a `.v` field (and,
//! for pairs, a `.target` entity), so they can be used directly as a row field.

const c = @import("c");
const Entity = @import("entity.zig").Entity;
const meta = @import("meta.zig");

// ---- query ordering (the `sort` decl on a query/system) ----
//
// `pub const sort = flecs.ascBy(Position, .y);` on a query struct lowers to
// flecs' order_by. The sort spec is a *type* exposing the component to sort on
// and a `callconv(.c)` comparator; the binding reads `Comp`/`order` off it.

/// Sort by a user comparator: `fn(a: *const T, b: *const T) bool` (a < b).
pub fn sortBy(comptime T: type, comptime less: fn (*const T, *const T) bool) type {
    return struct {
        pub const Comp = T;
        pub fn order(e1: c.ecs_entity_t, p1: ?*const anyopaque, e2: c.ecs_entity_t, p2: ?*const anyopaque) callconv(.c) c_int {
            _ = e1;
            _ = e2;
            const a: *const T = @ptrCast(@alignCast(p1));
            const b: *const T = @ptrCast(@alignCast(p2));
            if (less(a, b)) return -1;
            if (less(b, a)) return 1;
            return 0;
        }
    };
}

fn memberLess(comptime T: type, comptime field: @TypeOf(.enum_literal), comptime ascending: bool) fn (*const T, *const T) bool {
    return struct {
        fn lt(a: *const T, b: *const T) bool {
            const av = @field(a, @tagName(field));
            const bv = @field(b, @tagName(field));
            return if (ascending) av < bv else av > bv;
        }
    }.lt;
}

/// Sort ascending by a field of `T` (e.g. `ascBy(Position, .y)`).
pub fn ascBy(comptime T: type, comptime field: @TypeOf(.enum_literal)) type {
    return sortBy(T, memberLess(T, field, true));
}

/// Sort descending by a field of `T`.
pub fn descBy(comptime T: type, comptime field: @TypeOf(.enum_literal)) type {
    return sortBy(T, memberLess(T, field, false));
}

// ---- filter operators (no data) ----

/// Match `T` but read no data (`inout = None`).
pub fn With(comptime T: type) type {
    return struct {
        pub const flecs_kind: Kind = .with;
        pub const Comp = T;
    };
}

/// The entity must NOT have `T` (`oper = Not`).
pub fn Without(comptime T: type) type {
    return struct {
        pub const flecs_kind: Kind = .without;
        pub const Comp = T;
    };
}

/// Match any one of the given component types (`oper = Or` chain). Filter only.
pub fn Or(comptime types: anytype) type {
    return struct {
        pub const flecs_kind: Kind = .or_;
        pub const Comps = types;
    };
}

/// Entity must have ALL components of type/prefab `T` (`oper = AndFrom`).
pub fn AndFrom(comptime T: type) type {
    return struct {
        pub const flecs_kind: Kind = .and_from;
        pub const Comp = T;
    };
}
/// Entity must have AT LEAST ONE component of `T` (`oper = OrFrom`).
pub fn OrFrom(comptime T: type) type {
    return struct {
        pub const flecs_kind: Kind = .or_from;
        pub const Comp = T;
    };
}
/// Entity must have NONE of `T`'s components (`oper = NotFrom`).
pub fn NotFrom(comptime T: type) type {
    return struct {
        pub const flecs_kind: Kind = .not_from;
        pub const Comp = T;
    };
}

// ---- data operators (carry a `.v` pointer) ----

/// Read `T` from the first ancestor along relationship `R` (default ChildOf).
/// `Ptr` is `*const T` / `*T`.
pub fn Up(comptime R: type, comptime Ptr: type) type {
    return struct {
        pub const flecs_kind: Kind = .up;
        pub const Rel = R;
        v: Ptr,
    };
}

/// Like `Up`, but orders results breadth-first by depth (`EcsCascade`).
pub fn Cascade(comptime R: type, comptime Ptr: type) type {
    return struct {
        pub const flecs_kind: Kind = .cascade;
        pub const Rel = R;
        v: Ptr,
    };
}

/// Read a singleton component `T` (term source fixed to the component entity).
pub fn Singleton(comptime Ptr: type) type {
    return struct {
        pub const flecs_kind: Kind = .singleton;
        v: Ptr,
    };
}

/// Read a component from a *fixed* source entity (looked up by `name` at query
/// creation) rather than the matched entity - e.g. pull shared config off a
/// named "GameConfig" entity. `Ptr` is `*const T` / `*T`.
pub fn From(comptime name: [:0]const u8, comptime Ptr: type) type {
    return struct {
        pub const flecs_kind: Kind = .from;
        pub const src_name = name;
        v: Ptr,
    };
}

/// A nested query scope: applies `op` to a group of component terms (so e.g.
/// `Scope(.not, .{Frozen, Dead})` is `!{ Frozen, Dead }`). Filter only.
pub fn Scope(comptime op: ScopeOp, comptime types: anytype) type {
    return struct {
        pub const flecs_kind: Kind = .scope;
        pub const scope_op = op;
        pub const Comps = types;
    };
}

pub const ScopeOp = enum { and_, not, optional };

/// Match relationship pair `(R, *)` and read the pair's data plus the matched
/// target. `Ptr` is `*const Data` / `*Data` where Data is the pair component.
pub fn Pair(comptime R: type, comptime Ptr: type) type {
    return struct {
        pub const flecs_kind: Kind = .pair;
        pub const Rel = R;
        v: Ptr,
        target: Entity,
    };
}

// ---- run-system params (drive their own iteration) ----

/// Read-only access to a singleton resource as a run-system parameter.
pub fn Res(comptime T: type) type {
    return struct {
        pub const flecs_res = T;
        pub const flecs_res_mut = false;
        v: *const T,
    };
}

/// Mutable access to a singleton resource as a run-system parameter.
pub fn ResMut(comptime T: type) type {
    return struct {
        pub const flecs_res = T;
        pub const flecs_res_mut = true;
        v: *T,
    };
}

pub fn isRes(comptime T: type) bool {
    return meta.hasDecl(T, "flecs_res");
}

// ---- special system/observer params ----

/// System parameter carrying the frame delta time (seconds).
pub const Delta = struct { s: f32 };

/// Observer event markers. As a parameter, `OnAdd(T)` &co select the event to
/// observe (and ensure `T` is part of the query).
pub fn OnAdd(comptime T: type) type {
    return struct {
        pub const flecs_kind: Kind = .event;
        pub const flecs_event = .add;
        pub const Comp = T;
    };
}
pub fn OnRemove(comptime T: type) type {
    return struct {
        pub const flecs_kind: Kind = .event;
        pub const flecs_event = .remove;
        pub const Comp = T;
    };
}
pub fn OnSet(comptime T: type) type {
    return struct {
        pub const flecs_kind: Kind = .event;
        pub const flecs_event = .set;
        pub const Comp = T;
    };
}

/// Observe a custom event `E`. The event payload is delivered through a
/// `*const E` parameter on the same observer (read from `it.param`).
pub fn OnEvent(comptime E: type) type {
    return struct {
        pub const flecs_kind: Kind = .event;
        pub const flecs_event = .custom;
        pub const Comp = E;
    };
}

/// The classification of a single query/system slot.
pub const Kind = enum {
    entity, // flecs.Entity field
    delta, // flecs.Delta param
    event, // OnAdd/OnRemove/OnSet/OnEvent marker
    payload, // *const E event payload (read from it.param)
    data, // *T / *const T / ?*T
    with,
    without,
    or_,
    and_from,
    or_from,
    not_from,
    up,
    cascade,
    singleton,
    pair,
    from, // fixed-source term (From)
    scope, // nested query scope (Scope)
};

/// Read the `flecs_kind` marker decl, if any.
pub fn kindOf(comptime T: type) ?Kind {
    return if (meta.hasDecl(T, "flecs_kind")) T.flecs_kind else null;
}
