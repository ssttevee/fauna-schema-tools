const std = @import("std");
const zbind = @import("node_modules/zbind/zbind.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fauna = b.dependency("fauna10", .{ .target = target, .optimize = optimize });

    if (target.result.isWasm()) {
        const addon = try zbind.build(
            .{
                .builder = b,
                .main = "src/wasm.zig",
                .out = "dist/root",
                .target = target,
                .optimize = optimize,
            },
        );

        addon.entry = .disabled;
        addon.root_module.addImport("fauna", fauna.module("root"));
    } else {
        const exe = b.addExecutable(.{
            .name = "fauna-schema-tools",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        exe.root_module.addImport("fauna", fauna.module("root"));

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        run_cmd.step.dependOn(b.getInstallStep());

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tools/dts.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_unit_tests.root_module.addImport("fauna", fauna.module("root"));

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
