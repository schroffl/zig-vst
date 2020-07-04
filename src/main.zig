const std = @import("std");

pub const api = @import("api.zig");

pub const Info = struct {
    /// The unique ID of the VST Plugin
    id: i32,

    /// The version of the VST Plugin
    version: [4]u8,

    /// The name of the VST Plugin
    name: []const u8 = "",

    /// The vendor of the VST Plugin
    vendor: []const u8 = "",

    /// The amount of audio inputs
    inputs: usize,

    /// The amount of audio outputs
    outputs: usize,

    /// The initial delay in samples until the plugin produces output.
    delay: usize = 0,

    flags: []const api.Plugin.Flag,

    category: api.Plugin.Category = .Unknown,

    fn versionToI32(self: Info) i32 {
        const v = self.version;

        return (@as(i32, v[0]) << 24) | (@as(i32, v[1]) << 16) | (@as(i32, v[2]) << 8) | @as(i32, v[3]);
    }
};

pub fn VstPlugin(comptime info: Info, comptime T: type) type {
    return struct {
        const Self = @This();

        inner: T,
        effect: api.AEffect,

        /// TODO Remove the dummy argument once https://github.com/ziglang/zig/issues/5380
        ///      gets fixed
        pub fn exportVSTPluginMain(comptime dummy: void) void {
            @export(VSTPluginMain, .{
                .name = "VSTPluginMain",
                .linkage = .Strong,
            });
        }

        fn VSTPluginMain(callback: api.HostCallback) callconv(.C) ?*api.AEffect {
            var allocator = std.heap.page_allocator;
            var instance = allocator.create(Self) catch return null;

            const takes_allocator = false;
            const returns_error = false;

            if (!takes_allocator and !returns_error) {
                instance.inner = T.init();
            } else if (takes_allocator and !returns_error) {
                instance.inner = T.init(allocator);
            } else if (!takes_allocator and returns_error) {
                instance.inner = T.init() catch return null;
            } else if (takes_allocator and returns_error) {
                instance.inner = T.init(allocator) catch return null;
            }

            instance.effect = .{
                .dispatcher = dispatcherCallback,
                .setParameter = setParameterCallback,
                .getParameter = getParameterCallback,
                .processReplacing = processReplacingCallback,
                .processReplacingF64 = processReplacingCallbackF64,
                .num_programs = 0,
                .num_params = 0,
                .num_inputs = info.inputs,
                .num_outputs = info.outputs,
                .flags = api.Plugin.Flag.toBitmask(info.flags),
                .initial_delay = info.delay,
                .unique_id = info.id,
                .version = info.versionToI32(),
            };

            std.debug.warn("{}\n", .{instance.effect});

            return &instance.effect;
        }

        fn dispatcherCallback(effect: *api.AEffect, opcode: i32, index: i32, value: isize, ptr: ?*c_void, opt: f32) callconv(.C) isize {
            std.debug.print("Got Opcode: {}\n", .{opcode});

            switch (opcode) {
                // GetProductName
                48 => {
                    setData(ptr.?, info.name, api.ProductNameMaxLength);
                },
                // GetVendorName
                47 => {
                    setData(ptr.?, info.vendor, api.VendorNameMaxLength);
                },
                // GetCategory
                35 => {
                    return @intCast(isize, @enumToInt(info.category));
                },
                // GetCategoryVersion
                58 => {
                    return 2400;
                },
                else => return 0,
            }

            return 0;
        }

        fn setParameterCallback(effect: *api.AEffect, index: i32, parameter: f32) callconv(.C) void {}

        fn getParameterCallback(effect: *api.AEffect, index: i32) callconv(.C) f32 {
            return 0;
        }

        fn processReplacingCallback(effect: *api.AEffect, inputs: [*c][*c]f32, outputs: [*c][*c]f32, sample_frames: i32) callconv(.C) void {
            const frames = @intCast(usize, sample_frames);

            const ins = inputs[0..info.inputs];
            const outs = outputs[0..info.outputs];
        }

        fn processReplacingCallbackF64(effect: *api.AEffect, inputs: [*c][*c]f64, outputs: [*c][*c]f64, sample_frames: i32) callconv(.C) void {}

        fn setData(ptr: *c_void, data: []const u8, max_length: usize) void {
            const buf_ptr = @ptrCast([*c]u8, ptr);
            const copy_len = std.math.min(max_length - 1, data.len);

            @memcpy(buf_ptr, data.ptr, copy_len);
            std.mem.set(u8, buf_ptr[copy_len..max_length], 0);
        }
    };
}

test "VstPlugin" {
    const Plugin = VstPlugin(
        Info{
            .id = [_]u8{ 1, 2, 3, 4 },
            .version = [_]u8{ 1, 2, 3, 4 },
            .name = "Test Plugin",
            .vendor = "Test Vendor",
            .inputs = 0,
            .outputs = 2,
            .delay = 0,
            .flags = &[_]api.Plugin.Flag{ .IsSynth, .CanReplacing },
        },
        struct {
            frequency: f32,

            // pub fn process(
        },
    );
}

test "" {
    _ = @import("api.zig");
}
