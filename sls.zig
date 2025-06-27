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
    const Files = std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8));
    const PositionEntry = struct {
        start: lsp.Position,
        end: lsp.Position,
        file: []const u8,
    };
    const Positions = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(PositionEntry));

    allocator: std.mem.Allocator,
    root: ?[]const u8 = null,
    /// Maps lowercase filename to relative file paths
    files: Files = .{},
    /// Maps relative file path to position/Files-index pairs
    positions: Positions = .{},
    response_arena: std.heap.ArenaAllocator,

    pub const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .response_arena = .init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.root) |root| {
            self.allocator.free(root);
        }
        var iter = self.files.iterator();
        while (iter.next()) |*entry| {
            for (entry.value_ptr.items) |path| {
                self.allocator.free(path);
            }
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.files.deinit(self.allocator);
        self.response_arena.deinit();
    }

    pub fn responseSent(self: *Self) !void {
        // Reset the arena but don't bother deallocating, since we will probably need memory again.
        if (!self.response_arena.reset(.retain_capacity)) {
            _ = self.response_arena.reset(.free_all);
        }
    }

    fn addFile(self: *Self, name: []const u8, path: []const u8) !void {
        const key: []const u8 = try std.ascii.allocLowerString(
            self.allocator,
            if (std.mem.endsWith(u8, name, ".sty")) name[0 .. name.len - 4] else name,
        );
        errdefer self.allocator.free(key);
        std.debug.print("Add file {s}: {s} -> {s}\n", .{ name, key, path });
        std.log.info("Add file {s}: {s} -> {s}", .{ name, key, path });
        const paths = try self.files.getOrPut(self.allocator, key);
        if (paths.found_existing) {
            self.allocator.free(key);
        } else {
            paths.value_ptr.* = .empty;
        }
        try paths.value_ptr.append(self.allocator, try self.allocator.dupe(u8, path));
    }

    fn populateFiles(self: *Self, root_path: []const u8) !void {
        self.root = try self.allocator.dupe(u8, root_path);
        const dir = try std.fs.openDirAbsolute(root_path, .{ .iterate = true });
        var iter = try dir.walk(self.allocator);
        defer iter.deinit();
        while (try iter.next()) |entry| {
            var path_buf: [1024]u8 = undefined;
            var path = path_buf[0..entry.path.len];
            std.mem.copyForwards(u8, path, entry.path);
            // Resolve symlinks until we have a regular file to add, or know we can skip.
            resolve: switch (entry.kind) {
                .file => {
                    try self.addFile(entry.basename, path);
                },
                .sym_link => {
                    path = try dir.readLink(path, &path_buf);
                    continue :resolve (try dir.statFile(path)).kind;
                },
                else => {},
            }
        }
    }

    /// SLS currently doesn't do anything with self or params on initialization.
    pub fn initialize(self: *Self, params: lsp.InitializeParams) !lsp.InitializeResult {
        if (params.rootUri.value) |root_uri| {
            std.log.info("Initializing sls from URI {s}", .{root_uri});
            const uri = try std.Uri.parse(root_uri);
            try self.populateFiles(uri.path.raw);
        } else if (params.rootPath) |root_path| {
            std.log.info("Initializing sls from path {s}", .{root_path});
            try self.populateFiles(root_path);
        }
        return .{
            .serverInfo = .{ .name = "sls", .version = "0.0.0" },
            .capabilities = .{
                .definitionProvider = .{ .boolean = true },
            },
        };
    }

    /// Look up a term in the file map.
    /// If the term appears as a key in the map, it is the first element in the returned slice.
    /// All other entries that partially match are returned in no particular order.
    /// Caller owns the returned memory and is expected to free it with self.allocator.
    fn lookup(self: *Self, term: []const u8) ![]const []const u8 {
        var results: std.ArrayListUnmanaged([]const u8) = .empty;
        const lower = try std.ascii.allocLowerString(self.allocator, term);
        defer self.allocator.free(lower);
        var iter = self.files.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, lower, entry.key_ptr.*)) {
                try results.insertSlice(self.allocator, 0, entry.value_ptr.items);
            } else if (std.mem.containsAtLeast(u8, entry.key_ptr.*, 1, lower)) {
                try results.appendSlice(self.allocator, entry.value_ptr.items);
            }
        }
        return results.toOwnedSlice(self.allocator);
    }

    pub fn @"textDocument/definition"(self: *Self, params: lsp.DefinitionParams) !lsp.DefinitionResult {
        std.log.info("Going to definition of symbol at {s}:{}:{}", .{ params.textDocument.uri, params.position.line, params.position.character });
        // Step 1: get and maintain a listing of all files in the directory tree.
        // Step 2: figure out what symbol it is - which means implement a `textDocument/didOpen` function
        //         and a `textDocument/didChange` function.
        const files = try self.lookup("Turminder Xuss");
        defer self.allocator.free(files);
        if (files.len != 0) {
            const path = try std.fmt.allocPrint(self.response_arena.allocator(), "file://{s}/{s}", .{ self.root.?, files[0] });
            std.log.info("  Definition URI: {s}", .{path});
            return .{ .location = .{
                .uri = path,
                .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
            } };
        } else {
            std.log.warn("Definition not found for symbol at {s}:{}:{}", .{ params.textDocument.uri, params.position.line, params.position.character });
            return error.DefinitionNotFound;
        }
    }

    pub fn shutdown(_: *Self) !void {
        std.log.info("Shutting down sls", .{});
    }
};

test "Server" {
    var server: Server = .init(std.testing.allocator);
    defer server.deinit();
    try server.populateFiles("/home/tsmanner/terrasa-notes");
    const paths = try server.lookup("Turminder xuss");
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings("characters/Turminder Xuss.sty", paths[0]);
    const result = try server.@"textDocument/definition"(.{
        .position = .{ .line = 0, .character = 0 },
        .textDocument = .{ .uri = "" },
    });
    try std.testing.expectEqualStrings("file:///home/tsmanner/terrasa-notes/characters/Turminder Xuss.sty", result.location.uri);
    server.allocator.free(paths);
}

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

    var backend: Server = .init(allocator);
    std.log.info("Initiating sls!", .{});
    try lsp.serve(allocator, std.io.getStdIn().reader().any(), std.io.getStdOut().writer().any(), &backend);
    std.log.info("Exiting sls!", .{});

    return 0;
}
