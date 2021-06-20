const std = @import("std");
const Builder = @import("std").build.Builder;

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
name: []const u8,
options: Options,

pub fn create(builder: *Builder, name: []const u8, root_src: []const u8, options: Options) *Self {
    const self = builder.allocator.create(Self) catch unreachable;

    if (options.version) |version| {
        self.lib_step = builder.addSharedLibrary(name, root_src, .{ .versioned = version });
    } else {
        self.lib_step = builder.addSharedLibrary(name, root_src, .{ .unversioned = {} });
    }

    self.builder = builder;
    self.name = name;
    self.step = std.build.Step.init(.Custom, "macOS .vst bundle", builder.allocator, make);
    self.options = options;

    if (options.mode) |mode| self.lib_step.setBuildMode(mode);
    self.lib_step.setTarget(options.target);

    self.addPackage() catch unreachable;

    self.lib_step.install();

    self.step.dependOn(&self.lib_step.step);

    return self;
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
        else => {},
    };
}

fn makeMacOS(self: *Self) !void {
    const bundle_path = try self.getOutputDir();

    const cwd = std.fs.cwd();
    var bundle_dir = try cwd.makeOpenPath(bundle_path, .{});
    defer bundle_dir.close();

    try bundle_dir.makePath("Contents/MacOS");

    const binary_path = try std.fs.path.join(self.builder.allocator, &[_][]const u8{
        "Contents/MacOS",
        self.name,
    });

    const lib_output_path = self.lib_step.getOutputPath();
    try cwd.copyFile(lib_output_path, bundle_dir, binary_path, .{});

    const plist_file = try bundle_dir.createFile("Contents/Info.plist", .{});
    defer plist_file.close();
    try self.writePlist(plist_file);

    const pkginfo_file = try bundle_dir.createFile("Contents/PkgInfo", .{});
    defer pkginfo_file.close();
    try pkginfo_file.writeAll("BNDL????");
}

fn getOutputDir(self: *Self) ![]const u8 {
    const vst_path = self.builder.getInstallPath(.Prefix, "vst");
    const bundle_basename = self.builder.fmt("{s}.vst", .{self.name});

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
        self.name,
        self.options.identifier,
        self.name,
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
