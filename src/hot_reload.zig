const std = @import("std");
const api = @import("api.zig");
const EmbedInfo = @import("main.zig").EmbedInfo;

var log_file: ?std.fs.File = null;
var log_allocator = std.heap.page_allocator;

pub const HotReloadInit = fn (
    embed_info: *EmbedInfo,
    log_fn: HotReloadLog,
) callconv(.Cold) bool;

pub const HotReloadDeinit = fn (
    embed_info: *EmbedInfo,
) callconv(.Cold) void;

pub const HotReloadUpdate = fn (
    embed_info: *EmbedInfo,
    log_fn: HotReloadLog,
) callconv(.Cold) bool;

pub const HotReloadLog = fn (
    ptr: [*]u8,
    len: usize,
) callconv(.Fastcall) void;

pub const MetaInfo = struct {
    watch_path: []const u8,
    log_file_path: []const u8,
};

// TODO Maybe these functions should log that they got called
pub const Noops = struct {
    fn dispatcher(effect: *api.AEffect, opcode: i32, index: i32, value: isize, ptr: ?*c_void, opt: f32) callconv(.C) isize {
        return 0;
    }

    fn setParameter(effect: *api.AEffect, index: i32, parameter: f32) callconv(.C) void {}

    fn getParameter(effect: *api.AEffect, indeX: i32) callconv(.C) f32 {
        return 0;
    }

    fn processReplacing(effect: *api.AEffect, inputs: [*c][*c]f32, outputs: [*c][*c]f32, sample_frames: i32) callconv(.C) void {}

    fn processReplacingF64(effect: *api.AEffect, inputs: [*c][*c]f64, outputs: [*c][*c]f64, sample_frames: i32) callconv(.C) void {}
};

