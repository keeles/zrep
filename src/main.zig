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

pub fn openFileAndSearch(io: std.Io, item: []const u8, pattern: [:0]const u8) !void {
    const stdout = std.Io.File.stdout();

    const file = std.Io.Dir.cwd().openFile(io, item, .{ .mode = .read_only }) catch |err| {
        switch (err) {
            error.FileNotFound => std.debug.print("{s}: no such file\n", .{item}),
            else => std.debug.print("{s}: {s}\n", .{ item, @errorName(err) }),
        }
        return;
    };
    defer file.close(io);

    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const r = &reader.interface;

    try searchStreamPrintMatch(r, stdout, io, item, pattern);
    return;
}

// hello -> comment is for testing do not remove
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 3) return error.InvalidArguments;
    const pattern = args[1];

    var flags: []u8 = undefined;
    var flag_length: usize = 0;

    // size is know becuase of arg.len so I could allocated fixed mem here
    var files: std.ArrayList([:0]const u8) = .empty;
    defer files.deinit(allocator);

    var directories: std.ArrayList([:0]const u8) = .empty;
    defer directories.deinit(allocator);

    for (args[2..]) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            flags[flag_length] = arg[arg.len];
            flag_length += 1;
            continue;
        }

        const st = std.Io.Dir.cwd().statFile(io, arg, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => std.debug.print("zrep: {s}: no such file or directory\n", .{arg}),
                else => std.debug.print("zrep: {s}: {s}\n", .{ arg, @errorName(err) }),
            }
            continue;
        };

        switch (st.kind) {
            .file => try files.append(allocator, arg),
            .directory => try directories.append(allocator, arg),
            else => {}, // sockets, devices, etc.
        }
    }

    for (files.items) |item| {
        try openFileAndSearch(io, item, pattern);
    }

    for (directories.items) |item| {
        const dir = try std.Io.Dir.cwd().openDir(io, item, .{ .iterate = true });
        defer dir.close(io);

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind == .file) {
                const pathToFile = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ item, entry.path });
                defer allocator.free(pathToFile);

                try openFileAndSearch(io, pathToFile, pattern);
            }
        }
    }
}
