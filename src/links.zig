const std = @import("std");

pub const Kind = enum { url, text, image, dir, other };

pub const Link = struct {
    label: []const u8,
    target: []const u8,
    is_url: bool,
};

const OSC_OPEN = "\x1b]8;";
const FILE = "file://";
const SCHEMES = [_][]const u8{ "https://", "http://", "ftp://", FILE };
const TRAILING = ".,:;!?)]}'\"";
const NOISE = "claude.ai/code/session_";

const IMAGE = [_][]const u8{
    "png", "jpg", "jpeg", "gif",  "webp", "svg",
    "bmp", "ico", "avif", "heic", "tif",  "tiff",
};

const BINARY = [_][]const u8{
    "pdf",  "zip",  "gz",   "xz",    "zst", "tar",
    "7z",   "mp3",  "mp4",  "mkv",   "wav", "ogg",
    "webm", "docx", "xlsx", "pptx",  "odt", "epub",
    "ttf",  "otf",  "woff", "woff2", "so",  "bin",
    "exe",  "wasm",
};

fn isTerminator(byte: u8) bool {
    return byte == 0x07 or byte == 0x1b;
}

fn isFinal(byte: u8) bool {
    return byte >= 0x40 and byte <= 0x7e;
}

fn schemeOf(target: []const u8) ?[]const u8 {
    for (SCHEMES) |scheme| {
        if (std.mem.startsWith(u8, target, scheme)) return scheme;
    }
    return null;
}

pub fn stripAnsi(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != 0x1b) {
            try out.append(gpa, raw[i]);
            i += 1;
            continue;
        }
        if (i + 1 >= raw.len) break;
        switch (raw[i + 1]) {
            '[' => {
                i += 2;
                while (i < raw.len and !isFinal(raw[i])) i += 1;
                i += 1;
            },
            ']' => {
                i += 2;
                while (i < raw.len and !isTerminator(raw[i])) i += 1;
                if (i < raw.len and raw[i] == 0x1b) i += 1;
                i += 1;
            },
            '(', ')' => i += 3,
            else => i += 2,
        }
    }
    return out.toOwnedSlice(gpa);
}

fn trimTrailing(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and std.mem.indexOfScalar(u8, TRAILING, text[end - 1]) != null) {
        end -= 1;
    }
    return text[0..end];
}

fn trimToName(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0) : (end -= 1) {
        const byte = text[end - 1];
        if (std.ascii.isAlphanumeric(byte)) break;
        if (std.mem.indexOfScalar(u8, "_@+-", byte) != null) break;
    }
    return text[0..end];
}

fn urlEnd(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) : (i += 1) {
        const byte = text[i];
        if (byte <= ' ' or std.mem.indexOfScalar(u8, "'\"<>()[]`", byte) != null) break;
    }
    return i;
}

fn isPathByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or
        std.mem.indexOfScalar(u8, "_@.+-/~", byte) != null;
}

fn startsPath(text: []const u8, i: usize) bool {
    if (i > 0 and isPathByte(text[i - 1])) return false;
    if (text[i] == '/') return true;
    if (text[i] == '~' or text[i] == '.') {
        var j = i;
        while (j < text.len and text[j] == '.') j += 1;
        if (text[i] == '~') j = i + 1;
        return j < text.len and text[j] == '/';
    }
    return false;
}

