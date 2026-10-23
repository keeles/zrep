const std = @import("std");
const zrep = @import("zrep");
const print = std.debug.print;

// TODO: need to handle check if dir => return err; OR if recursive flag walk dir
pub fn openFileAndSearch(io: std.Io, item: []const u8, pattern: []const u8, opts: zrep.Options) !void {
    const stdout = std.Io.File.stdout();

    const file = std.Io.Dir.cwd().openFile(io, item, .{ .mode = .read_only }) catch |err| {
        switch (err) {
            error.FileNotFound => print("{s}: no such file\n", .{item}),
            else => print("{s}: {s}\n", .{ item, @errorName(err) }),
        }
        return;
    };
    defer file.close(io);

    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const r = &reader.interface;

    try zrep.searchStream(r, stdout, io, item, pattern, opts);
    return;
}

// hello -> comment is for testing do not remove
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var options: zrep.Options = .{};
    var pattern: ?[]const u8 = null;

    const args = try init.minimal.args.toSlice(allocator);

    // size is know becuase of arg.len so I could allocated fixed mem here
    var files: std.ArrayList([:0]const u8) = .empty;
    defer files.deinit(allocator);

    var directories: std.ArrayList([:0]const u8) = .empty;
    defer directories.deinit(allocator);

    var paths: std.ArrayList([]const u8) = .empty;

    // parse args
    for (args[1..]) |arg| {
        if (arg.len > 1 and std.mem.startsWith(u8, arg, "-")) {
            for (arg[1..]) |flag| {
                switch (flag) {
                    'c' => options.count = true,
                    'r' => options.recursive = true,
                    'i' => options.ignore_case = true,
                    'l' => options.line_numbers = true,
                    'v' => options.invert = true,
                    else => {},
                }
            }
            continue;
        } else if (pattern == null) {
            pattern = arg;
        } else {
            try paths.append(allocator, arg);
        }
    }

    const pat = pattern orelse return error.InvalidArguments;

    // find matches
    for (paths.items) |item| {
        openFileAndSearch(io, item, pat, options) catch |err| {
            switch (err) {
                // TODO: statFile to determine if dir and handle appropriately
                error.ReadFailed => {
                    if (options.recursive == false) {
                        print("{s} is not a file. Read failed. Use flag -r to recursively search directories\n", .{item});
                    } else {
                        // TODO: handle errors better?
                        // check if dir
                        const dir = try std.Io.Dir.cwd().openDir(io, item, .{ .iterate = true });
                        defer dir.close(io);

                        var walker = try dir.walk(allocator);
                        defer walker.deinit();

                        while (try walker.next(io)) |entry| {
                            if (entry.kind == .file) {
                                const pathToFile = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ item, entry.path });
                                defer allocator.free(pathToFile);

                                try openFileAndSearch(io, pathToFile, pat, options);
                            }
                        }
                    }
                },
                else => print("{s}: {s}\n", .{ item, @errorName(err) }),
            }
            continue;
        };
    }
}
