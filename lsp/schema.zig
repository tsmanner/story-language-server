//! Refactor the JSON parsing part here to be key-order independent.
//! (1) Parse in two passes, first as just std.json.Value and then switch on the method key
//!     and use jsonParseValue to do the params parsing and merge step.
//! (2) Have separate method and params fields, and allow params to be a tagged union of std.json.Value
//!     and the <method>.Params tagged union.  When method is parsed, if params is std.json.Value, use
//!     jsonParseValue to convert it to <method>.Params.  When params is parsed, if method is not null,
//!     use jsonParse to parse directly into <method>.Params, otherwise store it as a std.json.Value.

const std = @import("std");

pub const Position = struct {
    line: u32,
    character: u32,

    pub const Encoding = enum {
        @"utf-8",
        @"utf-16",
        @"utf-32",
    };
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

pub const TextDocumentItem = struct {
    uri: DocumentUri,
    languageId: []const u8,
    version: i32,
    text: []const u8,
};

pub const TextDocumentSync = union(enum) {
    pub const Kind = enum(u32) {
        None = 0,
        Full = 1,
        Incremental = 2,
    };

    options: struct { openClose: ?bool, change: ?Kind },
    kind: Kind,
};

pub fn BoolOrOptions(comptime Options: type) type {
    return union(enum) {
        bool: bool,
        options: Options,
    };
}

pub fn BoolOrRegistrationOptions(comptime Options: type, comptime RegistrationOptions: type) type {
    return union(enum) {
        bool: bool,
        options: Options,
        registration_options: RegistrationOptions,
    };
}

pub const Message = struct {
    jsonrpc: []const u8,
    id: ?u32,
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
                return .{
                    .jsonrpc = try std.json.innerParseFromValue(
                        []const u8,
                        allocator,
                        object.get("jsonrpc") orelse return error.MissingField,
                        options,
                    ),
                    .id = if (object.get("id")) |id|
                        try std.json.innerParseFromValue(
                            u32,
                            allocator,
                            id,
                            options,
                        )
                    else
                        null,
                    .payload = blk: {
                        if (object.get("method")) |method| {
                            break :blk switch (std.meta.stringToEnum(Request.Tag, method.string) orelse return error.InvalidEnumTag) {
                                inline else => |tag| .{ .request = @unionInit(
                                    Request,
                                    @tagName(tag),
                                    try std.json.innerParseFromValue(
                                        std.meta.TagPayload(Request, tag),
                                        allocator,
                                        object.get("params").?,
                                        options,
                                    ),
                                ) },
                            };
                            // } else if (object.get("result")) |result| {
                            //     break :blk switch (try std.meta.stringToEnum(Response.Tag, result) orelse return error.InvalidEnuTag) {
                            //         inline else => |tag| .{ .response = @unionInit(
                            //             Response,
                            //             @tagName(tag),
                            //             try std.json.innerParseFromValue(
                            //                 std.meta.TagPayload(Response, tag),
                            //                 allocator,
                            //                 result,
                            //                 options,
                            //             ),
                            //         ) },
                            //     };
                        } else {
                            return error.MissingField;
                        }
                    },
                };
            },
            else => return error.UnexpectedToken,
        }
    }

    fn writeObjectField(comptime field_name: []const u8, write_stream: anytype, value: anytype) !void {
        try write_stream.objectField(field_name);
        try write_stream.write(@field(value, field_name));
    }

    pub fn jsonStringify(self: Message, write_stream: anytype) !void {
        try write_stream.beginObject();
        try writeObjectField("jsonrpc", write_stream, self);
        try writeObjectField("id", write_stream, self);
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

    initialize: Initialize.Params,
    initialized: struct {},
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
    initialize: Initialize.Result,
    @"error": Error,
};

