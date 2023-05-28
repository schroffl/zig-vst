const std = @import("std");

pub const BuildStep = @import("src/build_step.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vst_step = BuildStep.create(b, .{
        .name = "zig-vst-example",
        .root_source_file = .{ .path = "./plugin.zig" },
        .target = target,
        .optimize = optimize,
        .macos = .{
            .bundle_identifier = "org.zig-vst.example",
        },
    });

    _ = b.addModule("vst", .{
        .source_file = .{ .path = "src/index.zig" },
    });

    vst_step.lib.addModule("vst", b.modules.get("vst").?);
    b.default_step.dependOn(vst_step.step);

    const tests = b.addTest(.{
        .name = "vst-tests",
        .root_source_file = .{ .path = "src/index.zig" },
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&tests.step);
}
