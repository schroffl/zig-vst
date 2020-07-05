const Builder = @import("std").build.Builder;
const vst_build = @import("src/main.zig").build_util;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});
    const lib = b.addStaticLibrary("zig-vst", "src/main.zig");
    lib.setBuildMode(mode);
    lib.install();

    var main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    var vst_step = vst_build.BuildStep.create(b, "plugin.zig", .{
        .name = "Zig VST Example Plugin",
        .version = .{
            .major = 0,
            .minor = 1,
            .patch = 2,
        },
        .macos_bundle = .{
            .bundle_identifier = "org.zig-vst.example-synth",
        },
        .mode = mode,
        .target = target,
    });

    b.default_step.dependOn(vst_step.step);
}
