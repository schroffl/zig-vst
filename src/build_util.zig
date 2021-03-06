const std = @import("std");

pub const BuildStep = struct {
    pub const Child = union(enum) {
        MacOSBundle: *MacOSBundleStep,
        DefaultStep: *std.build.LibExeObjStep,
    };

    builder: *std.build.Builder,
    options: Options,
    child: Child,
    step: *std.build.Step,
    source_path: []const u8,

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
        var lib_step = builder.addSharedLibrary(options.name, source_path, .{
            .versioned = options.version,
        });
        lib_step.setTarget(options.target);

        if (options.mode) |mode| {
            lib_step.setBuildMode(mode);
        }

        switch (options.target.getOsTag()) {
            .macos => {
                // TODO There's probably a nicer way to do this.
                if (options.macos_bundle == null) {
                    @panic("You cannot build a macOS VST without setting the required bundle information");
                }

                var self = BuildStep{
                    .child = .{
                        .MacOSBundle = MacOSBundleStep.create(builder, lib_step, options),
                    },
                    .step = undefined,
                    .builder = builder,
                    .options = options,
                    .source_path = source_path,
                };

                self.step = &self.child.MacOSBundle.step;

                return self;
            },
            else => {
                // TODO Wrap this in a seperate step where we copy the shared library to
                //      zig-cache/lib/<name>(.dll|.so)
                var self = BuildStep{
                    .child = .{ .DefaultStep = lib_step },
                    .step = undefined,
                    .builder = builder,
                    .options = options,
                    .source_path = source_path,
                };

                lib_step.install();
                self.step = &self.child.DefaultStep.step;

                return self;
            },
        }
    }

    // TODO Have this function take a package, which should point to
    //      this library. That way we can resolve the paths to
    //      src/hr_plugin.zig etc.
    pub fn hotReload(self: *BuildStep) *HotReloadStep {
        var lib_step = switch (self.child) {
            .MacOSBundle => |bundle_step| bundle_step.lib_step,
            .DefaultStep => |default_step| default_step,
        };

        var file_name_sha1 = std.crypto.hash.Sha1.init(.{});
        var out: [20]u8 = undefined;
        file_name_sha1.update(self.source_path);
        file_name_sha1.final(&out);

        const out_text = std.fmt.fmtSliceHexLower(&out);
        const meta_id = self.builder.fmt("{}", .{out_text});

        return HotReloadStep.create(self.builder, lib_step, self.options, meta_id);
    }
};

