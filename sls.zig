const lsp = @import("lsp");
const std = @import("std");
const story = @import("src/story.zig");
const zeit = @import("zeit");

var log_file: ?std.fs.File = null;
var local_timezone: ?zeit.TimeZone = null;

fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (log_file) |file| {
        if (local_timezone) |*tz| {
            const now = zeit.instant(.{}) catch return;
            now.in(tz).time().strftime(file.writer(), "[%d-%m-%Y %H:%M:%S %Z] ") catch return;
        } else {
            file.writer().print("[{:>11}] ", .{std.time.timestamp()}) catch return;
        }
        const prefix =
            comptime message_level.asText() ++
            if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        nosuspend file.writer().print(prefix ++ format ++ "\n", args) catch return;
    }
}

pub const std_options = std.Options{
    .logFn = logFn,
    .log_level = .debug,
};

pub const Server = struct {
    pub const Self = @This();

    /// SLS currently doesn't do anything with self or params on initialization.
    pub fn initialize(_: *Self, _: lsp.InitializeParams) !lsp.InitializeResult {
        return .{
            .serverInfo = .{ .name = "sls", .version = "0.0.0" },
            .capabilities = .{
                .definitionProvider = .{ .boolean = true },
            },
        };
    }

    pub fn @"textDocument/definition"(_: *Self, params: lsp.DefinitionParams) !lsp.DefinitionResult {
        std.log.info("Going to definition of symbol at {any}", .{params.position});
        return error.NotImplementedYet;
    }

    pub fn shutdown(_: *Self) !void {}
};

fn initLogFile(allocator: std.mem.Allocator) !void {
    var parts = std.ArrayList([]const u8).init(allocator);
    defer parts.deinit();
    if (std.posix.getenv("SLS_LOG_DIR")) |dir| {
        try parts.append(dir);
    } else if (std.posix.getenv("XDG_STATE_HOME")) |dir| {
        try parts.append(dir);
        try parts.append("sls");
    } else if (std.posix.getenv("HOME")) |dir| {
        try parts.append(dir);
        try parts.append(".local");
        try parts.append("state");
        try parts.append("sls");
    }
    try parts.append("sls.log");
    const path = try std.fs.path.join(allocator, parts.items);
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    log_file = try std.fs.createFileAbsolute(path, .{ .truncate = false });
    try log_file.?.seekFromEnd(0);
}

fn initTimeZone(allocator: std.mem.Allocator) !void {
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    local_timezone = try zeit.local(allocator, &env);
}

pub fn main() !u8 {
    const allocator = std.heap.page_allocator;

    try initLogFile(allocator);
    defer if (log_file) |file| file.close();

    try initTimeZone(allocator);
    defer if (local_timezone) |tz| tz.deinit();

    var backend = Server{};
    std.log.info("Initiating sls!", .{});
    try lsp.serve(allocator, std.io.getStdIn().reader().any(), std.io.getStdOut().writer().any(), &backend);
    std.log.info("Exiting sls!", .{});

    return 0;
}

test {
    std.testing.refAllDeclsRecursive(@This());
    std.testing.refAllDeclsRecursive(story);
}
