//! Style lints for Zig code in the zig-mcp codebase.
//!
//! Adapted from Roc's zig_lints.zig with modifications for zig-mcp.
//!
//! Checks:
//! 1. Separator comments (// ====, // ----, and // ───) are banned
//! 2. All pub declarations require doc comments (///)
//! 3. New Zig files require top-level comments (//!)

const std = @import("std");

const Allocator = std.mem.Allocator;
const PathList = std.ArrayList([]u8);

const max_file_bytes: usize = 16 * 1024 * 1024;

const TermColor = struct {
    pub const red = "\x1b[0;31m";
    pub const green = "\x1b[0;32m";
    pub const reset = "\x1b[0m";
};

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_state = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_state.interface;

    var found_errors = false;

    // Lint 1: Check for separator comments (// ==== and // ───)
    try stdout.print("Checking for separator comments...\n", .{});

    {
        var zig_files = PathList{};
        defer freePathList(&zig_files, gpa);

        // Scan src/ (not ci/ since zig_lints.zig mentions the pattern)
        try walkTree(gpa, "src", &zig_files);

        // Add build.zig directly
        try zig_files.append(gpa, try gpa.dupe(u8, "build.zig"));

        for (zig_files.items) |file_path| {
            const errors = try checkSeparatorComments(gpa, file_path);
            defer gpa.free(errors);

            if (errors.len > 0) {
                try stdout.print("{s}", .{errors});
                found_errors = true;
            }
        }

        if (found_errors) {
            try stdout.print("\n", .{});
            try stdout.print("Separator comments like '// ====', '// ----', or '// ───' are not allowed. Please delete these lines.\n", .{});
            try stdout.print("\n", .{});
            try stdout.flush();
            std.process.exit(1);
        }
    }

    // Lint 2: Check for pub declarations without doc comments
    try stdout.print("Checking for pub declarations without doc comments...\n", .{});

    var zig_files = PathList{};
    defer freePathList(&zig_files, gpa);

    try walkTree(gpa, "src", &zig_files);

    for (zig_files.items) |file_path| {
        const errors = try checkPubDocComments(gpa, file_path);
        defer gpa.free(errors);

        if (errors.len > 0) {
            try stdout.print("{s}", .{errors});
            found_errors = true;
        }
    }

    if (found_errors) {
        try stdout.print("\n", .{});
        try stdout.print("Please add doc comments to the spots listed above, they make the code easier to understand for everyone.\n", .{});
        try stdout.print("\n", .{});
        try stdout.flush();
        std.process.exit(1);
    }

    // Lint 3: Check for top level comments in new Zig files
    try stdout.print("Checking for top level comments in new Zig files...\n", .{});

    var new_zig_files = try getNewZigFiles(gpa);
    defer {
        for (new_zig_files.items) |path| {
            gpa.free(path);
        }
        new_zig_files.deinit(gpa);
    }

    if (new_zig_files.items.len == 0) {
        try stdout.print("{s}[OK]{s} All lints passed!\n", .{ TermColor.green, TermColor.reset });
        try stdout.flush();
        return;
    }

    var failed_files = PathList{};
    defer freePathList(&failed_files, gpa);

    for (new_zig_files.items) |file_path| {
        if (!try fileHasTopLevelComment(gpa, file_path)) {
            try stdout.print("Error: {s} is missing top level comment (//!)\n", .{file_path});
            try failed_files.append(gpa, try gpa.dupe(u8, file_path));
        }
    }

    if (failed_files.items.len > 0) {
        try stdout.print("\n", .{});
        try stdout.print("The following files are missing a top level comment:\n", .{});
        for (failed_files.items) |path| {
            try stdout.print("    {s}\n", .{path});
        }
        try stdout.print("\n", .{});
        try stdout.print("Add a //! comment that explains the purpose of the file BEFORE any other code.\n", .{});
        try stdout.flush();
        std.process.exit(1);
    }

    try stdout.print("{s}[OK]{s} All lints passed!\n", .{ TermColor.green, TermColor.reset });
    try stdout.flush();
}

