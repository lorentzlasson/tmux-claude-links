const std = @import("std");
const links = @import("links.zig");

const Kind = links.Kind;
const Link = links.Link;

const HISTORY_LIMIT = "-2000";
const LABEL_MAX = 50;
const DIM = "\x1b[2m";
const RESET = "\x1b[0m";

const Entry = struct {
    label: []const u8,
    target: []const u8,
    kind: Kind,
};

fn icon(kind: Kind) []const u8 {
    return switch (kind) {
        .url => "🌐",
        .text => "📄",
        .image => "🖼️",
        .dir => "📁",
        .other => "📎",
    };
}

const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    editor: []const u8,
};

fn run(ctx: Ctx, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(ctx.gpa, ctx.io, .{ .argv = argv });
    const failed = switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    };
    if (failed) {
        std.debug.print("tmux-claude-links: {s} failed\n{s}", .{ argv[0], result.stderr });
        return error.CommandFailed;
    }
    return result.stdout;
}

fn capture(ctx: Ctx, pane: []const u8) ![]u8 {
    return run(ctx, &.{
        "tmux", "capture-pane", "-p", "-e",          "-J",
        "-t",   pane,           "-S", HISTORY_LIMIT,
    });
}

fn mine(ctx: Ctx, target: []const u8) !bool {
    if (std.mem.startsWith(u8, target, ".")) return true;
    const full = try links.expand(ctx.gpa, target, ctx.home);
    if (!std.mem.startsWith(u8, full, ctx.home)) return false;
    const rest = full[ctx.home.len..];
    return rest.len == 0 or rest[0] == '/';
}

fn classify(ctx: Ctx, link: Link) !?Kind {
    if (link.is_url) return .url;
    if (!try mine(ctx, link.target)) return null;
    const path = try links.expand(ctx.gpa, link.target, ctx.home);
    const stat = std.Io.Dir.cwd().statFile(ctx.io, path, .{}) catch return null;
    return if (stat.kind == .directory) .dir else links.guess(path);
}

fn named(ctx: Ctx, link: Link) ![]const u8 {
    const label = try links.expand(ctx.gpa, link.label, ctx.home);
    const target = try links.expand(ctx.gpa, link.target, ctx.home);
    return if (std.mem.eql(u8, label, target)) "" else link.label;
}

fn entries(ctx: Ctx, found: []const Link) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    for (found) |link| {
        const kind = try classify(ctx, link) orelse continue;
        try out.append(ctx.gpa, .{
            .label = try named(ctx, link),
            .target = link.target,
            .kind = kind,
        });
    }
    return out.toOwnedSlice(ctx.gpa);
}

fn width(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn clip(text: []const u8, max: usize) []const u8 {
    var i: usize = 0;
    var count: usize = 0;
    while (i < text.len and count < max) : (count += 1) {
        i += std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
    }
    return text[0..@min(i, text.len)];
}

fn column(listed: []const Entry) usize {
    var widest: usize = 0;
    for (listed) |entry| widest = @max(widest, width(entry.label));
    return @min(LABEL_MAX, widest);
}

fn writeRow(out: *std.Io.Writer, entry: Entry, pad: usize) !void {
    const name = clip(entry.label, pad);
    try out.writeAll(name);
    try out.splatByteAll(' ', pad -| width(name));
    try out.print("  {s}  {s}{s}{s}\t{s}\t{d}\n", .{
        icon(entry.kind), DIM,                      entry.target, RESET,
        entry.target,     @intFromEnum(entry.kind),
    });
}

fn feed(out: *std.Io.Writer, listed: []const Entry, pad: usize) !void {
    for (listed) |entry| try writeRow(out, entry, pad);
    try out.flush();
}

fn pick(ctx: Ctx, listed: []const Entry) ![]const u8 {
    const pad = column(listed);

    var child = try std.process.spawn(ctx.io, .{
        .argv = &.{
            "fzf",         "--tmux",       "center,90%,60%", "--ansi",
            "--delimiter", "\t",           "--with-nth",     "1",
            "--no-sort",   "--no-preview", "-0",             "-1",
        },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    var buf: [4096]u8 = undefined;
    var writer = child.stdin.?.writer(ctx.io, &buf);
    feed(&writer.interface, listed, pad) catch {};
    child.stdin.?.close(ctx.io);
    child.stdin = null;

    var read_buf: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(ctx.io, &read_buf);
    const chosen = try reader.interface.allocRemaining(ctx.gpa, .unlimited);
    _ = try child.wait(ctx.io);
    return std.mem.trim(u8, chosen, "\n");
}

fn edit(ctx: Ctx, path: []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(ctx.gpa, &.{ "tmux", "new-window", "--" });
    var words = std.mem.tokenizeScalar(u8, ctx.editor, ' ');
    while (words.next()) |word| try argv.append(ctx.gpa, word);
    try argv.append(ctx.gpa, path);
    _ = try run(ctx, argv.items);
}

fn open(ctx: Ctx, target: []const u8, kind: Kind) !void {
    if (kind == .url) {
        _ = try run(ctx, &.{ "xdg-open", target });
        return;
    }
    const path = try links.expand(ctx.gpa, target, ctx.home);
    if (kind == .text or kind == .dir) return edit(ctx, path);
    _ = try run(ctx, &.{ "xdg-open", path });
}

fn notify(ctx: Ctx, message: []const u8) !void {
    _ = try run(ctx, &.{ "tmux", "display-message", message });
}

fn collect(ctx: Ctx, raw: []const u8) ![]Link {
    var all: std.ArrayList(Link) = .empty;
    var lines = std.mem.splitBackwardsScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        try all.appendSlice(ctx.gpa, try links.extract(ctx.gpa, line));
    }
    return links.dedupe(ctx.gpa, all.items, ctx.home);
}

pub fn main(init: std.process.Init) !void {
    const ctx: Ctx = .{
        .gpa = init.arena.allocator(),
        .io = init.io,
        .home = init.minimal.environ.getPosix("HOME") orelse "",
        .editor = init.minimal.environ.getPosix("EDITOR") orelse "vi",
    };

    const argv = try init.minimal.args.toSlice(ctx.gpa);
    const pane: []const u8 = if (argv.len > 1) argv[1] else "";

    const raw = try capture(ctx, pane);
    const listed = try entries(ctx, try collect(ctx, raw));
    if (listed.len == 0) return notify(ctx, "tmux-claude-links: nothing found");

    const chosen = try pick(ctx, listed);
    if (chosen.len == 0) return;

    var fields = std.mem.splitScalar(u8, chosen, '\t');
    _ = fields.next();
    const target = fields.next() orelse return;
    const field = fields.next() orelse return;
    const tag = std.fmt.parseInt(u8, field, 10) catch return;
    const kind = std.enums.fromInt(Kind, tag) orelse return;
    try open(ctx, target, kind);
}
