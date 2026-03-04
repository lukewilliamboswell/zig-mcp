const std = @import("std");

/// Thread-safe cache for LSP publishDiagnostics data.
/// Maps file URIs to raw JSON strings of the diagnostics array.
pub const DiagnosticsCache = struct {
    map: std.StringHashMapUnmanaged([]const u8),
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DiagnosticsCache {
        return .{
            .map = .empty,
            .allocator = allocator,
        };
    }

    /// Store or overwrite diagnostics JSON for a URI.
    /// Called from the reader thread when publishDiagnostics arrives.
    pub fn put(self: *DiagnosticsCache, uri: []const u8, diagnostics_json: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const duped_json = self.allocator.dupe(u8, diagnostics_json) catch return;

        if (self.map.getEntry(uri)) |entry| {
            // Overwrite existing entry — free old JSON, reuse key
            self.allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = duped_json;
        } else {
            const duped_uri = self.allocator.dupe(u8, uri) catch {
                self.allocator.free(duped_json);
                return;
            };
            self.map.put(self.allocator, duped_uri, duped_json) catch {
                self.allocator.free(duped_uri);
                self.allocator.free(duped_json);
            };
        }
    }

    /// Return a duped copy of the diagnostics JSON for one URI.
    pub fn get(self: *DiagnosticsCache, allocator: std.mem.Allocator, uri: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const json = self.map.get(uri) orelse return null;
        return allocator.dupe(u8, json) catch null;
    }

    pub const UriDiagnostics = struct {
        uri: []const u8,
        diagnostics_json: []const u8,
    };

    /// Return all cached entries. Caller owns all returned slices.
    pub fn getAll(self: *DiagnosticsCache, allocator: std.mem.Allocator) ?[]UriDiagnostics {
        self.mutex.lock();
        defer self.mutex.unlock();

        const count = self.map.count();
        if (count == 0) return null;

        var result = std.ArrayList(UriDiagnostics).initCapacity(allocator, count) catch return null;

        var it = self.map.iterator();
        while (it.next()) |entry| {
            const uri = allocator.dupe(u8, entry.key_ptr.*) catch continue;
            const json = allocator.dupe(u8, entry.value_ptr.*) catch {
                allocator.free(uri);
                continue;
            };
            result.append(allocator, .{ .uri = uri, .diagnostics_json = json }) catch {
                allocator.free(uri);
                allocator.free(json);
                continue;
            };
        }

        return result.toOwnedSlice(allocator) catch null;
    }

    /// Remove a single entry (e.g., on file close).
    pub fn remove(self: *DiagnosticsCache, uri: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.map.fetchRemove(uri)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    /// Clear all entries (e.g., on ZLS reconnect).
    pub fn clearAll(self: *DiagnosticsCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.clearRetainingCapacity();
    }

    pub fn deinit(self: *DiagnosticsCache) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }
};

test "DiagnosticsCache put and get" {
    const allocator = std.testing.allocator;
    var cache = DiagnosticsCache.init(allocator);
    defer cache.deinit();

    cache.put("file:///a.zig", "[{\"message\":\"error\"}]");

    const result = cache.get(allocator, "file:///a.zig") orelse return error.TestUnexpectedResult;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("[{\"message\":\"error\"}]", result);
}

test "DiagnosticsCache get missing returns null" {
    const allocator = std.testing.allocator;
    var cache = DiagnosticsCache.init(allocator);
    defer cache.deinit();

    try std.testing.expect(cache.get(allocator, "file:///missing.zig") == null);
}

test "DiagnosticsCache put overwrites" {
    const allocator = std.testing.allocator;
    var cache = DiagnosticsCache.init(allocator);
    defer cache.deinit();

    cache.put("file:///a.zig", "[{\"old\":true}]");
    cache.put("file:///a.zig", "[{\"new\":true}]");

    const result = cache.get(allocator, "file:///a.zig") orelse return error.TestUnexpectedResult;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("[{\"new\":true}]", result);
}

test "DiagnosticsCache remove" {
    const allocator = std.testing.allocator;
    var cache = DiagnosticsCache.init(allocator);
    defer cache.deinit();

    cache.put("file:///a.zig", "[]");
    cache.remove("file:///a.zig");

    try std.testing.expect(cache.get(allocator, "file:///a.zig") == null);
}

test "DiagnosticsCache clearAll" {
    const allocator = std.testing.allocator;
    var cache = DiagnosticsCache.init(allocator);
    defer cache.deinit();

    cache.put("file:///a.zig", "[]");
    cache.put("file:///b.zig", "[]");
    cache.clearAll();

    try std.testing.expect(cache.get(allocator, "file:///a.zig") == null);
    try std.testing.expect(cache.get(allocator, "file:///b.zig") == null);
}

test "DiagnosticsCache getAll" {
    const allocator = std.testing.allocator;
    var cache = DiagnosticsCache.init(allocator);
    defer cache.deinit();

    cache.put("file:///a.zig", "[{\"a\":1}]");
    cache.put("file:///b.zig", "[{\"b\":2}]");

    const entries = cache.getAll(allocator) orelse return error.TestUnexpectedResult;
    defer {
        for (entries) |e| {
            allocator.free(e.uri);
            allocator.free(e.diagnostics_json);
        }
        allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
}

test "DiagnosticsCache getAll empty returns null" {
    const allocator = std.testing.allocator;
    var cache = DiagnosticsCache.init(allocator);
    defer cache.deinit();

    try std.testing.expect(cache.getAll(allocator) == null);
}
