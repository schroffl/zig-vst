const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("zig-vst", "src/main.zig");
    lib.setBuildMode(mode);
    lib.install();

    var main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    var plugin_lib = b.addSharedLibrary("example-plugin", "plugin.zig", .{
        .major = 0,
        .minor = 1,
        .patch = 0,
    });
    plugin_lib.setBuildMode(mode);
    plugin_lib.install();

    var exec_plugin = b.addSystemCommand(&[_][]const u8{
        "./simple_host",
        "./zig-cache/lib/libexample-plugin.dylib",
    });

    exec_plugin.step.dependOn(&plugin_lib.step);
    b.default_step.dependOn(&exec_plugin.step);
}
