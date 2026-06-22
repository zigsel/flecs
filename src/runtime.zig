//! Process-wide runtime configuration. Most importantly, this lets flecs route
//! all of its allocations through a Zig `std.mem.Allocator` by overriding the
//! flecs OS-API memory callbacks.
//!
//! flecs' callbacks only pass a pointer to `free`/`realloc` (no size), so each
//! block carries a small header recording its length and alignment.

const std = @import("std");
const c = @import("c");

const header_size: usize = 16; // keeps the returned pointer 16-byte aligned
const Align = std.mem.Alignment.fromByteUnits(16);

var allocator: ?std.mem.Allocator = null;

/// The allocator that binding-side Zig allocations should use: the one injected
/// via `configure(.{ .allocator })` if any, else the C allocator (which matches
/// flecs' own default OS-API heap). Keeps all allocations on one heap.
pub fn mem() std.mem.Allocator {
    return allocator orelse std.heap.c_allocator;
}

const Header = extern struct {
    total: usize, // total bytes allocated (header + payload)
    _pad: usize = 0,
};

fn alloc(size: usize) ?[*]u8 {
    const a = allocator.?;
    const total = header_size + size;
    const buf = a.rawAlloc(total, Align, @returnAddress()) orelse return null;
    const h: *Header = @ptrCast(@alignCast(buf));
    h.total = total;
    return buf + header_size;
}

fn freePtr(ptr: ?*anyopaque) void {
    const p = ptr orelse return;
    const base: [*]u8 = @as([*]u8, @ptrCast(p)) - header_size;
    const h: *Header = @ptrCast(@alignCast(base));
    allocator.?.rawFree(base[0..h.total], Align, @returnAddress());
}

fn mallocCb(size: c.ecs_size_t) callconv(.c) ?*anyopaque {
    if (size <= 0) return null;
    return @ptrCast(alloc(@intCast(size)));
}

fn callocCb(size: c.ecs_size_t) callconv(.c) ?*anyopaque {
    if (size <= 0) return null;
    const p = alloc(@intCast(size)) orelse return null;
    @memset(p[0..@intCast(size)], 0);
    return @ptrCast(p);
}

fn reallocCb(ptr: ?*anyopaque, size: c.ecs_size_t) callconv(.c) ?*anyopaque {
    if (ptr == null) return mallocCb(size);
    if (size <= 0) {
        freePtr(ptr);
        return null;
    }
    const old_base: [*]u8 = @as([*]u8, @ptrCast(ptr.?)) - header_size;
    const oh: *Header = @ptrCast(@alignCast(old_base));
    const old_payload = oh.total - header_size;
    const new = alloc(@intCast(size)) orelse return null;
    const copy = @min(old_payload, @as(usize, @intCast(size)));
    @memcpy(new[0..copy], @as([*]u8, @ptrCast(ptr.?))[0..copy]);
    freePtr(ptr);
    return @ptrCast(new);
}

fn freeCb(ptr: ?*anyopaque) callconv(.c) void {
    freePtr(ptr);
}

// ---- pure-std platform layer (thread + mutex + cond) ----
//
// Zig 0.16's `std.Thread` no longer exposes Mutex/Condition/Futex (they moved
// into `std.Io`). flecs' OS API needs *synchronous, blocking* mutex/cond for
// its worker barrier, so we build them from the only pure-std primitives left:
// `std.Thread` + `std.atomic` + `std.Thread.yield`. The mutex is a spinlock and
// the condition variable is generation-counter based.
//
// The spin only burns CPU while a thread is *waiting at a barrier*. Pair this
// with `.task_threads` (workers created and joined within each update) so no
// worker idles - and thus spins - between frames.

const ThreadCtx = struct {
    callback: c.ecs_os_thread_callback_t,
    arg: ?*anyopaque,
    result: ?*anyopaque = null,
    thread: std.Thread = undefined,
};

fn threadRun(ctx: *ThreadCtx) void {
    ctx.result = ctx.callback.?(ctx.arg);
}

