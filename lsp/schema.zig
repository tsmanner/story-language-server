//! Language Server Protocol implementation.
//! This is a nearly 1:1 implementation of the LSP data model and flow.
//!
//! String enums:
//!   This implementation has chosen to represent string enums using their string representations as their tag name,
//!   rather than duplicate the LSP defined names and strings in parallel structures.  Unfortunately, at least one LSP
//!   string enum has a tag `Empty = ""`.  Zig doesn't allow empty field names, even with `.@""`, so these fields are
//!   currently omitted from the enum entirely.
//!
//! Null handling:
//!   The LSP allows many fields to be omitted entirely from messages.  This is great for compatibility, but leads to
//!   a bit of ambiguity on the zig side in this implementation.  The obvious solution is to use optionals to represent
//!   the optional field that we know about, and ignore the ones we don't, and setting the `.emit_null_optional_fields`
//!   option to `false` when calling `jsonStringify`.  There is another class of value in the LSP that is required to
//!   be present, but may take the value `null`, which would be handled easily by setting that same option to `true`
//!   instead.  Because it can't be set per-field, and we would like to avoid duplicating a large part of the standard
//!   library here, we instead support two solutions:
//!     1. Any type that can be null can be wrapped in `Nullable`, which is a simple struct holding an optional
//!        instance of that type.  `Nullable` defines a `jsonStringify` function that always stringifies the underlying
//!        optional, which naturally prints `null` if it is not set, and the value if it is.  This hides the optional
//!        from the standard library stream writer, causing `Nullable` fields to always be printed, regardless of the
//!        `emit_null_optional_fields` setting.
//!     2. Union types that can be null may add `null: Null` to the set of union fields and declare
//!       `pub const jsonStringify = jsonStringifyUnion;`, which will stringify the union as it's value, omitting the
//!        active tag.
//!
//! Options vs RegistrationOptions
//!   Many LSP configurations are negotiated using a union of `boolean | FeatureOptions | FeatureRegistrationOptions`,
//!   where the registration options struct inherits from the normal options.  This library only defines the
//!   registration form, and guarantees that the additional fields are all optional.

const std = @import("std");

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const DocumentUri = struct {
    value: std.Uri,

    pub fn jsonParseFromValue(
        _: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) std.json.ParseFromValueError!DocumentUri {
        return switch (source) {
            .string => |string| .{ .value = std.Uri.parse(string) catch return error.UnexpectedToken },
            else => error.UnexpectedToken,
        };
    }
};

pub fn BoolOrOptions(comptime Options: type) type {
    return union(enum) {
        boolean: bool,
        options: Options,
        pub const jsonParseFromValue = jsonParseFromValueUnion(@This());
        pub const jsonStringify = jsonStringifyUnion;
    };
}

pub const Id = struct {
    value: ?u32,

    pub fn format(
        self: Id,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (self.value) |value| {
            return std.fmt.formatType(value, fmt, options, writer, 1);
        } else {
            if (std.ascii.isDigit(@truncate(options.fill))) {
                return std.fmt.formatType('-', "c", .{
                    .precision = options.precision,
                    .width = options.width,
                    .alignment = options.alignment,
                    .fill = '-',
                }, writer, 1);
            } else {
                return std.fmt.formatType('-', "c", options, writer, 1);
            }
        }
    }
};

pub const Message = struct {
    jsonrpc: []const u8,
    id: Id,
    payload: union(enum) {
        request: Request,
        response: Response,
    },

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!Message {
        switch (source) {
            .object => |*object| {
                const jsonrpc = try std.json.innerParseFromValue(
                    []const u8,
                    allocator,
                    object.get("jsonrpc") orelse return error.MissingField,
                    options,
                );
                const id = Id{
                    .value = if (object.get("id")) |id_json|
                        try std.json.innerParseFromValue(u32, allocator, id_json, options)
                    else
                        null,
                };
                // This looks like an RPC request
                if (object.get("method")) |method| {
                    const method_tag = std.meta.stringToEnum(Request.Tag, method.string) orelse {
                        std.log.info("Invalid method {s}", .{method.string});
                        return error.InvalidEnumTag;
                    };
                    switch (method_tag) {
                        inline else => |tag| {
                            const Payload = std.meta.TagPayload(Request, tag);
                            switch (@typeInfo(Payload)) {
                                .@"struct" => {
                                    if (object.get("params")) |params| {
                                        return .{ .jsonrpc = jsonrpc, .id = id, .payload = .{ .request = @unionInit(
                                            Request,
                                            @tagName(tag),
                                            try std.json.innerParseFromValue(
                                                Payload,
                                                allocator,
                                                params,
                                                options,
                                            ),
                                        ) } };
                                    }
                                    std.log.err("While parsing an incoming message: 'params' key not found", .{});
                                    return error.MissingField;
                                },
                                .void => {
                                    return .{ .jsonrpc = jsonrpc, .id = id, .payload = .{ .request = @unionInit(Request, @tagName(tag), void{}) } };
                                },
                                else => {
                                    std.log.err("Request payload is not a struct or void", .{});
                                    return error.MissingField;
                                },
                            }
                        },
                    }
                } else {
                    std.log.err("Unrecognized message: expected 'method' field.", .{});
                    return error.MissingField;
                }
            },
            else => |token| {
                std.log.err("Unexpected '{}' JSON token, expected 'object'", .{token});
                return error.UnexpectedToken;
            },
        }
    }

    pub fn jsonStringify(self: Message, write_stream: anytype) !void {
        try write_stream.beginObject();

        try write_stream.objectField("jsonrpc");
        try write_stream.write(self.jsonrpc);

        if (self.id.value) |id| {
            try write_stream.objectField("id");
            try write_stream.write(id);
        }

        switch (self.payload) {
            .request => |request| {
                _ = request;
            },
            .response => |*response| {
                switch (response.*) {
                    .none => {},
                    .@"error" => |err| {
                        _ = err;
                    },
                    .initialize => |*init| {
                        // result: {}   <- the init struct
                        try write_stream.objectField("result");
                        try write_stream.write(init);
                    },
                }
            },
        }
        try write_stream.endObject();
    }
};

pub const Request = union(enum) {
    const Tag = std.meta.Tag(@This());

    initialize: InitializeParams,
    // initialized: Initialized.Params,
    @"textDocument/didOpen": TextDocument.DidOpen.Params,
    shutdown: Shutdown.Params,
};

pub const Response = union(enum) {
    const Tag = std.meta.Tag(@This());
    pub const Error = struct {
        pub const Code = enum(i32) {
            ParseError = -32700,
            InvalidRequest = -32600,
            MethodNotFound = -32601,
            InvalidParams = -32602,
            InternalError = -32603,
            ServerNotInitialized = -32002,
            UnknownErrorCode = -32001,
            RequestFailed = -32803,
            ServerCancelled = -32802,
            ContentModified = -32801,
            RequestCancelled = -32800,
        };

        code: Code,
        message: []const u8,
    };

    // None means there is no response payload, but the operation was successful.
    none: struct {},
    initialize: InitializeResult,
    @"error": Error,
};

pub const TextDocument = struct {
    pub const Item = struct {
        uri: DocumentUri,
        languageId: []const u8,
        version: i32,
        text: []const u8,
    };
    pub const DidOpen = struct {
        pub const Params = struct {
            textDocument: Item,
        };
    };
};

