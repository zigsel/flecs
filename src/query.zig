//! Typed queries. The row struct *is* the query: each field lowers to flecs
//! term(s) via the shared term compiler, and iteration hands back a populated
//! row struct with named fields. Both per-entity (`iter`) and per-table
//! (`tableIter`, cache-friendly SoA slices) iteration are supported.

const std = @import("std");
const c = @import("c");
const meta = @import("meta.zig");
const compile = @import("compile.zig");
const Entity = @import("entity.zig").Entity;

/// Apply `sort` / `group` / `cache` declarations from a query Row type onto a
/// query desc. (Tuples have no decls, so this is a no-op for them.)
pub fn applyConfig(comptime Row: type, world: *c.ecs_world_t, desc: *c.ecs_query_desc_t) void {
    if (@typeInfo(Row) != .@"struct") return;
    if (@hasDecl(Row, "sort")) {
        const S = Row.sort;
        desc.order_by = meta.id(world, S.Comp);
        desc.order_by_callback = S.order;
    }
    if (@hasDecl(Row, "group")) {
        desc.group_by = meta.id(world, Row.group);
    }
    if (@hasDecl(Row, "cache")) {
        desc.cache_kind = switch (Row.cache) {
            .auto => c.EcsQueryCacheAuto,
            .all => c.EcsQueryCacheAll,
            .none => c.EcsQueryCacheNone,
        };
    }
}

fn slotsOf(comptime Row: type) []const compile.Slot {
    const info = @typeInfo(Row);
    if (info != .@"struct") @compileError("query row must be a struct");
    const fields = info.@"struct".fields;
    comptime var slots: [fields.len]compile.Slot = undefined;
    inline for (fields, 0..) |f, i| slots[i] = compile.classify(f.type);
    const final = slots;
    return &final;
}

/// Resolve a query spec to a Row type: a struct/tuple type is used as-is; a
/// tuple *value* of types (e.g. `.{ *Position, *const Velocity }`) becomes a
/// tuple Row with positional rows.
pub fn RowOf(comptime spec: anytype) type {
    if (@TypeOf(spec) == type) return spec;
    const fields = std.meta.fields(@TypeOf(spec));
    comptime var types: [fields.len]type = undefined;
    inline for (fields, 0..) |f, i| types[i] = @field(spec, f.name);
    return @Tuple(&types);
}

