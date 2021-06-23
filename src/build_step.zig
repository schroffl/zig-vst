const std = @import("std");
const Builder = @import("std").build.Builder;
const ReloadStep = @import("./reload_step.zig");

const Self = @This();

pub const PackageAddOptions = union(enum) {
    Automatic: []const u8,
    Manual: struct {
        name: []const u8,
        src: []const u8,
    },
    None: void,
};

pub const Options = struct {
    name: []const u8,
    identifier: []const u8,
    version: ?std.builtin.Version = null,

    target: std.zig.CrossTarget = std.zig.CrossTarget{},
    mode: ?std.builtin.Mode = null,
    package_add: PackageAddOptions = .{
        .Automatic = "zig-vst",
    },
};

builder: *Builder,
lib_step: *std.build.LibExeObjStep,
step: std.build.Step,
options: Options,

pub fn create(builder: *Builder, root_src: []const u8, options: Options) *Self {
    const self = builder.allocator.create(Self) catch unreachable;
    const name = options.name;

    if (options.version) |version| {
        self.lib_step = builder.addSharedLibrary(name, root_src, .{ .versioned = version });
    } else {
        self.lib_step = builder.addSharedLibrary(name, root_src, .{ .unversioned = {} });
    }

    self.builder = builder;
    self.step = std.build.Step.init(.custom, "macOS .vst bundle", builder.allocator, make);
    self.options = options;

    if (options.mode) |mode| self.lib_step.setBuildMode(mode);
    self.lib_step.setTarget(options.target);

    self.addPackage() catch unreachable;

    self.step.dependOn(&self.lib_step.step);

    return self;
}

pub fn autoReload(self: *Self) *ReloadStep {
    return ReloadStep.create(self);
}

pub fn getInternalLibOutputPath(self: *Self) []const u8 {
    const output_source = self.lib_step.getOutputSource();
    return output_source.getPath(self.builder);
}

fn addPackage(self: *Self) !void {
    switch (self.options.package_add) {
        .Automatic => |package_name| {
            const this_filename = @src().file;

            if (std.fs.path.dirname(this_filename)) |dirname| {
                const main_path = try std.fs.path.resolve(self.builder.allocator, &[_][]const u8{
                    dirname,
                    "main.zig",
                });

                self.lib_step.addPackagePath(package_name, main_path);
            } else {
                std.log.err("Failed to automatically determine the location of the zig-vst source code. Consider changing your Options.package_add value to .Manual or .None\n", .{});
            }
        },
        .Manual => |manual_config| {
            self.lib_step.addPackagePath(manual_config.name, manual_config.src);
        },
        .None => {},
    }
}

fn make(step: *std.build.Step) !void {
    const self = @fieldParentPtr(Self, "step", step);

    return switch (self.options.target.getOsTag()) {
        .macos => self.makeMacOS(),
        else => self.makeDefault(),
    };
}

fn makeDefault(self: *Self) !void {
    const cwd = std.fs.cwd();
    const lib_output_path = self.getInternalLibOutputPath();

    const extension = std.fs.path.extension(lib_output_path);
    const version_string = if (self.options.version) |version|
        self.builder.fmt(".{}.{}.{}", .{
            version.major,
            version.minor,
            version.patch,
        })
    else
        "";

    const name = self.builder.fmt("{s}{s}{s}", .{
        self.options.name,
        version_string,
        extension,
    });

    const vst_path = self.builder.getInstallPath(.prefix, "vst");
    var vst_dir = try cwd.makeOpenPath(vst_path, .{});
    defer vst_dir.close();

    try cwd.copyFile(lib_output_path, vst_dir, name, .{});
}

fn makeMacOS(self: *Self) !void {
    const bundle_path = try self.getOutputDir();

    const cwd = std.fs.cwd();
    var bundle_dir = try cwd.makeOpenPath(bundle_path, .{});
    defer bundle_dir.close();

    try bundle_dir.makePath("Contents/MacOS");

    const binary_path = try std.fs.path.join(self.builder.allocator, &[_][]const u8{
        "Contents/MacOS",
        self.options.name,
    });

    const lib_output_path = self.getInternalLibOutputPath();
    try cwd.copyFile(lib_output_path, bundle_dir, binary_path, .{});

    const plist_file = try bundle_dir.createFile("Contents/Info.plist", .{});
    defer plist_file.close();
    try self.writePlist(plist_file);

    const pkginfo_file = try bundle_dir.createFile("Contents/PkgInfo", .{});
    defer pkginfo_file.close();
    try pkginfo_file.writeAll("BNDL????");
}

fn getOutputDir(self: *Self) ![]const u8 {
    const vst_path = self.builder.getInstallPath(.prefix, "vst");
    const bundle_basename = self.builder.fmt("{s}.vst", .{self.options.name});

    return try std.fs.path.join(self.builder.allocator, &[_][]const u8{
        vst_path,
        bundle_basename,
    });
}

fn writePlist(self: *Self, file: std.fs.File) !void {
    var writer = file.writer();
    const template = @embedFile("./Info.template.plist");
    const version_string = if (self.options.version) |version|
        self.builder.fmt("{}.{}.{}", .{
            version.major,
            version.minor,
            version.patch,
        })
    else
        "unversioned";

    var replace_idx: usize = 0;
    const replace = [_][]const u8{
        "English",
        self.options.name,
        self.options.identifier,
        self.options.name,
        "????",
        version_string,
        version_string,
    };

    for (template) |char| {
        if (char == '$' and replace_idx < replace.len) {
            try writer.writeAll(replace[replace_idx]);
            replace_idx += 1;
        } else {
            try writer.writeByte(char);
        }
    }
}