pub const Shutdown = struct {
    pub const Params = void;
};

//
// New stuff
//

//
// LSP message types
//

pub const HeaderPart = struct {
    content_length: usize,
    content_type: ?[]const u8,

    pub fn parse(reader: std.io.AnyReader) !HeaderPart {
        var content_length: ?usize = null;
        var content_type: ?[]const u8 = null;
        var buf: [4096]u8 = undefined;
        while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            // A blank line means the header is over.  Delimiter is not included in line.
            if (std.mem.eql(u8, "\r", line)) {
                break;
            } else if (std.mem.startsWith(u8, line, "Content-Length: ")) {
                // line.len - 1 because LSP requires \r\n line endings...
                content_length = try std.fmt.parseInt(usize, line[16 .. line.len - 1], 10);
            } else if (std.mem.startsWith(u8, line, "Content-Type: ")) {
                // line.len - 1 because LSP requires \r\n line endings...
                content_type = line[14 .. line.len - 1];
            }
        }
        if (content_length == null) {
            return error.HeaderPartMissingContentLength;
        }
        return .{
            .content_length = content_length.?,
            .content_type = content_type,
        };
    }

    pub fn format(
        self: HeaderPart,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll("Content-Length: ");
        try std.fmt.format(writer, "{}", .{self.content_length});
        if (self.content_type) |content_type| {
            try writer.writeAll(" Content-Type: ");
            try std.fmt.format(writer, "{s}", .{content_type});
        }
    }
};

test "jsonParseFromValue HeaderPart" {
    var buf = std.io.fixedBufferStream("Content-Length: 12345\r\n\r\n");
    const header = try HeaderPart.parse(buf.reader().any());
    try std.testing.expectEqual(@as(usize, 12345), header.content_length);

    buf = std.io.fixedBufferStream("\r\n");
    try std.testing.expectError(error.HeaderPartMissingContentLength, HeaderPart.parse(buf.reader().any()));
}

pub const ContentPart = union(enum) {
    notification: NotificationMessage,
    request: RequestMessage,
    response: ResponseMessage,

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!ContentPart {
        switch (source) {
            .object => |object| {
                if (object.contains("method")) {
                    if (object.contains("id")) {
                        return .{ .request = try std.json.parseFromValueLeaky(RequestMessage, allocator, source, options) };
                    } else {
                        return .{ .notification = try std.json.parseFromValueLeaky(NotificationMessage, allocator, source, options) };
                    }
                } else if (object.contains("result") or object.contains("error")) {
                    return .{ .response = try std.json.parseFromValueLeaky(ResponseMessage, allocator, source, options) };
                } else {
                    return error.UnexpectedToken;
                }
            },
            else => return error.UnexpectedToken,
        }
    }

    pub const jsonStringify = jsonStringifyUnion;
};

test "jsonParseFromValue ContentPart" {
    const jsonrpc_s = "\"jsonrpc\":\"2.0\"";
    const id_s = "\"id\":5";
    const method_s = "\"method\":\"initialize\"";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var scanner = std.json.Scanner.initCompleteInput(arena.allocator(), "{}");
    var json_value = try std.json.Value.jsonParse(arena.allocator(), &scanner, .{ .max_value_len = scanner.input.len });
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromValueLeaky(ContentPart, arena.allocator(), json_value, .{}));

    _ = arena.reset(.free_all);
    scanner = std.json.Scanner.initCompleteInput(arena.allocator(), "{" ++ method_s ++ "}");
    json_value = try std.json.Value.jsonParse(arena.allocator(), &scanner, .{ .max_value_len = scanner.input.len });
    try std.testing.expectError(error.MissingField, std.json.parseFromValueLeaky(ContentPart, arena.allocator(), json_value, .{}));

    _ = arena.reset(.free_all);
    scanner = std.json.Scanner.initCompleteInput(arena.allocator(), "{" ++ jsonrpc_s ++ "," ++ method_s ++ "}");
    json_value = try std.json.Value.jsonParse(arena.allocator(), &scanner, .{ .max_value_len = scanner.input.len });
    var content = try std.json.parseFromValueLeaky(ContentPart, arena.allocator(), json_value, .{});
    try std.testing.expectEqual(.notification, std.meta.activeTag(content));
    try std.testing.expectEqualStrings("2.0", content.notification.jsonrpc);

    _ = arena.reset(.free_all);
    scanner = std.json.Scanner.initCompleteInput(arena.allocator(), "{" ++ jsonrpc_s ++ "," ++ id_s ++ "," ++ method_s ++ "}");
    json_value = try std.json.Value.jsonParse(arena.allocator(), &scanner, .{ .max_value_len = scanner.input.len });
    content = try std.json.parseFromValueLeaky(ContentPart, arena.allocator(), json_value, .{});
    try std.testing.expectEqual(.request, std.meta.activeTag(content));
    try std.testing.expectEqualStrings("2.0", content.request.jsonrpc);
    try std.testing.expectEqual(5, content.request.id.integer);
}

const Null = @TypeOf(null);

const Method = struct {
    /// If a method accepts parameters, this optional is the LSP data type of them.  null means it is called
    /// without parameters.
    params: ?type = null,
    /// If a method returns a result, this is the data type of it.  null means a method sends a response message with
    /// an explicit null result.  Notifications must be null.
    result: ?type = null,

    pub const RequestResult = union(enum) {
        result: ?[]const u8,
        @"error": ResponseError,
    };

    pub const initialize = Method{ .params = InitializeParams, .result = InitializeResult };
    pub const initialized = Method{ .params = InitializeParams };
    pub const @"textDocument/didOpen" = Method{ .params = TextDocument.DidOpen.Params };
    pub const shutdown = Method{};
    pub const exit = Method{};
};

/// Read LSP messages from `in` in a loop and dispatch them to `backend` until `backend` returns `error.Break` or
/// the stream ends.  The stream ending before a break is a fatal error.
pub fn serve(allocator: std.mem.Allocator, in: std.io.AnyReader, out: std.io.AnyWriter, backend: anytype) !void {
    _ = out;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const header = try HeaderPart.parse(in);
        const buf = allocator.alloc(u8, header.content_length);
        defer allocator.free(buf);
        if (in.readAll(buf) < buf.len) {
            std.log.err("End of stream reached before Content-Length of {} bytes was read.", .{buf.len});
            return error.EndOfStream;
        }
        var scanner = std.json.Scanner.initCompleteInput(arena.allocator(), buf);
        const json_value = try std.json.Value.jsonParse(arena.allocator(), &scanner, .{ .max_value_len = buf.len });
        const content = try std.json.parseFromValueLeaky(ContentPart, arena.allocator(), json_value, .{});
        switch (content) {
            .notification => |notification| {
                callMethod(void, callMethodNotification, arena.allocator(), backend, notification.method, notification.params) catch |err|
                    std.log.err("Caught error '{}' while processing '{s}' notification", .{ err, notification.method });
                if (std.mem.eql(u8, "exit", notification.method)) {
                    break;
                }
            },
            .request => |request| {
                const response = ResponseMessage.init(
                    request.id,
                    callMethod(?[]const u8, callMethodRequest, arena.allocator(), backend, request.method, request.params),
                );
                _ = response;
            },
            .response => |response| {
                _ = response;
            },
        }
        break;
    }
}

