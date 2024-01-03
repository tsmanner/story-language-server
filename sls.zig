const std = @import("std");

var log_file: ?[]const u8 = null;

pub const std_options = struct {
    pub fn logFn(
        comptime message_level: std.log.Level,
        comptime scope: @Type(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (log_file) |path| {
            var file = std.fs.createFileAbsolute(path, .{ .truncate = false }) catch return;
            defer file.close();
            file.seekFromEnd(0) catch {};
            const level_txt = comptime message_level.asText();
            const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
            nosuspend file.writer().print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
        }
    }
};

fn reply(id: u64, message: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try std.fmt.format(stream.writer(), "{{\"jsonrpc\":\"2.0\",\"id\":{},{s}}}", .{ id, message });
    try stream.writer().writeByte(0);
    const content = std.mem.sliceTo(&buf, 0);
    std.log.scoped(.reply).info("{s}", .{content});
    std.fmt.format(std.io.getStdOut().writer(), "Content-Length: {}\r\n\r\n{s}", .{ content.len, content }) catch |e| {
        std.log.err("Error {s} while replying to id={}!", .{ @errorName(e), id });
    };
}

const Coordinate = struct {
    line: u64,
    char: u64,
};

const Token = struct {
    text: []const u8,
    start: Coordinate,
    end: Coordinate,
};

const Tokens = std.ArrayListUnmanaged(Token);

const Method = enum {
    initialize,
    initialized,
    @"textDocument/didChange",
    @"textDocument/didOpen",
    @"textDocument/definition",
    shutdown,
    exit,
};

const Uri = struct {
    text: []const u8,
    uri: std.Uri,
};

const Payload = struct {
    allocator: std.mem.Allocator,
    id: ?u64 = null,
    method: ?Method = null,
    file_path: ?[]const u8 = null,
    tokens: ?Tokens = null,
    line: ?u64 = null,
    char: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) Payload {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Payload) void {
        if (self.file_path) |file_path| {
            self.allocator.free(file_path);
        }
        if (self.tokens) |*tokens| {
            tokens.deinit(self.allocator);
        }
    }

    pub fn format(self: Payload, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        _ = fmt;
        try writer.writeAll("Payload:");
        if (self.id) |id| {
            try writer.print(" id={}", .{id});
        }
        if (self.method) |method| {
            try writer.print(" method={s}", .{@tagName(method)});
        }
        if (self.file_path) |file_path| {
            try writer.print(" file_path={s}", .{file_path});
        }
        if (self.tokens) |tokens| {
            try writer.print(" token_count={}", .{tokens.items.len});
        }
        if (self.line) |line| {
            try writer.print(" line={}", .{line});
        }
        if (self.char) |char| {
            try writer.print(" char={}", .{char});
        }
    }
};

