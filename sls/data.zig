const std = @import("std");

pub const FileMap = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),

    pub fn init(allocator: std.mem.Allocator) FileMap {
        return .{
            .allocator = allocator,
            .files = .{},
        };
    }

    pub fn insert(self: *FileMap, path: []const u8) !void {
        var entry = try self.files.getOrPut(self.allocator, std.fs.path.basename(path));
        try entry.value_ptr.append(self.allocator, std.fs.path.dirname(path) orelse ".");
    }
};

test FileMap {
    var fm = FileMap.init(std.testing.allocator);
    try std.testing.expectEqual(std.testing.allocator, fm.allocator);
    const f = "foo/bar.txt";
    try fm.insert(f);
    // try fm.insert("foo/bar.txt");
    const value = fm.files.get("bar.txt");
    if (value) |v| {
        try std.testing.expectEqual(@as(usize, 1), v.items.len);
        try std.testing.expectEqualStrings("foo", v.items[0]);
    } else {
        return error.KeyNotFound;
    }
}