/// Returns an error, or void.
fn callMethodNotification(
    allocator: std.mem.Allocator,
    backend: anytype,
    comptime method_name: []const u8,
    params: ?std.json.Value,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const Backend = @TypeOf(backend);
    const method = @field(Backend, method_name);
    try @call(
        .auto,
        method,
        if (@field(Method, method_name).params) |Params|
            .{ backend, try std.json.parseFromValueLeaky(Params, arena.allocator(), params, .{}) }
        else
            .{backend},
    );
}

/// Returns an error, the stringified result, or null.  The caller owns the returned memory.
fn callMethodRequest(
    allocator: std.mem.Allocator,
    backend: anytype,
    comptime method_name: []const u8,
    params: ?std.json.Value,
) ![]const u8 {
    const Backend = @TypeOf(backend);
    const method = @field(Backend, method_name);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    if (@field(Method, method_name).result) |Result| {
        const result: Result = try @call(
            .auto,
            method,
            if (@field(Method, method_name).params) |Params|
                .{ backend, try std.json.parseFromValueLeaky(Params, arena.allocator(), params orelse return error.InvalidParams, .{}) }
            else
                .{backend},
        );
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        try std.json.stringify(result, .{ .emit_null_optional_fields = false }, buf.writer());
        return try buf.toOwnedSlice();
    } else {
        try @call(
            .auto,
            method,
            if (@field(Method, method_name).params) |Params|
                .{ backend, try std.json.parseFromValueLeaky(Params, arena.allocator(), params, .{}) }
            else
                .{backend},
        );
        return "null";
    }
}

/// Matches method_name to the methods declared in the Method type, and then uses an inline switch to promote that
/// string to a comptime field name that can be used to resolve the backend function to call and the Params and
/// Result types by the callHandler.
fn callMethod(
    comptime Result: type,
    comptime callHandler: anytype,
    allocator: std.mem.Allocator,
    backend: anytype,
    method_name: []const u8,
    params: ?std.json.Value,
) !Result {
    const Backend = @TypeOf(backend);
    if (std.meta.stringToEnum(std.meta.DeclEnum(Method), method_name)) |method_rt| {
        switch (method_rt) {
            inline else => |method_ct| {
                const method_name_ct = @tagName(method_ct);
                if (std.meta.hasMethod(Backend, method_name_ct)) {
                    return callHandler(allocator, backend, method_name_ct, params);
                } else {
                    return error.NotImplemented;
                }
            },
        }
    } else {
        return error.UnrecognizedMethodName;
    }
}

//
// LSP data types
//

pub const CallHierarchyClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
};

pub const CallHierarchyRegistrationOptions = struct {
    workDoneProgress: ?bool = null,
    documentSelector: ?DocumentSelector = null,
    id: ?[]const u8 = null,
};

pub const ClientCapabilities = struct {
    workDoneToken: ?ProgressToken = null,
    workspace: ?struct {
        applyEdit: ?bool = null,
        workspaceEdit: ?WorkspaceEditClientCapabilities = null,
        didChangeConfiguration: ?DidChangeConfigurationClientCapabilities = null,
        didChangeWatchedFiles: ?DidChangeWatchedFilesClientCapabilities = null,
        symbol: ?WorkspaceSymbolClientCapabilities = null,
        executeCommand: ?ExecuteCommandClientCapabilities = null,
        workspaceFolders: ?bool = null,
        configuration: ?bool = null,
        semanticTokens: ?SemanticTokensWorkspaceClientCapabilities = null,
        codeLens: ?CodeLensWorkspaceClientCapabilities = null,
        fileOperations: ?struct {
            dynamicRegistration: ?bool = null,
            didCreate: ?bool = null,
            willCreate: ?bool = null,
            didRename: ?bool = null,
            willRename: ?bool = null,
            didDelete: ?bool = null,
            willDelete: ?bool = null,
        } = null,
        inlineValue: ?InlineValueWorkspaceClientCapabilities = null,
        inlayHint: ?InlayHintWorkspaceClientCapabilities = null,
        diagnostics: ?DiagnosticsWorkspaceClientCapabilities = null,
    },
    textDocument: ?TextDocumentClientCapabilities = null,
    notebookDocument: ?NotebookDocumentClientCapabilities = null,
    window: Nullable(struct {
        workDoneProgress: ?bool = null,
        showMessage: ?ShowMessageRequestClientCapabilities = null,
        showDocument: ?ShowDocumentClientCapabilities = null,
    }),
    general: Nullable(struct {
        staleRequestSupport: ?struct {
            cancel: bool,
            retryOnContentModified: []const []const u8,
        } = null,
        regularExpressions: ?RegularExpressionsClientCapabilities = null,
        markdown: ?MarkdownClientCapabilities = null,
        positionEncodings: ?[]const PositionEncodingKind = &[_]PositionEncodingKind{.@"utf-16"},
    }),
    experimental: ?std.json.Value = null,
};

pub const CodeActionClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
    codeActionLiteralSupport: ?struct {
        codeActionKind: struct {
            valueSet: []const CodeActionKind,
        },
    } = null,
    isPreferredSupport: ?bool = null,
    disabledSupport: ?bool = null,
    dataSupport: ?bool = null,
    resolveSupport: ?struct {
        properties: []const []const u8,
    } = null,
    honorsChangeAnnotations: ?bool = null,
};

/// Does not include `Empty = ''` kind.
pub const CodeActionKind = enum {
    empty,
    quickfix,
    refactor,
    @"refactor.extract",
    @"refactor.inline",
    @"refactor.rewrite",
    source,
    @"source.organizeImports",
    @"source.fixAll",

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !CodeActionKind {
        switch (source) {
            .string => |string| if (source.string.len == 0) {
                return .empty;
            } else if (std.meta.stringToEnum(CodeActionKind, string)) |kind| {
                return kind;
            },
            else => {},
        }
        return error.InvalidEnumTag;
    }
};

pub const CodeActionOptions = struct {
    workDoneProgress: ?bool = null,
    codeActionKinds: ?[]const CodeActionKind = null,
    resolveProvider: ?bool = null,
};

pub const CodeLensClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
};

pub const CodeLensOptions = struct {
    workDoneProgress: ?bool = null,
    resolveProvider: ?bool = null,
};

pub const CodeLensWorkspaceClientCapabilities = struct {
    refreshSupport: ?bool = null,
};

pub const CompletionClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
    completionItem: ?struct {
        snippetSupport: ?bool = null,
        commitCharactersSupport: ?bool = null,
        documentationFormat: ?[]const MarkupKind = null,
        deprecatedSupport: ?bool = null,
        preselectSupport: ?bool = null,
        tagSupport: ?struct {
            valueSet: []const CompletionItemTag,
        } = null,
        insertReplaceSupport: ?bool = null,
        resolveSupport: ?struct {
            properties: []const []const u8,
        } = null,
        insertTextModeSupport: ?struct {
            valueSet: []const InsertTextMode,
        } = null,
        labelDetailsSupport: ?bool = null,
    } = null,
    completionItemKind: ?struct {
        valueSet: ?[]const CompletionItemKind = null,
    } = null,
    contextSupport: ?bool = null,
    insertTextMode: ?InsertTextMode = null,
    completionList: ?struct {
        itemDefaults: ?[]const []const u8 = null,
    } = null,
};