pub fn Query(comptime Row: type) type {
    const raw_slots = comptime slotsOf(Row);
    const slots = comptime compile.plan(raw_slots);
    const fields = @typeInfo(Row).@"struct".fields;

    return struct {
        q: *c.ecs_query_t,
        world: *c.ecs_world_t,

        pub const flecs_query_row = Row;

        const Self = @This();

        pub fn fromDesc(world: *c.ecs_world_t, base: c.ecs_query_desc_t) !Self {
            var desc = base;
            compile.fillTerms(slots, world, &desc.terms);
            applyConfig(Row, world, &desc);
            const q = c.ecs_query_init(world, &desc) orelse return error.QueryInitFailed;
            return .{ .q = q, .world = world };
        }

        pub fn init(world: *c.ecs_world_t) !Self {
            return fromDesc(world, std.mem.zeroes(c.ecs_query_desc_t));
        }

        pub fn deinit(self: *Self) void {
            c.ecs_query_fini(self.q);
        }

        /// Has any matched table changed since the last iteration? (Requires a
        /// cached query; flecs reports change at table granularity.)
        pub fn changed(self: *Self) bool {
            return c.ecs_query_changed(self.q);
        }

        /// Counts of matched results / entities / tables (one full evaluation).
        pub fn count(self: *const Self) c.ecs_query_count_t {
            return c.ecs_query_count(self.q);
        }

        /// Whether the query matches anything - cheaper than `count` when you
        /// only need existence.
        pub fn isTrue(self: *const Self) bool {
            return c.ecs_query_is_true(self.q);
        }

        /// Stats (match/table counts + ctx) for one group of a grouped query.
        pub fn groupInfo(self: *const Self, group_id: u64) ?*const c.ecs_query_group_info_t {
            return c.ecs_query_get_group_info(self.q, group_id);
        }

        /// The user context attached to a query group (from `on_group_create`).
        pub fn groupCtx(self: *const Self, group_id: u64) ?*anyopaque {
            return c.ecs_query_get_group_ctx(self.q, group_id);
        }

        /// Serialize this query's results to JSON. Caller owns the slice.
        pub fn toJson(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
            return @import("addons.zig").iterToJson(self.world, self.q, allocator);
        }

        /// The query as its DSL string (e.g. `"Position, [in] Velocity"`), as an
        /// `allocator`-owned slice. For logging/debugging.
        pub fn str(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
            const s = c.ecs_query_str(self.q);
            if (s == null) return error.Failed;
            defer meta.osFree(@ptrCast(s));
            return allocator.dupe(u8, std.mem.span(s));
        }

        // ---- per-entity iteration ----

        pub fn iter(self: *const Self) Iterator {
            return .{ .it = c.ecs_query_iter(self.world, self.q), .row = 0, .count = 0, .bases = undefined, .done = false, .started = true, .mode = .query, .chain_base = undefined };
        }

        /// Iterate only `[offset, offset+limit)` of the matched entities - a
        /// pageable view (e.g. for batching or virtualized lists).
        pub fn pageIter(self: *const Self, offset: i32, limit: i32) Iterator {
            return .{ .it = undefined, .row = 0, .count = 0, .bases = undefined, .done = false, .started = false, .mode = .{ .page = .{ offset, limit } }, .chain_base = c.ecs_query_iter(self.world, self.q) };
        }

        /// Iterate worker `index` of `workers`' equal share of the matched
        /// entities - manual sharding across threads (each worker its own slice).
        pub fn workerIter(self: *const Self, index: i32, workers: i32) Iterator {
            return .{ .it = undefined, .row = 0, .count = 0, .bases = undefined, .done = false, .started = false, .mode = .{ .worker = .{ index, workers } }, .chain_base = c.ecs_query_iter(self.world, self.q) };
        }

        const Mode = union(enum) { query, page: [2]i32, worker: [2]i32 };

        pub const Iterator = struct {
            it: c.ecs_iter_t,
            row: i32,
            count: i32,
            bases: [compile.dataCount(slots)]?[*]u8,
            done: bool,
            /// A page/worker view chains to `chain_base`, which must keep a stable
            /// address - so the view is built lazily on the first `next`, once
            /// this struct sits in its final storage.
            started: bool,
            mode: Mode,
            chain_base: c.ecs_iter_t,

            pub fn next(self: *Iterator) ?Row {
                if (!self.started) {
                    self.started = true;
                    switch (self.mode) {
                        .query => {},
                        .page => |p| self.it = c.ecs_page_iter(&self.chain_base, p[0], p[1]),
                        .worker => |w| self.it = c.ecs_worker_iter(&self.chain_base, w[0], w[1]),
                    }
                }
                while (self.row >= self.count) {
                    const more = switch (self.mode) {
                        .query => c.ecs_query_next(&self.it),
                        else => c.ecs_iter_next(&self.it), // page/worker dispatch generically
                    };
                    if (!more) {
                        self.done = true; // flecs finalized the iterator
                        return null;
                    }
                    self.count = self.it.count;
                    self.row = 0;
                    self.bases = compile.cacheBases(slots, &self.it);
                }
                const i: usize = @intCast(self.row);
                self.row += 1;
                var row: Row = undefined;
                inline for (fields, slots) |f, s| {
                    @field(row, f.name) = compile.value(s, &self.it, self.bases, i);
                }
                return row;
            }

            /// Constrain iteration to query group `group_id` (call before the
            /// first `next`; requires a `pub const group` on the query).
            pub fn setGroup(self: *Iterator, group_id: u64) void {
                c.ecs_iter_set_group(&self.it, group_id);
            }

            /// The group id of the current table (with a grouped query).
            pub fn group(self: *Iterator) u64 {
                return c.ecs_iter_get_group(&self.it);
            }

            /// Skip the current table's entities (they won't be re-matched this
            /// iteration) - e.g. for change-detection-driven early-out.
            pub fn skip(self: *Iterator) void {
                c.ecs_iter_skip(&self.it);
            }

            /// Release iterator resources. Idempotent - safe to `defer` and a
            /// no-op once the loop has drained to `null`. Write it as
            /// `var it = q.iter(); defer it.deinit();` and breaking early is safe.
            pub fn deinit(self: *Iterator) void {
                if (self.done) return;
                // A page/worker view never advanced still owns its base iter.
                c.ecs_iter_fini(if (self.started) &self.it else &self.chain_base);
                self.done = true;
            }
        };

        // ---- per-table iteration (SoA slices) ----

        pub fn tableIter(self: *const Self) TableIterator {
            return .{ .it = c.ecs_query_iter(self.world, self.q), .done = false };
        }

        /// Per-field column for a matched table. Data fields become slices;
        /// filter fields stay markers. Entity fields become the entity slice.
        pub const Table = blk: {
            var names: [fields.len][]const u8 = undefined;
            var types: [fields.len]type = undefined;
            var attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
            for (fields, slots, 0..) |f, s, i| {
                names[i] = f.name;
                types[i] = columnType(s);
                attrs[i] = .{};
            }
            break :blk @Struct(.auto, null, &names, &types, &attrs);
        };

        pub const TableIterator = struct {
            it: c.ecs_iter_t,
            done: bool,

            pub fn next(self: *TableIterator) ?Table {
                if (!c.ecs_query_next(&self.it)) {
                    self.done = true;
                    return null;
                }
                const bases = compile.cacheBases(slots, &self.it);
                const n: usize = @intCast(self.it.count);
                var tab: Table = undefined;
                inline for (fields, slots) |f, s| {
                    @field(tab, f.name) = columnValue(s, &self.it, bases, n);
                }
                return tab;
            }

            /// Idempotent cleanup; see `Iterator.deinit`.
            pub fn deinit(self: *TableIterator) void {
                if (!self.done) {
                    c.ecs_iter_fini(&self.it);
                    self.done = true;
                }
            }
        };
    };
}

