const std = @import("std");
const VST = @import("src/main.zig");

const Synth = struct {
    pub fn init() Synth {
        return .{};
    }
};

const Plugin = VST.VstPlugin(.{
    .id = 0x30d98,
    .version = .{ 0, 0, 1, 0 },
    .name = "Example Zig VST",
    .vendor = "zig-vst",
    .inputs = 0,
    .outputs = 2,
    .delay = 0,
    .flags = &[_]VST.api.Plugin.Flags{ .IsSynth, .CanReplacing },
    .category = .Synthesizer,
}, Synth);

comptime {
    Plugin.exportVSTPluginMain({});
}