pub const CompletionItemTag = enum(i32) {
    Deprecated = 1,
    pub const jsonStringify = jsonStringifyEnumAsInt;
};

pub const CompletionItemKind = enum(i32) {
    Text = 1,
    Method = 2,
    Function = 3,
    Constructor = 4,
    Field = 5,
    Variable = 6,
    Class = 7,
    Interface = 8,
    Module = 9,
    Property = 10,
    Unit = 11,
    Value = 12,
    Enum = 13,
    Keyword = 14,
    Snippet = 15,
    Color = 16,
    File = 17,
    Reference = 18,
    Folder = 19,
    EnumMember = 20,
    Constant = 21,
    Struct = 22,
    Event = 23,
    Operator = 24,
    TypeParameter = 25,
    pub const jsonStringify = jsonStringifyEnumAsInt;
};

pub const CompletionOptions = struct {
    workDoneProgress: ?bool = null,
    triggerCharacters: ?[]const []const u8 = null,
    allCommitCharacters: ?[]const []const u8 = null,
    resolveProvider: ?bool = null,
    completionItem: ?struct {
        labelDetailsSupport: ?bool = null,
    } = null,
};

pub const DeclarationClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
    linkSupport: ?bool = null,
};

pub const DeclarationRegistrationOptions = struct {
    workDoneProgress: ?bool = null,
    documentSelector: ?DocumentSelector = null,
    id: ?[]const u8 = null,
};

pub const DefinitionClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
    linkSupport: ?bool = null,
};

pub const DefinitionOptions = struct {
    workDoneProgress: ?bool = null,
};

pub const DiagnosticRegistrationOptions = struct {
    identifier: ?[]const u8 = null,
    interFileDependencies: bool,
    workspaceDiagnostics: bool,
    workDoneProgress: ?bool = null,
    documentSelector: ?DocumentSelector = null,
    id: ?[]const u8 = null,
};

pub const DiagnosticTag = enum(i32) {
    Unnecessary = 1,
    Deprecated = 2,
    pub const jsonStringify = jsonStringifyEnumAsInt;
};

pub const DiagnosticsClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
    relatedDocumentSupport: ?bool = null,
};

pub const DiagnosticsWorkspaceClientCapabilities = struct {
    refreshSupport: ?bool = null,
};

pub const DidChangeConfigurationClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
};

pub const DidChangeWatchedFilesClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
    relativePatternSupport: ?bool = null,
};

pub const DocumentColorOptions = struct {
    workDoneProgress: ?bool = null,
};

pub const DocumentColorProviderClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
};

pub const DocumentColorRegistrationOptions = struct {
    workDoneProgress: ?bool = null,
    documentSelector: Nullable(DocumentSelector),
    id: ?[]const u8 = null,
};

pub const DocumentFilter = struct {
    language: ?[]const u8 = null,
    scheme: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
};

pub const DocumentFormattingClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
};

pub const DocumentFormattingOptions = struct {
    workDoneProgress: ?bool = null,
};

pub const DocumentHighlightClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
};

pub const DocumentHighlightOptions = struct {
    workDoneProgress: ?bool = null,
};

pub const DocumentLinkClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
    tooltipSupport: ?bool = null,
};

pub const DocumentLinkOptions = struct {
    workDoneProgress: ?bool = null,
    resolveProvider: ?[]const u8 = null,
};

pub const DocumentOnTypeFormattingClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
};

pub const DocumentOnTypeFormattingOptions = struct {
    firstTriggerCharacter: []const u8,
    moreTriggerCharacters: ?[]const []const u8 = null,
};

pub const DocumentRangeFormattingClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
};

pub const DocumentRangeFormattingOptions = struct {
    workDoneProgress: ?bool = null,
};

pub const DocumentSelector = []const DocumentFilter;

pub const DocumentSymbolClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
    symbolKind: ?struct {
        valueSet: ?[]const SymbolKind = null,
    } = null,
    hierarchicalDocumentSymbolSupport: ?bool = null,
    tagSupport: ?struct {
        valueSet: []const SymbolTag,
    } = null,
    labelSupport: ?bool = null,
};

pub const DocumentSymbolOptions = struct {
    workDoneProgress: ?bool = null,
    label: ?[]const u8 = null,
};

pub const ErrorCodes = enum(i32) {
    ParseError = -32700,
    InvalidRequest = -32600,
    MethodNotFound = -32601,
    InvalidParams = -32602,
    InternalError = -32603,
    ServerNotInitialized = -32002,
    UnknownErrorCode = -32001,
    RequestFailed = -32803,
    ServerCancelled = -32802,
    ContentModified = -32801,
    RequestCancelled = -32800,
};

pub const ExecuteCommandClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
};

pub const ExecuteCommandOptions = struct {
    workDoneProgress: ?bool = null,
    commands: []const []const u8,
};

pub const FailureHandlingKind = enum {
    abort,
    transactional,
    textOnlyTransactional,
    undo,
};

pub const FileOperationFilter = struct {
    scheme: ?[]const u8 = null,
    pattern: FileOperationPattern,
};

pub const FileOperationPattern = struct {
    glob: []const u8,
    matches: ?FileOperationPatternKind = null,
    options: ?FileOperationPatternOptions = null,
};

pub const FileOperationPatternKind = enum {
    file,
    folder,
};

pub const FileOperationPatternOptions = struct {
    ignoreCase: ?bool = null,
};

pub const FileOperationRegistrationOptions = struct {
    filters: []const FileOperationFilter,
};

pub const FoldingRangeClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
    rangeLimit: ?u32 = null,
    lineFoldingOnly: ?bool = null,
    foldingRangeKind: ?struct {
        valueSet: ?[]const FoldingRangeKind = null,
    } = null,
    foldingRange: ?struct {
        collapsedText: ?bool = null,
    } = null,
};

pub const FoldingRangeKind = enum {
    commend,
    imports,
    region,
};

pub const FoldingRangeRegistrationOptions = struct {
    workDoneProgress: ?bool = null,
    documentSelector: ?DocumentSelector = null,
    id: ?[]const u8 = null,
};

pub const HoverClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
    contentFormat: []const []const u8,
};

pub const HoverOptions = struct {
    workDoneProgress: ?bool = null,
};

pub const ImplementationClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
    linkSupport: ?bool = null,
};

pub const ImplementationRegistrationOptions = struct {
    workDoneProgress: ?bool = null,
    documentSelector: ?DocumentSelector = null,
    id: ?[]const u8 = null,
};

pub const InitializeParams = struct {
    processId: Nullable(u64),
    clientInfo: ?struct {
        name: []const u8,
        version: []const u8,
    } = null,
    locale: ?[]const u8 = null,
    rootPath: ?[]const u8 = null,
    rootUri: Nullable(DocumentUri),
    initializationOptions: ?std.json.Value = null,
    capabilities: ClientCapabilities,
    trace: ?TraceValue = null,
    workspaceFolders: ?[]const WorkspaceFolder = null,
};

pub const InitializeResult = struct {
    capabilities: ServerCapabilities,
    serverInfo: ?struct {
        name: []const u8,
        version: ?[]const u8 = null,
    } = null,
};