/// Untyped query built from a flecs query-DSL string - the escape hatch for
/// tooling, REPLs, runtime-built queries, and member-value queries (e.g.
/// `"Position, $this.Position.x > 5"`). Yields entities; use `field` for data.
pub const Expr = struct {
    q: *c.ecs_query_t,
    world: *c.ecs_world_t,

    pub fn init(world: *c.ecs_world_t, expr: [*:0]const u8) !Expr {
        var desc = std.mem.zeroes(c.ecs_query_desc_t);
        desc.expr = expr;
        const q = c.ecs_query_init(world, &desc) orelse return error.QueryInitFailed;
        return .{ .q = q, .world = world };
    }

    pub fn deinit(self: *Expr) void {
        c.ecs_query_fini(self.q);
    }

    /// Resolve a named query variable (e.g. `$food`) to its index, or null if
    /// the query has no such variable. Pass the index to `ExprIter.setVar`.
    pub fn findVar(self: *const Expr, name: [*:0]const u8) ?i32 {
        const v = c.ecs_query_find_var(self.q, name);
        return if (v == -1) null else v;
    }

    pub fn iter(self: *const Expr) ExprIter {
        return .{ .it = c.ecs_query_iter(self.world, self.q), .row = 0, .count = 0, .done = false };
    }

    pub const ExprIter = struct {
        it: c.ecs_iter_t,
        row: i32,
        count: i32,
        done: bool,

        /// Constrain a query variable to `entity` before iterating (call after
        /// `iter()`, before the first `next()`). Index comes from `findVar`.
        pub fn setVar(self: *ExprIter, var_id: i32, entity: Entity) void {
            c.ecs_iter_set_var(&self.it, var_id, entity.id);
        }

        pub fn next(self: *ExprIter) ?Entity {
            while (self.row >= self.count) {
                if (!c.ecs_query_next(&self.it)) {
                    self.done = true;
                    return null;
                }
                self.count = self.it.count;
                self.row = 0;
            }
            const i: usize = @intCast(self.row);
            self.row += 1;
            return Entity.init(self.it.world.?, self.it.entities[i]);
        }

        /// Access the current row's data for the term at 0-based DSL `field_index`.
        pub fn field(self: *ExprIter, comptime T: type, field_index: i8) ?*const T {
            const ptr = c.ecs_field_w_size(&self.it, @sizeOf(T), field_index);
            if (ptr == null) return null;
            const base: [*]const T = @ptrCast(@alignCast(ptr));
            return &base[@intCast(self.row - 1)];
        }

        /// Idempotent cleanup; see `Query.Iterator.deinit`.
        pub fn deinit(self: *ExprIter) void {
            if (!self.done) {
                c.ecs_iter_fini(&self.it);
                self.done = true;
            }
        }
    };
};

fn columnType(comptime s: compile.Slot) type {
    return switch (s.kind) {
        .entity => []const meta.Id,
        .data => if (s.is_const) []const s.Comp else []s.Comp,
        else => s.Field, // filters/shared stay as the declared marker/value
    };
}

fn columnValue(comptime s: compile.Slot, it: *c.ecs_iter_t, bases: anytype, n: usize) columnType(s) {
    switch (s.kind) {
        .entity => return it.entities[0..n],
        .data => {
            // An absent optional column has no data for this table -> empty slice.
            const base = bases[@intCast(s.data_ord)] orelse return &.{};
            const ptr: [*]s.Comp = @ptrCast(@alignCast(base));
            return ptr[0..n];
        },
        else => return compile.value(s, it, bases, 0),
    }
}
