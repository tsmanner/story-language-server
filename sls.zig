const schema = @import("lsp/schema.zig");
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
        if (local_timezone) |tz| {
            const now = zeit.instant(.{}) catch return;
            now.in(&tz).time().strftime(file.writer(), "[%d-%m-%Y %H:%M:%S %Z] ") catch return;
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
};

pub fn Server(comptime Input: type, comptime Output: type) type {
    return struct {
        pub const Self = @This();

        input: Input,
        output: Output,

        fn parseMessage(self: Self, allocator: std.mem.Allocator, header: Header) !schema.Message {
            const buf = try allocator.alloc(u8, header.content_length);
            const bytes_read = try self.input.read(buf);
            if (bytes_read != buf.len) {
                return error.EndOfStream;
            }
            var scanner = std.json.Scanner.initCompleteInput(allocator, buf);
            defer scanner.deinit();
            const parsed = try std.json.Value.jsonParse(
                allocator,
                &scanner,
                .{ .max_value_len = buf.len, .allocate = .alloc_always },
            );
            const id: ?i64 = if (parsed.object.get("id")) |id_json| id_json.integer else null;
            std.log.info("[{?}]  client→ {s}", .{ id, buf });
            return std.json.parseFromValueLeaky(schema.Message, allocator, parsed, .{ .ignore_unknown_fields = true });
        }

        fn processRequest(self: Self, allocator: std.mem.Allocator, id: schema.Id, request: schema.Request) !void {
            switch (request) {
                .initialize => |init| {
                    _ = init;
                    const response = schema.Message{
                        .jsonrpc = "2.0",
                        .id = id,
                        .payload = .{ .response = .{ .initialize = .{
                            .serverInfo = .{ .name = "sls", .version = "0.0.0" },
                            .capabilities = .{},
                        } } },
                    };
                    const message = try std.json.stringifyAlloc(allocator, response, .{
                        .emit_null_optional_fields = false,
                    });
                    defer allocator.free(message);
                    std.log.info("[{?}] ←server  {s}", .{ id, message });
                    try self.output.print("Content-Length: {}\r\n\r\n{s}", .{ message.len, message });
                },
                .initialized => {
                    std.log.info("[{?}]  server  Client initialized", .{id});
                },
                .@"textDocument/didOpen" => |doc| {
                    std.log.info("[{?}]  server  textDocument/didOpen notification", .{id});
                    _ = doc;
                    // try story.parse(doc.uri, doc.text);
                },
                .shutdown => {
                    const response = schema.Message{
                        .jsonrpc = "2.0",
                        .id = id,
                        .payload = .{ .response = .{ .none = .{} } },
                    };
                    const message = try std.json.stringifyAlloc(allocator, response, .{
                        .emit_null_optional_fields = false,
                    });
                    defer allocator.free(message);
                    std.log.info("[{?}]  server  Shut down", .{id});
                    std.log.info("[{?}] ←server  {s}", .{ id, message });
                    try self.output.print("Content-Length: {}\r\n\r\n{s}", .{ message.len, message });
                },
            }
        }

        fn processResponse(self: Self, id: schema.Id, response: schema.Response) !void {
            _ = .{
                self,
                id,
                response,
            };
        }

        pub fn run(self: *Self, allocator: std.mem.Allocator) !void {
            while (true) {
                const header = try self.parseHeader(allocator);
                std.log.info("[?]  client→ Message Header: {}", .{header});
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const message = try self.parseMessage(arena.allocator(), header);
                std.log.info("[{?}]  client→ {}", .{ message.id, message });
                switch (message.payload) {
                    .request => |request| try self.processRequest(allocator, message.id, request),
                    .response => |response| try self.processResponse(message.id, response),
                }
            }
        }
    };
}

pub fn initServer(
    input: anytype,
    output: anytype,
) Server(@TypeOf(input), @TypeOf(output)) {
    return .{
        .input = input,
        .output = output,
    };
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

    std.log.info("Initiating sls!", .{});
    var server = initServer(
        std.io.getStdIn().reader(),
        std.io.getStdOut().writer(),
    );
    try server.run(allocator);
    return 0;
}

const initialize_s =
    "Content-Length: 1557\r\n" ++
    "\r\n" ++
    "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-8\",\"utf-32\",\"utf-16\"]},\"textDocument\":{\"codeAction\":{\"codeActionLiteralSupport\":{\"codeActionKind\":{\"valueSet\":[\"\",\"quickfix\",\"refactor\",\"refactor.extract\",\"refactor.inline\",\"refactor.rewrite\",\"source\",\"source.organizeImports\"]}}},\"completion\":{\"completionItem\":{\"deprecatedSupport\":true,\"insertReplaceSupport\":true,\"resolveSupport\":{\"properties\":[\"documentation\",\"detail\",\"additionalTextEdits\"]},\"snippetSupport\":true,\"tagSupport\":{\"valueSet\":[1]}},\"completionItemKind\":{}},\"hover\":{\"contentFormat\":[\"markdown\"]},\"inlayHint\":{\"dynamicRegistration\":false},\"publishDiagnostics\":{\"versionSupport\":true},\"rename\":{\"dynamicRegistration\":false,\"honorsChangeAnnotations\":false,\"prepareSupport\":true},\"signatureHelp\":{\"signatureInformation\":{\"activeParameterSupport\":true,\"documentationFormat\":[\"markdown\"],\"parameterInformation\":{\"labelOffsetSupport\":true}}}},\"window\":{\"workDoneProgress\":true},\"workspace\":{\"applyEdit\":true,\"configuration\":true,\"didChangeConfiguration\":{\"dynamicRegistration\":false},\"executeCommand\":{\"dynamicRegistration\":false},\"inlayHint\":{\"refreshSupport\":false},\"symbol\":{\"dynamicRegistration\":false},\"workspaceEdit\":{\"documentChanges\":true,\"failureHandling\":\"abort\",\"normalizesLineEndings\":false,\"resourceOperations\":[\"create\",\"rename\",\"delete\"]},\"workspaceFolders\":true}},\"clientInfo\":{\"name\":\"helix\",\"version\":\"23.05 (7f5940be)\"},\"processId\":177984,\"rootPath\":\"/home/tsmanner/terrasa-notes\",\"rootUri\":null,\"workspaceFolders\":[]},\"id\":0}";