pub const InlineValueClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
};

pub const InlineValueRegistrationOptions = struct {
    workDoneProgress: ?bool = null,
    documentSelector: ?DocumentSelector = null,
    id: ?[]const u8 = null,
};

pub const InlineValueWorkspaceClientCapabilities = struct {
    refreshSupport: ?bool = null,
};

pub const InlayHintClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
};

pub const InlayHintRegistrationOptions = struct {
    resolveProvider: ?bool = null,
    workDoneProgress: ?bool = null,
    documentSelector: ?DocumentSelector = null,
    id: ?[]const u8 = null,
};

pub const InlayHintWorkspaceClientCapabilities = struct {
    refreshSupport: ?bool = null,
};

pub const InsertTextMode = enum(i32) {
    asIs = 1,
    adjustIndentation = 2,
    pub const jsonStringify = jsonStringifyEnumAsInt;
};

pub const LinkedEditingRangeClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
};

pub const LinkedEditingRangeRegistrationOptions = struct {
    workDoneProgress: ?bool = null,
    documentSelector: ?DocumentSelector = null,
    id: ?[]const u8 = null,
};

pub const MarkdownClientCapabilities = struct {
    parser: []const u8,
    version: ?[]const u8 = null,
    allowedTags: ?[]const []const u8 = null,
};

pub const MarkupKind = enum {
    plaintext,
    markdown,
};

pub const MessageId = union(enum) {
    integer: i32,
    string: []const u8,
    pub const jsonParseFromValue = jsonParseFromValueUnion(@This());
    pub const jsonStringify = jsonStringifyUnion;
};

pub const MonikerClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
};

pub const MonikerRegistrationOptions = struct {
    workDoneProgress: ?bool = null,
    documentSelector: ?DocumentSelector = null,
};

pub const NotebookDocumentClientCapabilities = struct {
    synchronization: struct {
        dynamicRegistration: ?bool = null,
        executionSummarySupport: ?bool = null,
    },
};

pub const NotebookDocumentFilter = struct {
    notebookType: ?[]const u8 = null,
    scheme: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
};

pub const NotebookDocumentSyncRegistrationOptions = struct {
    notebookSelector: []const struct {
        notebook: ?union(enum) {
            string: []const u8,
            filter: NotebookDocumentFilter,
            pub const jsonParseFromValue = jsonParseFromValueUnion(@This());
            pub const jsonStringify = jsonStringifyUnion;
        } = null,
        cells: ?[]const struct {
            language: []const u8,
        } = null,
    },
    save: ?bool = null,
    id: ?[]const u8 = null,
};

pub const NotificationMessage = struct {
    jsonrpc: []const u8,
    method: []const u8,
    /// Parsed into the method's params type later.
    params: ?std.json.Value = null,
};

pub const PositionEncodingKind = enum {
    @"utf-8",
    @"utf-16",
    @"utf-32",
};

pub const PrepareSupportDefaultBehavior = enum(i32) {
    Identifier = 1,
    pub const jsonStringify = jsonStringifyEnumAsInt;
};

pub const ProgressToken = union(enum) {
    integer: i32,
    string: []const u8,
    pub const jsonParseFromValue = jsonParseFromValueUnion(@This());
    pub const jsonStringify = jsonStringifyUnion;
};

pub const PublishDiagnosticsClientCapabilities = struct {
    relatedInformation: ?bool = null,
    tagSupport: ?struct {
        valueSet: []const DiagnosticTag,
    } = null,
    versionSupport: ?bool = null,
    codeDescriptionSupport: ?bool = null,
    dataSupport: ?bool = null,
};

pub const ReferencesClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
};

pub const ReferencesOptions = struct {
    workDoneProgress: ?bool = null,
};

pub const RegularExpressionsClientCapabilities = struct {
    engine: []const u8,
    version: ?[]const u8 = null,
};

pub const RenameClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
    prepareSupport: ?bool = null,
    prepareSupportDefaultBehavior: ?PrepareSupportDefaultBehavior = null,
    honorsChangeAnnotations: ?bool = null,
};

pub const RenameOptions = struct {
    workDoneProgress: ?bool = null,
    prepareProvider: ?bool = null,
};

pub const RequestMessage = struct {
    jsonrpc: []const u8,
    id: MessageId,
    method: []const u8,
    /// Parsed into the method's params type later.
    params: ?std.json.Value = null,
};

pub const ResourceOperationKind = enum {
    create,
    rename,
    delete,
};

pub const ResponseError = struct {
    code: ErrorCodes,
    message: []const u8,
    /// JSON stringified additional data.
    data: ?[]const u8 = null,
};

pub const ResponseMessage = struct {
    jsonrpc: []const u8,
    id: MessageId,
    /// JSON stringified result for the matching request's method.
    result: ?[]const u8 = null,
    @"error": ?ResponseError = null,

    pub fn init(id: MessageId, payload: anytype) ResponseMessage {
        var response: ResponseMessage = .{
            .jsonrpc = "2.0",
            .id = id,
        };
        if (payload) |result| {
            response.result = result;
        } else |err| {
            response.@"error" = .{
                .code = if (std.meta.stringToEnum(ErrorCodes, @tagName(err))) |code| code else .InternalError,
                .message = @tagName(err),
            };
        }
        return response;
    }
};

pub const SelectionRangeClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
};

pub const SelectionRangeRegistrationOptions = struct {
    workDoneProgress: ?bool = null,
    documentSelector: ?DocumentSelector = null,
    id: ?[]const u8 = null,
};

pub const SemanticTokensClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
    requests: struct {
        range: ?union(enum) {
            boolean: bool,
            object: struct {},
            pub const jsonParseFromValue = jsonParseFromValueUnion(@This());
            pub const jsonStringify = jsonStringifyUnion;
        } = null,
        full: ?union(enum) {
            boolean: bool,
            object: struct {
                delta: ?bool = null,
            },
            pub const jsonParseFromValue = jsonParseFromValueUnion(@This());
            pub const jsonStringify = jsonStringifyUnion;
        } = null,
    },
    tokenTypes: []const []const u8,
    tokenModifiers: []const []const u8,
    formats: []const TokenFormat,
    overlappingTokenSupport: ?bool = null,
    multilineTokenSupport: ?bool = null,
    serverCancelSupport: ?bool = null,
    augmentsSyntaxTokens: ?bool = null,
};

pub const SemanticTokensLegend = struct {
    tokenTypes: []const []const u8,
    tokenModifiers: []const []const u8,
};

pub const SemanticTokensRegistrationOptions = struct {
    workDoneProgress: ?bool = null,
    legend: SemanticTokensLegend,
    range: ?union(enum) {
        boolean: bool,
        object: struct {},
        pub const jsonParseFromValue = jsonParseFromValueUnion(@This());
        pub const jsonStringify = jsonStringifyUnion;
    } = null,
    full: ?union(enum) {
        boolean: bool,
        object: struct {
            delta: ?bool = null,
        },
        pub const jsonParseFromValue = jsonParseFromValueUnion(@This());
        pub const jsonStringify = jsonStringifyUnion;
    } = null,
    documentSelector: ?DocumentSelector = null,
    id: ?[]const u8 = null,
};