fn stdThreadNew(cb: c.ecs_os_thread_callback_t, arg: ?*anyopaque) callconv(.c) c.ecs_os_thread_t {
    const ctx = mem().create(ThreadCtx) catch return 0;
    ctx.* = .{ .callback = cb, .arg = arg };
    ctx.thread = std.Thread.spawn(.{}, threadRun, .{ctx}) catch {
        mem().destroy(ctx);
        return 0;
    };
    return @intFromPtr(ctx);
}

fn stdThreadJoin(handle: c.ecs_os_thread_t) callconv(.c) ?*anyopaque {
    if (handle == 0) return null;
    const ctx: *ThreadCtx = @ptrFromInt(handle);
    ctx.thread.join();
    const r = ctx.result;
    mem().destroy(ctx);
    return r;
}

fn stdThreadSelf() callconv(.c) c.ecs_os_thread_id_t {
    return std.Thread.getCurrentId();
}

const SpinMutex = struct {
    state: std.atomic.Value(u32) = .init(0), // 0 = unlocked, 1 = locked
};

fn stdMutexNew() callconv(.c) c.ecs_os_mutex_t {
    const m = mem().create(SpinMutex) catch return 0;
    m.* = .{};
    return @intFromPtr(m);
}
fn stdMutexFree(h: c.ecs_os_mutex_t) callconv(.c) void {
    if (h == 0) return;
    mem().destroy(@as(*SpinMutex, @ptrFromInt(h)));
}
fn stdMutexLock(h: c.ecs_os_mutex_t) callconv(.c) void {
    const m: *SpinMutex = @ptrFromInt(h);
    while (m.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        std.Thread.yield() catch {};
    }
}
fn stdMutexUnlock(h: c.ecs_os_mutex_t) callconv(.c) void {
    const m: *SpinMutex = @ptrFromInt(h);
    m.state.store(0, .release);
}

const SpinCond = struct {
    generation: std.atomic.Value(u32) = .init(0),
};

fn stdCondNew() callconv(.c) c.ecs_os_cond_t {
    const cv = mem().create(SpinCond) catch return 0;
    cv.* = .{};
    return @intFromPtr(cv);
}
fn stdCondFree(h: c.ecs_os_cond_t) callconv(.c) void {
    if (h == 0) return;
    mem().destroy(@as(*SpinCond, @ptrFromInt(h)));
}
fn stdCondSignalImpl(h: c.ecs_os_cond_t) void {
    const cv: *SpinCond = @ptrFromInt(h);
    _ = cv.generation.fetchAdd(1, .release);
}
fn stdCondSignal(h: c.ecs_os_cond_t) callconv(.c) void {
    stdCondSignalImpl(h);
}
fn stdCondBroadcast(h: c.ecs_os_cond_t) callconv(.c) void {
    stdCondSignalImpl(h);
}
fn stdCondWait(ch: c.ecs_os_cond_t, mh: c.ecs_os_mutex_t) callconv(.c) void {
    const cv: *SpinCond = @ptrFromInt(ch);
    // Read the generation while still holding the mutex (the signaler must take
    // the mutex before broadcasting, so it cannot advance between here and the
    // unlock below - no lost wakeups).
    const gen = cv.generation.load(.acquire);
    stdMutexUnlock(mh);
    while (cv.generation.load(.acquire) == gen) {
        std.Thread.yield() catch {};
    }
    stdMutexLock(mh);
}

pub const Threading = enum {
    /// Use flecs' built-in platform layer (posix/win32 threads, mutex, cond).
    default,
    /// Use a pure-`std` platform layer: `std.Thread` for threads and a
    /// spinlock/generation-counter mutex & condition built from `std.atomic`.
    /// No libc/pthread dependency. Best paired with `.task_threads`.
    std,
};

fn installStdThreading(api: *c.ecs_os_api_t) void {
    api.thread_new_ = stdThreadNew;
    api.thread_join_ = stdThreadJoin;
    api.thread_self_ = stdThreadSelf;
    api.task_new_ = stdThreadNew;
    api.task_join_ = stdThreadJoin;
    api.mutex_new_ = stdMutexNew;
    api.mutex_free_ = stdMutexFree;
    api.mutex_lock_ = stdMutexLock;
    api.mutex_unlock_ = stdMutexUnlock;
    api.cond_new_ = stdCondNew;
    api.cond_free_ = stdCondFree;
    api.cond_signal_ = stdCondSignal;
    api.cond_broadcast_ = stdCondBroadcast;
    api.cond_wait_ = stdCondWait;
}

