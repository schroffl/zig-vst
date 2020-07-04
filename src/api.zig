const std = @import("std");
const testing = std.testing;

pub const AEffect = extern struct {
    pub const Magic: i32 = ('V' << 24) | ('s' << 16) | ('t' << 8) | 'P';

    /// Magic bytes required to identify a VST Plugin
    magic: i32 = Magic,

    /// Host to Plugin Dispatcher
    dispatcher: DispatcherCallback,

    /// Deprecated in VST 2.4
    deprecated_process: ProcessCallback = deprecatedProcessCallback,

    setParameter: SetParameterCallback,

    getParameter: GetParameterCallback,

    num_programs: i32,

    num_params: i32,

    num_inputs: i32,

    num_outputs: i32,

    flags: i32,

    reserved1: isize = 0,

    reserved2: isize = 0,

    initial_delay: i32,

    _real_qualities: i32 = 0,

    _off_qualities: i32 = 0,

    _io_ratio: i32 = 0,

    object: ?*c_void = null,

    user: ?*c_void = null,

    unique_id: i32,

    version: i32,

    processReplacing: ProcessCallback,

    processReplacingF64: ProcessCallbackF64,

    future: [56]u8 = [_]u8{0} ** 56,

    fn deprecatedProcessCallback(effect: *AEffect, inputs: [*c][*c]f32, outputs: [*c][*c]f32, sample_frames: i32) callconv(.C) void {}
};

test "AEffect" {
    testing.expectEqual(@as(i32, 0x56737450), AEffect.Magic);
}

pub const Plugin = struct {
    pub const Flag = enum(i32) {
        HasEditor = 1,
        CanReplacing = 1 << 4,
        ProgramChunks = 1 << 5,
        IsSynth = 1 << 8,
        NoSoundInStop = 1 << 9,
        CanDoubleReplacing = 1 << 12,

        pub fn toBitmask(flags: []const Flag) i32 {
            var result: i32 = 0;

            for (flags) |flag| {
                result = result | @enumToInt(flag);
            }

            return result;
        }
    };

    pub const Category = enum(usize) {
        Unknown,
        Effect,
        Synthesizer,
        Analysis,
        Mastering,
        Spacializer,
        RoomFx,
        SurroundFx,
        Restoration,
        OfflineProcess,
        Shell,
        Generator,
    };
};

pub const ProductNameMaxLength = 64;
pub const VendorNameMaxLength = 64;

pub const PluginMain = fn (
    callback: HostCallback,
) callconv(.C) ?*AEffect;

pub const HostCallback = fn (
    effect: *AEffect,
    opcode: i32,
    index: i32,
    value: isize,
    ptr: ?*c_void,
    opt: f32,
) callconv(.C) isize;

pub const DispatcherCallback = fn (
    effect: *AEffect,
    opcode: i32,
    index: i32,
    value: isize,
    ptr: ?*c_void,
    opt: f32,
) callconv(.C) isize;

pub const ProcessCallback = fn (
    effect: *AEffect,
    inputs: [*c][*c]f32,
    outputs: [*c][*c]f32,
    sample_frames: i32,
) callconv(.C) void;

pub const ProcessCallbackF64 = fn (
    effect: *AEffect,
    inputs: [*c][*c]f64,
    outputs: [*c][*c]f64,
    sample_frames: i32,
) callconv(.C) void;

pub const SetParameterCallback = fn (
    effect: *AEffect,
    index: i32,
    parameter: f32,
) callconv(.C) void;

pub const GetParameterCallback = fn (
    effect: *AEffect,
    index: i32,
) callconv(.C) f32;
