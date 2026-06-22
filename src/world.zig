//! The world: the entry point. Thin translation layer over `ecs_world_t` that
//! ties together entities, components, queries, systems and observers.

const std = @import("std");
const c = @import("c");
const meta = @import("meta.zig");
const Entity = @import("entity.zig").Entity;
const Table = @import("entity.zig").Table;
const query_mod = @import("query.zig");
const sys = @import("system.zig");
const reflect_mod = @import("reflect.zig");
const addons = @import("addons.zig");
const events = @import("events.zig");
const bundle = @import("bundle.zig");
const runtime = @import("runtime.zig");

pub const Phase = enum {
    on_load,
    post_load,
    pre_update,
    on_update,
    on_validate,
    post_update,
    pre_store,
    on_store,

    fn id(self: Phase) meta.Id {
        return switch (self) {
            .on_load => c.EcsOnLoad,
            .post_load => c.EcsPostLoad,
            .pre_update => c.EcsPreUpdate,
            .on_update => c.EcsOnUpdate,
            .on_validate => c.EcsOnValidate,
            .post_update => c.EcsPostUpdate,
            .pre_store => c.EcsPreStore,
            .on_store => c.EcsOnStore,
        };
    }
};

pub const InitOptions = struct {
    /// Persistent worker threads for the pipeline. 0 = single-threaded.
    threads: i32 = 0,
    /// One-shot task threads per sync point. Routes through a `std.Io` executor
    /// when one is installed via `flecs.runtime(.{ .io })`. Mutually exclusive
    /// with `threads`.
    task_threads: i32 = 0,
};

pub const EntityOptions = struct {
    name: ?[*:0]const u8 = null,
    parent: ?Entity = null,
};

pub const EmitOptions = events.EmitOptions;

pub const RestOptions = struct {
    port: u16 = 27750,
};

