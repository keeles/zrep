const std = @import("std");

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

/// Pure logic: no I/O, trivially testable. Grows as you add flags.
pub fn lineMatches(line: []const u8, pattern: []const u8, opts: Options) bool {
    const found = if (opts.ignore_case)
        std.ascii.findIgnoreCasePos(line, 0, pattern) != null
    else
        std.mem.indexOf(u8, line, pattern) != null;
    return found != opts.invert;
}

pub fn write(w: anytype, io: std.Io, str: []const u8, new_line: bool) !void {
    try w.writeStreamingAll(io, str);
    if (new_line) {
        try w.writeStreamingAll(io, "\n");
    }
}

/// Writes matching lines to `w` (anything with writeStreamingAll). Returns true if any matched.
pub fn searchStream(
    allocator: std.mem.Allocator,
    r: *std.Io.Reader,
    w: anytype,
    io: std.Io,
    path: []const u8,
    pattern: []const u8,
    opts: Options,
) !bool {
    var line_num: usize = 0;
    var printed_header = false;

    var matches: usize = 0;
    var matched: bool = false;
    var printed_a_context: usize = 0;

    var ring_len: usize = 0;
    var ring_start: usize = 0;

    var printed_lines = std.AutoHashMap(usize, void).init(allocator);
    defer printed_lines.deinit();

    const ring = try allocator.alloc(std.ArrayList(u8), opts.before_context);
    defer allocator.free(ring);

    for (ring) |*slot| slot.* = .empty;
    defer {
        for (ring) |*slot| slot.deinit(allocator);
    }

    while (try r.takeDelimiter('\n')) |line| {
        if (printed_a_context == opts.after_context) {
            matched = false;
            printed_a_context = 0;
        }

        // print after context
        if (opts.after_context > printed_a_context and matched) {
            printed_a_context += 1;
            if (!printed_lines.contains(line_num + 1)) {
                var out: [64 * 1024]u8 = undefined;
                const str = if (opts.line_numbers)
                    try std.fmt.bufPrint(&out, "{d}:{s}\n", .{ line_num + 1, line })
                else
                    try std.fmt.bufPrint(&out, "{s}\n", .{line});
                try printed_lines.put(line_num + 1, {});
                try write(w, io, str, false);
            }
        }

        line_num += 1;
        if (!lineMatches(line, pattern, opts)) {
            // store before context
            if (opts.before_context > 0) {
                if (ring_len < opts.before_context) {
                    try ring[(ring_start + ring_len) % opts.before_context].appendSlice(allocator, line);
                    ring_len += 1;
                } else {
                    ring[ring_start].clearRetainingCapacity();
                    try ring[ring_start].appendSlice(allocator, line);
                    ring_start = (ring_start + 1) % opts.before_context;
                }
            }
            continue;
        }

        matched = true;
        printed_a_context = 0;
        matches += 1;

        if (!opts.count and !printed_header) {
            // write file name
            try write(w, io, path, true);
            printed_header = true;
        }

        if (!opts.count) {
            // print before context
            if (opts.before_context > 0) {
                var prev_line_count: usize = ring_len;

                for (0..ring_len) |i| {
                    const first_i = (ring_start + i) % opts.before_context;
                    const ring_line = ring[first_i].items;
                    var num: [64 * 1024]u8 = undefined;
                    const prev_line_num = line_num - prev_line_count;
                    prev_line_count = prev_line_count -| 1;

                    if (printed_lines.contains(prev_line_num)) continue;

                    if (opts.line_numbers) {
                        const str = try std.fmt.bufPrint(&num, "{d}:", .{prev_line_num});
                        try printed_lines.put(prev_line_num, {});
                        try write(w, io, str, false);
                    }

                    try printed_lines.put(prev_line_num, {});
                    try write(w, io, ring_line, true);
                }
            }

            if (!printed_lines.contains(line_num)) {
                var out: [64 * 1024]u8 = undefined;
                const str = if (opts.line_numbers)
                    try std.fmt.bufPrint(&out, "{d}:{s}\n", .{ line_num, line })
                else
                    try std.fmt.bufPrint(&out, "{s}\n", .{line});
                try printed_lines.put(line_num, {});
                try write(w, io, str, false);
            }
        }
    }

    if (opts.count) {
        if (opts.show_filenames) {
            try write(w, io, path, false);
            try write(w, io, ":", false);
        }
        var out: [32]u8 = undefined;
        const str = try std.fmt.bufPrint(&out, "{d}\n", .{matches});
        try write(w, io, str, false);
    }

    return matches > 0;
}

