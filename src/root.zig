const std = @import("std");

pub const Options = struct {
    ignore_case: bool = false,
    line_numbers: bool = false,
    invert: bool = false,
    count: bool = false,
    recursive: bool = false,
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
    r: *std.Io.Reader,
    w: anytype,
    io: std.Io,
    path: []const u8,
    pattern: []const u8,
    opts: Options,
) !void {
    var line_num: usize = 0;
    var printed_header = false;

    while (try r.takeDelimiter('\n')) |line| {
        line_num += 1;
        if (!lineMatches(line, pattern, opts)) continue;

        if (!printed_header) {
            try w.writeStreamingAll(io, "\n");
            try w.writeStreamingAll(io, path);
            try w.writeStreamingAll(io, "\n");
            printed_header = true;
        }

        var out: [64 * 1024]u8 = undefined;
        const str = if (opts.line_numbers)
            try std.fmt.bufPrint(&out, "{d}:{s}\n", .{ line_num, line })
        else
            try std.fmt.bufPrint(&out, "{s}\n", .{line});
        try w.writeStreamingAll(io, str);
    }
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
    var r = std.Io.Reader.fixed("alpha\nbeta\nalphabet\n");
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const matched = try searchStream(&r, TestSink{ .list = &out }, std.testing.io, "f.txt", "alpha", .{ .line_numbers = true });

    try std.testing.expect(matched);
    try std.testing.expectEqualStrings("\nf.txt\n1:alpha\n3:alphabet\n", out.written());
}