/// Build a world type. `cfg` may carry:
///   .ext = .{ ExtA, ExtB }   - extension modules grafted onto the world
///   .use = .{ @This() }      - namespaces for typed-query name resolution
///
/// `flecs.World(.{})` is the zero-config common case. An extension is a module
/// exposing `pub const Options`, `pub fn init(world, opts)` and
/// `pub fn Api(comptime World) type` (the grafted namespace, reached via
/// `world.ext(Ext)`).
pub fn World(comptime world_cfg: anytype) type {
    const Cfg = @TypeOf(world_cfg);
    const ext_list = if (@hasField(Cfg, "ext")) world_cfg.ext else .{};
    const exts = comptime ext_fields(ext_list);

    return struct {
        raw: *c.ecs_world_t,

        const Self = @This();
        pub const config = world_cfg;

        pub fn init(opts: InitOptions) !Self {
            const w = c.ecs_init() orelse return error.WorldInitFailed;
            if (opts.threads > 0) c.ecs_set_threads(w, opts.threads);
            if (opts.task_threads > 0) c.ecs_set_task_threads(w, opts.task_threads);
            var self = Self{ .raw = w };
            // Auto-import extensions with default options.
            inline for (exts) |E| {
                try E.init(&self, defaultOptions(E));
            }
            return self;
        }

        /// Like `init`, but supplies per-extension options as a positional tuple
        /// aligned to the `.ext` list (missing entries use defaults).
        pub fn initExt(opts: InitOptions, ext_opts: anytype) !Self {
            const w = c.ecs_init() orelse return error.WorldInitFailed;
            if (opts.threads > 0) c.ecs_set_threads(w, opts.threads);
            if (opts.task_threads > 0) c.ecs_set_task_threads(w, opts.task_threads);
            var self = Self{ .raw = w };
            const n_opts = std.meta.fields(@TypeOf(ext_opts)).len;
            inline for (exts, 0..) |E, i| {
                var opt: E.Options = defaultOptions(E);
                if (comptime i < n_opts) opt = ext_opts[i];
                try E.init(&self, opt);
            }
            return self;
        }

        /// The grafted namespace for extension `E`, bound to this world.
        pub fn ext(self: *Self, comptime E: type) E.Api(Self) {
            return .{ .world = self };
        }

        pub fn deinit(self: *Self) void {
            _ = c.ecs_fini(self.raw);
        }

        /// Advance the world one frame. Returns false after `quit`.
        pub fn progress(self: *Self, delta_time: f32) bool {
            return c.ecs_progress(self.raw, delta_time);
        }

        pub fn quit(self: *Self) void {
            c.ecs_quit(self.raw);
        }

        /// Set the number of worker threads for multithreaded systems/pipelines.
        pub fn setThreads(self: *Self, n: i32) void {
            c.ecs_set_threads(self.raw, n);
        }

        // ---- entities ----

        pub fn new(self: *Self) Entity {
            return Entity.init(self.raw, c.ecs_new(self.raw));
        }

        /// Create or look up a (optionally named, optionally parented) entity.
        pub fn entity(self: *Self, opts: EntityOptions) Entity {
            var edesc = std.mem.zeroes(c.ecs_entity_desc_t);
            edesc.name = opts.name;
            if (opts.parent) |p| edesc.parent = p.id;
            return Entity.init(self.raw, c.ecs_entity_init(self.raw, &edesc));
        }

        /// Spawn an entity with a bundle of items. Each tuple element is a component
        /// *value* (`Position{...}`), a tag *type* (`Active`), `flecs.isA(base)`, or
        /// `flecs.autoOverride(T)`.
        pub fn spawn(self: *Self, items: anytype) Entity {
            const e = self.new();
            applyBundle(self.raw, e, items);
            return e;
        }

        /// Create a prefab. Accepts `.name`, `.with` (a bundle), and `.children`
        /// (a tuple of `.{ .name, .slot, .with, .children }` descriptors).
        pub fn prefab(self: *Self, desc: anytype) Entity {
            var edesc = std.mem.zeroes(c.ecs_entity_desc_t);
            if (@hasField(@TypeOf(desc), "name")) edesc.name = @field(desc, "name");
            const p = Entity.init(self.raw, c.ecs_entity_init(self.raw, &edesc));
            c.ecs_add_id(self.raw, p.id, c.EcsPrefab);
            if (@hasField(@TypeOf(desc), "with")) applyBundle(self.raw, p, @field(desc, "with"));
            if (@hasField(@TypeOf(desc), "children")) {
                inline for (std.meta.fields(@TypeOf(@field(desc, "children")))) |cf| {
                    self.prefabChild(p, @field(@field(desc, "children"), cf.name));
                }
            }
            return p;
        }

        fn prefabChild(self: *Self, parent: Entity, cdesc: anytype) void {
            var edesc = std.mem.zeroes(c.ecs_entity_desc_t);
            if (@hasField(@TypeOf(cdesc), "name")) edesc.name = @field(cdesc, "name");
            edesc.parent = parent.id;
            const child = Entity.init(self.raw, c.ecs_entity_init(self.raw, &edesc));
            c.ecs_add_id(self.raw, child.id, c.EcsPrefab);
            if (@hasField(@TypeOf(cdesc), "slot") and @field(cdesc, "slot")) {
                c.ecs_add_id(self.raw, child.id, c.ecs_make_pair(c.EcsSlotOf, parent.id));
            }
            if (@hasField(@TypeOf(cdesc), "with")) applyBundle(self.raw, child, @field(cdesc, "with"));
            if (@hasField(@TypeOf(cdesc), "children")) {
                inline for (std.meta.fields(@TypeOf(@field(cdesc, "children")))) |cf| {
                    self.prefabChild(child, @field(@field(cdesc, "children"), cf.name));
                }
            }
        }

        /// Bulk-create `n` entities in one table op. Each field of `spec` is either:
        ///   - a slice `[]T` / `[]const T` (per-entity data, must be length `n`)
        ///   - a value `T`                 (broadcast the same value to all `n`)
        ///   - a type `T`                  (tag / zeroed component)
        /// Returns the flecs-owned id array (valid until the next structural change;
        /// copy it if you need to keep it).
        pub fn spawnMany(self: *Self, n: i32, spec: anytype) []const meta.Id {
            const fields = std.meta.fields(@TypeOf(spec));
            var desc = std.mem.zeroes(c.ecs_bulk_desc_t);
            // `desc.ids`/`desc.data` are fixed-size (FLECS_ID_DESC_MAX); reject
            // an over-long spec at compile time rather than overflowing silently.
            if (fields.len > @typeInfo(@TypeOf(desc.ids)).array.len)
                @compileError("spawnMany: too many components in spec (max " ++ std.fmt.comptimePrint("{d}", .{@typeInfo(@TypeOf(desc.ids)).array.len}) ++ ")");
            desc.count = n;

            // Broadcast buffers live only for the duration of the bulk op.
            var arena = std.heap.ArenaAllocator.init(runtime.mem());
            defer arena.deinit();
            const a = arena.allocator();

            // desc.data is a caller-provided array of per-id data pointers.
            var data: [fields.len]?*anyopaque = .{null} ** fields.len;

            inline for (fields, 0..) |f, i| {
                const elem = @field(spec, f.name);
                const ET = @TypeOf(elem);
                if (ET == type) {
                    desc.ids[i] = meta.id(self.raw, elem);
                    data[i] = null;
                } else if (@typeInfo(ET) == .pointer and @typeInfo(ET).pointer.size == .slice) {
                    const Comp = @typeInfo(ET).pointer.child;
                    desc.ids[i] = meta.id(self.raw, Comp);
                    data[i] = @ptrCast(@constCast(elem.ptr));
                } else {
                    // Broadcast a single value into an n-length buffer.
                    const col = a.alloc(ET, @intCast(n)) catch @panic("OOM");
                    for (col) |*slot| slot.* = elem;
                    desc.ids[i] = meta.id(self.raw, ET);
                    data[i] = @ptrCast(col.ptr);
                }
            }
            desc.data = &data;

            const ids = c.ecs_bulk_init(self.raw, &desc);
            if (ids == null) return &.{};
            return ids[0..@intCast(n)];
        }

        /// Restrict automatically-generated entity ids to `[min, max)` (max = 0 for
        /// no upper bound). Useful to reserve id ranges (e.g. for networking).
        pub fn setEntityRange(self: *Self, min: meta.Id, max: meta.Id) void {
            c.ecs_set_entity_range(self.raw, min, max);
        }

        /// Number of live entities with component `T`.
        pub fn count(self: *Self, comptime T: type) i32 {
            return c.ecs_count_id(self.raw, meta.id(self.raw, T));
        }

        /// Delete every entity that has component `T`.
        pub fn deleteWith(self: *Self, comptime T: type) void {
            c.ecs_delete_with(self.raw, meta.id(self.raw, T));
        }

        /// Remove component `T` from every entity that has it.
        pub fn removeAll(self: *Self, comptime T: type) void {
            c.ecs_remove_all(self.raw, meta.id(self.raw, T));
        }

        /// World timing/frame info (delta_time, frame count, target_fps, …).
        pub fn info(self: *Self) *const c.ecs_world_info_t {
            return c.ecs_get_world_info(self.raw);
        }

        pub fn setTargetFps(self: *Self, fps: f32) void {
            c.ecs_set_target_fps(self.raw, fps);
        }

        /// Scale `delta_time` seen by systems (0.5 = slow-mo, 2 = fast-forward,
        /// 0 = pause). Affects `progress`-driven timing, not the raw delta.
        pub fn setTimeScale(self: *Self, scale: f32) void {
            c.ecs_set_time_scale(self.raw, scale);
        }

        /// Reset the world clock (`world_time_total`) back to zero.
        pub fn resetClock(self: *Self) void {
            c.ecs_reset_clock(self.raw);
        }

        /// Preallocate space for `entity_count` entities (a sizing hint that
        /// avoids reallocations when you know roughly how many you'll create).
        pub fn dim(self: *Self, entity_count: i32) void {
            c.ecs_dim(self.raw, entity_count);
        }

        /// Toggle per-frame timing measurement (fills `info().frame_time_total`
        /// etc.). On by default when a target FPS is set.
        pub fn measureFrameTime(self: *Self, enable: bool) void {
            c.ecs_measure_frame_time(self.raw, enable);
        }

        /// Toggle per-system timing measurement (adds overhead; for profiling).
        pub fn measureSystemTime(self: *Self, enable: bool) void {
            c.ecs_measure_system_time(self.raw, enable);
        }

        // ---- entity liveness / generations (manual id management, networking) ----

        /// Whether `id` was ever issued in this world (alive or recycled).
        pub fn exists(self: *Self, id: meta.Id) bool {
            return c.ecs_exists(self.raw, id);
        }

        /// Ensure a specific entity id is alive (e.g. to mirror a server's id on a
        /// client). With a generation in the id, bumps the entity to that version.
        pub fn makeAlive(self: *Self, id: meta.Id) Entity {
            c.ecs_make_alive(self.raw, id);
            return Entity.init(self.raw, id);
        }

        /// The live version of `id` (with its current generation), or null if the
        /// id is not alive in any generation.
        pub fn getAlive(self: *Self, id: meta.Id) ?Entity {
            const e = c.ecs_get_alive(self.raw, id);
            if (e == 0) return null;
            return Entity.init(self.raw, e);
        }

        /// Snapshot of all entity ids in the world (alive and recycled). The
        /// slice is flecs-owned and valid until the next structural change.
        pub fn entities(self: *Self) []const meta.Id {
            const es = c.ecs_get_entities(self.raw);
            if (es.ids == null) return &.{};
            return es.ids[0..@intCast(es.count)];
        }

        // ---- advanced world configuration ----

        /// Auto-add `T` to every entity created until the returned scope is
        /// restored: `const prev = world.setWith(Npc); defer _ = world.setWithId(prev);`
        pub fn setWith(self: *Self, comptime T: type) meta.Id {
            return c.ecs_set_with(self.raw, meta.id(self.raw, T));
        }
        /// Restore a previous `setWith` id (0 clears it).
        pub fn setWithId(self: *Self, id: meta.Id) meta.Id {
            return c.ecs_set_with(self.raw, id);
        }
        /// The id currently auto-added by `setWith` (0 if none).
        pub fn getWith(self: *Self) meta.Id {
            return c.ecs_get_with(self.raw);
        }

        /// Attach an opaque user context to the world (retrieve with `getCtx`).
        /// Prefer a singleton for typed data; this matches flecs' raw `void*` slot.
        pub fn setCtx(self: *Self, ptr: ?*anyopaque) void {
            c.ecs_set_ctx(self.raw, ptr, null);
        }
        pub fn getCtx(self: *Self) ?*anyopaque {
            return c.ecs_get_ctx(self.raw);
        }

        /// Set the prefix stripped from component type names during lookups (e.g.
        /// `"Ecs"`); returns the previous prefix.
        pub fn setNamePrefix(self: *Self, prefix: ?[*:0]const u8) ?[*:0]const u8 {
            return c.ecs_set_name_prefix(self.raw, prefix);
        }
        /// Set the parent-scope search path for unqualified lookups (a 0-terminated
        /// id array); returns the previous path.
        pub fn setLookupPath(self: *Self, path: ?[*:0]const meta.Id) ?[*]meta.Id {
            return c.ecs_set_lookup_path(self.raw, path);
        }
        pub fn getLookupPath(self: *Self) ?[*]meta.Id {
            return c.ecs_get_lookup_path(self.raw);
        }

        /// Run a specific pipeline once (instead of the default via `progress`).
        pub fn runPipeline(self: *Self, p: Entity, delta_time: f32) void {
            c.ecs_run_pipeline(self.raw, p.id, delta_time);
        }

        /// Whether this world spins up task threads per sync point (vs persistent
        /// worker threads).
        pub fn usingTaskThreads(self: *Self) bool {
            return c.ecs_using_task_threads(self.raw);
        }

        /// Return unused reserved memory to the OS.
        pub fn shrink(self: *Self) void {
            c.ecs_shrink(self.raw);
        }

        pub const DeleteEmptyTablesOptions = struct {
            /// Free a table's data once it has been empty for this many calls.
            clear_generation: u16 = 0,
            /// Delete a table once it has been empty for this many calls.
            delete_generation: u16 = 0,
            /// Cap on time spent (seconds); 0 = no limit.
            time_budget_seconds: f64 = 0,
        };
        /// Reclaim memory from long-empty tables. Returns the number cleared.
        pub fn deleteEmptyTables(self: *Self, opts: DeleteEmptyTablesOptions) i32 {
            var desc = std.mem.zeroes(c.ecs_delete_empty_tables_desc_t);
            desc.clear_generation = opts.clear_generation;
            desc.delete_generation = opts.delete_generation;
            desc.time_budget_seconds = opts.time_budget_seconds;
            return c.ecs_delete_empty_tables(self.raw, &desc);
        }

        // ---- tables & dynamic values (low-level) ----

        /// Find the table (archetype) whose exact id set is `ids`, or null if no
        /// such table exists yet. The `Entity.table` handle exposes its storage.
        pub fn tableFind(self: *Self, ids: []const meta.Id) ?Table {
            const t = c.ecs_table_find(self.raw, ids.ptr, @intCast(ids.len));
            if (t == null) return null;
            return .{ .world = self.raw, .raw = t.? };
        }

        /// Create an entity directly in `table` (skips the per-component add path).
        pub fn spawnInTable(self: *Self, table: Table) Entity {
            return Entity.init(self.raw, c.ecs_new_w_table(self.raw, table.raw));
        }

        /// Run `T`'s registered constructor on raw storage at `ptr` (the dynamic
        /// counterpart of letting flecs add a component). Pair with `valueFini`.
        pub fn valueInit(self: *Self, comptime T: type, ptr: *T) void {
            _ = c.ecs_value_init(self.raw, meta.id(self.raw, T), ptr);
        }
        /// Run `T`'s destructor on the value at `ptr`.
        pub fn valueFini(self: *Self, comptime T: type, ptr: *T) void {
            _ = c.ecs_value_fini(self.raw, meta.id(self.raw, T), ptr);
        }
        /// Copy a `T` value using its registered copy hook.
        pub fn valueCopy(self: *Self, comptime T: type, dst: *T, src: *const T) void {
            _ = c.ecs_value_copy(self.raw, meta.id(self.raw, T), dst, src);
        }
        /// Move a `T` value using its registered move hook.
        pub fn valueMove(self: *Self, comptime T: type, dst: *T, src: *T) void {
            _ = c.ecs_value_move(self.raw, meta.id(self.raw, T), dst, src);
        }

        /// Create a shared timer (tick source) that ticks every `interval` seconds.
        /// Assign it to one or more systems with `setTickSource` so they share a rate
        /// (nested tick sources: pass a timer as the source of `setRate`).
        pub fn timer(self: *Self, interval: f32) Entity {
            return Entity.init(self.raw, c.ecs_set_interval(self.raw, 0, interval));
        }

        /// Drive a system from a shared tick source (timer or another system).
        pub fn setTickSource(self: *Self, the_system: Entity, source: Entity) void {
            c.ecs_set_tick_source(self.raw, the_system.id, source.id);
        }

        /// Create a rate filter (ticks every `rate` ticks of `source`) - used for
        /// nested tick sources.
        pub fn rateFilter(self: *Self, rate: i32, source: Entity) Entity {
            return Entity.init(self.raw, c.ecs_set_rate(self.raw, 0, rate, source.id));
        }

        /// Unregister a component, deleting its component entity.
        pub fn unregister(self: *Self, comptime T: type) void {
            c.ecs_delete(self.raw, meta.id(self.raw, T));
        }

        /// Set the default parent scope for newly-created entities; returns the
        /// previous scope. Pair with a `defer world.setScope(prev)`.
        pub fn setScope(self: *Self, scope: Entity) Entity {
            return Entity.init(self.raw, c.ecs_set_scope(self.raw, scope.id));
        }
        /// The current default parent scope (0-entity if none).
        pub fn getScope(self: *Self) Entity {
            return Entity.init(self.raw, c.ecs_get_scope(self.raw));
        }

        /// Run a single system on demand (outside the pipeline), once over its
        /// matched entities. `delta_time` is what the system sees.
        pub fn runSystem(self: *Self, the_system: Entity, delta_time: f32) void {
            _ = c.ecs_run(self.raw, the_system.id, delta_time, null);
        }

        pub fn deferBegin(self: *Self) bool {
            return c.ecs_defer_begin(self.raw);
        }
        pub fn deferEnd(self: *Self) bool {
            return c.ecs_defer_end(self.raw);
        }

        // ---- staging (manual multithreading) ----
        //
        // A stage is a queue of structural changes that can be filled from a
        // worker thread, then merged into the world. Bracket parallel work with
        // `readonlyBegin`/`readonlyEnd`, give each thread its own `stage(i)`
        // (itself a world handle), and flecs merges the commands at the end.

        /// Allocate `n` stages for `n`-way parallel command recording.
        pub fn setStageCount(self: *Self, n: i32) void {
            c.ecs_set_stage_count(self.raw, n);
        }
        pub fn stageCount(self: *Self) i32 {
            return c.ecs_get_stage_count(self.raw);
        }
        /// The `i`-th stage as a world handle. Use it from worker thread `i`;
        /// structural changes are queued and merged at `readonlyEnd`.
        pub fn stage(self: *Self, i: i32) Self {
            return .{ .raw = c.ecs_get_stage(self.raw, i).? };
        }
        /// Enter readonly mode: stages accept deferred commands; the main store
        /// is immutable until `readonlyEnd`. Pass `multi_threaded = true` only
        /// when worker threads will each drive a `stage(i)` concurrently.
        /// Returns false if already readonly.
        pub fn readonlyBegin(self: *Self, multi_threaded: bool) bool {
            return c.ecs_readonly_begin(self.raw, multi_threaded);
        }
        /// Leave readonly mode, merging every stage's queued commands.
        pub fn readonlyEnd(self: *Self) void {
            c.ecs_readonly_end(self.raw);
        }
        /// Explicitly merge staged commands into the world.
        pub fn merge(self: *Self) void {
            c.ecs_merge(self.raw);
        }

        /// Create an unmanaged (async) stage: a standalone command queue you can
        /// fill from any thread outside a frame, then `merge`. Free with
        /// `freeStage`. Independent of `setStageCount`'s frame stages.
        pub fn asyncStage(self: *Self) Self {
            return .{ .raw = c.ecs_stage_new(self.raw).? };
        }
        pub fn freeStage(self: *Self, s: Self) void {
            _ = self;
            c.ecs_stage_free(s.raw);
        }
        /// This stage's index (0 for the main stage / world).
        pub fn stageId(self: *Self) i32 {
            return c.ecs_stage_get_id(self.raw);
        }

        /// Temporarily stop deferring commands inside a deferred region (e.g. to
        /// run an operation immediately); pair with `deferResume`.
        pub fn deferSuspend(self: *Self) void {
            c.ecs_defer_suspend(self.raw);
        }
        pub fn deferResume(self: *Self) void {
            c.ecs_defer_resume(self.raw);
        }

        /// Assert that only the calling thread may touch the world until
        /// `exclusiveAccessEnd` - a debugging aid that catches stray cross-thread
        /// access. `name` labels the owning thread in error messages.
        pub fn exclusiveAccessBegin(self: *Self, name: ?[*:0]const u8) void {
            c.ecs_exclusive_access_begin(self.raw, name);
        }
        /// Release exclusive access. `lock_world = true` then forbids *all*
        /// mutations until the next `exclusiveAccessBegin`.
        pub fn exclusiveAccessEnd(self: *Self, lock_world: bool) void {
            c.ecs_exclusive_access_end(self.raw, lock_world);
        }

        // ---- pair (id) decoding ----

        pub fn isPair(self: *Self, id: meta.Id) bool {
            _ = self;
            return c.ecs_id_is_pair(id);
        }
        /// The relationship (first element) of a pair id, as an entity.
        pub fn pairFirst(self: *Self, id: meta.Id) Entity {
            return Entity.init(self.raw, c.ecs_pair_first(self.raw, id));
        }
        /// The target (second element) of a pair id, as an entity.
        pub fn pairSecond(self: *Self, id: meta.Id) Entity {
            return Entity.init(self.raw, c.ecs_pair_second(self.raw, id));
        }

        /// The component/type entity that backs an id (for a pair, the data
        /// type), or null if the id carries no data.
        pub fn typeId(self: *Self, id: meta.Id) ?Entity {
            const t = c.ecs_get_typeid(self.raw, id);
            if (t == 0) return null;
            return Entity.init(self.raw, t);
        }

        /// Human-readable string for an id (e.g. `"(ChildOf,Player)"`), as an
        /// `allocator`-owned slice. Handy for logging/debugging.
        pub fn idStr(self: *Self, id: meta.Id, allocator: std.mem.Allocator) ![]u8 {
            const s = c.ecs_id_str(self.raw, id);
            if (s == null) return error.Failed;
            defer meta.osFree(@ptrCast(s));
            return allocator.dupe(u8, std.mem.span(s));
        }

        // ---- custom pipelines ----

        /// Create a custom pipeline from a system-selection query expression (e.g.
        /// `"flecs.system.System, ?flecs.pipeline.Phase(cascade(DependsOn))"`).
        pub fn pipeline(self: *Self, expr: [*:0]const u8) Entity {
            var desc = std.mem.zeroes(c.ecs_pipeline_desc_t);
            var edesc = std.mem.zeroes(c.ecs_entity_desc_t);
            desc.entity = c.ecs_entity_init(self.raw, &edesc);
            desc.query.expr = expr;
            return Entity.init(self.raw, c.ecs_pipeline_init(self.raw, &desc));
        }

        pub fn setPipeline(self: *Self, p: Entity) void {
            c.ecs_set_pipeline(self.raw, p.id);
        }
        /// The pipeline currently driven by `progress` (0-entity if unset).
        pub fn getPipeline(self: *Self) Entity {
            return Entity.init(self.raw, c.ecs_get_pipeline(self.raw));
        }

        // ---- meta extras ----

        pub const MemberRange = struct { min: f64, max: f64 };

        /// Set the valid value range for a reflected struct member (Explorer hint /
        /// alerts). Requires `world.reflect(T)` first.
        pub fn setMemberRange(self: *Self, comptime T: type, field: [*:0]const u8, range: MemberRange) void {
            const member = c.ecs_lookup_child(self.raw, meta.id(self.raw, T), field);
            if (member == 0) return;
            var mr = std.mem.zeroes(c.EcsMemberRanges);
            mr.value.min = range.min;
            mr.value.max = range.max;
            const rid = c.FLECS_IDEcsMemberRangesID_;
            _ = c.ecs_set_id(self.raw, member, rid, @sizeOf(c.EcsMemberRanges), &mr);
        }

        /// Annotate a reflected struct member with a unit entity, e.g.
        /// `world.setMemberUnit(Velocity, "x", flecs.units.MetersPerSecond())`.
        /// (Prefer declaring `pub const flecs_units` on the type.)
        pub fn setMemberUnit(self: *Self, comptime T: type, field: [*:0]const u8, unit: meta.Id) void {
            addons.importUnits(self.raw);
            const member = c.ecs_lookup_child(self.raw, meta.id(self.raw, T), field);
            if (member == 0 or unit == 0) return;
            const mid = c.FLECS_IDEcsMemberID_;
            const m: *c.EcsMember = @ptrCast(@alignCast(c.ecs_ensure_id(self.raw, member, mid, @sizeOf(c.EcsMember))));
            m.unit = unit;
            c.ecs_modified_id(self.raw, member, mid);
        }

        /// Register a flecs vector meta type whose element is component `T`. (Pair
        /// with the `flecsRegisterOpaque` protocol to map a Zig container onto it.)
        pub fn vectorOf(self: *Self, comptime T: type) meta.Id {
            var desc = std.mem.zeroes(c.ecs_vector_desc_t);
            desc.type = meta.id(self.raw, T);
            return c.ecs_vector_init(self.raw, &desc);
        }

        pub fn lookup(self: *Self, path: [*:0]const u8) ?Entity {
            const id = c.ecs_lookup(self.raw, path);
            if (id == 0) return null;
            return Entity.init(self.raw, id);
        }

        // ---- component configuration ----

        /// Explicitly register/configure a component with traits. Optional - a
        /// component is lazily registered on first use - but required when you need
        /// non-default storage, cleanup policy, etc. Call before creating instances.
        pub fn component(self: *Self, comptime T: type, comptime cfg: meta.Config) meta.Id {
            return meta.configure(self.raw, T, cfg);
        }

        // ---- singletons ----

        pub fn set(self: *Self, value: anytype) void {
            const T = @TypeOf(value);
            const cid = meta.id(self.raw, T);
            if (meta.isTag(T)) {
                c.ecs_add_id(self.raw, cid, cid);
            } else {
                var v = value;
                _ = c.ecs_set_id(self.raw, cid, cid, @sizeOf(T), &v);
            }
        }

        pub fn get(self: *Self, comptime T: type) ?*const T {
            const cid = meta.id(self.raw, T);
            const ptr = c.ecs_get_id(self.raw, cid, cid);
            if (ptr == null) return null;
            return @ptrCast(@alignCast(ptr));
        }

        /// Mutable pointer to singleton `T`, adding it (zeroed) if missing - the
        /// singleton counterpart of `entity.ensure`. Follow with `modified(T)` if
        /// observers should fire.
        pub fn ensure(self: *Self, comptime T: type) *T {
            const cid = meta.id(self.raw, T);
            return @ptrCast(@alignCast(c.ecs_ensure_id(self.raw, cid, cid, @sizeOf(T))));
        }

        /// Signal that singleton `T` changed (for observers), after mutating via
        /// `ensure`.
        pub fn modified(self: *Self, comptime T: type) void {
            const cid = meta.id(self.raw, T);
            c.ecs_modified_id(self.raw, cid, cid);
        }

        /// Remove singleton `T`.
        pub fn remove(self: *Self, comptime T: type) void {
            const cid = meta.id(self.raw, T);
            c.ecs_remove_id(self.raw, cid, cid);
        }

        // ---- queries ----

        /// Create a typed query. `spec` is a struct/tuple *type* (named or
        /// positional rows; `pub const sort`/`group`/`cache` decls configure it), or
        /// a tuple *value* of term types for a quick positional query.
        pub fn query(self: *Self, comptime spec: anytype) !query_mod.Query(query_mod.RowOf(spec)) {
            return query_mod.Query(query_mod.RowOf(spec)).init(self.raw);
        }

        /// Untyped query from a flecs query-DSL string (escape hatch for
        /// runtime-built and member-value queries).
        pub fn queryExpr(self: *Self, expr: [*:0]const u8) !query_mod.Expr {
            return query_mod.Expr.init(self.raw, expr);
        }

        /// The flecs name used for component `T` in DSL/JSON (a flat identifier).
        pub fn componentName(self: *Self, comptime T: type) [:0]const u8 {
            const id = meta.id(self.raw, T);
            return std.mem.span(c.ecs_get_name(self.raw, id));
        }

        // ---- systems & observers ----

        pub fn system(self: *Self, in_phase: Phase, comptime func: anytype) Entity {
            return Entity.init(self.raw, sys.system(self.raw, in_phase.id(), func, .{}, void));
        }

        /// Register an each-system with options (interval/rate timers). Returns the
        /// system entity, so you can `sys.enable(false)` to disable it.
        pub fn systemOpts(self: *Self, in_phase: Phase, comptime func: anytype, opts: sys.SystemOptions) Entity {
            return Entity.init(self.raw, sys.system(self.raw, in_phase.id(), func, opts, void));
        }

        /// Register an ECS construct described as a struct. Pass the *type* for a
        /// stateless system/observer, or an *instance* for a stateful one (its
        /// fields persist and are passed as the `*Self` first parameter of `each`):
        ///
        ///   world.add(Movement);              // stateless: pub fn each(pos, vel)
        ///   world.add(Spawner{ .rate = 2 });  // stateful:  pub fn each(self, dt, ...)
        ///
        /// Config lives as `pub const` decls - `phase`, `interval`, `rate`,
        /// `multi_threaded`, `immediate`, `sort`, `group`; an event marker in the
        /// signature makes it an observer.
        pub fn add(self: *Self, arg: anytype) Entity {
            const stateful = @TypeOf(arg) != type;
            const S = if (stateful) @TypeOf(arg) else arg;
            const func = if (@hasDecl(S, "each")) S.each else if (@hasDecl(S, "run")) S.run else if (@hasDecl(S, "on")) S.on else @compileError("struct system needs a pub fn each/run/on");

            if (!stateful and (comptime sys.isObserverFn(@TypeOf(func)) or @hasDecl(S, "monitor"))) {
                var oopts: sys.ObserverOptions = .{};
                if (@hasDecl(S, "yield_existing")) oopts.yield_existing = S.yield_existing;
                if (@hasDecl(S, "monitor")) oopts.monitor = S.monitor;
                return Entity.init(self.raw, sys.observer(self.raw, func, oopts));
            }

            const in_phase: Phase = if (@hasDecl(S, "phase")) S.phase else .on_update;
            var opts: sys.SystemOptions = .{};
            if (@hasDecl(S, "interval")) opts.interval = S.interval;
            if (@hasDecl(S, "rate")) opts.rate = S.rate;
            if (@hasDecl(S, "multi_threaded")) opts.multi_threaded = S.multi_threaded;
            if (@hasDecl(S, "immediate")) opts.immediate = S.immediate;

            if (stateful) {
                if (@hasDecl(S, "multi_threaded") and S.multi_threaded) @compileError("stateful system '" ++ @typeName(S) ++ "' cannot be multi_threaded (its instance is shared across threads)");
                return Entity.init(self.raw, sys.statefulSystem(self.raw, in_phase.id(), func, arg, opts, S));
            }
            return Entity.init(self.raw, sys.system(self.raw, in_phase.id(), func, opts, S));
        }

        /// Register many each-systems in the same phase.
        pub fn systems(self: *Self, in_phase: Phase, funcs: anytype) void {
            inline for (std.meta.fields(@TypeOf(funcs))) |f| {
                _ = self.system(in_phase, @field(funcs, f.name));
            }
        }

        pub fn observe(self: *Self, comptime func: anytype) Entity {
            return Entity.init(self.raw, sys.observer(self.raw, func, .{}));
        }

        /// Register an observer with options (yield_existing, monitor).
        pub fn observeOpts(self: *Self, comptime func: anytype, opts: sys.ObserverOptions) Entity {
            return Entity.init(self.raw, sys.observer(self.raw, func, opts));
        }

        // ---- events ----

        /// Emit a custom event with a payload, targeting an entity. Observers
        /// registered with `OnEvent(@TypeOf(value))` fire immediately.
        pub fn emit(self: *Self, value: anytype, opts: EmitOptions) void {
            events.emit(self.raw, value, opts, false);
        }

        // ---- custom pipeline phases ----

        /// Create a custom pipeline phase that runs after a builtin phase.
        pub fn phase(self: *Self, after: Phase) Entity {
            return self.makePhase(after.id());
        }

        /// Create a custom phase that runs after another (custom or builtin) phase.
        pub fn phaseAfter(self: *Self, after: Entity) Entity {
            return self.makePhase(after.id);
        }

        fn makePhase(self: *Self, after_id: meta.Id) Entity {
            const p = c.ecs_new(self.raw);
            c.ecs_add_id(self.raw, p, c.EcsPhase);
            c.ecs_add_id(self.raw, p, c.ecs_make_pair(c.EcsDependsOn, after_id));
            return Entity.init(self.raw, p);
        }

        /// Register an each-/run-system in a custom phase.
        pub fn systemIn(self: *Self, the_phase: Entity, comptime func: anytype) Entity {
            return Entity.init(self.raw, sys.system(self.raw, the_phase.id, func, .{}, void));
        }

        pub fn systemsIn(self: *Self, the_phase: Entity, funcs: anytype) void {
            inline for (std.meta.fields(@TypeOf(funcs))) |f| {
                _ = self.systemIn(the_phase, @field(funcs, f.name));
            }
        }

        // ---- remote API / explorer / stats ----

        /// Enable the REST API (and thus the web Explorer at https://flecs.dev/explorer).
        pub fn enableRest(self: *Self, opts: RestOptions) void {
            var r = std.mem.zeroes(c.EcsRest);
            r.port = opts.port;
            const rid = c.FLECS_IDEcsRestID_;
            _ = c.ecs_set_id(self.raw, rid, rid, @sizeOf(c.EcsRest), &r);
        }

        /// Import the stats module (periodic world/system/query statistics for the
        /// Explorer).
        pub fn importStats(self: *Self) void {
            c.FlecsStatsImport(self.raw);
        }

        pub fn importUnits(self: *Self) void {
            addons.importUnits(self.raw);
        }

        /// Serialize the whole world to JSON. Caller owns the returned slice.
        pub fn worldToJson(self: *Self, allocator: std.mem.Allocator) ![]u8 {
            return addons.worldToJson(self.raw, allocator);
        }

        /// Register a flag-enum as a bitmask meta type.
        pub fn bitmask(self: *Self, comptime E: type) meta.Id {
            return addons.bitmask(self.raw, E);
        }

        /// Create an alert flagging entities that match a query DSL expression.
        pub fn alert(self: *Self, opts: addons.AlertOptions) Entity {
            return addons.alert(self.raw, opts);
        }

        /// Track a component member as a metric over time.
        pub fn metric(self: *Self, comptime T: type, member: [*:0]const u8, kind: addons.MetricKind) Entity {
            return addons.metric(self.raw, T, member, kind);
        }

        /// Run the managed application main loop (`ecs_app_run`).
        pub fn run(self: *Self, opts: addons.RunOptions) i32 {
            return addons.run(self.raw, opts);
        }

        // ---- reflection / serialization ----

        /// Register reflection metadata for `T` (derived from `@typeInfo`). Enables
        /// JSON, Explorer values, and Flecs Script construction for that component.
        pub fn reflect(self: *Self, comptime T: type) meta.Id {
            return reflect_mod.register(self.raw, T);
        }

        /// A runtime cursor that reads/writes the fields of a `T` value at `ptr`
        /// by name/index (see `flecs.MetaCursor`). Registers `T`'s reflection
        /// first. `ptr` must outlive the cursor.
        pub fn metaCursor(self: *Self, comptime T: type, ptr: *T) @import("meta_cursor.zig").MetaCursor {
            const cid = reflect_mod.register(self.raw, T);
            return .{ .world = self.raw, .cur = c.ecs_meta_cursor(self.raw, cid, ptr) };
        }

        /// Serialize a component value to JSON. Caller owns the returned slice
        /// (allocated with `allocator`).
        pub fn toJson(self: *Self, value: anytype, allocator: std.mem.Allocator) ![]u8 {
            const T = @TypeOf(value);
            var v = value;
            const owned = reflect_mod.ptrToJson(self.raw, T, &v) orelse return error.SerializeFailed;
            defer reflect_mod.freeJson(owned);
            return allocator.dupe(u8, owned);
        }

        /// Parse a JSON object into a component value of type `T`.
        pub fn fromJson(self: *Self, comptime T: type, json: [*:0]const u8) !T {
            var out: T = undefined;
            if (!reflect_mod.ptrFromJson(self.raw, T, &out, json)) return error.ParseFailed;
            return out;
        }

        /// Serialize a whole entity (reflected components show values). Caller owns
        /// the returned slice.
        pub fn entityToJson(self: *Self, e: Entity, allocator: std.mem.Allocator) ![]u8 {
            const s = c.ecs_entity_to_json(self.raw, e.id, null);
            if (s == null) return error.SerializeFailed;
            defer meta.osFree(@ptrCast(s));
            return allocator.dupe(u8, std.mem.span(s));
        }

        /// Populate an entity from a JSON object (as produced by `entityToJson`).
        pub fn entityFromJson(self: *Self, e: Entity, json: [*:0]const u8) void {
            _ = c.ecs_entity_from_json(self.raw, e.id, json, null);
        }

        /// Load a whole world from JSON (as produced by `worldToJson`) - save/load.
        pub fn worldFromJson(self: *Self, json: [*:0]const u8) !void {
            if (c.ecs_world_from_json(self.raw, json, null) == null) return error.ParseFailed;
        }

        // ---- manual frame control ----

        /// Begin a frame manually (alternative to `progress`); returns the delta.
        pub fn frameBegin(self: *Self, delta_time: f32) f32 {
            return c.ecs_frame_begin(self.raw, delta_time);
        }
        pub fn frameEnd(self: *Self) void {
            c.ecs_frame_end(self.raw);
        }

        // ---- flecs script ----

        /// Run a Flecs Script once (creates the entities/components it declares).
        /// Component names follow `world.componentName` (simple names by default).
        pub fn script(self: *Self, code: [*:0]const u8) !void {
            if (c.ecs_script_run(self.raw, "inline_script", code, null) != 0) return error.ScriptFailed;
        }

        /// Run a Flecs Script with outside variables bound from a Zig struct.
        /// Each field becomes a script variable `$name` of the field's type, so
        /// the script can interpolate values computed in Zig:
        ///
        ///   try world.scriptWith("Turret { Position: {$x, $y} }",
        ///       .{ .x = @as(f32, 10), .y = @as(f32, 20) });
        pub fn scriptWith(self: *Self, code: [*:0]const u8, vars: anytype) !void {
            const V = @TypeOf(vars);
            const sv = c.ecs_script_vars_init(self.raw);
            defer c.ecs_script_vars_fini(sv);

            inline for (std.meta.fields(V)) |f| {
                const v = c.ecs_script_vars_define_id(sv, f.name ++ "", reflect_mod.metaId(self.raw, f.type));
                if (v == null) return error.ScriptVarFailed;
                const slot: *f.type = @ptrCast(@alignCast(v.*.value.ptr.?));
                slot.* = @field(vars, f.name);
            }

            var desc = std.mem.zeroes(c.ecs_script_eval_desc_t);
            desc.vars = sv;
            var result = std.mem.zeroes(c.ecs_script_eval_result_t);
            const s = c.ecs_script_parse(self.raw, "inline_script", code, &desc, &result) orelse return error.ScriptFailed;
            defer c.ecs_script_free(s);
            if (c.ecs_script_eval(s, &desc, &result) != 0) return error.ScriptFailed;
        }

        /// Load a managed (named, reloadable) script entity. Update by re-running
        /// with the same name; delete the returned entity to remove its content.
        pub fn loadScript(self: *Self, name: [*:0]const u8, code: [*:0]const u8) !Entity {
            var desc = std.mem.zeroes(c.ecs_script_desc_t);
            desc.code = code;
            var edesc = std.mem.zeroes(c.ecs_entity_desc_t);
            edesc.name = name;
            desc.entity = c.ecs_entity_init(self.raw, &edesc);
            const e = c.ecs_script_init(self.raw, &desc);
            if (e == 0) return error.ScriptFailed;
            return Entity.init(self.raw, e);
        }

        // ---- modules ----

        /// Import a module (a Zig container). Scans `pub` component types for
        /// registration and calls `pub fn init(*World) !void` if present.
        pub fn import(self: *Self, comptime Module: type) !void {
            if (@hasDecl(Module, "init")) {
                try Module.init(self);
            }
        }
    };
}