const initialize_s2 =
    "Content-Length: 1590\r\n" ++
    "\r\n" ++
    "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-8\",\"utf-32\",\"utf-16\"]},\"textDocument\":{\"codeAction\":{\"codeActionLiteralSupport\":{\"codeActionKind\":{\"valueSet\":[\"\",\"quickfix\",\"refactor\",\"refactor.extract\",\"refactor.inline\",\"refactor.rewrite\",\"source\",\"source.organizeImports\"]}}},\"completion\":{\"completionItem\":{\"deprecatedSupport\":true,\"insertReplaceSupport\":true,\"resolveSupport\":{\"properties\":[\"documentation\",\"detail\",\"additionalTextEdits\"]},\"snippetSupport\":true,\"tagSupport\":{\"valueSet\":[1]}},\"completionItemKind\":{}},\"hover\":{\"contentFormat\":[\"markdown\"]},\"inlayHint\":{\"dynamicRegistration\":false},\"publishDiagnostics\":{\"versionSupport\":true},\"rename\":{\"dynamicRegistration\":false,\"honorsChangeAnnotations\":false,\"prepareSupport\":true},\"signatureHelp\":{\"signatureInformation\":{\"activeParameterSupport\":true,\"documentationFormat\":[\"markdown\"],\"parameterInformation\":{\"labelOffsetSupport\":true}}}},\"window\":{\"workDoneProgress\":true},\"workspace\":{\"applyEdit\":true,\"configuration\":true,\"didChangeConfiguration\":{\"dynamicRegistration\":false},\"executeCommand\":{\"dynamicRegistration\":false},\"inlayHint\":{\"refreshSupport\":false},\"symbol\":{\"dynamicRegistration\":false},\"workspaceEdit\":{\"documentChanges\":true,\"failureHandling\":\"abort\",\"normalizesLineEndings\":false,\"resourceOperations\":[\"create\",\"rename\",\"delete\"]},\"workspaceFolders\":true}},\"clientInfo\":{\"name\":\"helix\",\"version\":\"23.05 (7f5940be)\"},\"processId\":177984,\"rootPath\":\"/home/tsmanner/terrasa-notes\",\"rootUri\":\"file:///home/tsmanner/terrasa-notes\",\"workspaceFolders\":[]},\"id\":0}";

const initialized_s =
    "Content-Length: 52\r\n" ++
    "\r\n" ++
    "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}\"";

const shutdown_s =
    "Content-Length: 44\r\n" ++
    "\r\n" ++
    "{\"jsonrpc\":\"2.0\",\"method\":\"shutdown\",\"id\":1}";

test "Server.parseHeader" {
    var buf = std.io.fixedBufferStream(initialize_s);
    var server = initServer(
        buf.reader(),
        std.io.null_writer,
    );
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const h = try server.parseHeader(allocator);
    try std.testing.expectEqual(@as(usize, 1557), h.content_length);
    try std.testing.expectEqualStrings("utf-8", h.content_type);
}

test "Server.parseMessage" {
    var buf = std.io.fixedBufferStream(initialize_s2);
    var server = initServer(
        buf.reader(),
        std.io.null_writer,
    );
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();
    const message = try server.parseMessage(allocator, try server.parseHeader(allocator));
    try std.testing.expectEqualStrings("2.0", message.jsonrpc);
    try std.testing.expectEqual(@as(?u32, 0), message.id.value);
    const init = message.payload.request.initialize;
    try std.testing.expectEqualDeep(
        init.capabilities.general.positionEncodings,
        &[_]schema.Position.Encoding{ .@"utf-8", .@"utf-32", .@"utf-16" },
    );
    try std.testing.expectEqualDeep(
        init.capabilities.textDocument.codeAction.codeActionLiteralSupport.codeActionKind.valueSet,
        &[_][]const u8{ "", "quickfix", "refactor", "refactor.extract", "refactor.inline", "refactor.rewrite", "source", "source.organizeImports" },
    );
    try std.testing.expectEqualStrings(
        init.rootPath.?,
        "/home/tsmanner/terrasa-notes",
    );
    if (init.rootUri) |root_uri| {
        try std.testing.expectEqualDeep(
            try std.Uri.parse("file:///home/tsmanner/terrasa-notes"),
            root_uri.value,
        );
    } else {
        return error.UnexpectedNullOptional;
    }
    // Initialized
    buf = std.io.fixedBufferStream(initialized_s);
    server.input = buf.reader();
    _ = try server.parseMessage(allocator, try server.parseHeader(allocator));
    // Shutdown
    buf = std.io.fixedBufferStream(shutdown_s);
    server.input = buf.reader();
    _ = try server.parseMessage(allocator, try server.parseHeader(allocator));
}

test "Server.processRequest" {
    var buf = std.io.fixedBufferStream(initialize_s2);
    var server = initServer(
        buf.reader(),
        std.io.null_writer,
    );
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();
    const message = try server.parseMessage(allocator, try server.parseHeader(allocator));
    try server.processRequest(std.testing.allocator, schema.Id{ .value = 0 }, message.payload.request);
}

test {
    std.testing.refAllDeclsRecursive(@This());
    std.testing.refAllDeclsRecursive(story);
}
