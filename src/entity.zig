//! A lightweight handle: a world pointer + an entity id. Methods translate
//! directly into flecs calls.

const std = @import("std");
const c = @import("c");
const meta = @import("meta.zig");
const runtime = @import("runtime.zig");

pub const Entity = struct {
    world: *c.ecs_world_t,
    id: meta.Id,

    const Self = @This();

    pub fn init(world: *c.ecs_world_t, id: meta.Id) Self {
        return .{ .world = world, .id = id };
    }

    /// Add a tag/component id with no value.
    pub fn add(self: Self, comptime T: type) void {
        c.ecs_add_id(self.world, self.id, meta.id(self.world, T));
    }

    pub fn remove(self: Self, comptime T: type) void {
        c.ecs_remove_id(self.world, self.id, meta.id(self.world, T));
    }

    /// Add-or-write a component value (moves archetype if newly added).
    pub fn set(self: Self, value: anytype) void {
        const T = @TypeOf(value);
        const cid = meta.id(self.world, T);
        if (meta.isTag(T)) {
            c.ecs_add_id(self.world, self.id, cid);
        } else {
            var v = value;
            _ = c.ecs_set_id(self.world, self.id, cid, @sizeOf(T), &v);
        }
    }

    /// Try-get an immutable pointer to a component (null if absent).
    pub fn get(self: Self, comptime T: type) ?*const T {
        const ptr = c.ecs_get_id(self.world, self.id, meta.id(self.world, T));
        if (ptr == null) return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Get a mutable pointer, adding the component (zeroed) if missing.
    pub fn ensure(self: Self, comptime T: type) *T {
        const ptr = c.ecs_ensure_id(self.world, self.id, meta.id(self.world, T), @sizeOf(T));
        return @ptrCast(@alignCast(ptr));
    }

    /// Mutable pointer to an *existing* component, or null if absent (unlike
    /// `ensure`, this never adds). Pair with `modified` if observers should fire.
    pub fn getMut(self: Self, comptime T: type) ?*T {
        const ptr = c.ecs_get_mut_id(self.world, self.id, meta.id(self.world, T));
        if (ptr == null) return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Force `T` to be owned (copied) on this instance rather than inherited from
    /// a prefab/base via `IsA` - the per-entity counterpart of prefab
    /// `autoOverride`.
    pub fn override(self: Self, comptime T: type) void {
        c.ecs_auto_override_id(self.world, self.id, meta.id(self.world, T));
    }

    /// Add `T` *uninitialized* and return a pointer to its storage for in-place
    /// construction. Unlike `ensure` (which zero-initializes), the bytes are
    /// raw - you must write a complete value before any reader sees it. Useful
    /// for non-zeroable types or to skip a redundant zero-fill.
    pub fn emplace(self: Self, comptime T: type) *T {
        const ptr = c.ecs_emplace_id(self.world, self.id, meta.id(self.world, T), @sizeOf(T), null);
        return @ptrCast(@alignCast(ptr));
    }

    /// Signal that a component mutated through `ensure` so observers fire.
    pub fn modified(self: Self, comptime T: type) void {
        c.ecs_modified_id(self.world, self.id, meta.id(self.world, T));
    }

    /// A cached reference to one component on this entity - the fast path for
    /// repeatedly reading the same component across frames (skips the lookup).
    pub fn ref(self: Self, comptime T: type) Ref(T) {
        const cid = meta.id(self.world, T);
        return .{ .world = self.world, .raw = c.ecs_ref_init_id(self.world, self.id, cid), .cid = cid };
    }

    pub fn has(self: Self, comptime T: type) bool {
        return c.ecs_has_id(self.world, self.id, meta.id(self.world, T));
    }

    // ---- relationships / pairs ----

    /// Add a relationship pair `(R, target)`.
    pub fn addPair(self: Self, comptime R: type, tgt: Self) void {
        c.ecs_add_id(self.world, self.id, c.ecs_make_pair(meta.id(self.world, R), tgt.id));
    }

    /// Set a pair carrying data: `(R, target)` holding an `R` value.
    pub fn setPair(self: Self, value: anytype, tgt: Self) void {
        const R = @TypeOf(value);
        const pair = c.ecs_make_pair(meta.id(self.world, R), tgt.id);
        var v = value;
        _ = c.ecs_set_id(self.world, self.id, pair, @sizeOf(R), &v);
    }

    pub fn hasPair(self: Self, comptime R: type, tgt: Self) bool {
        return c.ecs_has_id(self.world, self.id, c.ecs_make_pair(meta.id(self.world, R), tgt.id));
    }

    /// Whether the entity has relationship `R` to *any* target (`(R, *)`).
    pub fn hasRelation(self: Self, comptime R: type) bool {
        return c.ecs_has_id(self.world, self.id, c.ecs_make_pair(meta.id(self.world, R), c.EcsWildcard));
    }

    pub fn getPair(self: Self, comptime R: type, tgt: Self) ?*const R {
        const pair = c.ecs_make_pair(meta.id(self.world, R), tgt.id);
        const ptr = c.ecs_get_id(self.world, self.id, pair);
        if (ptr == null) return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Mutable pointer to the data of pair `(R, target)`, adding it (zeroed) if
    /// missing - the pair counterpart of `ensure`.
    pub fn ensurePair(self: Self, comptime R: type, tgt: Self) *R {
        const pair = c.ecs_make_pair(meta.id(self.world, R), tgt.id);
        return @ptrCast(@alignCast(c.ecs_ensure_id(self.world, self.id, pair, @sizeOf(R))));
    }

    /// Uninitialized in-place storage for pair `(R, target)` (pair `emplace`).
    pub fn emplacePair(self: Self, comptime R: type, tgt: Self) *R {
        const pair = c.ecs_make_pair(meta.id(self.world, R), tgt.id);
        return @ptrCast(@alignCast(c.ecs_emplace_id(self.world, self.id, pair, @sizeOf(R), null)));
    }

    /// Remove relationship pair `(R, target)`.
    pub fn removePair(self: Self, comptime R: type, tgt: Self) void {
        c.ecs_remove_id(self.world, self.id, c.ecs_make_pair(meta.id(self.world, R), tgt.id));
    }

    /// Iterate this entity's direct children (any order).
    pub fn children(self: Self) ChildIter {
        return .{ .world = self.world, .it = c.ecs_children(self.world, self.id), .row = 0, .count = 0, .done = false };
    }

    pub const ChildIter = struct {
        world: *c.ecs_world_t,
        it: c.ecs_iter_t,
        row: i32,
        count: i32,
        done: bool,
        pub fn next(self: *ChildIter) ?Self {
            while (self.row >= self.count) {
                if (!c.ecs_children_next(&self.it)) {
                    self.done = true;
                    return null;
                }
                self.count = self.it.count;
                self.row = 0;
            }
            const i: usize = @intCast(self.row);
            self.row += 1;
            return Self.init(self.world, self.it.entities[i]);
        }
        /// Idempotent cleanup; see `Query.Iterator.deinit`.
        pub fn deinit(self: *ChildIter) void {
            if (!self.done) {
                c.ecs_iter_fini(&self.it);
                self.done = true;
            }
        }
    };

    /// First target of relationship `R` (e.g. who this entity `Likes`).
    pub fn target(self: Self, comptime R: type) ?Self {
        const t = c.ecs_get_target(self.world, self.id, meta.id(self.world, R), 0);
        if (t == 0) return null;
        return Self.init(self.world, t);
    }

    /// Find the target of relationship `R` that provides component `C` (follows
    /// the relationship, including inherited components).
    pub fn targetFor(self: Self, comptime R: type, comptime C: type) ?Self {
        const t = c.ecs_get_target_for_id(self.world, self.id, meta.id(self.world, R), meta.id(self.world, C));
        if (t == 0) return null;
        return Self.init(self.world, t);
    }

    /// Distance to the root along relationship `R` (e.g. ChildOf depth in a
    /// hierarchy). 0 for an entity with no `R` target.
    pub fn depth(self: Self, comptime R: type) i32 {
        return c.ecs_get_depth(self.world, self.id, meta.id(self.world, R));
    }

    /// Iterate all targets of relationship `R` on this entity (e.g. everyone
    /// this entity `Likes`).
    pub fn targets(self: Self, comptime R: type) TargetIter {
        return .{ .e = self, .rel = meta.id(self.world, R), .index = 0 };
    }

    pub const TargetIter = struct {
        e: Self,
        rel: meta.Id,
        index: i32,
        pub fn next(self: *TargetIter) ?Self {
            const t = c.ecs_get_target(self.e.world, self.e.id, self.rel, self.index);
            if (t == 0) return null;
            self.index += 1;
            return Self.init(self.e.world, t);
        }
    };

    // ---- enum relationships ----

    /// Add an enum value as an exclusive `(Enum, .case)` pair (replaces any
    /// previous case of the same enum).
    pub fn addEnum(self: Self, value: anytype) void {
        c.ecs_add_id(self.world, self.id, meta.enumPair(self.world, value));
    }

    /// Read back the current case of enum `E`, if set.
    pub fn getEnum(self: Self, comptime E: type) ?E {
        const rel = meta.enumRel(self.world, E);
        const t = c.ecs_get_target(self.world, self.id, rel, 0);
        if (t == 0) return null;
        return meta.enumValue(self.world, E, t);
    }

    // ---- hierarchy ----

    pub fn childOf(self: Self, the_parent: Self) void {
        c.ecs_add_id(self.world, self.id, c.ecs_make_pair(c.EcsChildOf, the_parent.id));
    }

    /// Inherit components/structure from a base entity or prefab.
    pub fn isA(self: Self, base: Self) void {
        c.ecs_add_id(self.world, self.id, c.ecs_make_pair(c.EcsIsA, base.id));
    }

    /// Resolve a prefab slot on an instance: `slot_entity` is the prefab's child
    /// entity that was marked as a slot; returns the instance's corresponding child.
    pub fn slot(self: Self, slot_entity: Self) ?Self {
        const t = c.ecs_get_target(self.world, self.id, slot_entity.id, 0);
        if (t == 0) return null;
        return Self.init(self.world, t);
    }

    pub fn parent(self: Self) ?Self {
        const p = c.ecs_get_target(self.world, self.id, c.EcsChildOf, 0);
        if (p == 0) return null;
        return Self.init(self.world, p);
    }

    /// Enable stable, explicit child ordering on this (parent) entity.
    pub fn enableOrderedChildren(self: Self) void {
        c.ecs_add_id(self.world, self.id, c.EcsOrderedChildren);
    }

    /// Set the explicit order of this entity's children (requires
    /// `enableOrderedChildren`). The slice lists children in the desired order.
    pub fn setChildOrder(self: Self, order: []const Self) void {
        var buf = runtime.mem().alloc(meta.Id, order.len) catch @panic("OOM");
        defer runtime.mem().free(buf);
        for (order, 0..) |ch, i| buf[i] = ch.id;
        c.ecs_set_child_order(self.world, self.id, buf.ptr, @intCast(order.len));
    }

    /// The ordered children of this entity (valid until the hierarchy changes).
    pub fn orderedChildren(self: Self) OrderedChildren {
        return .{ .world = self.world, .ents = c.ecs_get_ordered_children(self.world, self.id) };
    }

    pub const OrderedChildren = struct {
        world: *c.ecs_world_t,
        ents: c.ecs_entities_t,
        i: usize = 0,

        pub fn len(self: OrderedChildren) usize {
            return @intCast(self.ents.count);
        }
        pub fn at(self: OrderedChildren, idx: usize) Self {
            return Self.init(self.world, self.ents.ids[idx]);
        }
        pub fn next(self: *OrderedChildren) ?Self {
            if (self.i >= @as(usize, @intCast(self.ents.count))) return null;
            defer self.i += 1;
            return Self.init(self.world, self.ents.ids[self.i]);
        }
    };

    // ---- documentation (Explorer / tooling) ----

    pub const Doc = struct {
        name: ?[*:0]const u8 = null,
        brief: ?[*:0]const u8 = null,
        detail: ?[*:0]const u8 = null,
        link: ?[*:0]const u8 = null,
        color: ?[*:0]const u8 = null,
    };

    /// Attach human-readable documentation (shown in the Explorer). The doc
    /// module is built into the default world.
    pub fn setDoc(self: Self, doc: Doc) void {
        if (doc.name) |s| c.ecs_doc_set_name(self.world, self.id, s);
        if (doc.brief) |s| c.ecs_doc_set_brief(self.world, self.id, s);
        if (doc.detail) |s| c.ecs_doc_set_detail(self.world, self.id, s);
        if (doc.link) |s| c.ecs_doc_set_link(self.world, self.id, s);
        if (doc.color) |s| c.ecs_doc_set_color(self.world, self.id, s);
    }

    fn spanOpt(s: [*c]const u8) ?[]const u8 {
        return if (s == null) null else std.mem.span(s);
    }
    pub fn getDocBrief(self: Self) ?[]const u8 {
        return spanOpt(c.ecs_doc_get_brief(self.world, self.id));
    }
    pub fn getDocDetail(self: Self) ?[]const u8 {
        return spanOpt(c.ecs_doc_get_detail(self.world, self.id));
    }
    pub fn getDocName(self: Self) ?[]const u8 {
        return spanOpt(c.ecs_doc_get_name(self.world, self.id));
    }

    // ---- lifecycle ----

    pub fn enable(self: Self, enabled: bool) void {
        c.ecs_enable(self.world, self.id, enabled);
    }

    /// Toggle a component on/off without removing it (requires the component to
    /// have the `can_toggle` trait). Disabled components are skipped by queries.
    pub fn toggle(self: Self, comptime T: type, enabled: bool) void {
        c.ecs_enable_id(self.world, self.id, meta.id(self.world, T), enabled);
    }

    /// Remove all components/relationships but keep the entity alive.
    pub fn clear(self: Self) void {
        c.ecs_clear(self.world, self.id);
    }

    pub fn isAlive(self: Self) bool {
        return c.ecs_is_alive(self.world, self.id);
    }

    /// Whether this id was ever issued (alive or not) - distinct from `isAlive`,
    /// which is false for a deleted entity. Useful for networking/id reuse.
    pub fn exists(self: Self) bool {
        return c.ecs_exists(self.world, self.id);
    }

    /// Whether this id is usable in operations (alive, or a non-recycled raw id).
    pub fn isValid(self: Self) bool {
        return c.ecs_is_valid(self.world, self.id);
    }

    pub fn destroy(self: Self) void {
        c.ecs_delete(self.world, self.id);
    }

    /// Delete every direct child of this entity (those with `(ChildOf, self)`).
    pub fn deleteChildren(self: Self) void {
        c.ecs_delete_with(self.world, c.ecs_make_pair(c.EcsChildOf, self.id));
    }

    // ---- low-level locked access (thread-safe single-entity read/write) ----

    /// Begin an exclusive write to this entity's record. Component access through
    /// the returned guard is faster (skips lookups) and safe against concurrent
    /// readers/writers. Must be matched with `WriteGuard.end()`.
    pub fn write(self: Self) ?WriteGuard {
        const r = c.ecs_write_begin(self.world, self.id);
        if (r == null) return null;
        return .{ .world = self.world, .record = r.? };
    }

    /// Begin a shared read of this entity's record (multiple readers allowed).
    /// Must be matched with `ReadGuard.end()`.
    pub fn read(self: Self) ?ReadGuard {
        const r = c.ecs_read_begin(self.world, self.id);
        if (r == null) return null;
        return .{ .world = self.world, .record = r.? };
    }

    /// The table this entity is stored in (its archetype), or null if it has no
    /// components. A read-only handle for inspecting columns / membership.
    pub fn table(self: Self) ?Table {
        const t = c.ecs_get_table(self.world, self.id);
        if (t == null) return null;
        return .{ .world = self.world, .raw = t.? };
    }

    /// Move this entity directly into `dst` table (its components become that
    /// archetype's). The low-level bulk alternative to add/remove.
    pub fn moveTo(self: Self, dst: Table) void {
        _ = c.ecs_commit(self.world, self.id, null, dst.raw, null, null);
    }

    /// Copy this entity (and optionally its component values) into a new entity.
    pub fn clone(self: Self, copy_values: bool) Self {
        return Self.init(self.world, c.ecs_clone(self.world, 0, self.id, copy_values));
    }

    /// Iterate every id (component/tag/pair) on this entity.
    pub fn ids(self: Self) IdIter {
        const t = c.ecs_get_type(self.world, self.id);
        return .{ .array = if (t == null) null else t.*.array, .count = if (t == null) 0 else t.*.count, .i = 0 };
    }

    pub const IdIter = struct {
        array: ?[*]const meta.Id,
        count: i32,
        i: i32,
        pub fn next(self: *IdIter) ?meta.Id {
            if (self.i >= self.count) return null;
            const id = self.array.?[@intCast(self.i)];
            self.i += 1;
            return id;
        }
    };

    // ---- names & path ----

    pub fn name(self: Self) ?[]const u8 {
        const n = c.ecs_get_name(self.world, self.id);
        if (n == null) return null;
        return std.mem.span(n);
    }

    pub fn setName(self: Self, n: [*:0]const u8) void {
        _ = c.ecs_set_name(self.world, self.id, n);
    }

    pub fn setAlias(self: Self, n: [*:0]const u8) void {
        c.ecs_set_alias(self.world, self.id, n);
    }

    /// Set this entity's unique symbol (the stable lookup key; components get
    /// one automatically from their Zig type name).
    pub fn setSymbol(self: Self, sym: [*:0]const u8) void {
        _ = c.ecs_set_symbol(self.world, self.id, sym);
    }

    /// A human-readable description of this entity - its full component list,
    /// e.g. `"[Position, Velocity, (ChildOf,Player)]"` - as an `allocator`-owned
    /// slice. For logging/debugging.
    pub fn typeStr(self: Self, allocator: std.mem.Allocator) ![]u8 {
        const s = c.ecs_entity_str(self.world, self.id);
        if (s == null) return error.Failed;
        defer meta.osFree(@ptrCast(s));
        return allocator.dupe(u8, std.mem.span(s));
    }

    /// Hierarchical path, e.g. "Player.Gun". Caller owns the returned slice;
    /// free it with `freePath`.
    pub fn path(self: Self) ?[]u8 {
        const p = c.ecs_get_path_w_sep(self.world, 0, self.id, ".", null);
        if (p == null) return null;
        return std.mem.span(p);
    }

    pub fn freePath(self: Self, p: []u8) void {
        meta.osFree(@ptrCast(@constCast(p.ptr)));
        _ = self;
    }
};

/// Exclusive write access to one entity's record (see `Entity.write`). Get
/// mutable component pointers, then `end()`.
pub const WriteGuard = struct {
    world: *c.ecs_world_t,
    record: *c.ecs_record_t,

    pub fn get(self: WriteGuard, comptime T: type) ?*T {
        const ptr = c.ecs_record_ensure_id(self.world, self.record, meta.id(self.world, T));
        if (ptr == null) return null;
        return @ptrCast(@alignCast(ptr));
    }
    pub fn end(self: WriteGuard) void {
        c.ecs_write_end(self.record);
    }
};

/// Shared read access to one entity's record (see `Entity.read`). Get const
/// component pointers, then `end()`.
pub const ReadGuard = struct {
    world: *c.ecs_world_t,
    record: *const c.ecs_record_t,

    pub fn get(self: ReadGuard, comptime T: type) ?*const T {
        const ptr = c.ecs_record_get_id(self.world, self.record, meta.id(self.world, T));
        if (ptr == null) return null;
        return @ptrCast(@alignCast(ptr));
    }
    pub fn end(self: ReadGuard) void {
        c.ecs_read_end(self.record);
    }
};

/// A read-only handle to a table (archetype) - the storage shared by every
/// entity with the same set of components. Reached via `Entity.table`.
pub const Table = struct {
    world: *c.ecs_world_t,
    raw: *c.ecs_table_t,

    /// Number of entities stored in this table.
    pub fn count(self: Table) i32 {
        return c.ecs_table_count(self.raw);
    }

    /// The entity ids in this table (length == `count()`), in storage order.
    pub fn entities(self: Table) []const meta.Id {
        const e = c.ecs_table_entities(self.raw);
        if (e == null) return &.{};
        return e[0..@intCast(self.count())];
    }

    /// Whether the table (its archetype) contains component `T`.
    pub fn has(self: Table, comptime T: type) bool {
        return c.ecs_table_has_id(self.world, self.raw, meta.id(self.world, T));
    }

    /// The contiguous column for component `T` as a slice (SoA), or null if the
    /// table doesn't store `T`.
    pub fn column(self: Table, comptime T: type) ?[]T {
        const p = c.ecs_table_get_id(self.world, self.raw, meta.id(self.world, T), 0);
        if (p == null) return null;
        const base: [*]T = @ptrCast(@alignCast(p));
        return base[0..@intCast(self.count())];
    }

    /// Every id (component/tag/pair) that makes up this table's archetype.
    pub fn typeIds(self: Table) []const meta.Id {
        const t = c.ecs_table_get_type(self.raw);
        if (t == null or t.*.count == 0) return &.{};
        return t.*.array[0..@intCast(t.*.count)];
    }

    /// Column index of component `T` in this table, or null if absent.
    pub fn columnIndex(self: Table, comptime T: type) ?i32 {
        const i = c.ecs_table_get_column_index(self.world, self.raw, meta.id(self.world, T));
        return if (i == -1) null else i;
    }

    /// Depth of this table along relationship `R` (e.g. ChildOf hierarchy depth).
    pub fn depth(self: Table, comptime R: type) i32 {
        return c.ecs_table_get_depth(self.world, self.raw, meta.id(self.world, R));
    }

    /// The table you'd reach by adding component `T` to this archetype (graph
    /// edge); useful for pre-building archetypes.
    pub fn with(self: Table, comptime T: type) Table {
        return .{ .world = self.world, .raw = c.ecs_table_add_id(self.world, self.raw, meta.id(self.world, T)).? };
    }

    /// The table reached by removing component `T` from this archetype.
    pub fn without(self: Table, comptime T: type) Table {
        return .{ .world = self.world, .raw = c.ecs_table_remove_id(self.world, self.raw, meta.id(self.world, T)).? };
    }

    /// Prevent structural changes to this table while you hold raw column
    /// pointers (debug-checked). Pair with `unlock`.
    pub fn lock(self: Table) void {
        c.ecs_table_lock(self.world, self.raw);
    }
    pub fn unlock(self: Table) void {
        c.ecs_table_unlock(self.world, self.raw);
    }

    /// Swap two rows (and their entities) within this table.
    pub fn swapRows(self: Table, row_a: i32, row_b: i32) void {
        c.ecs_table_swap_rows(self.world, self.raw, row_a, row_b);
    }

    /// Delete all entities in this table (keeps the table itself).
    pub fn clearEntities(self: Table) void {
        c.ecs_table_clear_entities(self.world, self.raw);
    }

    /// The archetype as a readable string (e.g. `"Position, Velocity"`), as an
    /// `allocator`-owned slice. For logging/debugging.
    pub fn str(self: Table, allocator: std.mem.Allocator) ![]u8 {
        const s = c.ecs_table_str(self.world, self.raw);
        if (s == null) return error.Failed;
        defer meta.osFree(@ptrCast(s));
        return allocator.dupe(u8, std.mem.span(s));
    }
};

/// A cached component reference (`ecs_ref_t`). Created via `entity.ref(T)`, it
/// keeps the table/record location so repeated `get()`s skip the component
/// lookup - the fast path for reading one component every frame. The cache
/// self-heals when the entity moves tables.
pub fn Ref(comptime T: type) type {
    return struct {
        world: *c.ecs_world_t,
        raw: c.ecs_ref_t,
        cid: meta.Id,

        const Self = @This();

        /// Current pointer to the component (null if the entity no longer has it).
        pub fn get(self: *Self) ?*T {
            const ptr = c.ecs_ref_get_id(self.world, &self.raw, self.cid);
            if (ptr == null) return null;
            return @ptrCast(@alignCast(ptr));
        }
    };
}