test "lineMatches: literal, ignore case, invert" {
    try std.testing.expect(lineMatches("hello world", "world", .{}));
    try std.testing.expect(!lineMatches("hello world", "WORLD", .{}));
    try std.testing.expect(lineMatches("hello world", "WORLD", .{ .ignore_case = true }));
    try std.testing.expect(!lineMatches("hello world", "world", .{ .invert = true }));
    try std.testing.expect(lineMatches("hello world", "xyz", .{ .invert = true }));
}

const TestSink = struct {
    list: *std.Io.Writer.Allocating,

    pub fn writeStreamingAll(self: TestSink, io: std.Io, bytes: []const u8) !void {
        _ = io;
        try self.list.writer.writeAll(bytes);
    }
};

test "searchStream prints header and numbered matches" {
    const allocator = std.testing.allocator;
    var r = std.Io.Reader.fixed("alpha\nbeta\nalphabet\n");
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    const matched = try searchStream(allocator, &r, TestSink{ .list = &out }, std.testing.io, "f.txt", "alpha", .{ .line_numbers = true });

    try std.testing.expect(matched);
    try std.testing.expectEqualStrings("f.txt\n1:alpha\n3:alphabet\n", out.written());
}

test "searchStream -c prints only the count" {
    const allocator = std.testing.allocator;
    var r = std.Io.Reader.fixed("a\nb\na\n");
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    const matched = try searchStream(allocator, &r, TestSink{ .list = &out }, std.testing.io, "f.txt", "a", .{ .count = true });

    try std.testing.expect(matched);
    try std.testing.expectEqualStrings("2\n", out.written());
}

test "searchStream -v selects non-matching lines" {
    const allocator = std.testing.allocator;
    var r = std.Io.Reader.fixed("a\nb\na\n");
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    _ = try searchStream(allocator, &r, TestSink{ .list = &out }, std.testing.io, "f.txt", "a", .{ .invert = true });

    try std.testing.expectEqualStrings("f.txt\nb\n", out.written());
}

test "searchStream reports no match" {
    const allocator = std.testing.allocator;
    var r = std.Io.Reader.fixed("a\nb\n");
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    const matched = try searchStream(allocator, &r, TestSink{ .list = &out }, std.testing.io, "f.txt", "zzz", .{});

    try std.testing.expect(!matched);
    try std.testing.expectEqualStrings("", out.written());
}

test "searchStream -B stays in bounds" {
    const allocator = std.testing.allocator;
    var r = std.Io.Reader.fixed("a\ntest\nb\nc\n");
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    const matched = try searchStream(allocator, &r, TestSink{ .list = &out }, std.testing.io, "f.txt", "test", .{ .before_context = 5 });

    try std.testing.expect(matched);
    try std.testing.expectEqualStrings("f.txt\na\ntest\n", out.written());
}

test "searchStream -B overlapping context prints each line once" {
    const allocator = std.testing.allocator;
    var r = std.Io.Reader.fixed("a\nhit\nb\nhit\nc\n");
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    const matched = try searchStream(allocator, &r, TestSink{ .list = &out }, std.testing.io, "f.txt", "hit", .{
        .line_numbers = true,
        .before_context = 2,
    });

    try std.testing.expect(matched);
    try std.testing.expectEqualStrings("f.txt\n1:a\n2:hit\n3:b\n4:hit\n", out.written());
}

test "test searchStream -B and -A overlapping context prints each line once" {
    const allocator = std.testing.allocator;
    var r = std.Io.Reader.fixed("a\nhit\nb\nhit\nhit\nc\nnoshow\n");
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    const matched = try searchStream(allocator, &r, TestSink{ .list = &out }, std.testing.io, "f.txt", "hit", .{
        .line_numbers = true,
        .before_context = 2,
        .after_context = 1,
    });

    try std.testing.expect(matched);
    try std.testing.expectEqualStrings("f.txt\n1:a\n2:hit\n3:b\n4:hit\n5:hit\n6:c\n", out.written());
}