pub const SemanticTokensWorkspaceClientCapabilities = struct {
    refreshSupport: ?bool = null,
};

pub const ServerCapabilities = struct {
    positionEncoding: ?PositionEncodingKind = null,
    textDocumentSync: ?union(enum) {
        options: TextDocumentSyncOptions,
        kind: TextDocumentSyncKind,
        pub const jsonParseFromValue = jsonParseFromValueUnion(@This());
        pub const jsonStringify = jsonStringifyUnion;
    } = null,
    notebookDocumentSync: ?NotebookDocumentSyncRegistrationOptions = null,
    completionProvider: ?CompletionOptions = null,
    hoverProvider: ?BoolOrOptions(HoverOptions) = null,
    signatureHelpProvider: ?SignatureHelpOptions = null,
    declarationProvider: ?BoolOrOptions(DeclarationRegistrationOptions) = null,
    definitionProvider: ?BoolOrOptions(DefinitionOptions) = null,
    typeDefinitionProvider: ?BoolOrOptions(TypeDefinitionRegistrationOptions) = null,
    implementationProvider: ?BoolOrOptions(ImplementationRegistrationOptions) = null,
    referencesProvider: ?BoolOrOptions(ReferencesOptions) = null,
    documentHighlightProvider: ?BoolOrOptions(DocumentHighlightOptions) = null,
    documentSymbolProvider: ?BoolOrOptions(DocumentSymbolOptions) = null,
    codeActionProvider: ?BoolOrOptions(CodeActionOptions) = null,
    codeLenseProvider: ?CodeLensOptions = null,
    documentLinkProvider: ?DocumentLinkOptions = null,
    colorProvider: ?BoolOrOptions(DocumentColorRegistrationOptions) = null,
    documentFormattingProvider: ?BoolOrOptions(DocumentFormattingOptions) = null,
    documentRangeFormattingProvider: ?BoolOrOptions(DocumentRangeFormattingOptions) = null,
    documentOnTypeFormattingProvider: ?DocumentOnTypeFormattingOptions = null,
    renameProvider: ?BoolOrOptions(RenameOptions) = null,
    foldingRangeProvider: ?BoolOrOptions(FoldingRangeRegistrationOptions) = null,
    executeCommandProvider: ?ExecuteCommandOptions = null,
    selectionRangeProvider: ?BoolOrOptions(SelectionRangeRegistrationOptions) = null,
    linkedEditingRangeProvider: ?BoolOrOptions(LinkedEditingRangeRegistrationOptions) = null,
    callHierarchyProvider: ?BoolOrOptions(CallHierarchyRegistrationOptions) = null,
    semanticTokensProvider: ?SemanticTokensRegistrationOptions = null,
    monikerProvider: ?BoolOrOptions(MonikerRegistrationOptions) = null,
    typeHierarchyProvider: ?BoolOrOptions(TypeHierarchyRegistrationOptions) = null,
    inlineValueProvider: ?BoolOrOptions(InlineValueRegistrationOptions) = null,
    inlayHintProvider: ?BoolOrOptions(InlayHintRegistrationOptions) = null,
    diagnosticProvider: ?DiagnosticRegistrationOptions = null,
    workspaceSymbolProvider: ?BoolOrOptions(WorkspaceSymbolOptions) = null,
    workspace: ?struct {
        workspaceFolders: ?WorkspaceFoldersServerCapabilities = null,
        fileOperators: ?struct {
            didCreate: ?FileOperationRegistrationOptions = null,
            willCreate: ?FileOperationRegistrationOptions = null,
            didRename: ?FileOperationRegistrationOptions = null,
            willRename: ?FileOperationRegistrationOptions = null,
            didDelete: ?FileOperationRegistrationOptions = null,
            willDelete: ?FileOperationRegistrationOptions = null,
        } = null,
    } = null,
};

pub const ShowDocumentClientCapabilities = struct {
    support: bool,
};

pub const ShowMessageRequestClientCapabilities = struct {
    messageActionItem: ?struct {
        additionalPropertiesSupport: ?bool = null,
    } = null,
};

pub const SignatureHelpClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
    signatureInformation: ?struct {
        documentationFormat: ?[]const MarkupKind = null,
        parameterInformation: ?struct {
            labelOffsetSupport: ?bool = null,
        } = null,
        activeParameterSupport: ?bool = null,
    } = null,
    contextSupport: ?bool = null,
};

pub const SignatureHelpOptions = struct {
    workDoneProgress: ?bool = null,
    triggerCharacters: ?[]const []const u8 = null,
    retriggerCharacters: ?[]const []const u8 = null,
};

pub const SymbolKind = enum(i32) {
    File = 1,
    Module = 2,
    Namespace = 3,
    Package = 4,
    Class = 5,
    Method = 6,
    Property = 7,
    Field = 8,
    Constructor = 9,
    Enum = 10,
    Interface = 11,
    Function = 12,
    Variable = 13,
    Constant = 14,
    String = 15,
    Number = 16,
    Boolean = 17,
    Array = 18,
    Object = 19,
    Key = 20,
    Null = 21,
    EnumMember = 22,
    Struct = 23,
    Event = 24,
    Operator = 25,
    TypeParameter = 26,
    pub const jsonStringify = jsonStringifyEnumAsInt;
};

pub const SymbolTag = enum(i32) {
    Deprecated = 1,
    pub const jsonStringify = jsonStringifyEnumAsInt;
};

pub const TextDocumentClientCapabilities = struct {
    synchronization: ?TextDocumentSyncClientCapabilities = null,
    completion: ?CompletionClientCapabilities = null,
    hover: ?HoverClientCapabilities = null,
    signatureHelp: ?SignatureHelpClientCapabilities = null,
    declaration: ?DeclarationClientCapabilities = null,
    definition: ?DefinitionClientCapabilities = null,
    typeDefinition: ?TypeDefinitionClientCapabilities = null,
    implementation: ?ImplementationClientCapabilities = null,
    references: ?ReferencesClientCapabilities = null,
    documentHighlight: ?DocumentHighlightClientCapabilities = null,
    documentSymbol: ?DocumentSymbolClientCapabilities = null,
    codeAction: ?CodeActionClientCapabilities = null,
    codeLens: ?CodeLensClientCapabilities = null,
    documentLink: ?DocumentLinkClientCapabilities = null,
    colorProvider: ?DocumentColorProviderClientCapabilities = null,
    formatting: ?DocumentFormattingClientCapabilities = null,
    rangeFormatting: ?DocumentRangeFormattingClientCapabilities = null,
    onTypeFormatting: ?DocumentOnTypeFormattingClientCapabilities = null,
    rename: ?RenameClientCapabilities = null,
    publishDiagnostics: ?PublishDiagnosticsClientCapabilities = null,
    foldingRange: ?FoldingRangeClientCapabilities = null,
    selectionRange: ?SelectionRangeClientCapabilities = null,
    linkedEditingRange: ?LinkedEditingRangeClientCapabilities = null,
    callHierarchy: ?CallHierarchyClientCapabilities = null,
    semanticTokens: ?SemanticTokensClientCapabilities = null,
    moniker: ?MonikerClientCapabilities = null,
    typeHierarchy: ?TypeHierarchyClientCapabilities = null,
    inlineValue: ?InlineValueClientCapabilities = null,
    inlayHint: InlayHintClientCapabilities,
    diagnostics: ?DiagnosticsClientCapabilities = null,
};

