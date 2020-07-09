const std = @import("std");
const trait = std.meta.trait;

pub const api = @import("api.zig");
pub const build_util = @import("build_util.zig");
pub const hot_reload = @import("hot_reload.zig");
pub const audio_io = @import("audio_io.zig");

pub const Info = struct {
    /// The unique ID of the VST Plugin
    id: i32,

    /// The version of the VST Plugin
    version: [4]u8,

    /// The name of the VST Plugin
    name: []const u8 = "",

    /// The vendor of the VST Plugin
    vendor: []const u8 = "",

    /// The amount of audio outputs
    /// The initial delay in samples until the plugin produces output.
    delay: usize = 0,

    flags: []const api.Plugin.Flag,

    category: api.Plugin.Category = .Unknown,

    /// The layout of the input buffers this plugin accepts.
    input: audio_io.IOLayout,

    /// The layout of the output buffers this plugin accepts.
    output: audio_io.IOLayout,

    fn versionToI32(self: Info) i32 {
        const v = self.version;

        return (@as(i32, v[0]) << 24) | (@as(i32, v[1]) << 16) | (@as(i32, v[2]) << 8) | @as(i32, v[3]);
    }
};

pub const EmbedInfo = struct {
    effect: api.AEffect,
    host_callback: api.HostCallback,

    // TODO I'm not happy with this yet. It feels kinda clunky.
    custom_ref: ?*c_void = null,

    pub fn query(
        self: *EmbedInfo,
        code: api.Codes.PluginToHost,
        index: i32,
        value: isize,
        ptr: ?*c_void,
        opt: f32,
    ) isize {
        return self.queryRaw(code.toInt(), index, value, ptr, opt);
    }

    pub fn queryRaw(
        self: *EmbedInfo,
        opcode: i32,
        index: i32,
        value: isize,
        ptr: ?*c_void,
        opt: f32,
    ) isize {
        return self.host_callback(&self.effect, opcode, index, value, ptr, opt);
    }

    fn setCustomRef(self: *EmbedInfo, ptr: var) void {
        self.custom_ref = @ptrCast(*c_void, ptr);
    }

    fn clearCustomRef(self: *EmbedInfo) void {
        self.custom_ref = null;
    }

    fn getCustomRef(self: *EmbedInfo, comptime T: type) ?*T {
        if (self.custom_ref) |ptr| {
            return @ptrCast(*T, @alignCast(@alignOf(T), ptr));
        }

        return null;
    }
};

