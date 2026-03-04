//! Filesystem abstraction layer for testability.

const std = @import("std");

/// Filesystem abstraction for testability.
/// Uses Zig's vtable pattern (like std.Io.Reader/Writer).
pub const FileSystem = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        readFileAlloc: *const fn (ctx: *const anyopaque, allocator: std.mem.Allocator, path: []const u8, max_size: usize) ReadError![]const u8,
        realpathAlloc: *const fn (ctx: *const anyopaque, allocator: std.mem.Allocator, path: []const u8) RealpathError![]const u8,
        writeFile: *const fn (ctx: *const anyopaque, path: []const u8, content: []const u8) WriteError!void,
    };

    pub const ReadError = error{
        FileNotFound,
        OutOfMemory,
        ReadFailed,
    };

    pub const RealpathError = error{
        FileNotFound,
        OutOfMemory,
        RealpathFailed,
    };

    pub const WriteError = error{
        FileNotFound,
        OutOfMemory,
        WriteFailed,
    };

    pub fn readFileAlloc(self: FileSystem, allocator: std.mem.Allocator, path: []const u8, max_size: usize) ReadError![]const u8 {
        return self.vtable.readFileAlloc(self.ptr, allocator, path, max_size);
    }

    pub fn realpathAlloc(self: FileSystem, allocator: std.mem.Allocator, path: []const u8) RealpathError![]const u8 {
        return self.vtable.realpathAlloc(self.ptr, allocator, path);
    }

    pub fn writeFile(self: FileSystem, path: []const u8, content: []const u8) WriteError!void {
        return self.vtable.writeFile(self.ptr, path, content);
    }
};

/// Production filesystem backend. Delegates to std.fs.cwd().
pub const OsFileSystem = struct {
    pub fn filesystem(self: *const OsFileSystem) FileSystem {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .readFileAlloc = readFileAllocImpl,
                .realpathAlloc = realpathAllocImpl,
                .writeFile = writeFileImpl,
            },
        };
    }

    fn readFileAllocImpl(_: *const anyopaque, allocator: std.mem.Allocator, path: []const u8, max_size: usize) FileSystem.ReadError![]const u8 {
        return std.fs.cwd().readFileAlloc(allocator, path, max_size) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ReadFailed,
        };
    }

    fn realpathAllocImpl(_: *const anyopaque, allocator: std.mem.Allocator, path: []const u8) FileSystem.RealpathError![]const u8 {
        return std.fs.cwd().realpathAlloc(allocator, path) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.RealpathFailed,
        };
    }

    fn writeFileImpl(_: *const anyopaque, path: []const u8, content: []const u8) FileSystem.WriteError!void {
        const file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return error.WriteFailed,
        };
        defer file.close();
        file.writeAll(content) catch return error.WriteFailed;
    }
};

/// In-memory filesystem backend for tests.
pub const TestFileSystem = struct {
    files: std.StringHashMapUnmanaged([]const u8) = .empty,
    allocator: ?std.mem.Allocator = null,

    pub fn init(allocator: std.mem.Allocator) TestFileSystem {
        return .{ .allocator = allocator };
    }

    pub fn filesystem(self: *const TestFileSystem) FileSystem {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .readFileAlloc = readFileAllocImpl,
                .realpathAlloc = realpathAllocImpl,
                .writeFile = writeFileImpl,
            },
        };
    }

    pub fn addFile(self: *TestFileSystem, allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
        const owned_content = if (self.allocator) |a| try a.dupe(u8, content) else content;
        try self.files.put(allocator, path, owned_content);
    }

    pub fn deinit(self: *TestFileSystem, allocator: std.mem.Allocator) void {
        if (self.allocator) |a| {
            var it = self.files.iterator();
            while (it.next()) |entry| {
                a.free(entry.value_ptr.*);
            }
        }
        self.files.deinit(allocator);
    }

    fn readFileAllocImpl(ctx: *const anyopaque, allocator: std.mem.Allocator, path: []const u8, _: usize) FileSystem.ReadError![]const u8 {
        const self: *const TestFileSystem = @ptrCast(@alignCast(ctx));
        const content = self.files.get(path) orelse return error.FileNotFound;
        return allocator.dupe(u8, content) catch return error.OutOfMemory;
    }

    fn realpathAllocImpl(ctx: *const anyopaque, allocator: std.mem.Allocator, path: []const u8) FileSystem.RealpathError![]const u8 {
        const self: *const TestFileSystem = @ptrCast(@alignCast(ctx));
        if (self.files.contains(path)) {
            return allocator.dupe(u8, path) catch return error.OutOfMemory;
        }
        return error.FileNotFound;
    }

    fn writeFileImpl(ctx: *const anyopaque, path: []const u8, content: []const u8) FileSystem.WriteError!void {
        const mutself: *TestFileSystem = @constCast(@ptrCast(@alignCast(ctx)));
        const alloc = mutself.allocator orelse return error.WriteFailed;
        const entry = mutself.files.getEntry(path) orelse return error.FileNotFound;
        const owned = alloc.dupe(u8, content) catch return error.OutOfMemory;
        alloc.free(entry.value_ptr.*);
        entry.value_ptr.* = owned;
    }
};


