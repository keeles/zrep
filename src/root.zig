const std = @import("std");
const print = std.debug.print;

pub const Options = struct {
    ignore_case: bool = false,
    line_numbers: bool = false,
    invert: bool = false,
    count: bool = false,
    recursive: bool = false,
    show_filenames: bool = false,
    after_context: usize = 0,
    before_context: usize = 0,
};

pub const RingBufError = error{OutOfMemory};

pub const RingBuf = struct {
    allocator: std.mem.Allocator,
    items: []std.ArrayList(u8),
    len: usize = 0,
    start: usize = 0,
    cap: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) RingBufError!@This() {
        const items = allocator.alloc(std.ArrayList(u8), capacity) catch |err| return err;
        for (items) |*slot| slot.* = .empty;

        return .{
            .len = 0,
            .start = 0,
            .cap = capacity,
            .items = items,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        for (self.items) |*slot| slot.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub const ParseError = error{
    MissingValue,
    InvalidContext,
    InvalidOption,
    OutOfMemory,
};

pub fn parseFlag(
    args: []const [:0]const u8,
    arg: [:0]const u8,
    param_indexes: *std.AutoHashMap(usize, void),
    i: usize,
    options: *Options,
) ParseError!void {
    for (arg[1..]) |flag| {
        switch (flag) {
            'c' => {
                options.count = true;

                // silently kill context window if count flag detected
                options.after_context = 0;
                options.before_context = 0;
            },
            'r' => options.recursive = true,
            'i' => options.ignore_case = true,
            'l' => options.line_numbers = true,
            'v' => options.invert = true,
            'A', 'B' => {
                if (args.len <= (i + 1)) {
                    return error.MissingValue;
                }

                const context_size = std.fmt.parseInt(usize, args[i + 1], 10) catch return error.InvalidContext;
                param_indexes.put(i + 1, {}) catch return error.OutOfMemory;

                // silently kill context window if count flag detected
                if (!options.count) {
                    if (flag == 'A') options.after_context = context_size else options.before_context = context_size;
                }
            },
            else => return error.InvalidOption,
        }
    }
}

/// Pure logic: no I/O, trivially testable.
pub fn lineMatches(line: []const u8, pattern: []const u8, opts: Options) bool {
    const found = if (opts.ignore_case)
        std.ascii.findIgnoreCasePos(line, 0, pattern) != null
    else
        std.mem.indexOf(u8, line, pattern) != null;
    return found != opts.invert;
}

pub const SearchError = error{
    WriteFailed,
    OutOfMemory,
    ReadFailed,
    StreamTooLong,
    NoSpaceLeft,
};

pub fn write(
    w: *std.Io.Writer,
    str: []const u8,
    new_line: bool,
    last_printed_line: usize,
    line_num: usize,
    opts: Options,
) SearchError!usize {
    if ((opts.before_context > 0 or opts.after_context > 0) and line_num <= last_printed_line)
        return last_printed_line;

    _ = w.writeAll(str) catch return error.WriteFailed;

    if (new_line) {
        _ = w.writeAll("\n") catch return error.WriteFailed;
    }

    return line_num;
}

pub fn countMatches(
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    path: []const u8,
    pattern: []const u8,
    opts: Options,
) SearchError!bool {
    var line_num: usize = 0;
    var matches: usize = 0;

    while (try r.takeDelimiter('\n')) |line| {
        line_num += 1;
        if (!lineMatches(line, pattern, opts)) continue;
        matches += 1;
    }

    var out: [32]u8 = undefined;
    const str = if (opts.show_filenames)
        try std.fmt.bufPrint(&out, "{s}:{d}\n", .{ path, matches })
    else
        try std.fmt.bufPrint(&out, "{d}\n", .{matches});

    _ = w.writeAll(str) catch |err| return err;
    return matches > 0;
}

/// Writes matching lines to `w` (anything with writeStreamingAll). Returns true if any matched.
pub fn searchStream(
    allocator: std.mem.Allocator,
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    path: []const u8,
    pattern: []const u8,
    opts: Options,
) SearchError!bool {
    var line_num: usize = 0;
    var last_printed_line: usize = 0;
    var printed_header = false;

    var matches: usize = 0;
    var matched: bool = false;
    var printed_a_context: usize = 0;

    var ring = RingBuf.init(allocator, opts.before_context) catch |err| return err;
    defer ring.deinit();

    while (try r.takeDelimiter('\n')) |line| {
        line_num += 1;

        if (printed_a_context == opts.after_context) {
            matched = false;
            printed_a_context = 0;
        }

        // print after context
        if (opts.after_context > printed_a_context and matched) {
            printed_a_context += 1;
            var out: [64 * 1024]u8 = undefined;
            const str = if (opts.line_numbers)
                try std.fmt.bufPrint(&out, "{d}:{s}\n", .{ line_num, line })
            else
                try std.fmt.bufPrint(&out, "{s}\n", .{line});
            last_printed_line = write(w, str, false, last_printed_line, line_num, opts) catch |err| return err;
        }

        if (!lineMatches(line, pattern, opts)) {
            // store before context
            if (opts.before_context > 0) {
                if (ring.len < opts.before_context) {
                    try ring.items[(ring.start + ring.len) % opts.before_context].appendSlice(allocator, line);
                    ring.len += 1;
                } else {
                    ring.items[ring.start].clearRetainingCapacity();
                    try ring.items[ring.start].appendSlice(allocator, line);
                    ring.start = (ring.start + 1) % opts.before_context;
                }
            }

            continue;
        }

        matched = true;
        printed_a_context = 0;
        matches += 1;

        // write file name
        if (!printed_header) {
            _ = write(w, path, true, last_printed_line, line_num, opts) catch |err| return err;
            printed_header = true;
        }

        // print before context
        if (opts.before_context > 0) {
            var prev_line_count: usize = ring.len;

            for (0..ring.len) |i| {
                const first_i = (ring.start + i) % opts.before_context;
                const ring_line = ring.items[first_i].items;
                var num: [64 * 1024]u8 = undefined;
                const prev_line_num = line_num - prev_line_count;
                prev_line_count = prev_line_count -| 1;

                if (last_printed_line == prev_line_num) continue;

                if (opts.line_numbers) {
                    const str = try std.fmt.bufPrint(&num, "{d}:", .{prev_line_num});
                    _ = write(w, str, false, last_printed_line, prev_line_num, opts) catch |err| return err;
                }

                _ = write(w, ring_line, true, last_printed_line, prev_line_num, opts) catch |err| return err;
            }
        }

        if (last_printed_line != line_num) {
            var out: [64 * 1024]u8 = undefined;
            const str = if (opts.line_numbers)
                try std.fmt.bufPrint(&out, "{d}:{s}\n", .{ line_num, line })
            else
                try std.fmt.bufPrint(&out, "{s}\n", .{line});
            last_printed_line = write(w, str, false, last_printed_line, line_num, opts) catch |err| return err;
        }
    }

    return matches > 0;
}

const testing = std.testing;

test "lineMatches: literal, ignore case, invert" {
    try testing.expect(lineMatches("hello world", "world", .{}));
    try testing.expect(!lineMatches("hello world", "WORLD", .{}));
    try testing.expect(lineMatches("hello world", "WORLD", .{ .ignore_case = true }));
    try testing.expect(!lineMatches("hello world", "world", .{ .invert = true }));
    try testing.expect(lineMatches("hello world", "xyz", .{ .invert = true }));
}

test "searchStream prints header and numbered matches" {
    const allocator = testing.allocator;
    var r = std.Io.Reader.fixed("alpha\nbeta\nalphabet\n");

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const matched = try searchStream(allocator, &r, &aw.writer, "f.txt", "alpha", .{ .line_numbers = true });
    try testing.expect(matched);
    try testing.expectEqualStrings("f.txt\n1:alpha\n3:alphabet\n", aw.written());
}

test "countMatches (-c) prints only the count" {
    var r = std.Io.Reader.fixed("a\nb\na\n");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const matched = try countMatches(&r, &aw.writer, "f.txt", "a", .{ .count = true });

    try testing.expect(matched);
    try testing.expectEqualStrings("2\n", aw.written());
}

test "searchStream -v selects non-matching lines" {
    const allocator = testing.allocator;
    var r = std.Io.Reader.fixed("a\nb\na\n");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    _ = try searchStream(allocator, &r, &aw.writer, "f.txt", "a", .{ .invert = true });

    try testing.expectEqualStrings("f.txt\nb\n", aw.written());
}

test "searchStream reports no match" {
    const allocator = testing.allocator;
    var r = std.Io.Reader.fixed("a\nb\n");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const matched = try searchStream(allocator, &r, &aw.writer, "f.txt", "zzz", .{});

    try testing.expect(!matched);
    try testing.expectEqualStrings("", aw.written());
}

test "searchStream -B stays in bounds" {
    const allocator = testing.allocator;
    var r = std.Io.Reader.fixed("a\ntest\nb\nc\n");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const matched = try searchStream(allocator, &r, &aw.writer, "f.txt", "test", .{ .before_context = 5 });

    try testing.expect(matched);
    try testing.expectEqualStrings("f.txt\na\ntest\n", aw.written());
}

test "searchStream -B overlapping context prints each line once" {
    const allocator = testing.allocator;
    var r = std.Io.Reader.fixed("a\nhit\nb\nhit\nc\n");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const matched = try searchStream(allocator, &r, &aw.writer, "f.txt", "hit", .{
        .line_numbers = true,
        .before_context = 2,
    });

    try testing.expect(matched);
    try testing.expectEqualStrings("f.txt\n1:a\n2:hit\n3:b\n4:hit\n", aw.written());
}

test "test searchStream -B and -A overlapping context prints each line once" {
    const allocator = testing.allocator;
    var r = std.Io.Reader.fixed("a\nhit\nb\nhit\nhit\nc\nnoshow\n");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const matched = try searchStream(allocator, &r, &aw.writer, "f.txt", "hit", .{
        .line_numbers = true,
        .before_context = 2,
        .after_context = 1,
    });

    try testing.expect(matched);
    try testing.expectEqualStrings("f.txt\n1:a\n2:hit\n3:b\n4:hit\n5:hit\n6:c\n", aw.written());
}

// Most tests don't inspect param_indexes, so this hides the boilerplate.
fn parse(args: []const [:0]const u8, i: usize, options: *Options) ParseError!void {
    var param_indexes = std.AutoHashMap(usize, void).init(testing.allocator);
    defer param_indexes.deinit();
    try parseFlag(args, args[i], &param_indexes, i, options);
}

test "parseFlag: single boolean flags" {
    const args = [_][:0]const u8{ "zrep", "-r", "pat" };
    var opts: Options = .{};
    try parse(&args, 1, &opts);
    try testing.expect(opts.recursive);
    try testing.expect(!opts.ignore_case);
    try testing.expect(!opts.invert);
    try testing.expect(!opts.line_numbers);
    try testing.expect(!opts.count);
}

test "parseFlag: combined boolean flags" {
    const args = [_][:0]const u8{ "zrep", "-rilv", "pat" };
    var opts: Options = .{};
    try parse(&args, 1, &opts);
    try testing.expect(opts.recursive);
    try testing.expect(opts.ignore_case);
    try testing.expect(opts.line_numbers);
    try testing.expect(opts.invert);
    try testing.expect(!opts.count);
}

test "parseFlag: lone dash is a no-op" {
    const args = [_][:0]const u8{ "zrep", "-", "pat" };
    var opts: Options = .{};
    try parse(&args, 1, &opts);
    try testing.expect(!opts.recursive);
    try testing.expect(!opts.count);
}

test "parseFlag: -A sets after_context and records the value index" {
    const args = [_][:0]const u8{ "zrep", "-A", "3", "pat" };
    var opts: Options = .{};
    var pi = std.AutoHashMap(usize, void).init(testing.allocator);
    defer pi.deinit();

    try parseFlag(&args, args[1], &pi, 1, &opts);
    try testing.expectEqual(@as(usize, 3), opts.after_context);
    try testing.expectEqual(@as(usize, 0), opts.before_context);
    try testing.expect(pi.contains(2));
    try testing.expectEqual(@as(u32, 1), pi.count());
}

test "parseFlag: -B sets before_context and records the value index" {
    const args = [_][:0]const u8{ "zrep", "-B", "4", "pat" };
    var opts: Options = .{};
    var pi = std.AutoHashMap(usize, void).init(testing.allocator);
    defer pi.deinit();

    try parseFlag(&args, args[1], &pi, 1, &opts);
    try testing.expectEqual(@as(usize, 4), opts.before_context);
    try testing.expectEqual(@as(usize, 0), opts.after_context);
    try testing.expect(pi.contains(2));
    try testing.expectEqual(@as(u32, 1), pi.count());
}

test "parseFlag: -A and -B work when combined with boolean flags" {
    const args = [_][:0]const u8{ "zrep", "-iA", "2", "pat" };
    var opts: Options = .{};
    try parse(&args, 1, &opts);
    try testing.expect(opts.ignore_case);
    try testing.expectEqual(@as(usize, 2), opts.after_context);
}

test "parseFlag: -A missing value" {
    // flag is the last arg
    const args = [_][:0]const u8{ "zrep", "pat", "-A" };
    var opts: Options = .{};
    try testing.expectError(error.MissingValue, parse(&args, 2, &opts));
    try testing.expectEqual(@as(usize, 0), opts.after_context);
}

test "parseFlag: -B missing value" {
    const args = [_][:0]const u8{ "zrep", "pat", "-B" };
    var opts: Options = .{};
    try testing.expectError(error.MissingValue, parse(&args, 2, &opts));
    try testing.expectEqual(@as(usize, 0), opts.before_context);
}

test "parseFlag: non-numeric context value" {
    const args = [_][:0]const u8{ "zrep", "-A", "abc", "pat" };
    var opts: Options = .{};
    var pi = std.AutoHashMap(usize, void).init(testing.allocator);
    defer pi.deinit();

    try testing.expectError(error.InvalidContext, parseFlag(&args, args[1], &pi, 1, &opts));
    try testing.expectEqual(@as(usize, 0), opts.after_context);
    try testing.expectEqual(@as(u32, 0), pi.count()); // nothing recorded on failure
}

test "parseFlag: negative context value is rejected" {
    const args = [_][:0]const u8{ "zrep", "-B", "-1", "pat" };
    var opts: Options = .{};
    try testing.expectError(error.InvalidContext, parse(&args, 1, &opts));
}

test "parseFlag: overflowing context value is rejected" {
    const args = [_][:0]const u8{ "zrep", "-A", "99999999999999999999999999", "pat" };
    var opts: Options = .{};
    try testing.expectError(error.InvalidContext, parse(&args, 1, &opts));
}

test "parseFlag: -c clears previously set context" {
    const args = [_][:0]const u8{ "zrep", "-c", "pat" };
    var opts: Options = .{ .after_context = 3, .before_context = 5 };
    try parse(&args, 1, &opts);
    try testing.expect(opts.count);
    try testing.expectEqual(@as(usize, 0), opts.after_context);
    try testing.expectEqual(@as(usize, 0), opts.before_context);
}

test "parseFlag: -c before -A in a cluster wins" {
    const args = [_][:0]const u8{ "zrep", "-cA", "3", "pat" };
    var opts: Options = .{};
    var pi = std.AutoHashMap(usize, void).init(testing.allocator);
    defer pi.deinit();

    try parseFlag(&args, args[1], &pi, 1, &opts);
    try testing.expect(opts.count);
    try testing.expectEqual(@as(usize, 0), opts.after_context);
    try testing.expect(pi.contains(2)); // value is still consumed
}

test "parseFlag: -c after -A in a cluster wins" {
    const args = [_][:0]const u8{ "zrep", "-Ac", "3", "pat" };
    var opts: Options = .{};
    try parse(&args, 1, &opts);
    try testing.expect(opts.count);
    try testing.expectEqual(@as(usize, 0), opts.after_context);
}

test "parseFlag: invalid option returns invalid option error" {
    const args = [_][:0]const u8{ "zrep", "-z", "pat" };
    var opts: Options = .{};
    try testing.expectError(error.InvalidOption, parse(&args, 1, &opts));
}

test "parseFlag: flags before an invalid one are still applied" {
    // Documents current behavior: options are mutated as the loop goes,
    // so a failure partway through leaves earlier flags set.
    const args = [_][:0]const u8{ "zrep", "-rz", "pat" };
    var opts: Options = .{};
    try testing.expectError(error.InvalidOption, parse(&args, 1, &opts));
    try testing.expect(opts.recursive);
}

test "parseFlag: out of memory storing param index" {
    const args = [_][:0]const u8{ "zrep", "-A", "3", "pat" };
    var opts: Options = .{};
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var pi = std.AutoHashMap(usize, void).init(failing.allocator());
    defer pi.deinit();

    try testing.expectError(error.OutOfMemory, parseFlag(&args, args[1], &pi, 1, &opts));
    try testing.expectEqual(@as(usize, 0), opts.after_context);
}
