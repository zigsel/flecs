//! Systems & observers derived from a plain function's signature. The parameter
//! list *is* the query; the binding synthesizes the flecs terms (via the shared
//! compiler), a `callconv(.c)` trampoline, and the registration call.

const std = @import("std");
const c = @import("c");
const meta = @import("meta.zig");
const compile = @import("compile.zig");
const terms = @import("terms.zig");
const query_mod = @import("query.zig");
const Stage = @import("stage.zig").Stage;
const runtime = @import("runtime.zig");
const hasDecl = meta.hasDecl;

const RunKind = enum { query, stage, res, res_mut, delta };

fn runKind(comptime T: type) RunKind {
    if (hasDecl(T, "flecs_query_row")) return .query;
    if (hasDecl(T, "flecs_stage")) return .stage;
    if (hasDecl(T, "flecs_res")) return if (T.flecs_res_mut) .res_mut else .res;
    if (T == terms.Delta) return .delta;
    @compileError("run-system param " ++ @typeName(T) ++ " must be Query/Stage/Res/ResMut/Delta");
}

/// Is `Fn` a run-system? (Any param is a Query / Stage / Res / ResMut.)
fn isRunSystem(comptime Fn: type) bool {
    inline for (@typeInfo(Fn).@"fn".params) |p| {
        const T = p.type.?;
        if (hasDecl(T, "flecs_query_row")) return true;
        if (hasDecl(T, "flecs_stage")) return true;
        if (terms.isRes(T)) return true;
    }
    return false;
}

fn slotsOf(comptime Fn: type) []const compile.Slot {
    const params = @typeInfo(Fn).@"fn".params;
    comptime var slots: [params.len]compile.Slot = undefined;
    inline for (params, 0..) |p, i| slots[i] = compile.classify(p.type.?);
    const final = slots;
    return &final;
}

/// Create the (anonymous) system entity, depending on `phase`. Systems are
/// anonymous: Zig has no stable per-function name, and naming by type would
/// collide for same-signature functions (flecs dedups by name).
fn makeSystemEntity(world: *c.ecs_world_t, phase: meta.Id) meta.Id {
    var edesc = std.mem.zeroes(c.ecs_entity_desc_t);
    const ids = [_]c.ecs_id_t{ if (phase != 0) c.ecs_make_pair(c.EcsDependsOn, phase) else 0, 0 };
    edesc.add = &ids;
    return c.ecs_entity_init(world, &edesc);
}

/// Copy timer/threading options onto a system desc.
fn applyOpts(sdesc: *c.ecs_system_desc_t, opts: SystemOptions) void {
    if (opts.interval > 0) sdesc.interval = opts.interval;
    if (opts.rate > 0) sdesc.rate = opts.rate;
    sdesc.multi_threaded = opts.multi_threaded;
    sdesc.immediate = opts.immediate;
}

/// The custom-event payload type for an observer, if any (`OnEvent(E)`).
fn payloadType(comptime Fn: type) ?type {
    inline for (slotsOf(Fn)) |s| {
        if (s.kind == .event and s.event == .custom) return s.Comp;
    }
    return null;
}

/// Observer slots: like `slotsOf`, but any `*const E` term matching the custom
/// event payload type is reclassified as a `.payload` (read from `it.param`).
fn observerSlots(comptime Fn: type) []const compile.Slot {
    const base = slotsOf(Fn);
    const P = payloadType(Fn);
    if (P == null) return compile.plan(base);
    comptime var out: [base.len]compile.Slot = undefined;
    inline for (base, 0..) |s, i| {
        var p = s;
        if (s.kind == .data and s.Comp == P.?) p.kind = .payload;
        out[i] = p;
    }
    const final = out;
    return compile.plan(&final);
}

/// Generate the `callconv(.c)` iterator callback for `func` over `slots`.
fn Cb(comptime func: anytype, comptime slots: []const compile.Slot) type {
    const Args = std.meta.ArgsTuple(@TypeOf(func));
    return struct {
        fn cb(it_ptr: [*c]c.ecs_iter_t) callconv(.c) void {
            const it: *c.ecs_iter_t = @ptrCast(it_ptr);
            const bases = compile.cacheBases(slots, it);
            var row: i32 = 0;
            while (row < it.count) : (row += 1) {
                const i: usize = @intCast(row);
                var args: Args = undefined;
                inline for (slots, 0..) |s, ai| {
                    const field = comptime std.fmt.comptimePrint("{d}", .{ai});
                    @field(args, field) = compile.value(s, it, bases, i);
                }
                @call(.auto, func, args);
            }
        }
    };
}

/// Each-system callback.
fn EachCb(comptime func: anytype) type {
    return Cb(func, comptime compile.plan(slotsOf(@TypeOf(func))));
}

/// Classify a function's params starting at `start` (used to skip the `*Self`
/// param of a stateful system).
fn slotsOfFrom(comptime Fn: type, comptime start: usize) []const compile.Slot {
    const params = @typeInfo(Fn).@"fn".params;
    comptime var slots: [params.len - start]compile.Slot = undefined;
    inline for (params[start..], 0..) |p, i| slots[i] = compile.classify(p.type.?);
    const final = slots;
    return &final;
}

