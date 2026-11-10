const std = @import("std");
const zrep = @import("zrep");
const print = std.debug.print;

pub fn searchFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    file: std.Io.File,
    item: []const u8,
    pattern: []const u8,
    opts: zrep.Options,
) bool {
    var match = false;
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const r = &reader.interface;

    if (opts.count) {
        match = zrep.countMatches(r, w, item, pattern, opts) catch |err| {
            print("Error counting matches: {t}\n", .{err});
            return match;
        };
        return match;
    }

    match = zrep.searchStream(allocator, r, w, item, pattern, opts) catch |err| {
        print("Error searching files: {t}\n", .{err});
        return match;
    };
    return match;
}

pub fn walkDir(
    io: std.Io,
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    directory: []const u8,
    pattern: []const u8,
    options: zrep.Options,
) bool {
    const dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| {
        print("Failed to open directory {s}: ", .{directory});
        switch (err) {
            error.AccessDenied => print("Access denied\n", .{}),
            error.BadPathName => print("Invalid path name\n", .{}),
            error.FileNotFound => print("Directory not found\n", .{}),
            error.NotDir => print("Not a directory\n", .{}),
            error.PermissionDenied => print("Permission denied\n", .{}),
            error.Unexpected => print("Unexpected\n", .{}),
            else => print("{t}\n", .{err}),
        }
        return false;
    };
    defer dir.close(io);
    var any_match = false;

    var walker = dir.walk(allocator) catch |err| {
        print("Failed to walk directory {s}: ", .{directory});
        switch (err) {
            error.OutOfMemory => print("Out of memory\n", .{}),
        }
        return false;
    };
    defer walker.deinit();

    while (walker.next(io) catch return false) |entry| {
        // skip symlinks, sockets, etc.
        if (entry.kind != .file) continue;

        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, entry.path }) catch |err| {
            print("Failed to allocate memory for path buffer: {s}\n", .{@errorName(err)});
            continue;
        };
        defer allocator.free(full_path);

        const file = dir.openFile(io, entry.path, .{ .mode = .read_only }) catch |err| {
            print("zrep: {s}: {s}\n", .{ full_path, @errorName(err) });
            continue;
        };
        defer file.close(io);

        const match = searchFile(allocator, io, w, file, full_path, pattern, options);
        if (any_match == false and match == true) any_match = true;
    }

    return any_match;
}

// hello -> comment is for testing do not remove
pub fn main(init: std.process.Init) u8 {
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &out_buf);
    const w = &fw.interface;

    var any_match: bool = false;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var options: zrep.Options = .{};
    var pattern: ?[]const u8 = null;

    const args = init.minimal.args.toSlice(allocator) catch |err| {
        print("Error allocating memory for args: ", .{});
        switch (err) {
            error.OutOfMemory => print("Out of memory\n", .{}),
            error.Unexpected => print("Unexpected error\n", .{}),
        }
        return 1;
    };

    // size is know becuase of arg.len so I could allocated fixed mem here
    var files: std.ArrayList([:0]const u8) = .empty;
    defer files.deinit(allocator);

    var directories: std.ArrayList([:0]const u8) = .empty;
    defer directories.deinit(allocator);

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    var param_indexes = std.AutoHashMap(usize, void).init(allocator);
    defer param_indexes.deinit();

    // parse args
    for (args[1..], 1..) |arg, i| {
        if (param_indexes.contains(i)) {
            continue;
        }

        if (arg.len > 1 and std.mem.startsWith(u8, arg, "-")) {
            const parsed = zrep.parseFlag(args, arg, &param_indexes, i, &options);
            if (parsed) {
                continue;
            } else return 1;
        }

        if (pattern == null) {
            pattern = arg;
            continue;
        }

        paths.append(allocator, arg) catch |err| {
            print("Error storing filepaths for search: {t}\n", .{err});
            return 1;
        };
    }
    options.show_filenames = paths.items.len > 1 or options.recursive;

    const pat = pattern orelse {
        print("No search pattern provided: {t}\n", .{error.InvalidArguments});
        return 1;
    };

    // try to read from stdin if no files, allows for cat foo | zrep help
    if (paths.items.len == 0 and !options.recursive) {
        _ = searchFile(allocator, io, w, std.Io.File.stdin(), "(standard input)", pat, options);
        return 0;
    }

    // find matches
    for (paths.items) |item| {
        var match = false;
        const file = std.Io.Dir.cwd().openFile(io, item, .{ .mode = .read_only }) catch |err| {
            switch (err) {
                error.FileNotFound => print("{s}: no such file\n", .{item}),
                else => print("{s}: {s}\n", .{ item, @errorName(err) }),
            }
            continue;
        };
        defer file.close(io);

        const meta = file.stat(io) catch |err| {
            print("Error checking type of paramater {s}: ", .{item});
            switch (err) {
                error.AccessDenied => print("Access denied\n", .{}),
                error.Canceled => print("Operation cancelled\n", .{}),
                error.PermissionDenied => print("Permission denied\n", .{}),
                error.Unexpected => print("Unexpected error\n", .{}),
                error.SystemResources => print("System resources\n", .{}),
                error.Streaming => print("Input is stream\n", .{}),
            }
            return 1;
        };

        switch (meta.kind) {
            .file => {
                match = searchFile(allocator, io, w, file, item, pat, options);
                if (any_match == false and match == true) any_match = true;
                w.flush() catch |err| {
                    print("Error: {t}\n", .{err});
                    return 1;
                };
            },
            .directory => {
                if (!options.recursive) {
                    print("Error: {s} is not a file. Use -r flag to scan directories\n", .{item});
                    break;
                }
                match = walkDir(io, w, allocator, item, pat, options);
                if (any_match == false and match == true) any_match = true;

                w.flush() catch |err| {
                    print("Error: {t}\n", .{err});
                    return 1;
                };
                continue;
            },
            .sym_link => {
                print("File {s} is symbolic link\n", .{item});
                continue;
            },
            else => {
                print("{s} is neither file nor directory\n", .{item});
                continue;
            },
        }
    }

    return 0;
}
