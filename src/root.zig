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

pub const RingBuf = struct {
    allocator: std.mem.Allocator,
    items: []std.ArrayList(u8),
    len: usize = 0,
    start: usize = 0,
    cap: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !@This() {
        const items = try allocator.alloc(std.ArrayList(u8), capacity);
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

/// Pure logic: no I/O, trivially testable.
pub fn lineMatches(line: []const u8, pattern: []const u8, opts: Options) bool {
    const found = if (opts.ignore_case)
        std.ascii.findIgnoreCasePos(line, 0, pattern) != null
    else
        std.mem.indexOf(u8, line, pattern) != null;
    return found != opts.invert;
}

pub fn write(
    w: anytype,
    io: std.Io,
    str: []const u8,
    new_line: bool,
    last_printed_line: usize,
    line_num: usize,
    opts: Options,
) !usize {
    if ((opts.before_context > 0 or opts.after_context > 0) and line_num <= last_printed_line)
        return last_printed_line;

    try w.writeStreamingAll(io, str);
    if (new_line) {
        try w.writeStreamingAll(io, "\n");
    }

    return line_num;
}

pub fn countMatches(
    r: *std.Io.Reader,
    w: anytype,
    io: std.Io,
    path: []const u8,
    pattern: []const u8,
    opts: Options,
) !bool {
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

    try w.writeStreamingAll(io, str);
    return matches > 0;
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
    var last_printed_line: usize = 0;
    var printed_header = false;

    var matches: usize = 0;
    var matched: bool = false;
    var printed_a_context: usize = 0;

    var ring = try RingBuf.init(allocator, opts.before_context);
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
            last_printed_line = try write(w, io, str, false, last_printed_line, line_num, opts);
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
            _ = try write(w, io, path, true, last_printed_line, line_num, opts);
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
                    _ = try write(w, io, str, false, last_printed_line, prev_line_num, opts);
                }

                _ = try write(w, io, ring_line, true, last_printed_line, prev_line_num, opts);
            }
        }

        if (last_printed_line != line_num) {
            var out: [64 * 1024]u8 = undefined;
            const str = if (opts.line_numbers)
                try std.fmt.bufPrint(&out, "{d}:{s}\n", .{ line_num, line })
            else
                try std.fmt.bufPrint(&out, "{s}\n", .{line});
            last_printed_line = try write(w, io, str, false, last_printed_line, line_num, opts);
        }
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

test "countMatches (-c) prints only the count" {
    const allocator = std.testing.allocator;
    var r = std.Io.Reader.fixed("a\nb\na\n");
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    const matched = try countMatches(&r, TestSink{ .list = &out }, std.testing.io, "f.txt", "a", .{ .count = true });

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
