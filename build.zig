const Builder = @import("std").build.Builder;
const vst_build = @import("src/main.zig").build_util;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    var main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    var vst_step = vst_build.BuildStep.create(b, "plugin.zig", .{
        .name = "Zig VST Example Plugin",
        .version = .{
            .major = 0,
            .minor = 1,
            .patch = 0,
        },
        .macos_bundle = .{
            .bundle_identifier = "org.zig-vst.example-plugin",
        },
        .mode = mode,
        .target = target,
    });

    var hr = vst_step.hotReload();
    b.default_step.dependOn(&hr.step);

    const log_step = b.step("logs", "Show hot reload logs");
    log_step.dependOn(hr.trackLogs());
}
