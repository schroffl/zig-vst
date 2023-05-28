const std = @import("std");
const Self = @This();

step: *std.Build.Step,
lib: *std.Build.CompileStep,

pub const VstStepOptions = struct {
    name: []const u8,
    root_source_file: std.Build.FileSource,
    target: std.zig.CrossTarget,
    optimize: std.builtin.OptimizeMode,
    version: ?std.builtin.Version = null,

    macos: ?MacosOptions = null,

    pub const MacosOptions = struct {
        bundle_identifier: []const u8,
    };
};

pub fn create(b: *std.Build, options: VstStepOptions) *Self {
    var self = b.allocator.create(Self) catch unreachable;

    self.lib = b.addSharedLibrary(.{
        .name = options.name,
        .root_source_file = options.root_source_file,
        .version = options.version,
        .optimize = options.optimize,
        .target = options.target,
    });

    const install_artifact = b.addInstallArtifact(self.lib);
    const install_path = b.getInstallPath(.prefix, "vst");

    self.step = b.step("install-vst", "Install the VST plugin");
    self.step.dependOn(&self.lib.step);
    self.step.dependOn(&install_artifact.step);

    const options_step = b.addOptions();
    options_step.addOption([]const u8, "log_path", b.pathFromRoot("output.log"));
    self.lib.addModule("vst-options", options_step.createModule());

    switch (options.target.os_tag orelse b.host.target.os.tag) {
        .macos => {
            const vst_name = b.fmt("{s}.vst", .{options.name});
            const path = b.pathJoin(&.{ install_path, vst_name });

            const version_string = if (options.version) |version|
                b.fmt("{}.{}.{}", .{
                    version.major,
                    version.minor,
                    version.patch,
                })
            else
                "unversioned";

            const plist = b.fmt(
                \\<?xml version="1.0" encoding="UTF-8"?>
                \\<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                \\<plist version="1.0">
                \\    <dict>
                \\        <key>CFBundleDevelopmentRegion</key>
                \\        <string>{s}</string>
                \\        <key>CFBundleExecutable</key>
                \\        <string>{s}</string>
                \\        <key>CFBundleIdentifier</key>
                \\        <string>{s}</string>
                \\        <key>CFBundleInfoDictionaryVersion</key>
                \\        <string>6.0</string>
                \\        <key>CFBundleName</key>
                \\        <string>{s}</string>
                \\        <key>CFBundlePackageType</key>
                \\        <string>BNDL</string>
                \\        <key>CFBundleSignature</key>
                \\        <string>{s}</string>
                \\        <key>CFBundleVersion</key>
                \\        <string>{s}</string>
                \\        <key>CFBundleShortVersionString</key>
                \\        <string>{s}</string>
                \\        <key>CFBundleGetInfoString</key>
                \\        <string>TODO</string>
                \\    </dict>
                \\</plist>
                \\
            ,
                .{
                    "English",
                    options.name,
                    if (options.macos) |m| m.bundle_identifier else "",
                    options.name,
                    "????",
                    version_string,
                    version_string,
                },
            );

            const plist_name = b.pathJoin(&.{ path, "Contents/Info.plist" });
            const plist_step = b.addWriteFile(plist_name, plist);

            const pkg_info_name = b.pathJoin(&.{ path, "Contents/PkgInfo" });
            const pkg_info_step = b.addWriteFile(pkg_info_name, "BNDL????");

            self.step.dependOn(&plist_step.step);
            self.step.dependOn(&pkg_info_step.step);

            const bin_path = b.pathJoin(&.{ "vst", vst_name, "Contents/MacOS" });
            install_artifact.dest_dir = .{ .custom = bin_path };
            install_artifact.dest_sub_path = options.name;
        },
        else => {
            install_artifact.dest_dir = .lib;
        },
    }

    return self;
}
