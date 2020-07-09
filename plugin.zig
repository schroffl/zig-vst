const std = @import("std");
const vst = @import("src/main.zig");

const Synth = struct {
    total_frames: usize = 0,

    pub fn create(into: *Synth, allocator: *std.mem.Allocator) void {
        into.* = Synth.init(allocator);
    }

    pub fn init(allocator: *std.mem.Allocator) Synth {
        return Synth{};
    }

    pub fn process(self: *Synth, input: var, output: var) void {
        var frame: usize = 0;

        while (frame < output.frames) : (frame += 1) {
            self.total_frames += 1;
            const t = @intToFloat(f32, self.total_frames) / 44100;

            const signal = sin(440, t);
            const detune_neg = sin(430, t);
            const detune_pos = sin(450, t);

            output.setFrame("Left", frame, signal * 0.9 + detune_neg * 0.1);
            output.setFrame("Right", frame, signal * 0.9 + detune_pos * 0.1);
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
    .delay = 0,
    .flags = &[_]vst.api.Plugin.Flag{ .IsSynth, .CanReplacing },
    .category = .Synthesizer,

    .input = &[_]vst.audio_io.Channel{},
    .output = &[_]vst.audio_io.Channel{
        .{ .name = "Left" },
        .{ .name = "Right" },
    },
}, Synth);

pub usingnamespace Plugin.generateTopLevelHandlers();

comptime {
    Plugin.generateExports({});
}