fn walkTree(allocator: Allocator, dir_path: []const u8, zig_files: *PathList) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .sym_link) continue;

        const next_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

        switch (entry.kind) {
            .directory => {
                // Skip .zig-cache directories
                if (std.mem.eql(u8, entry.name, ".zig-cache")) {
                    allocator.free(next_path);
                    continue;
                }
                defer allocator.free(next_path);
                try walkTree(allocator, next_path, zig_files);
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".zig")) {
                    try zig_files.append(allocator, next_path);
                } else {
                    allocator.free(next_path);
                }
            },
            else => allocator.free(next_path),
        }
    }
}

fn checkSeparatorComments(allocator: Allocator, file_path: []const u8) ![]u8 {
    const source = readSourceFile(allocator, file_path) catch |err| switch (err) {
        // Skip files we can't read
        error.FileNotFound => return try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(source);

    var errors = std.ArrayList(u8){};
    errdefer errors.deinit(allocator);

    var line_num: usize = 1;
    var lines = std.mem.splitScalar(u8, source, '\n');

    while (lines.next()) |line| {
        defer line_num += 1;

        // Trim leading whitespace
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        // Check if line starts with // and is a separator comment
        if (std.mem.startsWith(u8, trimmed, "//")) {
            const after_slashes = trimmed[2..];
            if (isSeparatorComment(after_slashes)) {
                try errors.writer(allocator).print("{s}:{d}: separator comment not allowed\n", .{ file_path, line_num });
            }
        }
    }

    return errors.toOwnedSlice(allocator);
}

/// Checks if a line (after the //) is a separator comment.
/// Detects both ASCII separators (====) and Unicode box-drawing separators (───).
///
/// Examples that should match:
///   " ===="
///   " ===== Section ====="
///   " ----"
///   " ----------- Section -----------"
///   " ─── Section ───────"
///   " ── Stage 1: Tokenize ──────"
/// Examples that should NOT match:
///   " 2. Stdout contains "=====""
///   " This is a normal comment about ===="
fn isSeparatorComment(after_slashes: []const u8) bool {
    // Trim whitespace
    const content = std.mem.trim(u8, after_slashes, " \t");
    if (content.len == 0) return false;

    // Check for ASCII separator (==== or ----)
    if (std.mem.startsWith(u8, content, "====") or std.mem.startsWith(u8, content, "----")) {
        return isAsciiSeparatorBody(content);
    }

    // Check for Unicode box-drawing separator (── or ───)
    // U+2500 BOX DRAWINGS LIGHT HORIZONTAL = 0xE2 0x94 0x80 in UTF-8
    if (startsWithBoxDrawing(content)) {
        return isBoxDrawingSeparatorBody(content);
    }

    return false;
}

fn isAsciiSeparatorBody(content: []const u8) bool {
    // Find where the leading separator chars end
    var i: usize = 0;
    while (i < content.len and (content[i] == '=' or content[i] == '-')) : (i += 1) {}

    // Everything after leading separator should be whitespace, letters, or trailing separator chars
    while (i < content.len) : (i += 1) {
        const c = content[i];
        if (c == '=' or c == '-' or c == ' ' or c == '\t' or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
            continue;
        }
        return false;
    }
    return true;
}

fn isBoxDrawingSeparatorBody(content: []const u8) bool {
    // Skip leading box-drawing characters
    var i: usize = 0;
    while (i + 2 < content.len and content[i] == 0xE2 and content[i + 1] == 0x94 and content[i + 2] == 0x80) {
        i += 3;
    }

    // Must have had at least 2 box-drawing chars (6 bytes)
    if (i < 6) return false;

    // Everything after leading box-drawing should be whitespace, ASCII letters, digits,
    // colons, slashes, or trailing box-drawing chars
    while (i < content.len) {
        const c = content[i];
        if (c == ' ' or c == '\t' or c == ':' or c == '/' or c == '_' or
            (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9'))
        {
            i += 1;
            continue;
        }
        // Check for box-drawing char
        if (i + 2 < content.len and c == 0xE2 and content[i + 1] == 0x94 and content[i + 2] == 0x80) {
            i += 3;
            continue;
        }
        return false;
    }
    return true;
}

fn startsWithBoxDrawing(content: []const u8) bool {
    if (content.len < 3) return false;
    return content[0] == 0xE2 and content[1] == 0x94 and content[2] == 0x80;
}

fn checkPubDocComments(allocator: Allocator, file_path: []const u8) ![]u8 {
    const source = readSourceFile(allocator, file_path) catch |err| switch (err) {
        // Skip files we can't read
        error.FileNotFound => return try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(source);

    var errors = std.ArrayList(u8){};
    errdefer errors.deinit(allocator);

    var line_num: usize = 1;
    var prev_line: []const u8 = "";
    var lines = std.mem.splitScalar(u8, source, '\n');

    while (lines.next()) |line| {
        defer {
            prev_line = line;
            line_num += 1;
        }

        // Check if line starts with "pub " (no leading whitespace - only top-level declarations)
        if (!std.mem.startsWith(u8, line, "pub ")) continue;

        // Check if previous line is a doc comment (allow indented doc comments)
        const prev_trimmed = std.mem.trimLeft(u8, prev_line, " \t");
        if (std.mem.startsWith(u8, prev_trimmed, "///")) continue;

        // Skip exceptions: init, deinit, main, @import, and pub const re-exports
        if (std.mem.indexOf(u8, line, "fn init") != null) continue;
        if (std.mem.indexOf(u8, line, "fn deinit") != null) continue;
        if (std.mem.indexOf(u8, line, "fn main") != null) continue;
        if (std.mem.indexOf(u8, line, "@import") != null) continue;

        // Check for pub const re-exports (e.g., "pub const Foo = bar.Baz;")
        if (isReExport(line)) continue;

        try errors.writer(allocator).print("{s}:{d}: pub declaration without doc comment `///`\n", .{ file_path, line_num });
    }

    return errors.toOwnedSlice(allocator);
}

fn isReExport(line: []const u8) bool {
    // Match pattern: pub const X = lowercase.something;
    // This detects re-exports like "pub const Foo = bar.Baz;"
    if (!std.mem.startsWith(u8, line, "pub const ")) return false;

    // Find the '=' sign
    const eq_pos = std.mem.indexOf(u8, line, "=") orelse return false;
    const after_eq = std.mem.trimLeft(u8, line[eq_pos + 1 ..], " \t");

    // Check if it starts with a lowercase letter (module reference)
    if (after_eq.len == 0) return false;
    const first_char = after_eq[0];
    if (first_char < 'a' or first_char > 'z') return false;

    // Check if it contains a dot and ends with semicolon (but not a function call)
    if (std.mem.indexOf(u8, after_eq, ".") == null) return false;
    if (std.mem.indexOf(u8, after_eq, "(") != null) return false;
    if (!std.mem.endsWith(u8, std.mem.trimRight(u8, after_eq, " \t"), ";")) return false;

    return true;
}

fn getNewZigFiles(allocator: Allocator) !PathList {
    var result = PathList{};
    errdefer {
        for (result.items) |path| {
            allocator.free(path);
        }
        result.deinit(allocator);
    }

    // Run git diff to get new files
    var child = std.process.Child.init(&.{ "git", "diff", "--name-only", "--diff-filter=A", "origin/main", "HEAD", "--", "src/" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    _ = child.spawn() catch {
        // Git not available or not in a repo - return empty list
        return result;
    };

    const stdout = child.stdout orelse return result;
    const output = stdout.readToEndAlloc(allocator, max_file_bytes) catch return result;
    defer allocator.free(output);

    const term = child.wait() catch return result;
    if (term.Exited != 0) return result;

    // Parse output line by line
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!std.mem.endsWith(u8, line, ".zig")) continue;

        try result.append(allocator, try allocator.dupe(u8, line));
    }

    return result;
}

fn fileHasTopLevelComment(allocator: Allocator, file_path: []const u8) !bool {
    const source = readSourceFile(allocator, file_path) catch |err| switch (err) {
        // File was deleted but still shows in git diff - skip it
        error.FileNotFound => return true,
        else => return err,
    };
    defer allocator.free(source);

    return std.mem.indexOf(u8, source, "//!") != null;
}

fn readSourceFile(allocator: Allocator, path: []const u8) ![:0]u8 {
    return try std.fs.cwd().readFileAllocOptions(
        allocator,
        path,
        max_file_bytes,
        null,
        std.mem.Alignment.of(u8),
        0,
    );
}

fn freePathList(list: *PathList, allocator: Allocator) void {
    for (list.items) |path| {
        allocator.free(path);
    }
    list.deinit(allocator);
}
