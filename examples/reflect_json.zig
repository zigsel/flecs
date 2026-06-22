//! Reflection: derive meta from @typeInfo for JSON (de)serialization, with
//! enums, arrays, strings, and declarative units/ranges.
const std = @import("std");
const flecs = @import("flecs");

const Dir = enum(u8) { north, south, east, west };

const Agent = struct {
    name: [:0]const u8, // string (opaque)
    speed: f32,
    heading: Dir, // enum
    waypoints: [3]f32, // fixed array

    // Units and value ranges declared right on the type.
    pub const flecs_units = .{ .speed = flecs.units.MetersPerSecond };
    pub const flecs_ranges = .{ .speed = .{ .min = 0.0, .max = 300.0 } };
};

pub fn main() !void {
    var world = try flecs.World(.{}).init(.{});
    defer world.deinit();
    const gpa = std.heap.page_allocator;

    _ = world.reflect(Agent); // derive EcsStruct meta (+ apply units/ranges)

    // value -> JSON (strings/enums/arrays all serialize)
    const a = Agent{ .name = "scout", .speed = 12.5, .heading = .east, .waypoints = .{ 1, 2, 3 } };
    const js = try world.toJson(a, gpa);
    defer gpa.free(js);
    std.debug.print("Agent JSON: {s}\n", .{js});

    // JSON -> value. (Opaque strings serialize but don't deserialize, so the
    // parse demo uses a plain numeric/enum struct.)
    const Stats = struct { hp: i32, heading: Dir };
    _ = world.reflect(Stats);
    const parsed = try world.fromJson(Stats, "{\"hp\":42, \"heading\":\"north\"}");
    std.debug.print("parsed: hp={d} heading={s}\n", .{ parsed.hp, @tagName(parsed.heading) });

    // whole-entity JSON
    const e = world.spawn(.{a});
    const ej = try world.entityToJson(e, gpa);
    defer gpa.free(ej);
    std.debug.print("entity JSON contains 'scout': {}\n", .{std.mem.indexOf(u8, ej, "scout") != null});
}