pub fn VstPlugin(comptime info_arg: Info, comptime T: type) type {
    return struct {
        pub const Inner = T;
        pub const info = info_arg;
        const Self = @This();

        var log_allocator = std.heap.page_allocator;
        var external_write_log: ?hot_reload.HotReloadLog = null;

        inner: T,
        allocator: *std.mem.Allocator,

        /// TODO Remove the dummy argument once https://github.com/ziglang/zig/issues/5380
        ///      gets fixed
        pub fn generateExports(comptime dummy: void) void {
            comptime std.debug.assert(@TypeOf(VSTPluginMain) == api.PluginMain);
            @export(VSTPluginMain, .{
                .name = "VSTPluginMain",
                .linkage = .Strong,
            });

            comptime std.debug.assert(@TypeOf(VSTHotReloadInit) == hot_reload.HotReloadInit);
            @export(VSTHotReloadInit, .{
                .name = "VSTHotReloadInit",
                .linkage = .Strong,
            });

            comptime std.debug.assert(@TypeOf(VSTHotReloadDeinit) == hot_reload.HotReloadDeinit);
            @export(VSTHotReloadDeinit, .{
                .name = "VSTHotReloadDeinit",
                .linkage = .Strong,
            });

            comptime std.debug.assert(@TypeOf(VSTHotReloadUpdate) == hot_reload.HotReloadUpdate);
            @export(VSTHotReloadUpdate, .{
                .name = "VSTHotReloadUpdate",
                .linkage = .Strong,
            });
        }

        /// This will set up a log handler, which you should probably do
        /// when you make use of hot reloads.
        pub fn generateTopLevelHandlers() type {
            // TODO How do we handle logging in standalone mode?
            return struct {
                pub fn log(
                    comptime level: std.log.Level,
                    comptime scope: @TypeOf(.EnumLiteral),
                    comptime format: []const u8,
                    args: var,
                ) void {
                    if (external_write_log) |log_fn| {
                        const data = std.fmt.allocPrint(log_allocator, format, args) catch return;
                        defer log_allocator.free(data);

                        log_fn(data.ptr, data.len);
                    }
                }
            };
        }

        fn VSTHotReloadInit(embed_info: *EmbedInfo, log_fn: hot_reload.HotReloadLog) callconv(.Cold) bool {
            external_write_log = log_fn;
            embed_info.effect = initAEffect();

            var self = init(std.heap.page_allocator, embed_info) catch return false;

            return true;
        }

        fn VSTHotReloadDeinit(embed_info: *EmbedInfo) callconv(.Cold) void {
            var self = embed_info.getCustomRef(Self) orelse return;
            self.deinit();
        }

        fn VSTHotReloadUpdate(embed_info: *EmbedInfo, log_fn: hot_reload.HotReloadLog) callconv(.Cold) bool {
            external_write_log = log_fn;
            const old_effect = embed_info.*.effect;
            embed_info.effect = initAEffect();
            var self = init(std.heap.page_allocator, embed_info) catch return false;

            // TODO Find out which properties can be updated. Especially, what
            //      about num_params? Since the hot reload feature is only
            //      intended for development we might be able to get away with
            //      pre-defining a huge amount of parameters and just have
            //      the majority of them be unused and labelled as such.
            //      If that works: Are we able to tell the host to reload the
            //      parameters? If I add a new one I want its name to show up
            //      in the DAW.

            const new_effect = embed_info.effect;

            if (old_effect.version != new_effect.version) {
                std.log.warn(.zig_vst, "You can't change the plugin version between hot reloads\n", .{});
            }

            if (old_effect.flags != new_effect.flags) {
                std.log.warn(.zig_vst, "You can't change the plugin flags between hot reloads\n", .{});
            }

            if (old_effect.unique_id != new_effect.unique_id) {
                std.log.warn(.zig_vst, "You can't change the plugin unique_id between hot reloads\n", .{});
            }

            if (old_effect.initial_delay != new_effect.initial_delay) {
                std.log.warn(.zig_vst, "You can't change the plugin initial_delay between hot reloads\n", .{});
            }

            if (old_effect.num_inputs != new_effect.num_inputs or old_effect.num_outputs != new_effect.num_outputs) {
                // TODO Find out if this works
                _ = embed_info.query(.IOChanged, 0, 0, null, 0);
            }

            return true;
        }

        fn VSTPluginMain(callback: api.HostCallback) callconv(.C) ?*api.AEffect {
            var allocator = std.heap.page_allocator;

            // TODO Maybe the VSTPluginMain should not initialize the inner
            //      value. Otherwise it always gets called, even when the
            //      VST host is just reading basic information.

            var embed_info = allocator.create(EmbedInfo) catch return null;
            embed_info.host_callback = callback;
            embed_info.effect = initAEffect();

            var self = init(allocator, embed_info) catch return null;

            return &embed_info.effect;
        }

        fn initAEffect() api.AEffect {
            return .{
                .dispatcher = dispatcherCallback,
                .setParameter = setParameterCallback,
                .getParameter = getParameterCallback,
                .processReplacing = processReplacingCallback,
                .processReplacingF64 = processReplacingCallbackF64,
                .num_programs = 0,
                .num_params = 0,
                .num_inputs = info.input.len,
                .num_outputs = info.output.len,
                .flags = api.Plugin.Flag.toBitmask(info.flags),
                .initial_delay = info.delay,
                .unique_id = info.id,
                .version = info.versionToI32(),
            };
        }

        fn init(allocator: *std.mem.Allocator, embed_info: *EmbedInfo) !*Self {
            var self = try allocator.create(Self);
            embed_info.setCustomRef(self);

            self.allocator = allocator;

            var effect = &embed_info.effect;
            effect.dispatcher = dispatcherCallback;
            effect.setParameter = setParameterCallback;
            effect.getParameter = getParameterCallback;
            effect.processReplacing = processReplacingCallback;
            effect.processReplacingF64 = processReplacingCallbackF64;

            const type_info = @typeInfo(@TypeOf(T.create)).Fn;
            const returns_error = comptime trait.is(.ErrorUnion)(type_info.return_type.?);
            const takes_allocator = comptime blk_takes_allocator: {
                const args = type_info.args;
                break :blk_takes_allocator args.len == 2 and args[1].arg_type == *std.mem.Allocator;
            };

            if (!takes_allocator and !returns_error) {
                T.create(&self.inner);
            } else if (takes_allocator and !returns_error) {
                T.create(&self.inner, allocator);
            } else if (!takes_allocator and returns_error) {
                try T.create(&self.inner);
            } else if (takes_allocator and returns_error) {
                try T.create(&self.inner, allocator);
            }

            return self;
        }

        fn deinit(self: *Self) void {
            if (comptime trait.hasFn("deinit")(T)) {
                T.deinit(&self.inner);
            }

            self.allocator.destroy(self);
        }

        fn fromEffectPtr(effect: *api.AEffect) ?*Self {
            const embed_info = @fieldParentPtr(EmbedInfo, "effect", effect);
            return embed_info.getCustomRef(Self);
        }

        fn dispatcherCallback(effect: *api.AEffect, opcode: i32, index: i32, value: isize, ptr: ?*c_void, opt: f32) callconv(.C) isize {
            const self = fromEffectPtr(effect) orelse unreachable;
            const code = api.Codes.HostToPlugin.fromInt(opcode) catch return -1;

            switch (code) {
                .Initialize => {},
                .Shutdown => self.deinit(),
                .GetProductName => setData(ptr.?, info.name, api.ProductNameMaxLength),
                .GetVendorName => setData(ptr.?, info.vendor, api.VendorNameMaxLength),
                .GetCategory => return info.category.toI32(),
                .GetApiVersion => return 2400,
                .GetTailSize => return 0,
                .SetSampleRate => {},
                .SetBufferSize => {},
                .StateChange => {},
                .GetInputInfo => {
                    std.log.debug(.zig_vst, "GetInputInfo\n", .{});
                },
                .GetOutputInfo => {
                    std.log.debug(.zig_vst, "GetOutputInfo\n", .{});
                },
                else => {},
            }

            return 0;
        }

        fn setParameterCallback(effect: *api.AEffect, index: i32, parameter: f32) callconv(.C) void {}

        fn getParameterCallback(effect: *api.AEffect, index: i32) callconv(.C) f32 {
            return 0;
        }

        fn processReplacingCallback(effect: *api.AEffect, inputs: [*][*]f32, outputs: [*][*]f32, sample_frames: i32) callconv(.C) void {
            const frames = @intCast(usize, sample_frames);

            var input = audio_io.AudioBuffer(info.input, f32).fromRaw(inputs, sample_frames);
            var output = audio_io.AudioBuffer(info.output, f32).fromRaw(outputs, sample_frames);

            const self = fromEffectPtr(effect) orelse return;
            self.inner.process(&input, &output);
        }

        fn processReplacingCallbackF64(effect: *api.AEffect, inputs: [*][*]f64, outputs: [*][*]f64, sample_frames: i32) callconv(.C) void {}
    };
}

