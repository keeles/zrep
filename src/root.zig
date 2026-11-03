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
    const ring = try allocator.alloc(std.ArrayList(u8), opts.before_context);
    for (ring) |*slot| slot.* = .empty;

    while (try r.takeDelimiter('\n')) |line| {
        if (printed_a_context == opts.after_context) {
            matched = false;
            printed_a_context = 0;
        }

        // print after context
        if (opts.after_context > printed_a_context and matched) {
            printed_a_context += 1;
            var out: [64 * 1024]u8 = undefined;
            const str = if (opts.line_numbers)
                try std.fmt.bufPrint(&out, "{d}:{s}\n", .{ line_num + printed_a_context, line })
            else
                try std.fmt.bufPrint(&out, "{s}\n", .{line});
            try w.writeStreamingAll(io, str);
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
        matches += 1;

        if (!opts.count and !printed_header) {
            // write file name
            try w.writeStreamingAll(io, "\n");
            try w.writeStreamingAll(io, path);
            try w.writeStreamingAll(io, "\n");
            printed_header = true;
        }

        if (!opts.count) {
            if (opts.before_context > 0) {
                var prev_line_count: usize = ring_len;
                for (0..ring_len) |i| {
                    const first_i = (ring_start + i) % opts.before_context;
                    const ring_line = ring[first_i].items;
                    var num: [64 * 1024]u8 = undefined;
                    if (opts.line_numbers) {
                        const prev_line_num = line_num - prev_line_count;
                        prev_line_count = prev_line_count -| 1;
                        const str = try std.fmt.bufPrint(&num, "{d}:", .{prev_line_num});
                        try w.writeStreamingAll(io, str);
                    }
                    try w.writeStreamingAll(io, ring_line);
                    try w.writeStreamingAll(io, "\n");
                }
            }
            var out: [64 * 1024]u8 = undefined;
            const str = if (opts.line_numbers)
                try std.fmt.bufPrint(&out, "{d}:{s}\n", .{ line_num, line })
            else
                try std.fmt.bufPrint(&out, "{s}\n", .{line});
            try w.writeStreamingAll(io, str);
        }
    }

    if (opts.count) {
        if (opts.show_filenames) {
            try w.writeStreamingAll(io, path);
            try w.writeStreamingAll(io, ":");
        }
        var out: [32]u8 = undefined;
        const str = try std.fmt.bufPrint(&out, "{d}\n", .{matches});
        try w.writeStreamingAll(io, str);
    }

    return matches > 0;
}

// TODO: add tests for context flags

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
    try std.testing.expectEqualStrings("\nf.txt\n1:alpha\n3:alphabet\n", out.written());
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

    try std.testing.expectEqualStrings("\nf.txt\nb\n", out.written());
}

test "searchStream reports no match" {
    const allocator = std.testing.allocator;
    var r = std.Io.Reader.fixed("a\nb\n");
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const matched = try searchStream(allocator, &r, TestSink{ .list = &out }, std.testing.io, "f.txt", "zzz", .{});

    try std.testing.expect(!matched);
    try std.testing.expectEqualStrings("", out.written());
}
