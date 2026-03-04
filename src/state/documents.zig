const std = @import("std");
const LspClient = @import("../lsp/client.zig").LspClient;
const uri_util = @import("../types/uri.zig");
const FileSystem = @import("../fs.zig").FileSystem;
const DiagnosticsCache = @import("diagnostics.zig").DiagnosticsCache;

const log = std.log.scoped(.docs);

/// Tracks which documents are open in the LSP session.
/// Sends didOpen/didClose notifications as needed.
pub const DocumentState = struct {
    open_docs: std.StringHashMapUnmanaged(DocInfo),
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    fs: FileSystem,
    mutex: std.Thread.Mutex = .{},
    diagnostics_cache: ?*DiagnosticsCache = null,

    const DocInfo = struct {
        version: i64,
        content_hash: [32]u8,
    };

    pub fn init(allocator: std.mem.Allocator, workspace_path: []const u8, fs: FileSystem) DocumentState {
        return .{
            .open_docs = .empty,
            .allocator = allocator,
            .workspace_path = workspace_path,
            .fs = fs,
        };
    }

    /// Ensure a file is open in ZLS. Reads file content and sends didOpen if not already open.
    /// `file_path` can be relative (resolved against workspace) or absolute.
    /// For newly-opened files, waits for ZLS to publish diagnostics (indicating analysis
    /// is complete) before returning, so subsequent hover/definition requests get results.
    /// Returns a URI allocated with `ret_allocator` (caller must free).
    pub fn ensureOpen(self: *DocumentState, lsp_client: *LspClient, file_path: []const u8, ret_allocator: std.mem.Allocator) ![]const u8 {
        const abs_path = try uri_util.resolvePathWithinWorkspace(self.allocator, self.workspace_path, file_path, self.fs);
        defer self.allocator.free(abs_path);

        const file_uri = try uri_util.pathToUri(self.allocator, abs_path);
        defer self.allocator.free(file_uri);

        // Fast path: check under lock, sync if changed, return if already open
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.open_docs.get(file_uri)) |_| {
                // Release lock for I/O, then sync if file changed on disk
                self.mutex.unlock();
                _ = self.syncIfChanged(lsp_client, file_uri, abs_path);
                self.mutex.lock();
                return try ret_allocator.dupe(u8, file_uri);
            }
        }

        // Slow path: read file content outside the lock (no mutex held during I/O)
        var content_hash: [32]u8 = undefined;
        const content = self.fs.readFileAlloc(self.allocator, abs_path, 10 * 1024 * 1024) catch |err| {
            return switch (err) {
                error.FileNotFound => error.FileNotFound,
                else => error.FileReadError,
            };
        };
        defer self.allocator.free(content);
        std.crypto.hash.Blake3.hash(content, &content_hash, .{});

        // Register a diagnostics waiter BEFORE sending didOpen to avoid race conditions.
        // ZLS sends textDocument/publishDiagnostics after analyzing the file.
        const diag_event = lsp_client.registerDiagnosticsWaiter(file_uri) catch null;

        // Re-acquire lock, double-check, then register
        // Use explicit lock/unlock (not defer) so we can release before the diagnostic wait.
        self.mutex.lock();

        // Double-check: another thread may have opened it while we were reading
        if (self.open_docs.get(file_uri)) |_| {
            self.mutex.unlock();
            if (diag_event != null) lsp_client.unregisterDiagnosticsWaiter(file_uri);
            return try ret_allocator.dupe(u8, file_uri);
        }

        // Send didOpen notification (still under lock to prevent duplicate opens)
        {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const DidOpenParams = struct {
                textDocument: struct {
                    uri: []const u8,
                    languageId: []const u8,
                    version: i64,
                    text: []const u8,
                },
            };

            lsp_client.sendNotification(arena.allocator(), "textDocument/didOpen", DidOpenParams{
                .textDocument = .{
                    .uri = file_uri,
                    .languageId = "zig",
                    .version = 1,
                    .text = content,
                },
            }) catch |err| {
                self.mutex.unlock();
                if (diag_event != null) lsp_client.unregisterDiagnosticsWaiter(file_uri);
                return err;
            };
        }

        // Track as open (stored with long-lived allocator)
        const stored_uri = self.allocator.dupe(u8, file_uri) catch {
            self.mutex.unlock();
            if (diag_event != null) lsp_client.unregisterDiagnosticsWaiter(file_uri);
            return error.OutOfMemory;
        };
        self.open_docs.put(self.allocator, stored_uri, .{
            .version = 1,
            .content_hash = content_hash,
        }) catch {
            self.allocator.free(stored_uri);
            self.mutex.unlock();
            if (diag_event != null) lsp_client.unregisterDiagnosticsWaiter(file_uri);
            return error.OutOfMemory;
        };

        // Release lock BEFORE waiting on diagnostics — no fragile unlock/relock pattern
        self.mutex.unlock();

        // Wait for ZLS to publish initial diagnostics, indicating it has analyzed the file.
        // This ensures subsequent hover/definition requests get meaningful results.
        if (diag_event) |event| {
            event.timedWait(10 * std.time.ns_per_s) catch {};
            lsp_client.unregisterDiagnosticsWaiter(file_uri);
        }

        return try ret_allocator.dupe(u8, file_uri);
    }

    /// Re-reads a file from disk, compares its BLAKE3 hash with the stored hash,
    /// and sends textDocument/didChange if the content has changed.
    /// Returns true if the file was re-synced.
    fn syncIfChanged(self: *DocumentState, lsp_client: *LspClient, file_uri: []const u8, abs_path: []const u8) bool {
        // Read file outside lock
        const content = self.fs.readFileAlloc(self.allocator, abs_path, 10 * 1024 * 1024) catch |err| {
            log.warn("syncIfChanged: failed to read {s}: {}", .{ abs_path, err });
            return false;
        };
        defer self.allocator.free(content);

        var new_hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(content, &new_hash, .{});

        self.mutex.lock();

        // Look up stored doc info
        const entry = self.open_docs.getEntry(file_uri) orelse {
            self.mutex.unlock();
            return false;
        };
        const info = entry.value_ptr;

        // Compare hashes — unchanged means no work needed
        if (std.mem.eql(u8, &info.content_hash, &new_hash)) {
            self.mutex.unlock();
            return false;
        }

        // Content changed: bump version, update hash
        info.version += 1;
        info.content_hash = new_hash;
        const version = info.version;

        // Register diagnostics waiter before sending notification
        const diag_event = lsp_client.registerDiagnosticsWaiter(file_uri) catch null;

        // Send didChange with full content replacement
        {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const ContentChange = struct { text: []const u8 };
            const DidChangeParams = struct {
                textDocument: struct {
                    uri: []const u8,
                    version: i64,
                },
                contentChanges: []const ContentChange,
            };

            const changes = [1]ContentChange{.{ .text = content }};

            lsp_client.sendNotification(arena.allocator(), "textDocument/didChange", DidChangeParams{
                .textDocument = .{
                    .uri = file_uri,
                    .version = version,
                },
                .contentChanges = &changes,
            }) catch |err| {
                log.warn("syncIfChanged: didChange failed: {}", .{err});
                self.mutex.unlock();
                if (diag_event != null) lsp_client.unregisterDiagnosticsWaiter(file_uri);
                return false;
            };
        }

        self.mutex.unlock();

        // Wait for ZLS to re-analyze the changed content
        if (diag_event) |event| {
            event.timedWait(10 * std.time.ns_per_s) catch {};
            lsp_client.unregisterDiagnosticsWaiter(file_uri);
        }

        log.info("syncIfChanged: re-synced {s} (version {d})", .{ file_uri, version });
        return true;
    }

    /// Close a document in ZLS.
    pub fn closeDoc(self: *DocumentState, lsp_client: *LspClient, file_uri: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.open_docs.fetchRemove(file_uri)) |kv| {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const CloseParams = struct {
                textDocument: struct { uri: []const u8 },
            };
            lsp_client.sendNotification(arena.allocator(), "textDocument/didClose", CloseParams{
                .textDocument = .{ .uri = file_uri },
            }) catch |err| {
                log.warn("didClose notification failed: {}", .{err});
            };

            self.allocator.free(kv.key);

            // Remove cached diagnostics for this file
            if (self.diagnostics_cache) |cache| cache.remove(file_uri);
        }
    }

    /// Reopen all tracked documents in a new ZLS session (after reconnect).
    pub fn reopenAll(self: *DocumentState, lsp_client: *LspClient) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.open_docs.iterator();
        while (it.next()) |entry| {
            const uri = entry.key_ptr.*;

            // Convert URI back to path for re-reading (handles percent-encoding)
            const path = uri_util.uriToPath(self.allocator, uri) catch {
                log.err("Failed to decode URI {s} for reopen", .{uri});
                continue;
            };
            defer self.allocator.free(path);

            const content = self.fs.readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch {
                log.err("Failed to re-read {s} for reopen", .{path});
                continue;
            };
            defer self.allocator.free(content);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const DidOpenParams = struct {
                textDocument: struct {
                    uri: []const u8,
                    languageId: []const u8,
                    version: i64,
                    text: []const u8,
                },
            };

            // Compute and store content hash for change detection
            std.crypto.hash.Blake3.hash(content, &entry.value_ptr.content_hash, .{});

            lsp_client.sendNotification(arena.allocator(), "textDocument/didOpen", DidOpenParams{
                .textDocument = .{
                    .uri = uri,
                    .languageId = "zig",
                    .version = entry.value_ptr.version,
                    .text = content,
                },
            }) catch |err| {
                log.err("Failed to reopen {s}: {}", .{ path, err });
            };
        }
    }

    pub fn deinit(self: *DocumentState) void {
        var it = self.open_docs.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.open_docs.deinit(self.allocator);
    }
};