const Server = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    // File URI -> Tokens
    data: std.StringHashMapUnmanaged(Tokens) = .{},
    root: ?[]const u8 = null,
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator) Server {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var key_iter = self.data.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.data.deinit(self.allocator);
        if (self.root) |root| {
            self.allocator.free(root);
        }
    }

    fn updateFile(self: *Self, payload: *Payload) !void {
        const log = std.log.scoped(.@"server.updateFile");
        var file_path = payload.file_path orelse return error.MissingFilePath;
        var tokens = payload.tokens orelse return error.MissingTokens;
        // Take ownership of the payload tokens.
        payload.tokens = null;
        log.info("{s}", .{file_path});
        for (tokens.items) |token| {
            log.info("{s} [{},{}]:[{},{}]", .{
                token.text,
                token.start.line,
                token.start.char,
                token.end.line,
                token.end.char,
            });
        }
        var maybe_old = try self.data.fetchPut(self.allocator, file_path, tokens);
        if (maybe_old) |*old| {
            old.value.deinit(self.allocator);
        } else {
            // If this file wasn't in there already, take ownership of the file_path memory.
            payload.file_path = null;
        }
    }

    pub fn process(self: *Self, payload: *Payload) !void {
        std.log.scoped(.server).info("{}", .{payload});
        if (payload.method) |method| {
            switch (method) {
                .initialize => {
                    const log = std.log.scoped(.@"server.initialize");
                    const id = payload.id orelse return error.MissingId;
                    const root_path = payload.file_path orelse return error.MissingRootPath;
                    payload.file_path = null;
                    log.info("{s}", .{root_path});
                    self.root = root_path;
                    try reply(id,
                        \\"result":{"capabilities":{"positionEncoding":"utf-8","textDocumentSync":{"openClose":true,"change":1},"definitionProvider":true,"referencesProvider":false,"documentHighlightProvider":false,"documentSymbolProvider":false,"workspaceSymbolProvider":false,"workspace":{"workspaceFolders":{"supported":false,"changeNotifications":false}}},"serverInfo":{"name":"sls","version":"0.1.0"}}
                    );
                },
                .initialized => {},
                .@"textDocument/didChange" => {
                    const log = std.log.scoped(.@"serve.textDocument/didChange");
                    log.info("Updating file", .{});
                    try self.updateFile(payload);
                },
                .@"textDocument/didOpen" => {
                    const log = std.log.scoped(.@"server.textDocument/didOpen");
                    log.info("Updating file", .{});
                    try self.updateFile(payload);
                },
                .@"textDocument/definition" => {
                    const log = std.log.scoped(.@"server.textDocument/definition");
                    const id = payload.id orelse return error.MissingId;
                    const file_path = payload.file_path orelse return error.MissingFilePath;
                    const root = self.root orelse return error.MissingServerRoot;
                    const coordinate = Coordinate{
                        .line = payload.line orelse return error.MissingCoordinateLine,
                        .char = payload.char orelse return error.MissingCoordinateChar,
                    };
                    log.info("id={}", .{id});
                    log.info("{s}:{}:{}", .{ file_path, coordinate.line, coordinate.char });
                    if (self.data.get(file_path)) |tokens| {
                        log.info("{} tokens total.", .{tokens.items.len});
                        for (tokens.items) |token| {
                            if (token.start.line <= coordinate.line and
                                token.start.char <= coordinate.char and
                                token.end.line >= coordinate.line and
                                token.end.char >= coordinate.char)
                            {
                                var name = std.ArrayList(u8).init(self.allocator);
                                defer name.deinit();
                                try name.appendSlice(token.text);
                                try name.appendSlice(".sty");
                                var find_result = try std.process.Child.exec(.{
                                    .allocator = self.allocator,
                                    .argv = &[_][]const u8{ "find", root, "-name", name.items, "-print0", "-quit" },
                                    .cwd = root,
                                });
                                defer self.allocator.free(find_result.stdout);
                                defer self.allocator.free(find_result.stderr);
                                const result_file_path = std.mem.sliceTo(find_result.stdout, 0);
                                log.info("{s}", .{result_file_path});
                                var content = std.ArrayList(u8).init(self.allocator);
                                defer content.deinit();
                                try std.fmt.format(
                                    content.writer(),
                                    \\"result":[{{"uri":"file://{s}","range":{{"start":{{"line":0,"character":0}},"end":{{"line":0,"character":0}}}}}}]
                                ,
                                    .{result_file_path},
                                );
                                try reply(id, content.items);
                            }
                        }
                    }
                },
                .shutdown => {
                    try reply(payload.id orelse return error.MissingId, "\"result\":null");
                },
                .exit => self.running = false,
            }
        }
    }
};