pub fn HotReloadWrapper(meta: MetaInfo) type {
    return struct {
        const Self = @This();

        meta: MetaInfo,
        allocator: *std.mem.Allocator,
        embed_info: EmbedInfo,
        child_info: ?ChildInfo,
        watch_thread: *std.Thread,
        stop_watching: bool = false,

        pub const ChildInfo = struct {
            lib: *std.DynLib,
            init: HotReloadInit,
            deinit: HotReloadDeinit,
            update: HotReloadUpdate,
            dispatcher: api.DispatcherCallback,
        };

        /// TODO Remove the dummy argument once https://github.com/ziglang/zig/issues/5380
        ///      gets fixed
        pub fn generateExports(comptime dummy: void) void {
            @export(VSTPluginMain, .{
                .name = "VSTPluginMain",
                .linkage = .Strong,
            });
        }

        pub fn generateTopLevelHandlers() type {
            return struct {
                pub fn log(
                    comptime level: std.log.Level,
                    comptime scope: @TypeOf(.EnumLiteral),
                    comptime format: []const u8,
                    args: var,
                ) void {
                    const data = std.fmt.allocPrint(log_allocator, format, args) catch return;
                    defer log_allocator.free(data);
                    if (log_file) |file| {
                        file.writeAll(data) catch return;
                    }

                    std.debug.print("{}", .{data});
                }

                pub fn panic(err: []const u8, maybe_trace: ?*std.builtin.StackTrace) noreturn {
                    if (log_file) |file| {
                        file.writeAll(err) catch {};

                        if (maybe_trace) |trace| {
                            const data = std.fmt.allocPrint(log_allocator, "{}", .{trace}) catch "";
                            file.writeAll(data) catch {};
                        }
                    }

                    while (true) {
                        @breakpoint();
                    }
                }
            };
        }

        fn VSTPluginMain(callback: api.HostCallback) callconv(.C) ?*api.AEffect {
            // Open the log file as early as possible
            const cwd = std.fs.cwd();
            log_file = cwd.createFile(meta.log_file_path, .{}) catch return null;

            var allocator = std.heap.page_allocator;
            var self = allocator.create(Self) catch unreachable;

            self.stop_watching = false;
            self.meta = meta;
            self.allocator = allocator;
            self.embed_info = .{
                .host_callback = callback,
                .effect = undefined,
            };

            const lib_path = self.readLibPath() catch |err| {
                std.log.emerg(.hot_reload_wrapper, "Failed to read lib_path from \"{}\": {}\n", .{ self.meta.watch_path, err });
                return null;
            };
            defer allocator.free(lib_path);

            self.reload(lib_path) catch |err| {
                std.log.emerg(.hot_reload_wrapper, "Failed to load library \"{}\": {}\n", .{ lib_path, err });
                return null;
            };

            self.watch_thread = std.Thread.spawn(self, checkLoopNoError) catch |err| {
                std.log.emerg(.hot_reload_wrapper, "Failed to spawn watch thread: {}\n", .{err});
                return null;
            };

            return &self.embed_info.effect;
        }

        fn deinit(self: *Self) void {
            self.deinitChild();
            self.stop_watching = true;
            self.watch_thread.wait();
            self.allocator.destroy(self);
        }

        fn interceptShutdown(effect: *api.AEffect, opcode: i32, index: i32, value: isize, ptr: ?*c_void, opt: f32) callconv(.C) isize {
            var embed_info = @fieldParentPtr(EmbedInfo, "effect", effect);
            var self = @fieldParentPtr(Self, "embed_info", embed_info);

            switch (opcode) {
                // Shutdown
                1 => {
                    self.deinit();
                    return 0;
                },
                else => return self.child_info.?.dispatcher(effect, opcode, index, value, ptr, opt),
            }
        }

        fn externalWriteLog(ptr: [*]u8, len: usize) callconv(.Fastcall) void {
            var data: []u8 = undefined;
            data.ptr = ptr;
            data.len = len;
            std.debug.print("{}", .{data});

            if (log_file) |file| {
                file.writeAll(data) catch return;
            }
        }

        fn deinitChild(self: *Self) void {
            if (self.child_info) |child_info| {
                {
                    var effect = &self.embed_info.effect;

                    // Set these pointers to dummy functions
                    effect.dispatcher = Noops.dispatcher;
                    effect.setParameter = Noops.setParameter;
                    effect.getParameter = Noops.getParameter;
                    effect.processReplacing = Noops.processReplacing;
                    effect.processReplacingF64 = Noops.processReplacingF64;
                }

                child_info.deinit(&self.embed_info);

                child_info.lib.close();
                self.allocator.destroy(child_info.lib);
                self.child_info = null;
            }
        }

        fn readLibPath(self: *Self) ![]const u8 {
            const cwd = std.fs.cwd();
            var watch_file = try cwd.openFile(self.meta.watch_path, .{});

            var stat = try watch_file.stat();
            var buffer = try self.allocator.alloc(u8, stat.size);

            _ = try watch_file.readAll(buffer);

            return buffer;
        }

        fn reload(self: *Self, lib_path: []const u8) !void {
            var first_init = self.child_info == null;
            self.deinitChild();

            var lib = try self.allocator.create(std.DynLib);
            lib.* = try std.DynLib.open(lib_path);

            var child_info = ChildInfo{
                .lib = lib,
                .init = lib.lookup(HotReloadInit, "VSTHotReloadInit") orelse return error.VSTHotReloadInitNotFound,
                .deinit = lib.lookup(HotReloadDeinit, "VSTHotReloadDeinit") orelse return error.VSTHotReloadDeinitNotFound,
                .update = lib.lookup(HotReloadUpdate, "VSTHotReloadUpdate") orelse return error.VSTHotReloadUpdateNotFound,
                .dispatcher = undefined,
            };

            if (first_init) {
                const result = child_info.init(&self.embed_info, externalWriteLog);

                if (!result) {
                    return error.VSTHotReloadInitFailed;
                }
            } else {
                // TODO Copy the embed_info and the atomically swap
                const result = child_info.update(&self.embed_info, externalWriteLog);

                if (!result) {
                    return error.VSTHotReloadUpdateFailed;
                }
            }

            child_info.dispatcher = self.embed_info.effect.dispatcher;
            self.child_info = child_info;

            self.embed_info.effect.dispatcher = interceptShutdown;
        }

        fn checkLoopNoError(self: *Self) void {
            self.checkLoop() catch |err| {
                std.log.emerg(.hot_reload_wrapper, "checkLoop failed: {}\n", .{err});
            };
        }

        // TODO Implement
        fn checkLoop(self: *Self) !void {
            const cwd = std.fs.cwd();
            var maybe_last: ?i128 = null;

            while (!self.stop_watching) {
                std.time.sleep(1 * std.time.ns_per_s);

                const watch_file = try cwd.openFile(self.meta.watch_path, .{});
                const stat = try watch_file.stat();

                if (maybe_last) |mtime| {
                    if (stat.mtime > mtime) {
                        var lib_path = try self.allocator.alloc(u8, stat.size);
                        defer self.allocator.free(lib_path);
                        _ = try watch_file.readAll(lib_path);
                        try self.reload(lib_path);
                    }
                }

                maybe_last = stat.mtime;
            }
        }
    };
}