test "uriToPath correctly decodes percent-encoded URIs used by reopenAll" {
    const allocator = std.testing.allocator;

    // Simulate what reopenAll does: convert a file URI back to a path.
    // The old code just stripped "file://" which breaks on percent-encoded paths.
    const uri = "file:///home/user/my%20project/foo%23bar.zig";
    const path = try uri_util.uriToPath(allocator, uri);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/home/user/my project/foo#bar.zig", path);
}

test "DocumentState init and deinit" {
    const allocator = std.testing.allocator;
    const TestFileSystem = @import("../fs.zig").TestFileSystem;
    var tfs = TestFileSystem{};
    defer tfs.deinit(allocator);
    var ds = DocumentState.init(allocator, "/tmp/workspace", tfs.filesystem());
    defer ds.deinit();
    try std.testing.expectEqualStrings("/tmp/workspace", ds.workspace_path);
}

test "content_hash is stored in DocInfo and differs for different content" {
    var hash_a: [32]u8 = undefined;
    var hash_b: [32]u8 = undefined;
    var hash_a2: [32]u8 = undefined;

    std.crypto.hash.Blake3.hash("const x = 1;", &hash_a, .{});
    std.crypto.hash.Blake3.hash("const x = 2;", &hash_b, .{});
    std.crypto.hash.Blake3.hash("const x = 1;", &hash_a2, .{});

    // Same content produces same hash
    try std.testing.expectEqual(hash_a, hash_a2);
    // Different content produces different hash
    try std.testing.expect(!std.mem.eql(u8, &hash_a, &hash_b));
}

test "DocInfo stores content_hash for change detection" {
    const allocator = std.testing.allocator;
    const TestFileSystem = @import("../fs.zig").TestFileSystem;
    var tfs = TestFileSystem{};
    defer tfs.deinit(allocator);
    var ds = DocumentState.init(allocator, "/tmp/workspace", tfs.filesystem());
    defer ds.deinit();

    // Simulate what ensureOpen does: compute hash and store DocInfo
    const content = "const std = @import(\"std\");";
    var hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(content, &hash, .{});

    const uri = try allocator.dupe(u8, "file:///tmp/workspace/main.zig");
    ds.open_docs.put(allocator, uri, .{
        .version = 1,
        .content_hash = hash,
    }) catch unreachable;

    // Verify stored hash matches
    const info = ds.open_docs.get("file:///tmp/workspace/main.zig").?;
    try std.testing.expectEqual(@as(i64, 1), info.version);
    try std.testing.expectEqual(hash, info.content_hash);

    // Verify a different content would produce a different hash
    var new_hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash("const std = @import(\"std\");\nvar x: u32 = 0;", &new_hash, .{});
    try std.testing.expect(!std.mem.eql(u8, &info.content_hash, &new_hash));
}
