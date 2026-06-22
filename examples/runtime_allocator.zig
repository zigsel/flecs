//! Route every flecs allocation through a Zig `std.mem.Allocator`. Configure
//! once at process start, before any world is created.
const std = @import("std");
const flecs = @import("flecs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

var counter: Counter = .{};
const Counter = struct {
    n: usize = 0,
    fn allocator(self: *Counter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = a, .resize = r, .remap = m, .free = f } };
    }
    fn a(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const s: *Counter = @ptrCast(@alignCast(ctx));
        s.n += 1;
        return std.heap.c_allocator.rawAlloc(len, al, ra);
    }
    fn r(_: *anyopaque, mm: []u8, al: std.mem.Alignment, nl: usize, ra: usize) bool {
        return std.heap.c_allocator.rawResize(mm, al, nl, ra);
    }
    fn m(_: *anyopaque, mm: []u8, al: std.mem.Alignment, nl: usize, ra: usize) ?[*]u8 {
        return std.heap.c_allocator.rawRemap(mm, al, nl, ra);
    }
    fn f(_: *anyopaque, mm: []u8, al: std.mem.Alignment, ra: usize) void {
        std.heap.c_allocator.rawFree(mm, al, ra);
    }
};

pub fn main() !void {
    flecs.runtime(.{ .allocator = counter.allocator() }); // before any world

    var world = try flecs.World(.{}).init(.{});
    defer world.deinit();
    _ = world.spawn(.{ Position{ .x = 1, .y = 2 }, Velocity{ .x = 3, .y = 4 } });
    var q = try world.query(struct { p: *Position });
    defer q.deinit();
    var it = q.iter();
    defer it.deinit();
    while (it.next()) |row| row.p.x += 1;

    std.debug.print("flecs made {d} allocations through the Zig allocator\n", .{counter.n});
}
