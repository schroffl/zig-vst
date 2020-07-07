const std = @import("std");
const vst = @import("src/main.zig");

const Synth = struct {
    total_frames: usize = 0,
    frequency: f32 = 440,

    pub fn create(into: *Synth) void {
        into.* = Synth.init();
        std.log.warn(.my_synth, "Playing tone at {d:.}Hz\n", .{into.frequency});
    }

    pub fn init() Synth {
        return .{};
    }

    pub fn process(self: *Synth, output: [*c]f32, frames: i32) void {
        var i: i32 = 0;

        while (i < frames) : (i += 1) {
            self.total_frames += 1;

            // TODO Get sample rate information from the host.
            const t = @intToFloat(f32, self.total_frames) / 44100;

            output[@intCast(usize, i)] = sin(self.frequency, t);
        }
    }

    fn sin(freq: f32, t: f32) f32 {
        return std.math.sin(t * std.math.pi * 2.0 * freq);
    }
};

const Plugin = vst.VstPlugin(.{
    .id = 0x30d98,
    .version = .{ 0, 0, 1, 0 },
    .name = "Example Zig VST",
    .vendor = "zig-vst",
    .inputs = 0,
    .outputs = 1,
    .delay = 0,
    .flags = &[_]vst.api.Plugin.Flag{ .IsSynth, .CanReplacing },
    .category = .Synthesizer,
}, Synth);

pub usingnamespace Plugin.generateTopLevelHandlers();

comptime {
    Plugin.generateExports({});
}
