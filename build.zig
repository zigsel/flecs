const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Upstream flecs, fetched via build.zig.zon (amalgamated in `distr/`).
    const flecs_dep = b.dependency("flecs", .{});
    const flecs_h = flecs_dep.path("distr/flecs.h");
    const flecs_c = flecs_dep.path("distr/flecs.c");

    // C translation of the flecs header -> a Zig module named "c".
    const translate_c = b.addTranslateC(.{
        .root_source_file = flecs_h,
        .target = target,
        .optimize = optimize,
    });
    const c_mod = translate_c.createModule();

    // The public flecs module.
    const flecs = b.addModule("flecs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    flecs.addImport("c", c_mod);
    flecs.addIncludePath(flecs_dep.path("distr"));
    flecs.addCSourceFile(.{
        .file = flecs_c,
        .flags = &.{ "-std=gnu11", "-fno-sanitize=undefined" },
    });
    flecs.link_libc = true;

    // ---- tests ----
    const tests = b.addTest(.{
        .root_module = flecs,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // ---- examples ----
    const examples = [_][]const u8{
        "hello",
        "entity",
        "component",
        "query_basics",
        "query_advanced",
        "system_each",
        "system_run",
        "system_threaded",
        "observer_events",
        "relationship",
        "prefab",
        "bundle",
        "pipeline",
        "module",
        "reflect_json",
        "script",
        "explorer",
        "runtime_allocator",
        "runtime_std_threads",
        "runtime_io",
    };
    const examples_step = b.step("examples", "Build all examples");
    for (examples) |name| {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        exe_mod.addImport("flecs", flecs);
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = exe_mod,
        });
        b.installArtifact(exe);
        examples_step.dependOn(&exe.step);

        const run = b.addRunArtifact(exe);
        const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example", .{name}));
        run_step.dependOn(&run.step);
    }
}
