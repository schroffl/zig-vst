const std = @import("std");

pub const BuildStep = struct {
    step: *std.build.Step,

    pub const Options = struct {
        name: []const u8,
        version: std.builtin.Version,
        target: std.zig.CrossTarget = std.zig.CrossTarget{},
        mode: ?std.builtin.Mode = null,
        macos_bundle: ?MacOSBundleStep.BundleOptions = null,
    };

    pub fn create(
        builder: *std.build.Builder,
        source_path: []const u8,
        options: Options,
    ) *BuildStep {
        const self = builder.allocator.create(BuildStep) catch unreachable;
        self.* = init(builder, source_path, options);
        return self;
    }

    pub fn init(
        builder: *std.build.Builder,
        source_path: []const u8,
        options: Options,
    ) BuildStep {
        switch (options.target.getOsTag()) {
            .macosx => {
                // TODO There's probably a nicer way to do this.
                if (options.macos_bundle == null) {
                    @panic("You cannot build a macOS VST without setting the required bundle information");
                }

                const bundle_step = MacOSBundleStep.create(builder, source_path, options);
                return .{ .step = &bundle_step.step };
            },
            else => {
                // TODO Wrap this in a seperate step where we copy the shared library to
                //      zig-cache/lib/<name>(.dll|.so)
                const lib_step = builder.addSharedLibrary(options.name, source_path, options.version);

                if (options.mode) |mode| {
                    lib_step.setBuildMode(mode);
                }

                lib_step.setTarget(options.target);
                lib_step.install();

                return .{ .step = &lib_step.step };
            },
        }
    }
};

pub const MacOSBundleStep = struct {
    builder: *std.build.Builder,
    lib_step: *std.build.LibExeObjStep,
    step: std.build.Step,
    options: BuildStep.Options,

    pub const BundleOptions = struct {
        bundle_identifier: []const u8,
        bundle_signature: [4]u8 = [_]u8{'?'} ** 4,
        bundle_development_region: []const u8 = "English",
    };

    pub fn create(
        builder: *std.build.Builder,
        source_path: []const u8,
        options: BuildStep.Options,
    ) *MacOSBundleStep {
        const self = builder.allocator.create(MacOSBundleStep) catch unreachable;
        self.* = init(builder, source_path, options) catch unreachable;
        return self;
    }

    pub fn init(
        builder: *std.build.Builder,
        source_path: []const u8,
        options: BuildStep.Options,
    ) !MacOSBundleStep {
        var self = MacOSBundleStep{
            .builder = builder,
            .lib_step = builder.addSharedLibrary(options.name, source_path, options.version),
            .step = undefined,
            .options = options,
        };

        self.step = std.build.Step.init(.Custom, "Create macOS .vst bundle", builder.allocator, make);
        self.step.dependOn(&self.lib_step.step);

        if (options.mode) |mode| {
            self.lib_step.setBuildMode(mode);
        }

        self.lib_step.setTarget(options.target);

        return self;
    }

    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(MacOSBundleStep, "step", step);
        const cwd = std.fs.cwd();

        const lib_path = self.builder.getInstallPath(.Lib, "");
        var lib_dir = try cwd.openDir(lib_path, .{});
        defer lib_dir.close();

        const bundle_basename = self.builder.fmt("{}.vst", .{self.options.name});
        const bundle_path = try std.fs.path.join(self.builder.allocator, &[_][]const u8{
            lib_path,
            bundle_basename,
        });
        defer self.builder.allocator.free(bundle_path);

        var bundle_dir = try lib_dir.makeOpenPath(bundle_path, .{});
        defer bundle_dir.close();

        try bundle_dir.makePath("Contents/MacOS");

        const binary_path = try std.fs.path.join(self.builder.allocator, &[_][]const u8{
            "Contents/MacOS",
            self.options.name,
        });
        defer self.builder.allocator.free(binary_path);

        const lib_output_path = self.lib_step.getOutputPath();
        try lib_dir.copyFile(lib_output_path, bundle_dir, binary_path, .{});

        const plist_file = try bundle_dir.createFile("Contents/Info.plist", .{});
        defer plist_file.close();
        try self.createPList(plist_file);

        const pkginfo_file = try bundle_dir.createFile("Contents/PkgInfo", .{});
        defer pkginfo_file.close();
        try self.createPkgInfo(pkginfo_file);
    }

    fn createPList(self: *MacOSBundleStep, out_file: std.fs.File) !void {
        const template = @embedFile("Info.template.plist");

        var variables = std.StringHashMap([]const u8).init(self.builder.allocator);
        defer variables.deinit();

        try self.generateVariables(&variables);

        const final = try replaceVariables(self.builder.allocator, template, variables);
        defer self.builder.allocator.free(final);

        try out_file.writeAll(final);
    }

    fn createPkgInfo(self: *MacOSBundleStep, out_file: std.fs.File) !void {
        const bundle_options = self.options.macos_bundle.?;
        var buffer: [8]u8 = undefined;

        std.mem.copy(u8, &buffer, "BNDL");
        std.mem.copy(u8, buffer[4..], &bundle_options.bundle_signature);

        try out_file.writeAll(&buffer);
    }

    fn generateVariables(self: *MacOSBundleStep, into: *std.StringHashMap([]const u8)) !void {
        const bundle_options = self.options.macos_bundle.?;
        const version_string = self.builder.fmt("{}.{}.{}", .{
            self.options.version.major,
            self.options.version.minor,
            self.options.version.patch,
        });

        _ = try into.put("$ZIGVST_CFBundleName", self.options.name);
        _ = try into.put("$ZIGVST_CFBundleExecutable", self.options.name);
        _ = try into.put("$ZIGVST_CFBundleSignature", &bundle_options.bundle_signature);
        _ = try into.put("$ZIGVST_CFBundleVersion", version_string);
        _ = try into.put("$ZIGVST_CFBundleIdentifier", bundle_options.bundle_identifier);
        _ = try into.put("$ZIGVST_CFBundleDevelopmentRegion", bundle_options.bundle_development_region);
    }
};

fn replaceVariables(
    allocator: *std.mem.Allocator,
    initial: []const u8,
    variables: std.StringHashMap([]const u8),
) ![]u8 {
    var it = variables.iterator();
    var buffer = try std.mem.dupe(allocator, u8, initial);

    while (it.next()) |entry| {
        while (replace(allocator, buffer, entry.key, entry.value)) |new_buffer| {
            allocator.free(buffer);
            buffer = new_buffer;
        } else |err| {
            switch (err) {
                error.NotFound => {},
                else => return err,
            }
        }
    }

    return buffer;
}

fn replace(
    allocator: *std.mem.Allocator,
    src: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    const dest = try allocator.alloc(u8, src.len - needle.len + replacement.len);
    errdefer allocator.free(dest);

    const index = std.mem.indexOf(u8, src, needle) orelse return error.NotFound;

    std.mem.copy(u8, dest[0..index], src[0..index]);
    std.mem.copy(u8, dest[index..], replacement);
    std.mem.copy(u8, dest[index + replacement.len ..], src[index + needle.len ..]);

    return dest;
}