fn Parser(comptime Reader: type) type {
    return struct {
        const Self = @This();
        const Error = Reader.Error || error{
            EndOfStream,
            ExpectedColon,
            InvalidCharacter,
            InvalidFormat,
            InvalidPort,
            OutOfMemory,
            Overflow,
            StreamTooLong,
            UnexpectedCharacter,
            UnrecognizedEscape,
            UnrecognizedLiteral,
            UnrecognizedObjectContent,
        };

        reader: Reader,
        depth: u32 = 0,
        char: u8,

        fn advance(self: *Self) !void {
            self.char = try self.reader.readByte();
        }

        fn skipWhitespace(self: *Self) !void {
            while (true) {
                switch (self.char) {
                    ' ', '\t', '\r', '\n' => try self.advance(),
                    else => return,
                }
            }
        }

        fn skipString(self: *Self) !void {
            var lookback: [2]u8 = [_]u8{ 0, 0 };
            while (true) {
                try self.advance();
                lookback[0] = lookback[1];
                lookback[1] = self.char;
                if (lookback[1] == '"' and lookback[0] != '\\') {
                    break;
                }
            }
            try self.advance();
        }

        fn skipArray(self: *Self) !void {
            while (true) {
                switch (self.char) {
                    ']' => {
                        try self.advance();
                        return;
                    },
                    ',' => {
                        try self.advance();
                        try self.skipValue();
                    },
                    else => try self.advance(),
                }
            }
        }

        fn skipObject(self: *Self) !void {
            try self.advance(); // Consume the '{'
            while (true) {
                switch (self.char) {
                    '{' => {
                        try self.skipObject();
                    },
                    '}' => {
                        try self.advance();
                        return;
                    },
                    '"' => {
                        try self.skipString();
                        try self.advance();
                        try self.skipValue();
                    },
                    ',' => {
                        try self.advance();
                    },
                    else => {
                        std.log.scoped(.@"parser.skipObject").err("Unrecognized Object Content '{c}'", .{self.char});
                        return error.UnrecognizedObjectContent;
                    },
                }
            }
        }

        fn skipNumber(self: *Self) !void {
            while (true) {
                switch (self.char) {
                    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '.' => try self.advance(),
                    else => break,
                }
            }
        }

        fn skipValue(self: *Self) Error!void {
            switch (self.char) {
                '"' => {
                    try self.skipString();
                },
                '[' => {
                    try self.skipArray();
                },
                '{' => {
                    try self.skipObject();
                },
                't', 'n' => {
                    // Skip "true" or "null"
                    try self.reader.skipBytes(3, .{});
                    try self.advance();
                },
                'f' => {
                    // Skip "false"
                    try self.reader.skipBytes(4, .{});
                    try self.advance();
                },
                '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => try self.skipNumber(),
                else => {
                    std.debug.print("Unrecognized Literal '{c}'\n", .{self.char});
                    return error.UnrecognizedLiteral;
                },
            }
        }

        fn parseString(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
            try self.advance(); // Consume the open '"'
            var value = std.ArrayList(u8).init(allocator);
            defer value.deinit();
            var value_writer = value.writer();
            try value_writer.writeByte(self.char);
            try self.reader.streamUntilDelimiter(value_writer, '"', null);
            while (value.items[value.items.len - 1] == '\\') {
                try self.reader.streamUntilDelimiter(value_writer, '"', null);
            }
            try self.advance(); // Consume the close '"'
            return value.toOwnedSlice();
        }

        fn parseInteger(self: *Self, allocator: std.mem.Allocator) !u64 {
            var str = std.ArrayList(u8).init(allocator);
            defer str.deinit();
            while (true) {
                switch (self.char) {
                    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => try str.append(self.char),
                    else => break,
                }
                try self.advance();
            }
            return try std.fmt.parseInt(u64, str.items, 10);
        }

        fn parseKeyThenValue(self: *Self, payload: *Payload) !void {
            var key = try self.parseString(payload.allocator);
            defer payload.allocator.free(key);
            std.log.scoped(.parser).info("BEGIN key={s}", .{key});
            defer std.log.scoped(.parser).info("-END- key={s}", .{key});
            if (self.char != ':') {
                return error.ExpectedColon;
            }
            try self.advance(); // Consume the ':'
            if (std.mem.eql(u8, key, "params")) {
                try self.parseObject(payload);
            } else if (std.mem.eql(u8, key, "textDocument")) {
                try self.parseObject(payload);
            } else if (std.mem.eql(u8, key, "position")) {
                try self.parseObject(payload);
            } else if (std.mem.eql(u8, key, "contentChanges")) {
                try self.advance();
                try self.parseObject(payload);
                try self.advance();
            } else if (std.mem.eql(u8, key, "id")) {
                payload.id = try self.parseInteger(payload.allocator);
            } else if (std.mem.eql(u8, key, "line")) {
                payload.line = try self.parseInteger(payload.allocator);
            } else if (std.mem.eql(u8, key, "character")) {
                payload.char = try self.parseInteger(payload.allocator);
            } else if (std.mem.eql(u8, key, "text")) {
                try self.parseDocument(payload);
            } else if (std.mem.eql(u8, key, "rootPath")) {
                payload.file_path = try self.parseString(payload.allocator);
            } else if (std.mem.eql(u8, key, "method")) {
                var method = try self.parseString(payload.allocator);
                defer payload.allocator.free(method);
                std.log.scoped(.@"parser.method").info("{s}", .{method});
                payload.method = std.meta.stringToEnum(Method, method);
            } else if (std.mem.eql(u8, key, "uri")) {
                var text = try self.parseString(payload.allocator);
                defer payload.allocator.free(text);
                var stream = std.io.fixedBufferStream(text);
                var reader = stream.reader();
                try reader.skipUntilDelimiterOrEof(':');
                try reader.skipBytes(2, .{});
                payload.file_path = try reader.readAllAlloc(payload.allocator, text.len);
            } else {
                std.log.scoped(.parser).info("Skipping {s}", .{key});
                try self.skipValue();
            }
        }

        fn parseObject(self: *Self, payload: *Payload) Error!void {
            std.debug.assert(self.char == '{');
            self.depth += 1;
            defer self.depth -= 1;
            std.log.scoped(.@"parser.object").info("BEGIN {}", .{self.depth});
            defer std.log.scoped(.@"parser.object").info("-END- {}", .{self.depth});
            try self.advance(); // Consume the '{'
            while (true) {
                switch (self.char) {
                    '{' => {
                        try self.parseObject(payload);
                    },
                    '}' => {
                        if (self.depth > 1) {
                            try self.advance();
                        }
                        return;
                    },
                    '"' => {
                        try self.parseKeyThenValue(payload);
                    },
                    ',' => {
                        try self.advance();
                    },
                    else => {
                        std.log.scoped(.@"parser.parseObject").err("Unrecognized Object Content '{c}'", .{self.char});
                        return error.UnrecognizedObjectContent;
                    },
                }
            }
        }

        fn parseContent(self: *Self, payload: *Payload) !void {
            std.log.scoped(.parser).info("parseContent", .{});
            if (self.char == '{') {
                try self.parseObject(payload);
            } else {
                return error.ExpectedObject;
            }
        }

        fn parseDocument(self: *Self, payload: *Payload) !void {
            std.log.scoped(.@"parser.document").info("BEGIN", .{});
            defer std.log.scoped(.@"parser.document").info("-END- @{c} tokens_len={}", .{ self.char, payload.tokens.?.items.len });
            payload.tokens = .{};
            var line: u64 = 0;
            var char: u64 = 0;
            var text = std.ArrayListUnmanaged(u8){};
            defer text.deinit(payload.allocator);
            var start_coordinate: ?Coordinate = null;
            var prev_char: u8 = 0;
            while (true) {
                prev_char = self.char;
                try self.advance();
                const current_char: u8 = blk: {
                    if (prev_char == '\\') {
                        break :blk switch (self.char) {
                            'n' => '\n',
                            't' => '\t',
                            'r' => '\r',
                            '"' => '"',
                            '\\' => '\\',
                            else => return error.UnrecognizedEscape,
                        };
                    } else {
                        if (self.char == '"') {
                            // When we see a non-escaped quote, we have reached the end of the document text.
                            // Advance one more time so we are pointing past the closing quote.
                            try self.advance();
                            return;
                        } else if (self.char == '\\') {
                            // Skip backslashes until we know what they're escaping.
                            continue;
                        }
                        break :blk self.char;
                    }
                };
                switch (current_char) {
                    '\n' => {
                        line += 1;
                        char = 0;
                    },
                    '{' => {
                        if (start_coordinate) |_| {
                            std.log.scoped(.@"parser.docment").err("Unexpected Open Curly at [{}, {}]", .{ line, char });
                        }
                        start_coordinate = .{ .line = line, .char = char };
                    },
                    '}' => {
                        if (start_coordinate) |start| {
                            try payload.tokens.?.append(payload.allocator, .{
                                .start = start,
                                .end = .{ .line = line, .char = char },
                                .text = try text.toOwnedSlice(payload.allocator),
                            });
                            start_coordinate = null;
                            text.clearAndFree(payload.allocator);
                        }
                    },
                    else => {
                        if (start_coordinate) |_| {
                            try text.append(payload.allocator, self.char);
                        }
                    },
                }
                char += 1;
            }
        }
    };
}