/// Trampoline for a stateful system: the persisted instance (`*S`, from it.ctx)
/// is passed as the first argument, the rest come from the query terms.
fn StatefulCb(comptime func: anytype, comptime S: type, comptime slots: []const compile.Slot) type {
    const Args = std.meta.ArgsTuple(@TypeOf(func));
    return struct {
        fn cb(it_ptr: [*c]c.ecs_iter_t) callconv(.c) void {
            const it: *c.ecs_iter_t = @ptrCast(it_ptr);
            const self: *S = @ptrCast(@alignCast(it.ctx));
            const bases = compile.cacheBases(slots, it);
            var row: i32 = 0;
            while (row < it.count) : (row += 1) {
                const i: usize = @intCast(row);
                var args: Args = undefined;
                args.@"0" = self;
                inline for (slots, 0..) |s, si| {
                    const field = comptime std.fmt.comptimePrint("{d}", .{si + 1});
                    @field(args, field) = compile.value(s, it, bases, i);
                }
                @call(.auto, func, args);
            }
        }
    };
}

/// Register a stateful each-system: `instance` is persisted and passed as the
/// `*Self` first parameter of `func` each run.
pub fn statefulSystem(world: *c.ecs_world_t, phase: meta.Id, comptime func: anytype, instance: anytype, opts: SystemOptions, comptime Cfg: type) meta.Id {
    const S = @TypeOf(instance);
    const slots = comptime compile.plan(slotsOfFrom(@TypeOf(func), 1));

    const ctx = runtime.mem().create(S) catch @panic("OOM");
    ctx.* = instance;

    var sdesc = std.mem.zeroes(c.ecs_system_desc_t);
    sdesc.entity = makeSystemEntity(world, phase);
    compile.fillTerms(slots, world, &sdesc.query.terms);
    if (Cfg != void) query_mod.applyConfig(Cfg, world, &sdesc.query);
    sdesc.callback = StatefulCb(func, S, slots).cb;
    sdesc.ctx = ctx;
    sdesc.ctx_free = struct {
        fn f(p: ?*anyopaque) callconv(.c) void {
            runtime.mem().destroy(@as(*S, @ptrCast(@alignCast(p))));
        }
    }.f;
    applyOpts(&sdesc, opts);
    return c.ecs_system_init(world, &sdesc);
}

/// Types of the Query params, in order (used to build the persistent ctx).
fn queryTypes(comptime Fn: type) []const type {
    const params = @typeInfo(Fn).@"fn".params;
    comptime var list: [params.len]type = undefined;
    comptime var n: usize = 0;
    inline for (params) |p| {
        if (runKind(p.type.?) == .query) {
            list[n] = p.type.?;
            n += 1;
        }
    }
    const final = list[0..n].*;
    return &final;
}

fn singletonPtr(world: *c.ecs_world_t, comptime T: type, comptime mutable: bool) if (mutable) *T else *const T {
    const cid = meta.id(world, T);
    if (mutable) {
        return @ptrCast(@alignCast(c.ecs_ensure_id(world, cid, cid, @sizeOf(T))));
    } else {
        return @ptrCast(@alignCast(c.ecs_get_id(world, cid, cid)));
    }
}

/// Generate the run-callback for a run-system. `Ctx` (a tuple of the created
/// Query instances) is passed via `it.ctx`.
fn RunCb(comptime func: anytype) type {
    const Fn = @TypeOf(func);
    const params = @typeInfo(Fn).@"fn".params;
    const Args = std.meta.ArgsTuple(Fn);
    const QTypes = queryTypes(Fn);
    const Ctx = @import("std").meta.Tuple(QTypes);

    return struct {
        const CtxT = Ctx;

        fn cb(it_ptr: [*c]c.ecs_iter_t) callconv(.c) void {
            const it: *c.ecs_iter_t = @ptrCast(it_ptr);
            const ctx: *Ctx = @ptrCast(@alignCast(it.ctx));

            var args: Args = undefined;
            comptime var qi: usize = 0;
            inline for (params, 0..) |p, ai| {
                const T = p.type.?;
                const field = comptime std.fmt.comptimePrint("{d}", .{ai});
                switch (comptime runKind(T)) {
                    .query => {
                        @field(args, field) = @field(ctx.*, std.fmt.comptimePrint("{d}", .{qi}));
                        qi += 1;
                    },
                    .stage => @field(args, field) = Stage{ .world = it.world.? },
                    .res => @field(args, field) = .{ .v = singletonPtr(it.real_world.?, T.flecs_res, false) },
                    .res_mut => @field(args, field) = .{ .v = singletonPtr(it.real_world.?, T.flecs_res, true) },
                    .delta => @field(args, field) = .{ .s = it.delta_time },
                }
            }
            @call(.auto, func, args);
        }
    };
}

