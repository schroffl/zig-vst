const meta = @import("hot-reload-meta");
const wrapper = @import("hot_reload.zig").HotReloadWrapper(.{
    .watch_path = meta.watch_path,
    .log_file_path = meta.log_path,
});

pub usingnamespace wrapper.generateTopLevelHandlers();

comptime {
    wrapper.generateExports({});
}