pub const Initialize = struct {
    pub const Params = struct {
        processId: ?u64,
        clientInfo: ?struct {
            name: []const u8,
            version: []const u8,
        } = null,
        locale: ?[]const u8 = null,
        rootPath: ?[]const u8,
        rootUri: ?DocumentUri,
        capabilities: struct {
            general: struct {
                positionEncodings: []const Position.Encoding,
            },
            textDocument: struct {
                codeAction: struct {
                    codeActionLiteralSupport: struct {
                        codeActionKind: struct {
                            valueSet: []const []const u8,
                        },
                    },
                },
                completion: struct {
                    completionItem: struct {
                        deprecatedSupport: bool,
                        insertReplaceSupport: bool,
                        resolveSupport: struct {
                            properties: []const []const u8,
                        },
                        snippetSupport: bool,
                        tagSupport: struct {
                            valueSet: []const u64,
                        },
                    },
                    completionItemKind: struct {},
                },
                hover: struct {
                    contentFormat: []const []const u8,
                },
                inlayHint: struct {
                    dynamicRegistration: bool,
                },
                publishDiagnostics: struct {
                    versionSupport: bool,
                },
                rename: struct {
                    dynamicRegistration: bool,
                    honorsChangeAnnotations: bool,
                    prepareSupport: bool,
                },
                signatureHelp: struct {
                    signatureInformation: struct {
                        activeParameterSupport: bool,
                        documentationFormat: []const []const u8,
                        parameterInformation: struct {
                            labelOffsetSupport: bool,
                        },
                    },
                },
            },
            window: struct {
                workDoneProgress: bool,
            },
            workspace: struct {
                applyEdit: bool,
                configuration: bool,
                didChangeConfiguration: struct {
                    dynamicRegistration: bool,
                },
                executeCommand: struct {
                    dynamicRegistration: bool,
                },
                inlayHint: struct {
                    refreshSupport: bool,
                },
                symbol: struct {
                    dynamicRegistration: bool,
                },
                workspaceEdit: struct {
                    documentChanges: bool,
                    failureHandling: []const u8, // TODO: enum?
                    normalizesLineEndings: bool,
                    resourceOperations: []const []const u8,
                },
                workspaceFolders: bool,
            },
        },
        workspaceFolders: []const []const u8,
    };

    pub const Result = struct {
        serverInfo: ?struct {
            name: []const u8,
            version: []const u8,
        } = null,
        capabilities: struct {
            positionEncoding: ?Position.Encoding = null,
            textDocumentSync: ?TextDocumentSync = null,
            notebookDocumentSync: ?struct {} = null,
            completionProvider: ?struct {} = null,
            hoverProvider: ?BoolOrOptions(struct {}) = null,
            signatureHelpProvider: ?struct {} = null,
            declarationProvider: ?BoolOrRegistrationOptions(struct {}, struct {}) = null,
            definitionProvider: ?BoolOrOptions(struct {}) = null,
            typeDefinitionProvider: ?BoolOrRegistrationOptions(struct {}, struct {}) = null,
            implementationProvider: ?BoolOrRegistrationOptions(struct {}, struct {}) = null,
            referencesProvider: ?BoolOrOptions(struct {}) = null,
            documentHighlightProvider: ?BoolOrOptions(struct {}) = null,
            documentSymbolProvider: ?BoolOrOptions(struct {}) = null,
            codeActionProvider: ?BoolOrOptions(struct {}) = null,
            codeLenseProvider: ?struct {} = null,
            documentLinkProvider: ?struct {} = null,
            colorProvider: ?BoolOrRegistrationOptions(struct {}, struct {}) = null,
            documentFormattingProvider: ?BoolOrOptions(struct {}) = null,
            documentRangeFormattingProvider: ?BoolOrOptions(struct {}) = null,
            documentOnTypeFormattingProvider: ?struct {} = null,
            renameProvider: ?BoolOrOptions(struct {}) = null,
            foldingRangeProvider: ?BoolOrRegistrationOptions(struct {}, struct {}) = null,
            executeCommandProvider: ?struct {} = null,
            selectionRangeProvider: ?BoolOrRegistrationOptions(struct {}, struct {}) = null,
            linkedEditingRangeProvider: ?BoolOrRegistrationOptions(struct {}, struct {}) = null,
            callHierarchyProvider: ?BoolOrRegistrationOptions(struct {}, struct {}) = null,
            semanticTokensProvider: ?union(enum) { options: struct {}, registrationOptions: struct {} } = null,
            monikerProvider: ?BoolOrRegistrationOptions(struct {}, struct {}) = null,
            typeHierarchyProvider: ?BoolOrRegistrationOptions(struct {}, struct {}) = null,
            inlineValueProvider: ?BoolOrRegistrationOptions(struct {}, struct {}) = null,
            inlayHintProvider: ?BoolOrRegistrationOptions(struct {}, struct {}) = null,
            diagnosticProvider: ?union(enum) { options: struct {}, registrationOptions: struct {} } = null,
            workspaceSymbolProvider: ?BoolOrOptions(struct {}) = null,
            workspace: ?struct {
                workspaceFolders: ?[]const struct {} = null,
                fileOperators: ?struct {
                    pub const RegistrationOptions = struct {};
                    didCreate: ?RegistrationOptions = null,
                    willCreate: ?RegistrationOptions = null,
                    didRename: ?RegistrationOptions = null,
                    willRename: ?RegistrationOptions = null,
                    didDelete: ?RegistrationOptions = null,
                    willDelete: ?RegistrationOptions = null,
                } = null,
            } = null,
        },
    };
};