/// Copy data to the given location. The max_length parameter should include 1
/// byte for a null character. So if you pass a max_length of 64 a maximum of
/// 63 bytes will be copied from the data.
/// The indices from data.len until max_length will be filled with zeroes.
fn setData(ptr: *c_void, data: []const u8, max_length: usize) void {
    const buf_ptr = @ptrCast([*]u8, ptr);
    const copy_len = std.math.min(max_length - 1, data.len);

    @memcpy(buf_ptr, data.ptr, copy_len);
    std.mem.set(u8, buf_ptr[copy_len..max_length], 0);
}

test "setData" {
    var raw_data = [_]u8{0xaa} ** 20;
    var c_ptr = @ptrCast(*c_void, &raw_data);
    setData(c_ptr, "Hello World!", 15);

    const correct = "Hello World!" ++ [_]u8{0} ** 3 ++ [_]u8{0xaa} ** 5;
    std.testing.expect(std.mem.eql(u8, &raw_data, correct));

    std.mem.set(u8, &raw_data, 0xaa);
    setData(c_ptr, "This is a very long string. Too long, in fact!", 20);

    const correct2 = "This is a very long" ++ [_]u8{0};
    std.testing.expectEqual(20, correct2.len);
    std.testing.expect(std.mem.eql(u8, &raw_data, correct2));
}
