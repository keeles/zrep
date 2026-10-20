const std = @import("std");
const zrep = @import("zrep");

pub fn searchStreamPrintMatch(r: *std.Io.Reader, w: std.Io.File, io: std.Io, path: []const u8, pattern: []const u8) !void {
    var line_num: usize = 0;
    var printed_header = false;

    while (try r.takeDelimiter('\n')) |line| {
        line_num += 1;
        if (std.mem.indexOf(u8, line, pattern) == null) continue;

        if (!printed_header) {
            try w.writeStreamingAll(io, "\n");
            try w.writeStreamingAll(io, path);
            try w.writeStreamingAll(io, "\n");
            printed_header = true;
        }

        var out: [64 * 1024]u8 = undefined;
        const str = try std.fmt.bufPrint(&out, "{d}:{s}\n", .{ line_num, line });
        try w.writeStreamingAll(io, str);
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout = std.Io.File.stdout();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 3) return error.InvalidArguments;
    const pattern = args[1];

    for (args[2..]) |path| {
        const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| {
            switch (err) {
                error.FileNotFound => std.debug.print("{s}: no such file\n", .{path}),
                else => std.debug.print("{s}: {s}\n", .{ path, @errorName(err) }),
            }
            continue;
        };
        defer file.close(io);

        var buffer: [64 * 1024]u8 = undefined;
        var reader = file.readerStreaming(io, &buffer);
        const r = &reader.interface;

        try searchStreamPrintMatch(r, stdout, io, path, pattern);
    }
}
