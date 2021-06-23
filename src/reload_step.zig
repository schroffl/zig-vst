const std = @import("std");
const BuildStep = @import("./build_step.zig");

const Self = @This();

builder: *std.build.Builder,
hosted_step: *BuildStep,
plugin_step: *BuildStep,
step: std.build.Step,

pub fn create(build_step: *BuildStep) *Self {
    const builder = build_step.builder;
    const self = builder.allocator.create(Self) catch unreachable;

    self.builder = builder;
    self.hosted_step = build_step;
    self.step = std.build.Step.init(.custom, "hot reload step", builder.allocator, make);

    var options = build_step.options;

    options.name = std.mem.join(builder.allocator, " ", &[_][]const u8{
        options.name,
        "(Auto Reload)",
    }) catch unreachable;

    options.identifier = std.mem.join(builder.allocator, "_", &[_][]const u8{
        "auto_reload",
        options.identifier,
    }) catch unreachable;

    options.package_add = .{ .Automatic = "zig-vst" };

    const plugin_src = self.resolveRelativeToSrc("reload.zig") catch unreachable;
    self.plugin_step = BuildStep.create(builder, plugin_src, options);

    const watch_file_path = self.getWatchFilePath() catch unreachable;
    self.plugin_step.lib_step.addBuildOption([]const u8, "watch_patch", watch_file_path);

    self.step.dependOn(&self.plugin_step.step);
    self.step.dependOn(&build_step.lib_step.step);

    return self;
}

fn make(step: *std.build.Step) anyerror!void {
    const self = @fieldParentPtr(Self, "step", step);

    const lib_output_path = self.hosted_step.getInternalLibOutputPath();
    try self.updateWatchPath(lib_output_path);
}

fn resolveRelativeToSrc(self: *Self, path: []const u8) ![]const u8 {
    const dirname = std.fs.path.dirname(@src().file) orelse return error.DirnameFailed;

    return std.fs.path.resolve(self.builder.allocator, &[_][]const u8{
        dirname,
        path,
    });
}

fn getWatchFileDir(self: *Self) ![]const u8 {
    const relative_to_root = try std.fs.path.join(self.builder.allocator, &[_][]const u8{
        self.builder.cache_root,
        "vst-reload",
    });

    return self.builder.pathFromRoot(relative_to_root);
}

fn getWatchFilePath(self: *Self) ![]const u8 {
    return try std.fs.path.join(self.builder.allocator, &[_][]const u8{
        try self.getWatchFileDir(),
        self.getWatchFileName(),
    });
}

fn getWatchFileName(self: *Self) []const u8 {
    return self.hosted_step.options.name;
}

fn updateWatchPath(self: *Self, new_path: []const u8) !void {
    const cwd = std.fs.cwd();
    const watch_path = try self.getWatchFileDir();
    const watch_dir = try cwd.makeOpenPath(watch_path, .{});

    const name = self.getWatchFileName();
    try watch_dir.writeFile(name, new_path);
}