pub const TextDocumentSyncClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
    willSave: ?bool = null,
    willSaveWaitUntil: ?bool = null,
    didSave: ?bool = null,
};

pub const TextDocumentSyncKind = enum(u32) {
    None = 0,
    Full = 1,
    Incremental = 2,
    pub const jsonStringify = jsonStringifyEnumAsInt;
};

pub const TextDocumentSyncOptions = struct {
    openClose: ?bool = null,
    change: ?TextDocumentSyncKind = null,
};

pub const TokenFormat = enum {
    relative,
};

pub const TraceValue = enum {
    off,
    messages,
    verbose,
};

pub const TypeDefinitionClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
    linkSupport: ?bool = null,
};

pub const TypeDefinitionRegistrationOptions = struct {
    workDoneProgress: ?bool = null,
    documentSelector: ?DocumentSelector = null,
    id: ?[]const u8 = null,
};

pub const TypeHierarchyClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
};

pub const TypeHierarchyRegistrationOptions = struct {
    workDoneProgress: ?bool = null,
    documentSelector: ?DocumentSelector = null,
    id: ?[]const u8 = null,
};

pub const WorkspaceEditClientCapabilities = struct {
    documentChanges: ?bool = null,
    resourceOperations: ?[]const ResourceOperationKind = null,
    failureHandling: ?FailureHandlingKind = null,
    normalizesLineEndings: ?bool = null,
    changeAnnotationSupport: ?struct {
        groupsOnLabel: ?bool,
    } = null,
};

pub const WorkspaceFolder = struct {
    uri: std.Uri,
    name: []const u8,
};

pub const WorkspaceFoldersServerCapabilities = struct {
    supported: ?bool = null,
    changeNotifications: ?union(enum) {
        string: []const u8,
        boolean: bool,
        pub const jsonParseFromValue = jsonParseFromValueUnion(@This());
        pub const jsonStringify = jsonStringifyUnion;
    } = null,
};

pub const WorkspaceSymbolClientCapabilities = struct {
    dynamicRegistration: ?bool = null,
    symbolKind: ?struct {
        valueSet: ?[]const SymbolKind = null,
    } = null,
    tagSupport: ?struct {
        valueSet: []const SymbolTag,
    } = null,
    resolveSupport: ?struct {
        properties: []const []const u8,
    } = null,
};

pub const WorkspaceSymbolOptions = struct {
    workDoneProgress: ?bool = null,
};

//
// Helpers
//

/// Nullable is an optional that must not be omitted from the JSON
fn Nullable(comptime T: type) type {
    return struct {
        value: ?T,

        pub fn jsonParseFromValue(
            allocator: std.mem.Allocator,
            source: std.json.Value,
            options: std.json.ParseOptions,
        ) !Nullable(T) {
            return .{ .value = try std.json.parseFromValueLeaky(?T, allocator, source, options) };
        }

        pub fn jsonStringify(self: @This(), write_stream: anytype) !void {
            return write_stream.write(self.value);
        }
    };
}

test Nullable {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    out.clearAndFree();
    const n1: Nullable(i32) = .{ .value = 5 };
    try std.testing.expectEqual(@as(i32, 5), n1.value);
    try std.json.stringify(n1, .{ .emit_null_optional_fields = false }, out.writer());
    try std.testing.expectEqualStrings("5", out.items);

    out.clearAndFree();
    const n2: Nullable(i32) = .{ .value = null };
    try std.testing.expectEqual(null, n2.value);
    try std.json.stringify(n2, .{ .emit_null_optional_fields = false }, out.writer());
    try std.testing.expectEqualStrings("null", out.items);
}

fn jsonStringifyEnumAsInt(value: anytype, write_stream: anytype) !void {
    const T = @TypeOf(value);
    const tinfo = @typeInfo(T);
    switch (tinfo) {
        .@"enum" => return write_stream.write(@intFromEnum(value)),
        .pointer => return jsonStringifyEnumAsInt(value.*, write_stream),
        else => @compileError("jsonStringifyEnumAsInt can only be used with enums, not '" ++ @typeName(T) ++ "'"),
    }
}

fn jsonParseFromValueUnion(comptime T: type) fn (
    std.mem.Allocator,
    std.json.Value,
    std.json.ParseOptions,
) std.json.ParseFromValueError!T {
    return struct {
        fn parse(
            allocator: std.mem.Allocator,
            source: std.json.Value,
            options: std.json.ParseOptions,
        ) std.json.ParseFromValueError!T {
            inline for (std.meta.fields(T)) |field| {
                if (std.json.parseFromValueLeaky(field.type, allocator, source, options)) |value| {
                    return @unionInit(T, field.name, value);
                } else |_| {}
            }
            // No matching union payload
            return error.UnexpectedToken;
        }
    }.parse;
}

fn jsonStringifyUnion(value: anytype, write_stream: anytype) !void {
    const T = @TypeOf(value);
    const tinfo = @typeInfo(T);
    switch (tinfo) {
        .@"union" => |u_info| {
            if (u_info.tag_type == null) {
                @compileError("jsonStringifyUnion can only be used with tagged unions, '" ++ @typeName(T) ++ "' is an untagged union");
            }
            switch (value) {
                inline else => |payload| {
                    if (@TypeOf(payload) == void) {
                        try write_stream.beginObject();
                        return write_stream.endObject();
                    } else {
                        return write_stream.write(payload);
                    }
                },
            }
            unreachable;
        },
        .pointer => return jsonStringifyUnion(value.*, write_stream),
        else => @compileError("jsonStringifyUnion can only be used with tagged unions, not '" ++ @typeName(T) ++ "'"),
    }
}

test "std.json.stringify MessageId" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    buf.clearAndFree();
    try std.json.stringify(MessageId{ .integer = 5 }, .{}, buf.writer());
    try std.testing.expectEqualStrings("5", buf.items);

    buf.clearAndFree();
    try std.json.stringify(MessageId{ .string = "foo" }, .{}, buf.writer());
    try std.testing.expectEqualStrings("\"foo\"", buf.items);
}

test "std.json.parseFromValue(MessageId, ...)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var scanner = std.json.Scanner.initCompleteInput(arena.allocator(), "5");
    const json_value_5 = try std.json.Value.jsonParse(arena.allocator(), &scanner, .{ .max_value_len = scanner.input.len });
    try std.testing.expectEqual(@as(i64, 5), json_value_5.integer);
    const id_5 = try std.json.parseFromValueLeaky(MessageId, arena.allocator(), json_value_5, .{});
    try std.testing.expectEqual(.integer, std.meta.activeTag(id_5));
    try std.testing.expectEqual(@as(i32, 5), id_5.integer);

    scanner = std.json.Scanner.initCompleteInput(arena.allocator(), "\"foo\"");
    const json_value_foo = try std.json.Value.jsonParse(arena.allocator(), &scanner, .{ .max_value_len = scanner.input.len });
    try std.testing.expectEqualStrings("foo", json_value_foo.string);
    const id_foo = try std.json.parseFromValueLeaky(MessageId, arena.allocator(), json_value_foo, .{});
    try std.testing.expectEqual(.string, std.meta.activeTag(id_foo));
    try std.testing.expectEqualStrings("foo", id_foo.string);
}