fn percentDecode(gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |byte| {
                try out.append(gpa, byte);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn localPath(gpa: std.mem.Allocator, target: []const u8) ![]const u8 {
    const rest = target[FILE.len..];
    const host = if (std.mem.startsWith(u8, rest, "localhost/"))
        rest["localhost".len..]
    else
        rest;
    return percentDecode(gpa, host);
}

fn addLink(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Link),
    label: []const u8,
    target: []const u8,
) !void {
    if (target.len == 0) return;
    const scheme = schemeOf(target);
    if (scheme) |found| {
        if (target.len == found.len) return;
        if (std.mem.indexOf(u8, target, NOISE) != null) return;
    }
    if (std.mem.startsWith(u8, target, FILE)) {
        const path = try localPath(gpa, target);
        try out.append(gpa, .{
            .label = if (std.mem.eql(u8, label, target)) path else label,
            .target = path,
            .is_url = false,
        });
        return;
    }
    try out.append(gpa, .{
        .label = label,
        .target = target,
        .is_url = scheme != null,
    });
}

fn hyperlinks(
    gpa: std.mem.Allocator,
    raw: []const u8,
    out: *std.ArrayList(Link),
) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, raw, i, OSC_OPEN)) |open| {
        const params = open + OSC_OPEN.len;
        const semi = std.mem.indexOfScalarPos(u8, raw, params, ';') orelse break;
        var stop = semi + 1;
        while (stop < raw.len and !isTerminator(raw[stop])) stop += 1;
        const target = raw[semi + 1 .. stop];
        var body = stop;
        if (body < raw.len and raw[body] == 0x1b) body += 1;
        body += 1;
        const close = std.mem.indexOfPos(u8, raw, body, OSC_OPEN) orelse break;
        const label = try stripAnsi(gpa, raw[body..close]);
        try addLink(gpa, out, std.mem.trim(u8, label, " "), target);
        i = close;
    }
}

fn bareTargets(
    gpa: std.mem.Allocator,
    text: []u8,
    out: *std.ArrayList(Link),
) !void {
    var i: usize = 0;
    while (i < text.len) {
        const scheme = schemeOf(text[i..]) orelse {
            i += 1;
            continue;
        };
        const stop = urlEnd(text, i);
        const trimmed = trimTrailing(text[i..stop]);
        if (trimmed.len > scheme.len) {
            const target = try gpa.dupe(u8, trimmed);
            try addLink(gpa, out, target, target);
        }
        @memset(text[i..stop], ' ');
        i = stop;
    }

    i = 0;
    while (i < text.len) {
        if (!startsPath(text, i)) {
            i += 1;
            continue;
        }
        var stop = i;
        while (stop < text.len and isPathByte(text[stop])) stop += 1;
        const target = trimToName(text[i..stop]);
        if (target.len > 1) try addLink(gpa, out, target, target);
        i = stop;
    }
}

pub fn extract(gpa: std.mem.Allocator, raw: []const u8) ![]Link {
    var out: std.ArrayList(Link) = .empty;
    try hyperlinks(gpa, raw, &out);
    const text = try stripAnsi(gpa, raw);
    try bareTargets(gpa, text, &out);
    return out.toOwnedSlice(gpa);
}

pub fn expand(gpa: std.mem.Allocator, path: []const u8, home: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, path, "~/")) return path;
    return std.mem.concat(gpa, u8, &.{ home, path[1..] });
}

fn extension(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const name = if (slash) |at| path[at + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0) return "";
    return name[dot + 1 ..];
}

pub fn guess(path: []const u8) Kind {
    var lower: [16]u8 = undefined;
    const ext = extension(path);
    if (ext.len == 0 or ext.len > lower.len) return .text;
    const key = std.ascii.lowerString(lower[0..ext.len], ext);
    for (IMAGE) |candidate| {
        if (std.mem.eql(u8, candidate, key)) return .image;
    }
    for (BINARY) |candidate| {
        if (std.mem.eql(u8, candidate, key)) return .other;
    }
    return .text;
}

pub fn dedupe(
    gpa: std.mem.Allocator,
    links: []const Link,
    home: []const u8,
) ![]Link {
    var seen: std.StringHashMap(usize) = .init(gpa);
    var out: std.ArrayList(Link) = .empty;
    for (links) |link| {
        const key = if (link.is_url)
            link.target
        else
            try expand(gpa, link.target, home);
        const found = try seen.getOrPut(key);
        if (!found.found_existing) {
            found.value_ptr.* = out.items.len;
            try out.append(gpa, link);
            continue;
        }
        const kept = out.items[found.value_ptr.*];
        if (std.mem.eql(u8, kept.label, kept.target)) {
            out.items[found.value_ptr.*] = link;
        }
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

fn osc8(gpa: std.mem.Allocator, target: []const u8, label: []const u8) ![]u8 {
    return std.mem.concat(gpa, u8, &.{
        "\x1b]8;;", target, "\x1b\\", label, "\x1b]8;;\x1b\\",
    });
}

test "hyperlink keeps its label" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const line = try std.mem.concat(a, u8, &.{
        "see ", try osc8(a, "https://example.com/deep", "the docs"), " now",
    });
    const found = try extract(a, line);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("the docs", found[0].label);
    try testing.expectEqualStrings("https://example.com/deep", found[0].target);
}

test "hyperlink label survives colour codes" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const line = try osc8(a, "https://example.com", "\x1b[32mgreen\x1b[0m");
    const found = try extract(a, line);
    try testing.expectEqualStrings("green", found[0].label);
}

