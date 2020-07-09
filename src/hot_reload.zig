const std = @import("std");
const api = @import("api.zig");
const EmbedInfo = @import("main.zig").EmbedInfo;

var log_file: ?std.fs.File = null;
var log_allocator = std.heap.page_allocator;

/// The function that gets called when the child plugin
/// is first initialized.
pub const HotReloadInit = fn (
    embed_info: *EmbedInfo,
    log_fn: HotReloadLog,
) callconv(.Cold) bool;

/// The function that gets called when the child plugin
/// is about to be destroyed.
pub const HotReloadDeinit = fn (
    embed_info: *EmbedInfo,
) callconv(.Cold) void;

/// The function that gets called when the child plugin
/// has already been initialized and is just getting updated.
/// Currently we use this to check which AEffect properties
/// were changed and don't work with hot reloads.
pub const HotReloadUpdate = fn (
    embed_info: *EmbedInfo,
    log_fn: HotReloadLog,
) callconv(.Cold) bool;

/// This function get passed _from_ the hot reload wrapper
/// to the child plugin. The latter can then use it to
/// write to a common log stream across reloads.
/// I guess this could be done inside the child plugin itself,
/// but this seems more convenient.
pub const HotReloadLog = fn (
    ptr: [*]u8,
    len: usize,
) callconv(.Fastcall) void;

pub const MetaInfo = struct {
    watch_path: []const u8,
    log_file_path: []const u8,
};

/// Used during reloads to track how many VST calls were missed.
const ReloadDiagnostics = struct {
    // TODO Maybe track which opcode got skipped
    skipped_dispatcher: usize = 0,
    skipped_get_parameter: usize = 0,
    skipped_set_parameter: usize = 0,
    skipped_process_replacing: usize = 0,
    skipped_process_replacing_f64: usize = 0,

    pub fn format(
        diagnostics: ReloadDiagnostics,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: var,
    ) !void {
        try writer.print("\n\t Skipped dispatcher calls: {}", .{diagnostics.skipped_dispatcher});
        try writer.print("\n\t Skipped get_parameter calls: {}", .{diagnostics.skipped_get_parameter});
        try writer.print("\n\t Skipped set_parameter calls: {}", .{diagnostics.skipped_set_parameter});
        try writer.print("\n\t Skipped process_replacing calls: {}", .{diagnostics.skipped_process_replacing});
        try writer.print("\n\t Skipped process_replacing_f64 calls: {}", .{diagnostics.skipped_process_replacing_f64});
    }
};

pub const ChildInfo = struct {
    /// A reference to the shared library of the child plugin.
    lib: *std.DynLib,
    init: HotReloadInit,
    deinit: HotReloadDeinit,
    update: HotReloadUpdate,

    dispatcher: api.DispatcherCallback,
    set_parameter: api.SetParameterCallback,
    get_parameter: api.GetParameterCallback,
    process_replacing: api.ProcessCallback,
    process_replacing_f64: api.ProcessCallbackF64,
};

/// Simple reference counter.
const Arc = struct {
    int: std.atomic.Int(usize),

    pub fn init() Arc {
        return Arc{
            .int = std.atomic.Int(usize).init(0),
        };
    }

    pub fn acquire(self: *Arc) void {
        _ = self.int.incr();
    }

    pub fn release(self: *Arc) void {
        _ = self.int.decr();
    }

    pub fn isLocked(self: *Arc) bool {
        return self.int.get() > 0;
    }
};

/// Tracks which plugin functions are currently running.
/// None of these should ever have a value higher than 1.
/// I could just use a bool then, but I want to know when
/// shit hits the fan.
pub const WhatsRunning = struct {
    dispatcher: Arc = Arc.init(),
    set_parameter: Arc = Arc.init(),
    get_parameter: Arc = Arc.init(),
    process_replacing: Arc = Arc.init(),
    process_replacing_f64: Arc = Arc.init(),

    pub fn isLocked(self: *WhatsRunning) bool {
        return self.dispatcher.isLocked() or self.set_parameter.isLocked() or
            self.get_parameter.isLocked() or self.process_replacing.isLocked() or self.process_replacing_f64.isLocked();
    }
};