/// Register `func` as a run-system (drives its own iteration via Query params).
fn runSystem(world: *c.ecs_world_t, phase: meta.Id, comptime func: anytype, opts: SystemOptions) meta.Id {
    const Tr = RunCb(func);
    const Ctx = Tr.CtxT;

    // Build & persist the query instances.
    const ctx = runtime.mem().create(Ctx) catch @panic("OOM");
    const QTypes = comptime queryTypes(@TypeOf(func));
    inline for (QTypes, 0..) |QT, j| {
        @field(ctx.*, std.fmt.comptimePrint("{d}", .{j})) = QT.init(world) catch @panic("query init failed");
    }

    var sdesc = std.mem.zeroes(c.ecs_system_desc_t);
    sdesc.entity = makeSystemEntity(world, phase);
    sdesc.callback = Tr.cb;
    sdesc.ctx = ctx;
    sdesc.ctx_free = struct {
        fn f(p: ?*anyopaque) callconv(.c) void {
            const cp: *Ctx = @ptrCast(@alignCast(p));
            inline for (0..QTypes.len) |j| {
                @field(cp.*, std.fmt.comptimePrint("{d}", .{j})).deinit();
            }
            runtime.mem().destroy(cp);
        }
    }.f;
    applyOpts(&sdesc, opts);
    return c.ecs_system_init(world, &sdesc);
}

pub const SystemOptions = struct {
    /// Run at most once every `interval` seconds (0 = every frame).
    interval: f32 = 0,
    /// Run once every `rate` matched ticks (0/1 = every tick).
    rate: i32 = 0,
    /// Shard this system's entities across worker threads (requires
    /// `world.setThreads`).
    multi_threaded: bool = false,
    /// Run outside the readonly/staged phase (mutations apply immediately).
    immediate: bool = false,
};

pub const ObserverOptions = struct {
    /// Fire immediately for entities that already match.
    yield_existing: bool = false,
    /// Make this a monitor: fires when an entity starts/stops matching.
    monitor: bool = false,
};

/// Register `func` as a system. Each-systems (component-data params) run once
/// per matching entity; run-systems (Query/Stage/Res params) run once per frame
/// and drive their own iteration. The kind is inferred from the signature.
pub fn system(world: *c.ecs_world_t, phase: meta.Id, comptime func: anytype, opts: SystemOptions, comptime Cfg: type) meta.Id {
    if (comptime isRunSystem(@TypeOf(func))) {
        return runSystem(world, phase, func, opts);
    }
    const slots = comptime compile.plan(slotsOf(@TypeOf(func)));

    var sdesc = std.mem.zeroes(c.ecs_system_desc_t);
    sdesc.entity = makeSystemEntity(world, phase);
    compile.fillTerms(slots, world, &sdesc.query.terms);
    if (Cfg != void) query_mod.applyConfig(Cfg, world, &sdesc.query);
    sdesc.callback = EachCb(func).cb;
    applyOpts(&sdesc, opts);
    return c.ecs_system_init(world, &sdesc);
}

/// True if `func`'s signature contains an event marker (OnAdd/OnSet/OnEvent…).
pub fn isObserverFn(comptime Fn: type) bool {
    inline for (slotsOf(Fn)) |s| {
        if (s.kind == .event) return true;
    }
    return false;
}

/// Register `func` as an observer. Events come from `OnAdd/OnRemove/OnSet`
/// marker params; the remaining params form the query.
pub fn observer(world: *c.ecs_world_t, comptime func: anytype, opts: ObserverOptions) meta.Id {
    const slots = comptime observerSlots(@TypeOf(func));

    var odesc = std.mem.zeroes(c.ecs_observer_desc_t);
    odesc.entity = 0;
    odesc.yield_existing = opts.yield_existing;

    compile.fillTerms(slots, world, &odesc.query.terms);

    comptime var ev_count: usize = 0;
    comptime var injected: usize = 0;
    inline for (slots) |s| {
        if (s.kind == .event) {
            odesc.events[ev_count] = switch (s.event) {
                .add => c.EcsOnAdd,
                .remove => c.EcsOnRemove,
                .set => c.EcsOnSet,
                .custom => meta.id(world, s.Comp),
                else => @compileError("unknown event"),
            };
            ev_count += 1;
            // For builtin add/remove/set events, ensure the observed component
            // is a query term. Custom events match on the observer's own terms.
            if (s.event != .custom) {
                comptime var present = false;
                inline for (slots) |q| {
                    if (q.term_start >= 0 and q.Comp == s.Comp) present = true;
                }
                if (!present) {
                    const idx = comptime compile.termTotal(slots) + injected;
                    injected += 1;
                    odesc.query.terms[idx].id = meta.id(world, s.Comp);
                    odesc.query.terms[idx].inout = c.EcsInOutNone;
                }
            }
        }
    }

    if (opts.monitor) {
        odesc.events[ev_count] = c.EcsMonitor;
    }

    odesc.callback = Cb(func, slots).cb;
    return c.ecs_observer_init(world, &odesc);
}