test "adjacent hyperlinks are both found" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const line = try std.mem.concat(a, u8, &.{
        "\x1b]8;;https://a.example\x1b\\one",
        "\x1b]8;;https://b.example\x1b\\two",
        "\x1b]8;;\x1b\\",
    });
    const found = try extract(a, line);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("https://a.example", found[0].target);
    try testing.expectEqualStrings("https://b.example", found[1].target);
}

test "bare url is its own label" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const found = try extract(a, "go to https://example.com/x.");
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("https://example.com/x", found[0].target);
}

test "a scheme on its own is not a link" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const found = try extract(a, "try https:// or http://)");
    try testing.expectEqual(@as(usize, 0), found.len);
}

test "paths are found" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const found = try extract(a, "edit ~/dotfiles/.tmux.conf please");
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("~/dotfiles/.tmux.conf", found[0].target);
}

test "an unknown csi sequence does not eat the line" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const found = try extract(a, "\x1b[3@/home/u/a.ts /home/u/b.ts");
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("/home/u/a.ts", found[0].target);
    try testing.expectEqualStrings("/home/u/b.ts", found[1].target);
}

test "a file url becomes a percent decoded path" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const found = try extract(a, try osc8(a, "file://localhost/home/u/my%20file.ts", "note"));
    try testing.expectEqualStrings("/home/u/my file.ts", found[0].target);
    try testing.expectEqual(false, found[0].is_url);
}

test "a file path is not filtered as claude noise" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const found = try extract(a, "/home/u/claude.ai/code/session_x");
    try testing.expectEqual(@as(usize, 1), found.len);
}

test "a file:// hyperlink and a bare path are one entry" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try extract(a, try osc8(a, "file:///home/u/dev/x.ts", "x.ts"));
    const second = try extract(a, "see ~/dev/x.ts");
    const both = try std.mem.concat(a, Link, &.{ first, second });
    const merged = try dedupe(a, both, "/home/u");
    try testing.expectEqual(@as(usize, 1), merged.len);
}

test "a bare file url loses to a labelled duplicate" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try extract(a, "see file:///home/u/dev/x.ts");
    const second = try extract(a, try osc8(a, "file:///home/u/dev/x.ts", "x.ts"));
    const both = try std.mem.concat(a, Link, &.{ first, second });
    const merged = try dedupe(a, both, "/home/u");
    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqualStrings("x.ts", merged[0].label);
}

test "the labelled entry wins a duplicate" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try extract(a, "see https://example.com");
    const second = try extract(a, try osc8(a, "https://example.com", "the docs"));
    const both = try std.mem.concat(a, Link, &.{ first, second });
    const merged = try dedupe(a, both, "/home/u");
    try testing.expectEqualStrings("the docs", merged[0].label);
}

test "the claude session link is dropped" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const found = try extract(a, "https://claude.ai/code/session_abc?from=cli");
    try testing.expectEqual(@as(usize, 0), found.len);
}

test "icons come from the extension" {
    try testing.expectEqual(Kind.image, guess("/a/b.png"));
    try testing.expectEqual(Kind.other, guess("/a/b.tar.zst"));
    try testing.expectEqual(Kind.text, guess("/a/b.ts"));
    try testing.expectEqual(Kind.text, guess("/a/README"));
    try testing.expectEqual(Kind.text, guess("/a/.tmux.conf"));
}
