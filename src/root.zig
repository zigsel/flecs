//! flecs - idiomatic Zig bindings for the flecs ECS.
//!
//! Design rule: the binding translates *declarations* into flecs calls; it
//! never invents runtime behavior. Components are plain structs, systems are
//! plain functions whose signature is their query, modules are plain Zig
//! containers. Everything comptime can derive is derived.

const std = @import("std");

// The raw flecs C bindings are an internal implementation detail and are not
// re-exported: the entire flecs feature set is reachable through the idiomatic
// API below. (Plain data structs that some calls return are aliased here so
// they remain nameable.)
const c = @import("c");

pub const units = @import("units.zig");
pub const log = @import("log.zig");

// ---- info / result structs returned by the API ----
pub const WorldInfo = c.ecs_world_info_t;
pub const QueryCount = c.ecs_query_count_t;
pub const QueryGroupInfo = c.ecs_query_group_info_t;

const world_mod = @import("world.zig");
const entity_mod = @import("entity.zig");
const query_mod = @import("query.zig");
const terms_mod = @import("terms.zig");
const meta_mod = @import("meta.zig");

// ---- core types ----
pub const World = world_mod.World;
pub const Phase = world_mod.Phase;
pub const InitOptions = world_mod.InitOptions;
pub const EntityOptions = world_mod.EntityOptions;
pub const Entity = entity_mod.Entity;
pub const Ref = entity_mod.Ref;
pub const Table = entity_mod.Table;
pub const WriteGuard = entity_mod.WriteGuard;
pub const ReadGuard = entity_mod.ReadGuard;
pub const MetaCursor = @import("meta_cursor.zig").MetaCursor;
pub const Query = query_mod.Query;

// ---- component configuration ----
pub const Traits = meta_mod.Traits;
pub const Config = meta_mod.Config;
pub const Cleanup = meta_mod.Cleanup;
pub const CleanupAction = meta_mod.CleanupAction;
pub const Id = meta_mod.Id;

// ---- term & param wrappers ----
pub const With = terms_mod.With;
pub const Without = terms_mod.Without;
pub const AndFrom = terms_mod.AndFrom;
pub const OrFrom = terms_mod.OrFrom;
pub const NotFrom = terms_mod.NotFrom;
pub const Or = terms_mod.Or;
pub const sortBy = terms_mod.sortBy;
pub const ascBy = terms_mod.ascBy;
pub const descBy = terms_mod.descBy;
pub const Up = terms_mod.Up;
pub const Cascade = terms_mod.Cascade;
pub const Singleton = terms_mod.Singleton;
pub const From = terms_mod.From;
pub const Scope = terms_mod.Scope;
pub const ScopeOp = terms_mod.ScopeOp;
pub const Pair = terms_mod.Pair;
pub const Delta = terms_mod.Delta;
pub const Res = terms_mod.Res;
pub const ResMut = terms_mod.ResMut;
pub const Stage = @import("stage.zig").Stage;
pub const OnAdd = terms_mod.OnAdd;
pub const OnRemove = terms_mod.OnRemove;
pub const OnSet = terms_mod.OnSet;
pub const OnEvent = terms_mod.OnEvent;
pub const EmitOptions = @import("events.zig").EmitOptions;

// bundle items
const bundle_mod = @import("bundle.zig");
pub const isA = bundle_mod.isA;
pub const autoOverride = bundle_mod.autoOverride;
pub const childOf = bundle_mod.childOf;
pub const pair = bundle_mod.pair;

/// A reusable spawn bundle - just a tuple of items. Name one and pass it to
/// `world.spawn`; extend with `++`. (Sugar; any tuple is already a bundle.)
pub fn bundle(comptime items: anytype) @TypeOf(items) {
    return items;
}

// builtin relationships (resolve to flecs' EcsChildOf / EcsIsA, not new components)
pub const ChildOf = struct {
    pub const flecs_builtin = .child_of;
};
pub const IsA = struct {
    pub const flecs_builtin = .is_a;
};

// ---- runtime configuration ----
const runtime_mod = @import("runtime.zig");
pub const RuntimeOptions = runtime_mod.Options;
pub const Threading = runtime_mod.Threading;
/// Configure the process-wide flecs runtime (e.g. inject a Zig allocator).
/// Call once at startup, before any other flecs call.
pub const runtime = runtime_mod.configure;

pub const Expr = query_mod.Expr;

// ---- addons ----
const addons_mod = @import("addons.zig");
pub const Severity = addons_mod.Severity;
pub const AlertOptions = addons_mod.AlertOptions;
pub const MetricKind = addons_mod.MetricKind;
pub const RunOptions = addons_mod.RunOptions;
pub const Doc = entity_mod.Entity.Doc;

// Re-export raw component id lookup for advanced use.
pub const componentId = meta_mod.id;

test {
    _ = @import("tests.zig");
}