fn makeParser(reader: anytype) !Parser(@TypeOf(reader)) {
    return .{
        .char = try reader.readByte(),
        .reader = reader,
    };
}

fn parseHeader(reader: anytype) !void {
    var lookback: [4]u8 = [_]u8{ 0, 0, 0, 0 };
    while (true) {
        std.mem.copyForwards(u8, lookback[0..3], lookback[1..4]);
        lookback[lookback.len - 1] = reader.readByte() catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (std.mem.eql(u8, &lookback, "\r\n\r\n")) {
            return;
        }
    }
}

fn parseJson(server: *Server, reader: anytype) !void {
    std.log.scoped(.parser).info("BEGIN parseJson", .{});
    defer std.log.scoped(.parser).info("-END- parseJson", .{});
    var payload = Payload.init(server.allocator);
    defer payload.deinit();
    var parser = try makeParser(reader);
    const end = blk: {
        parser.parseContent(&payload) catch |e| switch (e) {
            error.EndOfStream => break :blk true,
            else => {
                std.log.scoped(.parser).err("parseJson error {s}", .{@errorName(e)});
                return e;
            },
        };
        break :blk false;
    };
    try server.process(&payload);
    if (end) {
        return error.EndOfStream;
    }
}

pub fn main() !u8 {
    const allocator = std.heap.page_allocator;
    var parts = std.ArrayList([]const u8).init(allocator);
    if (std.os.getenv("XDG_CACHE_HOME")) |dir| {
        try parts.append(dir);
        try parts.append(".cache");
    } else if (std.os.getenv("SLS_LOG_DIR")) |dir| {
        try parts.append(dir);
    } else if (std.os.getenv("HOME")) |dir| {
        try parts.append(dir);
        try parts.append(".cache");
    }
    try parts.append("sls.log");
    log_file = try std.fs.path.join(allocator, parts.items);
    defer allocator.free(log_file.?);
    parts.deinit();
    std.log.info("Initiating sls!", .{});
    var server = Server.init(allocator);
    defer server.deinit();
    const reader = std.io.getStdIn().reader();
    while (server.running) {
        parseHeader(reader) catch |e| switch (e) {
            error.EndOfStream => {
                std.log.info("EndOfStream while parsing header", .{});
                break;
            },
            else => return e,
        };
        parseJson(&server, reader) catch |e| switch (e) {
            error.EndOfStream => {
                std.log.info("EndOfStream while parsing JSON", .{});
                break;
            },
            else => return e,
        };
    }
    return 0;
}
