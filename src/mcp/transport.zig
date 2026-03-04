const std = @import("std");
const json_rpc = @import("../types/json_rpc.zig");

const max_message_size = 1024 * 1024; // 1 MB

/// MCP transport: newline-delimited JSON-RPC over stdin/stdout.
/// Each message is a single JSON object followed by '\n'.
pub const McpTransport = struct {
    stdin_file: std.fs.File,
    stdout_file: std.fs.File,
    stdout_mutex: std.Thread.Mutex = .{},

    // Internal read buffer to avoid one-syscall-per-byte
    read_buf: [4096]u8 = undefined,
    buf_start: usize = 0,
    buf_end: usize = 0,

    pub fn init() McpTransport {
        return .{
            .stdin_file = std.fs.File.stdin(),
            .stdout_file = std.fs.File.stdout(),
        };
    }

    /// Read a single byte from the internal buffer (refills from file as needed).
    fn readByte(self: *McpTransport) !?u8 {
        if (self.buf_start >= self.buf_end) {
            const n = self.stdin_file.read(&self.read_buf) catch |err| switch (err) {
                error.BrokenPipe => return null,
                else => return err,
            };
            if (n == 0) return null;
            self.buf_start = 0;
            self.buf_end = n;
        }
        const byte = self.read_buf[self.buf_start];
        self.buf_start += 1;
        return byte;
    }

    /// Read one newline-delimited JSON message from stdin.
    /// Returns owned slice allocated with `allocator`, or null on EOF.
    pub fn readMessage(self: *McpTransport, allocator: std.mem.Allocator) !?[]const u8 {
        while (true) {
            var line: std.ArrayList(u8) = .empty;
            var too_large = false;

            const eof = while (true) {
                const byte = (try self.readByte()) orelse {
                    break true; // EOF
                };
                if (byte == '\n') break false;
                if (byte == '\r') continue; // skip CR
                if (too_large) continue; // drain rest of oversized line
                line.append(allocator, byte) catch {
                    line.deinit(allocator);
                    return error.OutOfMemory;
                };
                if (line.items.len > max_message_size) {
                    line.deinit(allocator);
                    line = .empty;
                    too_large = true;
                }
            };

            if (too_large) return error.MessageTooLarge;
            if (eof and line.items.len == 0) {
                line.deinit(allocator);
                return null;
            }
            if (line.items.len == 0) {
                line.deinit(allocator);
                continue; // ignore blank lines
            }
            return line.toOwnedSlice(allocator) catch {
                line.deinit(allocator);
                return error.OutOfMemory;
            };
        }
    }

    /// Write a newline-delimited JSON message to stdout.
    /// Thread-safe: uses mutex to serialize writes.
    pub fn writeMessage(self: *McpTransport, data: []const u8) !void {
        self.stdout_mutex.lock();
        defer self.stdout_mutex.unlock();
        try self.stdout_file.writeAll(data);
        try self.stdout_file.writeAll("\n");
    }
};

test "readMessage ignores blank lines" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("mcp_input.txt", .{ .read = true, .truncate = true });
    defer file.close();
    try file.writeAll("\n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n");
    try file.seekTo(0);

    var transport = McpTransport.init();
    transport.stdin_file = file;

    const msg = (try transport.readMessage(alloc)).?;
    defer alloc.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"method\":\"ping\"") != null);
}

test "readMessage drains oversized line and reads next message" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("mcp_oversize.txt", .{ .read = true, .truncate = true });
    defer file.close();

    const oversized = try alloc.alloc(u8, max_message_size + 2);
    defer alloc.free(oversized);
    @memset(oversized, 'a');
    oversized[oversized.len - 1] = '\n';
    try file.writeAll(oversized);
    try file.writeAll("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n");
    try file.seekTo(0);

    var transport = McpTransport.init();
    transport.stdin_file = file;

    try std.testing.expectError(error.MessageTooLarge, transport.readMessage(alloc));

    const msg = (try transport.readMessage(alloc)).?;
    defer alloc.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"id\":2") != null);
}

test "readMessage handles CRLF line endings" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("mcp_crlf.txt", .{ .read = true, .truncate = true });
    defer file.close();
    try file.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\r\n");
    try file.seekTo(0);

    var transport = McpTransport.init();
    transport.stdin_file = file;

    const msg = (try transport.readMessage(alloc)).?;
    defer alloc.free(msg);
    // Should not have trailing \r
    try std.testing.expect(msg[msg.len - 1] != '\r');
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"method\":\"ping\"") != null);
}

test "readMessage returns null on empty input" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("mcp_empty.txt", .{ .read = true, .truncate = true });
    defer file.close();
    try file.seekTo(0);

    var transport = McpTransport.init();
    transport.stdin_file = file;

    const msg = try transport.readMessage(alloc);
    try std.testing.expect(msg == null);
}

test "readMessage reads multiple messages" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("mcp_multi.txt", .{ .read = true, .truncate = true });
    defer file.close();
    try file.writeAll("{\"id\":1}\n{\"id\":2}\n{\"id\":3}\n");
    try file.seekTo(0);

    var transport = McpTransport.init();
    transport.stdin_file = file;

    const msg1 = (try transport.readMessage(alloc)).?;
    defer alloc.free(msg1);
    try std.testing.expect(std.mem.indexOf(u8, msg1, "\"id\":1") != null);

    const msg2 = (try transport.readMessage(alloc)).?;
    defer alloc.free(msg2);
    try std.testing.expect(std.mem.indexOf(u8, msg2, "\"id\":2") != null);

    const msg3 = (try transport.readMessage(alloc)).?;
    defer alloc.free(msg3);
    try std.testing.expect(std.mem.indexOf(u8, msg3, "\"id\":3") != null);

    const msg4 = try transport.readMessage(alloc);
    try std.testing.expect(msg4 == null);
}