test "TestFileSystem read existing file" {
    const allocator = std.testing.allocator;
    var tfs = TestFileSystem{};
    defer tfs.deinit(allocator);
    try tfs.addFile(allocator, "/test/file.zig", "const x = 42;");

    const fs = tfs.filesystem();
    const content = try fs.readFileAlloc(allocator, "/test/file.zig", 1024);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("const x = 42;", content);
}

test "TestFileSystem read missing file returns error" {
    var tfs = TestFileSystem{};
    const fs = tfs.filesystem();
    try std.testing.expectError(error.FileNotFound, fs.readFileAlloc(std.testing.allocator, "/nonexistent", 1024));
}

test "TestFileSystem realpath returns path as-is when file exists" {
    const allocator = std.testing.allocator;
    var tfs = TestFileSystem{};
    defer tfs.deinit(allocator);
    try tfs.addFile(allocator, "/workspace/src/main.zig", "pub fn main() {}");

    const fs = tfs.filesystem();
    const resolved = try fs.realpathAlloc(allocator, "/workspace/src/main.zig");
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("/workspace/src/main.zig", resolved);
}

test "TestFileSystem realpath returns error for missing path" {
    var tfs = TestFileSystem{};
    const fs = tfs.filesystem();
    try std.testing.expectError(error.FileNotFound, fs.realpathAlloc(std.testing.allocator, "/missing"));
}

test "OsFileSystem read existing file" {
    const allocator = std.testing.allocator;
    const os_fs: OsFileSystem = .{};
    const fs = os_fs.filesystem();

    // /tmp is a symlink to /private/tmp on macOS, so compare against std realpath
    const resolved = try fs.realpathAlloc(allocator, "/tmp");
    defer allocator.free(resolved);
    const expected = try std.fs.cwd().realpathAlloc(allocator, "/tmp");
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, resolved);
}

test "OsFileSystem read missing file returns FileNotFound" {
    const os_fs: OsFileSystem = .{};
    const fs = os_fs.filesystem();
    try std.testing.expectError(error.FileNotFound, fs.readFileAlloc(std.testing.allocator, "/nonexistent_file_abc123", 1024));
}

test "TestFileSystem writeFile updates content" {
    const allocator = std.testing.allocator;
    var tfs = TestFileSystem.init(allocator);
    defer tfs.deinit(allocator);
    try tfs.addFile(allocator, "/test/file.zig", "old content");

    const fs = tfs.filesystem();
    try fs.writeFile("/test/file.zig", "new content");

    const content = try fs.readFileAlloc(allocator, "/test/file.zig", 1024);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("new content", content);
}

test "TestFileSystem writeFile missing file returns error" {
    const allocator = std.testing.allocator;
    var tfs = TestFileSystem.init(allocator);
    defer tfs.deinit(allocator);

    const fs = tfs.filesystem();
    try std.testing.expectError(error.FileNotFound, fs.writeFile("/nonexistent", "data"));
}
