//! Applies LSP WorkspaceEdit operations (text edits) to files on disk.

const std = @import("std");
const uri_util = @import("../types/uri.zig");
const FileSystem = @import("../fs.zig").FileSystem;

/// Apply a workspace edit (from LSP JSON) to disk.
/// Returns a human-readable summary of changes made.
/// `edit_json` is a parsed JSON value representing a WorkspaceEdit object.
pub fn applyWorkspaceEdit(allocator: std.mem.Allocator, edit_json: std.json.Value, fs: FileSystem) ![]const u8 {
    const edit_obj = switch (edit_json) {
        .object => |o| o,
        else => return try allocator.dupe(u8, "Invalid workspace edit: not an object"),
    };

    const changes = switch (edit_obj.get("changes") orelse return try allocator.dupe(u8, "No changes in workspace edit")) {
        .object => |o| o,
        else => return try allocator.dupe(u8, "Invalid changes field"),
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var file_count: usize = 0;
    var total_edits: usize = 0;

    var it = changes.iterator();
    while (it.next()) |entry| {
        const file_uri = entry.key_ptr.*;
        const edits_val = entry.value_ptr.*;

        const edits_arr = switch (edits_val) {
            .array => |a| a,
            else => continue,
        };

        if (edits_arr.items.len == 0) continue;

        // Convert URI to path
        const path = uri_util.uriToPath(allocator, file_uri) catch {
            try aw.writer.print("Skipped {s}: invalid URI\n", .{file_uri});
            continue;
        };
        defer allocator.free(path);

        // Read current content
        const content = fs.readFileAlloc(allocator, path, 10 * 1024 * 1024) catch {
            try aw.writer.print("Skipped {s}: could not read file\n", .{path});
            continue;
        };
        defer allocator.free(content);

        // Apply text edits
        const new_content = applyTextEdits(allocator, content, edits_arr.items) catch {
            try aw.writer.print("Skipped {s}: failed to apply edits\n", .{path});
            continue;
        };
        defer allocator.free(new_content);

        // Write back
        fs.writeFile(path, new_content) catch {
            try aw.writer.print("Skipped {s}: could not write file\n", .{path});
            continue;
        };

        file_count += 1;
        total_edits += edits_arr.items.len;
        try aw.writer.print("{s}: {d} edit(s)\n", .{ path, edits_arr.items.len });
    }

    if (file_count == 0) {
        return try allocator.dupe(u8, "No files were modified");
    }

    try aw.writer.print("\nTotal: {d} file(s), {d} edit(s)", .{ file_count, total_edits });
    return try aw.toOwnedSlice();
}

/// A single text edit with byte-offset range and replacement text.
const TextEdit = struct {
    start_byte: usize,
    end_byte: usize,
    new_text: []const u8,
};

/// Apply an array of LSP TextEdit JSON values to content.
/// Returns new content with all edits applied.
pub fn applyTextEdits(allocator: std.mem.Allocator, content: []const u8, edits: []const std.json.Value) ![]const u8 {
    if (edits.len == 0) return try allocator.dupe(u8, content);

    // Parse all edits into byte-offset form
    var parsed_edits: std.ArrayList(TextEdit) = .empty;
    defer parsed_edits.deinit(allocator);
    try parsed_edits.ensureTotalCapacity(allocator, edits.len);

    for (edits) |edit| {
        const edit_obj = switch (edit) {
            .object => |o| o,
            else => continue,
        };

        const range = switch (edit_obj.get("range") orelse continue) {
            .object => |o| o,
            else => continue,
        };

        const start = switch (range.get("start") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const end = switch (range.get("end") orelse continue) {
            .object => |o| o,
            else => continue,
        };

        const start_line: usize = switch (start.get("line") orelse continue) {
            .integer => |i| if (i >= 0) @intCast(i) else continue,
            else => continue,
        };
        const start_char: usize = switch (start.get("character") orelse continue) {
            .integer => |i| if (i >= 0) @intCast(i) else continue,
            else => continue,
        };
        const end_line: usize = switch (end.get("line") orelse continue) {
            .integer => |i| if (i >= 0) @intCast(i) else continue,
            else => continue,
        };
        const end_char: usize = switch (end.get("character") orelse continue) {
            .integer => |i| if (i >= 0) @intCast(i) else continue,
            else => continue,
        };

        const new_text = switch (edit_obj.get("newText") orelse continue) {
            .string => |s| s,
            else => continue,
        };

        const start_byte = lineCharToByteOffset(content, start_line, start_char);
        const end_byte = lineCharToByteOffset(content, end_line, end_char);

        try parsed_edits.append(allocator, .{
            .start_byte = start_byte,
            .end_byte = end_byte,
            .new_text = new_text,
        });
    }

    if (parsed_edits.items.len == 0) return try allocator.dupe(u8, content);

    // Sort by start_byte descending so we can apply from end to start
    std.mem.sort(TextEdit, parsed_edits.items, {}, struct {
        fn cmp(_: void, a: TextEdit, b: TextEdit) bool {
            return a.start_byte > b.start_byte;
        }
    }.cmp);

    // Apply edits in reverse order (preserves earlier byte offsets)
    var result = try allocator.dupe(u8, content);
    errdefer allocator.free(result);

    for (parsed_edits.items) |edit| {
        const start = @min(edit.start_byte, result.len);
        const end = @min(edit.end_byte, result.len);
        if (start > end) continue;

        // Build new buffer: before + newText + after
        const new_len = start + edit.new_text.len + (result.len - end);
        const new_buf = try allocator.alloc(u8, new_len);
        @memcpy(new_buf[0..start], result[0..start]);
        @memcpy(new_buf[start..][0..edit.new_text.len], edit.new_text);
        @memcpy(new_buf[start + edit.new_text.len ..], result[end..]);

        allocator.free(result);
        result = new_buf;
    }

    return result;
}

/// Convert LSP line/character position to byte offset in content.
fn lineCharToByteOffset(content: []const u8, line: usize, character: usize) usize {
    var current_line: usize = 0;
    var i: usize = 0;

    // Skip to the target line
    while (i < content.len and current_line < line) {
        if (content[i] == '\n') {
            current_line += 1;
        }
        i += 1;
    }

    // Now advance by character offset (UTF-16 code units, but for ASCII this is bytes)
    var char_count: usize = 0;
    while (i < content.len and char_count < character) {
        if (content[i] == '\n') break;
        char_count += 1;
        i += 1;
    }

    return i;
}


test "applyTextEdits single edit" {
    const allocator = std.testing.allocator;

    // Construct a TextEdit JSON: replace "old" with "new" at line 0, char 0..3
    const json_str =
        \\[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"newText":"new"}]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();
    const edits = parsed.value.array.items;

    const result = try applyTextEdits(allocator, "old content here", edits);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("new content here", result);
}

test "applyTextEdits multiple edits on same line" {
    const allocator = std.testing.allocator;

    const json_str =
        \\[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"X"},{"range":{"start":{"line":0,"character":4},"end":{"line":0,"character":5}},"newText":"Y"}]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const result = try applyTextEdits(allocator, "abcde", parsed.value.array.items);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("XbcdY", result);
}

