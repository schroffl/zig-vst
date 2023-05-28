const std = @import("std");

pub const AEffect = extern struct {
    pub const Magic: i32 = ('V' << 24) | ('s' << 16) | ('t' << 8) | 'P';

    /// Magic bytes required to identify a VST Plugin
    magic: i32 = Magic,

    /// Host to Plugin Dispatcher
    dispatcher: *const DispatcherCallback,

    /// Deprecated in VST 2.4
    deprecated_process: *const ProcessCallback = deprecatedProcessCallback,

    setParameter: *const SetParameterCallback,

    getParameter: *const GetParameterCallback,

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

    object: ?*anyopaque = null,

    user: ?*anyopaque = null,

    unique_id: i32,

    version: i32,

    processReplacing: *const ProcessCallback,

    processReplacingF64: *const ProcessCallbackF64,

    future: [56]u8 = [_]u8{0} ** 56,

    fn deprecatedProcessCallback(effect: *AEffect, inputs: [*][*]f32, outputs: [*][*]f32, sample_frames: i32) callconv(.C) void {
        _ = effect;
        _ = inputs;
        _ = outputs;
        _ = sample_frames;
    }
};

pub const ProductNameMaxLength = 64;
pub const VendorNameMaxLength = 64;
pub const ParamMaxLength = 32;

pub const PluginMain = fn (
    callback: *const HostCallback,
) callconv(.C) ?*AEffect;

pub const HostCallback = fn (
    effect: *AEffect,
    opcode: i32,
    index: i32,
    value: isize,
    ptr: ?*anyopaque,
    opt: f32,
) callconv(.C) isize;

pub const DispatcherCallback = fn (
    effect: *AEffect,
    opcode: i32,
    index: i32,
    value: isize,
    ptr: ?*anyopaque,
    opt: f32,
) callconv(.C) isize;

pub const ProcessCallback = fn (
    effect: *AEffect,
    inputs: [*][*]f32,
    outputs: [*][*]f32,
    sample_frames: i32,
) callconv(.C) void;

pub const ProcessCallbackF64 = fn (
    effect: *AEffect,
    inputs: [*][*]f64,
    outputs: [*][*]f64,
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

pub const PluginFlags = packed struct(i32) {
    has_editor: bool = false,
    _unknown1: u3 = 0,
    can_replacing: bool = false,
    program_chunks: bool = false,
    _unknown2: u3 = 0,
    is_synth: bool = false,
    no_sound_in_stop: bool = false,
    _unknown3: u3 = 0,
    can_double_replacing: bool = false,
    _unknown4: u17 = 0,

    pub fn toInt(self: PluginFlags) i32 {
        return @bitCast(i32, self);
    }
};

pub const PluginCategory = enum {
    unknown,
    effect,
    synthesizer,
    analysis,
    mastering,
    spacializer,
    room_fx,
    surround_fx,
    restoration,
    offline_process,
    shell,
    generator,

    pub fn toInt(self: PluginCategory) i32 {
        return @intCast(i32, @enumToInt(self));
    }
};

pub const Rect = extern struct {
    top: i16,
    left: i16,
    bottom: i16,
    right: i16,
};

pub const Codes = struct {
    pub const HostToPlugin = enum(i32) {
        Initialize = 0,
        Shutdown = 1,
        GetCurrentPresetNum = 3,
        GetProductName = 48,
        GetVendorName = 47,
        GetInputInfo = 33,
        GetOutputInfo = 34,
        GetCategory = 35,
        GetTailSize = 52,
        GetApiVersion = 58,
        SetSampleRate = 10,
        SetBufferSize = 11,
        StateChange = 12,
        GetMidiInputs = 78,
        GetMidiOutputs = 79,
        GetMidiKeyName = 66,
        StartProcess = 71,
        StopProcess = 72,
        GetPresetName = 29,
        CanDo = 51,
        GetVendorVersion = 49,
        GetEffectName = 45,
        EditorGetRect = 13,
        EditorOpen = 14,
        EditorClose = 15,
        ChangePreset = 2,
        GetCurrentPresetName = 5,
        GetParameterLabel = 6,
        GetParameterDisplay = 7,
        GetParameterName = 8,
        CanBeAutomated = 26,
        EditorIdle = 19,
        EditorKeyDown = 59,
        EditorKeyUp = 60,
        ProcessEvents = 25,

        pub fn toInt(self: HostToPlugin) i32 {
            return @enumToInt(self);
        }

        pub fn fromInt(int: anytype) !HostToPlugin {
            return std.meta.intToEnum(HostToPlugin, int);
        }
    };

    pub const PluginToHost = enum(i32) {
        GetVersion = 1,
        IOChanged = 13,
        GetSampleRate = 16,
        GetBufferSize = 17,
        GetVendorString = 32,

        pub fn toInt(self: PluginToHost) i32 {
            return @enumToInt(self);
        }

        pub fn fromInt(int: anytype) !PluginToHost {
            return std.meta.intToEnum(HostToPlugin, int);
        }
    };
};

test {
    std.testing.refAllDecls(@This());
}