pub fn HotReloadWrapper(meta: MetaInfo) type {
    return struct {
        const Self = @This();

        var reload_diagnostics: ?*ReloadDiagnostics = null;

        meta: MetaInfo,
        allocator: *std.mem.Allocator,
        embed_info: EmbedInfo,
        child_info: ?ChildInfo,
        watch_thread: *std.Thread,
        stop_watching: bool,
        execute_noops: bool = false,
        whats_running: WhatsRunning,

        /// TODO Remove the dummy argument once https://github.com/ziglang/zig/issues/5380
        ///      gets fixed
        pub fn generateExports(comptime dummy: void) void {
            @export(VSTPluginMain, .{
                .name = "VSTPluginMain",
                .linkage = .Strong,
            });
        }

        /// No-Op functions that are called when no child plugin is currently loaded.
        /// This happens during reloads, between when the old one is unloaded and
        /// the new one is initialized.
        ///
        /// If reload_diagnostics is a valid pointer, these functions will increment
        /// the respective counters.
        pub const Noops = struct {
            fn dispatcher(effect: *api.AEffect, opcode: i32, index: i32, value: isize, ptr: ?*c_void, opt: f32) callconv(.C) isize {
                if (reload_diagnostics) |diag|
                    diag.skipped_dispatcher += 1;

                return 0;
            }

            fn setParameter(effect: *api.AEffect, index: i32, parameter: f32) callconv(.C) void {
                if (reload_diagnostics) |diag|
                    diag.skipped_set_parameter += 1;
            }

            fn getParameter(effect: *api.AEffect, indeX: i32) callconv(.C) f32 {
                if (reload_diagnostics) |diag|
                    diag.skipped_get_parameter += 1;

                return 0;
            }

            fn processReplacing(effect: *api.AEffect, inputs: [*][*]f32, outputs: [*][*]f32, sample_frames: i32) callconv(.C) void {
                if (reload_diagnostics) |diag|
                    diag.skipped_process_replacing += 1;
            }

            fn processReplacingF64(effect: *api.AEffect, inputs: [*][*]f64, outputs: [*][*]f64, sample_frames: i32) callconv(.C) void {
                if (reload_diagnostics) |diag|
                    diag.skipped_process_replacing_f64 += 1;
            }
        };

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

                    const now = std.time.milliTimestamp();
                    const data2 = std.fmt.allocPrint(log_allocator, "[{d}, {}, {}] {}", .{
                        now,
                        scope,
                        level,
                        data,
                    }) catch return;
                    defer log_allocator.free(data2);

                    if (log_file) |file| {
                        file.writeAll(data2) catch return;
                    }

                    std.debug.print("{}", .{data2});
                }
            };
        }

        fn VSTPluginMain(callback: api.HostCallback) callconv(.C) ?*api.AEffect {
            // Open the log file as early as possible
            const cwd = std.fs.cwd();
            log_file = cwd.createFile(meta.log_file_path, .{}) catch return null;

            // TODO Find out if we can move this allocator to the heap and pass
            //      it to the child plugin.
            var allocator = std.heap.page_allocator;
            var self = allocator.create(Self) catch unreachable;

            self.stop_watching = false;
            self.execute_noops = false;
            self.whats_running = .{};
            self.meta = meta;
            self.allocator = allocator;
            self.embed_info = .{
                .host_callback = callback,
                .effect = undefined,
            };

            const lib_path = self.readLibPath() catch |err| {
                std.log.emerg(.vst_hot_reload, "Failed to read lib_path from \"{}\": {}\n", .{ self.meta.watch_path, err });
                return null;
            };
            defer allocator.free(lib_path);

            self.reload(lib_path) catch |err| {
                std.log.emerg(.vst_hot_reload, "Failed to load library \"{}\": {}\n", .{ lib_path, err });
                return null;
            };

            self.watch_thread = std.Thread.spawn(self, checkLoopNoError) catch |err| {
                std.log.emerg(.vst_hot_reload, "Failed to spawn watch thread: {}\n", .{err});
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

        /// Gets passed to the child plugin. See HotReloadLog.
        fn externalWriteLog(ptr: [*]u8, len: usize) callconv(.Fastcall) void {
            var data: []u8 = undefined;
            data.ptr = ptr;
            data.len = len;
            std.debug.print("{}", .{data});

            if (log_file) |file| {
                file.writeAll(data) catch return;
            }
        }

        /// Read the location of the shared library from the watch file.
        fn readLibPath(self: *Self) ![]const u8 {
            const cwd = std.fs.cwd();
            var watch_file = try cwd.openFile(self.meta.watch_path, .{});
            defer watch_file.close();

            var stat = try watch_file.stat();
            var buffer = try self.allocator.alloc(u8, stat.size);

            _ = try watch_file.readAll(buffer);

            return buffer;
        }

        fn reload(self: *Self, lib_path: []const u8) !void {
            var reload_timer = try std.time.Timer.start();
            var diagnostics = ReloadDiagnostics{};
            reload_diagnostics = &diagnostics;
            defer {
                reload_diagnostics = null;
                const reload_took = reload_timer.read();
                const reload_took_ms = @intToFloat(f64, reload_took) / std.time.ns_per_ms;
                std.log.debug(.vst_hot_reload, "Reload took {d:.2}ms {}\n", .{ reload_took_ms, diagnostics });
            }

            const first_init = self.child_info == null;
            self.unloadChild();

            var lib = try self.allocator.create(std.DynLib);
            lib.* = try std.DynLib.open(lib_path);

            try self.loadChild(lib, first_init);
        }

        fn loadChild(self: *Self, lib: *std.DynLib, call_init: bool) !void {
            var child_info = ChildInfo{
                .lib = lib,
                .init = lib.lookup(HotReloadInit, "VSTHotReloadInit") orelse return error.MissingExport,
                .deinit = lib.lookup(HotReloadDeinit, "VSTHotReloadDeinit") orelse return error.MissingExport,
                .update = lib.lookup(HotReloadUpdate, "VSTHotReloadUpdate") orelse return error.MissingExport,

                .dispatcher = undefined,
                .set_parameter = undefined,
                .get_parameter = undefined,
                .process_replacing = undefined,
                .process_replacing_f64 = undefined,
            };

            var embed_info = try self.allocator.create(EmbedInfo);
            embed_info.* = self.embed_info;

            if (call_init) {
                std.log.debug(.vst_hot_reload, "Calling VSTHotReloadInit\n", .{});
                const result = child_info.init(embed_info, externalWriteLog);
                if (!result) return error.VSTHotReloadInitFailed;
            } else {
                std.log.debug(.vst_hot_reload, "Calling VSTHotReloadUpdate\n", .{});
                const result = child_info.update(embed_info, externalWriteLog);
                if (!result) return error.VSTHotReloadUpdateFailed;
            }

            const effect = embed_info.effect;
            child_info.dispatcher = effect.dispatcher;
            child_info.set_parameter = effect.setParameter;
            child_info.get_parameter = effect.getParameter;
            child_info.process_replacing = effect.processReplacing;
            child_info.process_replacing_f64 = effect.processReplacingF64;

            self.embed_info.effect = .{
                .dispatcher = dispatchWrapper,
                .setParameter = setParameterWrapper,
                .getParameter = getParameterWrapper,
                .processReplacing = processReplacingWrapper,
                .processReplacingF64 = processReplacingWrapperF64,
                .num_programs = effect.num_programs,
                .num_params = effect.num_params,
                .num_inputs = effect.num_inputs,
                .num_outputs = effect.num_outputs,
                .flags = effect.flags,
                .initial_delay = effect.initial_delay,
                .unique_id = effect.unique_id,
                .version = effect.version,
            };

            // TODO Pass the actual embed_info pointer to the plugin
            self.embed_info.custom_ref = embed_info.custom_ref;
            self.child_info = child_info;
            self.execute_noops = false;
        }

        fn unloadChild(self: *Self) void {
            var child_info = self.child_info orelse return;

            std.log.debug(.vst_hot_reload, "Running noops from now on\n", .{});
            self.execute_noops = true;

            // We need to make sure that no plugin function is running when we call
            // deinit.
            while (self.whats_running.isLocked()) {
                std.log.debug(.hot_reload, "Waiting for: {}\n", .{self.whats_running});
                std.time.sleep(1 * std.time.ns_per_ms);
            }

            std.log.debug(.vst_hot_reload, "Calling VSTHotReloadDeinit\n", .{});

            child_info.deinit(&self.embed_info);
            child_info.lib.close();
            self.allocator.destroy(child_info.lib);

            self.child_info = null;
        }

        fn checkLoopNoError(self: *Self) void {
            self.checkLoop() catch |err| {
                std.log.emerg(.vst_hot_reload, "checkLoop failed: {}\n", .{err});
            };
        }

        fn checkLoop(self: *Self) !void {
            const cwd = std.fs.cwd();
            var maybe_last: ?i128 = null;

            while (!self.stop_watching) {
                std.time.sleep(1 * std.time.ns_per_s);

                // TODO If a reload is currently in process we need
                //      to wait for that first.

                // TODO When you delete zig-cache this call fails, so you have
                //      to restart the plugin to have automatic reloads again.
                const watch_file = try cwd.openFile(self.meta.watch_path, .{});
                defer watch_file.close();

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

        fn dispatchWrapper(
            effect: *api.AEffect,
            opcode: i32,
            index: i32,
            value: isize,
            ptr: ?*c_void,
            opt: f32,
        ) callconv(.C) isize {
            var self = fromEffectPtr(effect);

            if (opcode == 1) {
                // TODO Handle Shutdown
            }

            return self.callOrNoop("dispatcher", Noops.dispatcher, .{
                effect, opcode, index, value, ptr, opt,
            });
        }

        fn setParameterWrapper(effect: *api.AEffect, index: i32, parameter: f32) callconv(.C) void {
            var self = fromEffectPtr(effect);

            self.callOrNoop("set_parameter", Noops.setParameter, .{
                effect, index, parameter,
            });
        }

        fn getParameterWrapper(effect: *api.AEffect, index: i32) callconv(.C) f32 {
            var self = fromEffectPtr(effect);

            return self.callOrNoop("get_parameter", Noops.getParameter, .{
                effect, index,
            });
        }

        fn processReplacingWrapper(
            effect: *api.AEffect,
            inputs: [*][*]f32,
            outputs: [*][*]f32,
            sample_frames: i32,
        ) callconv(.C) void {
            var self = fromEffectPtr(effect);

            self.callOrNoop("process_replacing", Noops.processReplacing, .{
                effect, inputs, outputs, sample_frames,
            });
        }

        fn processReplacingWrapperF64(
            effect: *api.AEffect,
            inputs: [*][*]f64,
            outputs: [*][*]f64,
            sample_frames: i32,
        ) callconv(.C) void {
            var self = fromEffectPtr(effect);

            self.callOrNoop("process_replacing_f64", Noops.processReplacingF64, .{
                effect, inputs, outputs, sample_frames,
            });
        }

        fn fromEffectPtr(effect: *api.AEffect) *Self {
            const embed_info = @fieldParentPtr(EmbedInfo, "effect", effect);
            return @fieldParentPtr(Self, "embed_info", embed_info);
        }

        fn callOrNoop(self: *Self, comptime name: []const u8, noop: var, args: var) return_type: {
            break :return_type @typeInfo(@TypeOf(noop)).Fn.return_type.?;
        } {
            const arc = &@field(self.whats_running, name);

            if (self.execute_noops) {
                return @call(.{}, noop, args);
            } else if (self.child_info == null) {
                std.log.warn(.vst_hot_reload, "Had to unexepectedly call noop for {}\n", .{name});
                return @call(.{}, noop, args);
            } else {
                arc.acquire();
                defer arc.release();

                return @call(.{}, @field(self.child_info.?, name), args);
            }
        }
    };
}