test "applyTextEdits multiline content" {
    const allocator = std.testing.allocator;

    // Delete line 1 (second line) entirely: "const y = 2;\n"
    const content = "const x = 1;\nconst y = 2;\nconst z = 3;\n";
    const json_str =
        \\[{"range":{"start":{"line":1,"character":0},"end":{"line":2,"character":0}},"newText":""}]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const result = try applyTextEdits(allocator, content, parsed.value.array.items);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("const x = 1;\nconst z = 3;\n", result);
}

test "applyTextEdits insertion (empty range)" {
    const allocator = std.testing.allocator;

    const json_str =
        \\[{"range":{"start":{"line":0,"character":5},"end":{"line":0,"character":5}},"newText":"_inserted"}]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const result = try applyTextEdits(allocator, "hello world", parsed.value.array.items);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello_inserted world", result);
}

test "applyTextEdits empty edits returns original" {
    const allocator = std.testing.allocator;
    const result = try applyTextEdits(allocator, "unchanged", &.{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("unchanged", result);
}

test "lineCharToByteOffset basic" {
    const content = "line0\nline1\nline2\n";
    try std.testing.expectEqual(@as(usize, 0), lineCharToByteOffset(content, 0, 0));
    try std.testing.expectEqual(@as(usize, 3), lineCharToByteOffset(content, 0, 3));
    try std.testing.expectEqual(@as(usize, 6), lineCharToByteOffset(content, 1, 0));
    try std.testing.expectEqual(@as(usize, 12), lineCharToByteOffset(content, 2, 0));
}

test "applyWorkspaceEdit with TestFileSystem" {
    const allocator = std.testing.allocator;
    const TestFileSystem = @import("../fs.zig").TestFileSystem;

    var tfs = TestFileSystem.init(allocator);
    defer tfs.deinit(allocator);
    try tfs.addFile(allocator, "/workspace/src/main.zig", "const x = 1;\nconst y = 2;\n");

    // Build workspace edit JSON
    const edit_json_str =
        \\{"changes":{"file:///workspace/src/main.zig":[{"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":7}},"newText":"a"}]}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, edit_json_str, .{});
    defer parsed.deinit();

    const fs = tfs.filesystem();
    const summary = try applyWorkspaceEdit(allocator, parsed.value, fs);
    defer allocator.free(summary);

    // Verify file was modified
    const content = try fs.readFileAlloc(allocator, "/workspace/src/main.zig", 1024);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("const a = 1;\nconst y = 2;\n", content);

    // Summary should mention the file
    try std.testing.expect(std.mem.indexOf(u8, summary, "main.zig") != null);
}