// ---- std.Io executor integration ----
//
// flecs' *task* threads (ecs_set_task_threads) spawn one short-lived task per
// sync point per frame and join them - a perfect match for an `Io` executor's
// async/await. Routing task_new_/task_join_ onto a user-provided `std.Io` runs
// flecs' parallel pipeline work on that executor (e.g. std.Io.Threaded's pool).

var io_instance: ?std.Io = null;

/// flecs task callbacks return a `void*`.
const TaskResult = ?*anyopaque;

const TaskContext = struct {
    cb: c.ecs_os_thread_callback_t,
    arg: ?*anyopaque,
};

const TaskHolder = struct {
    future: ?*std.Io.AnyFuture,
    result: TaskResult,
};

fn startTask(context: *const anyopaque, result: *anyopaque) void {
    const ctx: *const TaskContext = @ptrCast(@alignCast(context));
    const r: *TaskResult = @ptrCast(@alignCast(result));
    r.* = ctx.cb.?(ctx.arg);
}

fn ioTaskNew(cb: c.ecs_os_thread_callback_t, arg: ?*anyopaque) callconv(.c) c.ecs_os_thread_t {
    const io = io_instance.?;
    const ctx = TaskContext{ .cb = cb, .arg = arg };
    var eager: TaskResult = null;
    const fut = io.vtable.async(
        io.userdata,
        std.mem.asBytes(&eager),
        std.mem.Alignment.fromByteUnits(@alignOf(TaskResult)),
        std.mem.asBytes(&ctx),
        std.mem.Alignment.fromByteUnits(@alignOf(TaskContext)),
        startTask,
    );
    const h = mem().create(TaskHolder) catch return 0;
    h.* = .{ .future = fut, .result = eager };
    return @intFromPtr(h);
}

fn ioTaskJoin(handle: c.ecs_os_thread_t) callconv(.c) TaskResult {
    if (handle == 0) return null;
    const io = io_instance.?;
    const h: *TaskHolder = @ptrFromInt(handle);
    var result: TaskResult = h.result;
    if (h.future) |f| {
        io.vtable.await(io.userdata, f, std.mem.asBytes(&result), std.mem.Alignment.fromByteUnits(@alignOf(TaskResult)));
    }
    mem().destroy(h);
    return result;
}

pub const Options = struct {
    /// Route all flecs allocations through this allocator. Must be set before
    /// the first `World.init` that should use it, and must outlive every world
    /// created while it is active.
    allocator: ?std.mem.Allocator = null,
    /// Platform layer for threads/mutex/cond. `.std` makes flecs fully
    /// self-contained on pure `std` (no libc/pthread), portable anywhere
    /// `std.Thread` runs. Best paired with `World.init(.{ .task_threads = N })`.
    threading: Threading = .default,
    /// Run flecs' task threads on this `std.Io` executor (use with
    /// `World.init(.{ .task_threads = N })`). The executor must outlive every
    /// world. Composes with `threading = .std` (which supplies mutex/cond).
    io: ?std.Io = null,
};

/// Configure the flecs runtime: optionally wire a Zig allocator and/or run
/// flecs' worker threads on `std.Thread`.
///
/// IMPORTANT: call once at program start, before the first `World.init` and
/// before any other flecs call. flecs keeps process-global state that is
/// allocated lazily; switching backends after allocations exist corrupts the
/// heap on free. Any injected allocator must outlive every world.
pub fn configure(opts: Options) void {
    if (opts.allocator == null and opts.io == null and opts.threading == .default) return;

    c.ecs_os_set_api_defaults();
    var api = c.ecs_os_api;

    if (opts.allocator) |a| {
        allocator = a;
        api.malloc_ = mallocCb;
        api.calloc_ = callocCb;
        api.realloc_ = reallocCb;
        api.free_ = freeCb;
    }
    if (opts.threading == .std) installStdThreading(&api);
    if (opts.io) |io| {
        io_instance = io;
        api.task_new_ = ioTaskNew;
        api.task_join_ = ioTaskJoin;
    }

    // Install via ecs_os_set_api so ecs_init won't reset back to defaults.
    c.ecs_os_set_api(&api);
}
