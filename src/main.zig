const std = @import("std");
const zrep = @import("zrep");
const print = std.debug.print;

pub fn searchFile(
    io: std.Io,
    stdout: std.Io.File,
    file: std.Io.File,
    item: []const u8,
    pattern: []const u8,
    opts: zrep.Options,
) !void {
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const r = &reader.interface;

    _ = try zrep.searchStream(r, stdout, io, item, pattern, opts);
    return;
}

pub fn walkDir(
    io: std.Io,
    stdout: std.Io.File,
    allocator: std.mem.Allocator,
    directory: []const u8,
    pattern: []const u8,
    options: zrep.Options,
) !void {
    const dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        // skip symlinks, sockets, etc.
        if (entry.kind != .file) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, entry.path });
        defer allocator.free(full_path);

        const file = dir.openFile(io, entry.path, .{ .mode = .read_only }) catch |err| {
            print("zrep: {s}: {s}\n", .{ full_path, @errorName(err) });
            continue;
        };
        defer file.close(io);

        try searchFile(io, stdout, file, full_path, pattern, options);
    }
}
// hello -> comment is for testing do not remove
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout = std.Io.File.stdout();

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
    options.show_filenames = paths.items.len > 1 or options.recursive;

    const pat = pattern orelse return error.InvalidArguments;

    // find matches
    for (paths.items) |item| {
        const file = std.Io.Dir.cwd().openFile(io, item, .{ .mode = .read_only }) catch |err| {
            switch (err) {
                error.FileNotFound => print("{s}: no such file\n", .{item}),
                else => print("{s}: {s}\n", .{ item, @errorName(err) }),
            }
            return;
        };
        defer file.close(io);

        const meta = try file.stat(io);

        switch (meta.kind) {
            .file => try searchFile(io, stdout, file, item, pat, options),
            .directory => {
                if (!options.recursive) {
                    print("Error: {s} is not a file. Use -r flag to scan directories\n", .{item});
                    break;
                }
                try walkDir(io, stdout, allocator, item, pat, options);
            },
            .sym_link => print("File {s} is symbolic link\n", .{item}),
            else => {
                print("{s} is neither file nor directory\n", .{item});
            },
        }
    }
}