/// Apply a bundle (tuple of items) to an entity.
fn applyBundle(world: *c.ecs_world_t, e: Entity, items: anytype) void {
    inline for (std.meta.fields(@TypeOf(items))) |f| {
        applyItem(world, e, @field(items, f.name));
    }
}

fn applyItem(world: *c.ecs_world_t, e: Entity, item: anytype) void {
    const T = @TypeOf(item);
    if (T == type) {
        // A bare type: either an autoOverride marker or a plain tag.
        if (comptime bundle.applyKind(item)) |k| {
            switch (k) {
                .auto_override => c.ecs_auto_override_id(world, e.id, meta.id(world, item.Comp)),
                else => @compileError("invalid bundle marker type"),
            }
        } else {
            e.add(item);
        }
    } else if (comptime bundle.applyKind(T)) |k| {
        switch (k) {
            .isa => c.ecs_add_id(world, e.id, c.ecs_make_pair(c.EcsIsA, item.target)),
            .child_of => c.ecs_add_id(world, e.id, c.ecs_make_pair(c.EcsChildOf, item.target)),
            .pair => c.ecs_add_id(world, e.id, c.ecs_make_pair(meta.id(world, T.Rel), item.target)),
            else => @compileError("invalid bundle marker value"),
        }
    } else {
        e.set(item);
    }
}

/// Collect the extension module types from the `.ext` tuple.
fn ext_fields(comptime ext_list: anytype) []const type {
    const fields = std.meta.fields(@TypeOf(ext_list));
    comptime var arr: [fields.len]type = undefined;
    inline for (fields, 0..) |f, i| arr[i] = @field(ext_list, f.name);
    const final = arr;
    return &final;
}

fn defaultOptions(comptime E: type) E.Options {
    return E.Options{};
}