pub const HotReloadStep = struct {
    builder: *std.build.Builder,

    step: std.build.Step,

    watch_lib_step: *std.build.LibExeObjStep,
    vst_step: *BuildStep,
    meta_package: std.build.Pkg,
    meta_id: []const u8,

    const Paths = struct {
        base: []const u8,
        watch_path: []const u8,
        log_path: []const u8,
        package_path: []const u8,
    };

    pub fn create(
        builder: *std.build.Builder,
        watch_lib_step: *std.build.LibExeObjStep,
        parent_options: BuildStep.Options,
        meta_id: []const u8,
    ) *HotReloadStep {
        var self = builder.allocator.create(HotReloadStep) catch unreachable;
        var options = parent_options;

        options.name = std.mem.join(builder.allocator, " ", &[_][]const u8{
            parent_options.name,
            "(Hot Reload)",
        }) catch unreachable;

        self.builder = builder;
        self.watch_lib_step = watch_lib_step;
        self.vst_step = BuildStep.create(builder, "src/hr_plugin.zig", options);
        self.meta_id = meta_id;

        const paths = self.getPaths() catch unreachable;
        self.setupPaths(paths) catch unreachable;

        const package_source = builder.fmt("pub const watch_path = \"{s}\";\npub const log_path = \"{s}\";\n", .{
            escapeBackslash(builder.allocator, paths.watch_path) catch unreachable,
            escapeBackslash(builder.allocator, paths.log_path) catch unreachable,
        });

        const package_write_step = builder.addWriteFile(paths.package_path, package_source);

        var hr_lib_step = switch (self.vst_step.child) {
            .MacOSBundle => |bundle_step| bundle_step.lib_step,
            .DefaultStep => |default_step| default_step,
        };

        self.meta_package = .{
            .name = "hot-reload-meta",
            .path = paths.package_path,
        };

        hr_lib_step.step.dependOn(&package_write_step.step);
        hr_lib_step.addPackage(self.meta_package);

        self.step = std.build.Step.init(.Custom, "Create Hot Reload Wrapper", builder.allocator, make);
        self.step.dependOn(self.vst_step.step);
        self.step.dependOn(&self.watch_lib_step.step);

        return self;
    }

    fn getPaths(self: *HotReloadStep) !Paths {
        const cwd = std.fs.cwd();
        const allocator = self.builder.allocator;

        const meta_id = self.meta_id;
        const meta_dir = self.builder.fmt("vst-meta/{s}", .{meta_id});

        const meta_path = self.builder.getInstallPath(.Prefix, meta_dir);

        return Paths{
            .base = meta_path,
            .watch_path = try std.fs.path.join(allocator, &[_][]const u8{
                meta_path,
                "watch",
            }),
            .log_path = try std.fs.path.join(allocator, &[_][]const u8{
                meta_path,
                "log.log",
            }),
            .package_path = try std.fs.path.join(allocator, &[_][]const u8{
                meta_path,
                "package.zig",
            }),
        };
    }

    fn setupPaths(self: *HotReloadStep, paths: Paths) !void {
        const cwd = std.fs.cwd();
        try cwd.makePath(paths.base);

        var log_file = try cwd.createFile(paths.log_path, .{});
        defer log_file.close();

        var package_file = try cwd.createFile(paths.package_path, .{});
        defer package_file.close();
    }

    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(HotReloadStep, "step", step);
        const lib_output_path = self.watch_lib_step.getOutputPath();
        const paths = try self.getPaths();

        const cwd = std.fs.cwd();
        var watch_file = try cwd.createFile(paths.watch_path, .{});
        defer watch_file.close();

        try watch_file.writeAll(lib_output_path);
    }

    pub fn trackLogs(self: *HotReloadStep) *std.build.Step {
        const paths = self.getPaths() catch unreachable;
        const tail = self.builder.addSystemCommand(&[_][]const u8{
            "tail",
            "-n +0",
            "-f",
            paths.log_path,
        });

        return &tail.step;
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
        lib_step: *std.build.LibExeObjStep,
        options: BuildStep.Options,
    ) *MacOSBundleStep {
        const self = builder.allocator.create(MacOSBundleStep) catch unreachable;
        self.* = init(builder, lib_step, options) catch unreachable;
        return self;
    }

    pub fn init(
        builder: *std.build.Builder,
        lib_step: *std.build.LibExeObjStep,
        options: BuildStep.Options,
    ) !MacOSBundleStep {
        var self = MacOSBundleStep{
            .builder = builder,
            .lib_step = lib_step,
            .step = undefined,
            .options = options,
        };

        self.step = std.build.Step.init(.Custom, "Create macOS .vst bundle", builder.allocator, make);
        self.step.dependOn(&self.lib_step.step);

        return self;
    }

    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(MacOSBundleStep, "step", step);
        const cwd = std.fs.cwd();

        const vst_path = self.builder.getInstallPath(.Prefix, "vst");

        const bundle_basename = self.builder.fmt("{s}.vst", .{self.options.name});
        const bundle_path = try std.fs.path.join(self.builder.allocator, &[_][]const u8{
            vst_path,
            bundle_basename,
        });
        defer self.builder.allocator.free(bundle_path);

        var bundle_dir = try cwd.makeOpenPath(bundle_path, .{});
        defer bundle_dir.close();

        try bundle_dir.makePath("Contents/MacOS");

        const binary_path = try std.fs.path.join(self.builder.allocator, &[_][]const u8{
            "Contents/MacOS",
            self.options.name,
        });
        defer self.builder.allocator.free(binary_path);

        const lib_output_path = self.lib_step.getOutputPath();
        try cwd.copyFile(lib_output_path, bundle_dir, binary_path, .{});

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
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        while (replace(allocator, buffer, key, value)) |new_buffer| {
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

fn escapeBackslash(allocator: *std.mem.Allocator, path: []const u8) ![]const u8 {
    var count_iterator = std.mem.split(path, "\\");
    var count: usize = 0;

    while (count_iterator.next()) |_| count += 1;

    var list = try allocator.alloc([]const u8, count);
    defer allocator.free(list);

    var iterator = std.mem.split(path, "\\");
    var i: usize = 0;

    while (iterator.next()) |part| {
        list[i] = part;
        i += 1;
    }

    return std.mem.join(allocator, "\\\\", list);
}