const Foo = struct {
    union_value: union(enum) {
        null: Null,
        void: void,
        empty: struct {},
        full: i32,
        pub const jsonParseFromValue = jsonParseFromValueUnion(@This());
        pub const jsonStringify = jsonStringifyUnion;
    },
    optional: ?i32 = null,
};

test {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    out.clearAndFree();
    try std.json.stringify(Foo{ .union_value = .{ .null = null } }, .{ .emit_null_optional_fields = false }, out.writer());
    try std.testing.expectEqualStrings("{\"union_value\":null}", out.items);

    out.clearAndFree();
    try std.json.stringify(Foo{ .union_value = .{ .void = void{} } }, .{ .emit_null_optional_fields = false }, out.writer());
    try std.testing.expectEqualStrings("{\"union_value\":{}}", out.items);

    out.clearAndFree();
    try std.json.stringify(Foo{ .union_value = .{ .empty = .{} } }, .{ .emit_null_optional_fields = false }, out.writer());
    try std.testing.expectEqualStrings("{\"union_value\":{}}", out.items);

    out.clearAndFree();
    try std.json.stringify(Foo{ .union_value = .{ .full = 5 } }, .{ .emit_null_optional_fields = false }, out.writer());
    try std.testing.expectEqualStrings("{\"union_value\":5}", out.items);

    out.clearAndFree();
    try std.json.stringify(Foo{ .union_value = .{ .null = null }, .optional = 8 }, .{ .emit_null_optional_fields = false }, out.writer());
    try std.testing.expectEqualStrings("{\"union_value\":null,\"optional\":8}", out.items);

    out.clearAndFree();
    try std.json.stringify(Foo{ .union_value = .{ .void = void{} }, .optional = 8 }, .{ .emit_null_optional_fields = false }, out.writer());
    try std.testing.expectEqualStrings("{\"union_value\":{},\"optional\":8}", out.items);

    out.clearAndFree();
    try std.json.stringify(Foo{ .union_value = .{ .empty = .{} }, .optional = 8 }, .{ .emit_null_optional_fields = false }, out.writer());
    try std.testing.expectEqualStrings("{\"union_value\":{},\"optional\":8}", out.items);

    out.clearAndFree();
    try std.json.stringify(Foo{ .union_value = .{ .full = 5 }, .optional = 8 }, .{ .emit_null_optional_fields = false }, out.writer());
    try std.testing.expectEqualStrings("{\"union_value\":5,\"optional\":8}", out.items);
}

test callMethodNotification {
    try callMethod(
        void,
        callMethodNotification,
        std.testing.allocator,
        struct {
            pub fn exit(_: @This()) !void {}
        }{},
        "exit",
        null,
    );
    try std.testing.expectError(error.InvalidParams, callMethod(
        void,
        callMethodNotification,
        std.testing.allocator,
        struct {
            pub fn exit(_: @This()) !void {
                return error.InvalidParams;
            }
        }{},
        "exit",
        null,
    ));
    try std.testing.expectError(error.NotImplemented, callMethod(
        void,
        callMethodNotification,
        std.testing.allocator,
        struct {}{},
        "exit",
        null,
    ));
}

test callMethodRequest {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const initialize_s = "{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-8\",\"utf-32\",\"utf-16\"]},\"textDocument\":{\"codeAction\":{\"codeActionLiteralSupport\":{\"codeActionKind\":{\"valueSet\":[\"\",\"quickfix\",\"refactor\",\"refactor.extract\",\"refactor.inline\",\"refactor.rewrite\",\"source\",\"source.organizeImports\"]}}},\"completion\":{\"completionItem\":{\"deprecatedSupport\":true,\"insertReplaceSupport\":true,\"resolveSupport\":{\"properties\":[\"documentation\",\"detail\",\"additionalTextEdits\"]},\"snippetSupport\":true,\"tagSupport\":{\"valueSet\":[1]}},\"completionItemKind\":{}},\"hover\":{\"contentFormat\":[\"markdown\"]},\"inlayHint\":{\"dynamicRegistration\":false},\"publishDiagnostics\":{\"versionSupport\":true},\"rename\":{\"dynamicRegistration\":false,\"honorsChangeAnnotations\":false,\"prepareSupport\":true},\"signatureHelp\":{\"signatureInformation\":{\"activeParameterSupport\":true,\"documentationFormat\":[\"markdown\"],\"parameterInformation\":{\"labelOffsetSupport\":true}}}},\"window\":{\"workDoneProgress\":true},\"workspace\":{\"applyEdit\":true,\"configuration\":true,\"didChangeConfiguration\":{\"dynamicRegistration\":false},\"executeCommand\":{\"dynamicRegistration\":false},\"inlayHint\":{\"refreshSupport\":false},\"symbol\":{\"dynamicRegistration\":false},\"workspaceEdit\":{\"documentChanges\":true,\"failureHandling\":\"abort\",\"normalizesLineEndings\":false,\"resourceOperations\":[\"create\",\"rename\",\"delete\"]},\"workspaceFolders\":true}},\"clientInfo\":{\"name\":\"helix\",\"version\":\"23.05 (7f5940be)\"},\"processId\":177984,\"rootPath\":\"/home/tsmanner/terrasa-notes\",\"rootUri\":null,\"workspaceFolders\":[]}";
    var scanner = std.json.Scanner.initCompleteInput(allocator, initialize_s);
    try std.testing.expectEqualStrings("{\"capabilities\":{}}", try callMethod(
        []const u8,
        callMethodRequest,
        allocator,
        struct {
            pub fn initialize(_: @This(), _: InitializeParams) !InitializeResult {
                return .{ .capabilities = .{} };
            }
        }{},
        "initialize",
        try std.json.Value.jsonParse(allocator, &scanner, .{ .max_value_len = scanner.input.len }),
    ));
    _ = arena.reset(.free_all);

    try std.testing.expectError(error.InvalidParams, callMethod(
        []const u8,
        callMethodRequest,
        allocator,
        struct {
            pub fn initialize(_: @This(), _: InitializeParams) !InitializeResult {
                return error.InvalidParams;
            }
        }{},
        "initialize",
        null,
    ));
    _ = arena.reset(.free_all);

    try std.testing.expectError(error.NotImplemented, callMethod(
        []const u8,
        callMethodRequest,
        allocator,
        struct {}{},
        "initialize",
        null,
    ));
    _ = arena.reset(.free_all);

    try std.testing.expectEqualStrings("null", try callMethod(
        []const u8,
        callMethodRequest,
        allocator,
        struct {
            pub fn shutdown(_: @This()) !void {}
        }{},
        "shutdown",
        null,
    ));
    _ = arena.reset(.free_all);

    try std.testing.expectError(error.InvalidParams, callMethod(
        []const u8,
        callMethodRequest,
        allocator,
        struct {
            pub fn shutdown(_: @This()) !void {
                return error.InvalidParams;
            }
        }{},
        "shutdown",
        null,
    ));
    _ = arena.reset(.free_all);

    try std.testing.expectError(error.NotImplemented, callMethod(
        []const u8,
        callMethodRequest,
        allocator,
        struct {}{},
        "shutdown",
        null,
    ));
    _ = arena.reset(.free_all);
}
