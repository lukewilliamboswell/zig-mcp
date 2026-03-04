const std = @import("std");
const mcp_types = @import("../mcp/types.zig");
const uri_util = @import("../types/uri.zig");
const Workspace = @import("../state/workspace.zig").Workspace;
const LspClient = @import("../lsp/client.zig").LspClient;
const DocumentState = @import("../state/documents.zig").DocumentState;
const FileSystem = @import("../fs.zig").FileSystem;

/// Context passed to prompt handlers.
pub const PromptContext = struct {
    allocator: std.mem.Allocator,
    workspace: *const Workspace,
    lsp_client: *LspClient,
    doc_state: *DocumentState,
    zig_path: ?[]const u8,
    fs: FileSystem,
};

pub const PromptError = error{
    PromptNotFound,
    InvalidParams,
    OutOfMemory,
    FileNotFound,
    FileReadError,
    PathOutsideWorkspace,
};

/// List all available prompts (comptime).
pub fn listPrompts() []const mcp_types.Prompt {
    return &.{
        .{
            .name = "review",
            .description = "Review a Zig source file for correctness, memory safety, error handling, and idiomatic style",
            .arguments = &.{
                .{ .name = "file", .description = "Path to the Zig source file", .required = true },
            },
        },
        .{
            .name = "explain",
            .description = "Explain a Zig source file or a specific symbol at a given position",
            .arguments = &.{
                .{ .name = "file", .description = "Path to the Zig source file", .required = true },
                .{ .name = "line", .description = "0-based line number (optional, for symbol hover)" },
                .{ .name = "character", .description = "0-based character offset (optional, for symbol hover)" },
            },
        },
        .{
            .name = "fix-diagnostics",
            .description = "Run zig ast-check on a file and provide diagnostics with fix suggestions",
            .arguments = &.{
                .{ .name = "file", .description = "Path to the Zig source file", .required = true },
            },
        },
        .{
            .name = "optimize",
            .description = "Analyze a Zig source file for optimization opportunities (comptime, SIMD, allocations, cache)",
            .arguments = &.{
                .{ .name = "file", .description = "Path to the Zig source file", .required = true },
            },
        },
        .{
            .name = "test-scaffold",
            .description = "Generate test scaffolding for public symbols in a Zig source file",
            .arguments = &.{
                .{ .name = "file", .description = "Path to the Zig source file", .required = true },
            },
        },
    };
}

/// Get a prompt by name, returning the rendered messages.
pub fn getPrompt(ctx: PromptContext, name: []const u8, arguments: std.json.Value) PromptError![]const mcp_types.PromptMessage {
    if (std.mem.eql(u8, name, "review")) {
        return handleReview(ctx, arguments);
    } else if (std.mem.eql(u8, name, "explain")) {
        return handleExplain(ctx, arguments);
    } else if (std.mem.eql(u8, name, "fix-diagnostics")) {
        return handleFixDiagnostics(ctx, arguments);
    } else if (std.mem.eql(u8, name, "optimize")) {
        return handleOptimize(ctx, arguments);
    } else if (std.mem.eql(u8, name, "test-scaffold")) {
        return handleTestScaffold(ctx, arguments);
    }
    return error.PromptNotFound;
}

// ── Prompt handlers ──

fn handleReview(ctx: PromptContext, arguments: std.json.Value) PromptError![]const mcp_types.PromptMessage {
    const file = getStringArg(arguments, "file") orelse return error.InvalidParams;
    const source = readFileInWorkspace(ctx, file) orelse return error.FileNotFound;

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    aw.writer.print(
        \\You are an expert Zig developer performing a focused code review. Report only actionable issues.
        \\
        \\Review the following Zig source file for:
        \\
        \\1. **Correctness**: Logic errors, off-by-one, incorrect type usage, undefined behavior from unsafe builtins (`@intCast`, `@ptrCast`, `@bitCast`)
        \\2. **Memory safety**: Missing `defer`/`errdefer` paired with allocations, use-after-free, missing cleanup on error paths, partial initialization without `errdefer` for already-acquired resources
        \\3. **Error handling**: Use of `anyerror` where a named error set would be better, silently discarded errors (`catch {{}}`), missing `errdefer` cleanup, error set completeness
        \\4. **Idiomatic Zig**:
        \\   - Naming: TitleCase for types and type-returning functions, camelCase for other functions, snake_case for variables/fields
        \\   - Prefer optionals (`?T` + `orelse`) over sentinel values
        \\   - Use tagged unions (`union(enum)`) over separate enum + data
        \\   - Exhaustive `switch` — avoid `else` on enums when cases can be enumerated
        \\   - Pass allocators explicitly, never use global state
        \\   - `init()`/`deinit()` convention — `deinit` must never return errors
        \\   - Prefer passing output buffers over returning allocated memory
        \\   - Use `packed struct` only for bit-level layout, `extern struct` only for C ABI
        \\5. **Performance**: Runtime computation movable to `comptime`, unnecessary heap allocations replaceable with stack/arena, large structs passed by value instead of `*const T`
        \\
        \\For each issue found, provide:
        \\- **Severity**: CRITICAL / HIGH / MEDIUM / LOW
        \\- **Line(s)**: approximate line number(s)
        \\- **Problem**: what is wrong and why it matters
        \\- **Fix**: concrete corrected code or clear suggestion
        \\
        \\Begin with a 1-2 sentence overall assessment. Order findings by severity. Do not flag formatting (use `zig fmt`) or suggest stylistic alternatives with no functional benefit.
        \\
        \\File: `{s}`
        \\
        \\```zig
        \\{s}
        \\```
    , .{ file, source }) catch return error.OutOfMemory;

    return singleUserMessage(ctx.allocator, &aw);
}

fn handleExplain(ctx: PromptContext, arguments: std.json.Value) PromptError![]const mcp_types.PromptMessage {
    const file = getStringArg(arguments, "file") orelse return error.InvalidParams;
    const source = readFileInWorkspace(ctx, file) orelse return error.FileNotFound;

    const line = getIntArg(arguments, "line");
    const char = getIntArg(arguments, "character");

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);

    // If position is given, try to get hover info from ZLS
    if (line != null and char != null) {
        const hover_info = getHoverInfo(ctx, file, line.?, char.?);
        if (hover_info) |info| {
            aw.writer.print(
                \\Explain the following Zig source file, with special attention to the symbol at line {d}, character {d}.
                \\
                \\**ZLS hover info for that position:**
                \\```
                \\{s}
                \\```
                \\
                \\File: `{s}`
                \\
                \\```zig
                \\{s}
                \\```
            , .{ line.?, char.?, info, file, source }) catch return error.OutOfMemory;
        } else {
            aw.writer.print(
                \\Explain the following Zig source file, with special attention to the symbol at line {d}, character {d}.
                \\
                \\File: `{s}`
                \\
                \\```zig
                \\{s}
                \\```
            , .{ line.?, char.?, file, source }) catch return error.OutOfMemory;
        }
    } else {
        aw.writer.print(
            \\Explain the following Zig source file. Cover:
            \\
            \\1. **Purpose**: What problem does this module solve? What is its role in the larger system?
            \\2. **Public API**: Exported functions/types — signatures, expected usage, and error conditions
            \\3. **Key Zig patterns**: Notable use of comptime, error sets, allocator threading, tagged unions, defer/errdefer, optionals
            \\4. **Memory ownership**: Who allocates, who frees? What is the lifetime model?
            \\5. **Dependencies**: What does it import and why? What are the coupling points?
            \\
            \\File: `{s}`
            \\
            \\```zig
            \\{s}
            \\```
        , .{ file, source }) catch return error.OutOfMemory;
    }

    return singleUserMessage(ctx.allocator, &aw);
}

fn handleFixDiagnostics(ctx: PromptContext, arguments: std.json.Value) PromptError![]const mcp_types.PromptMessage {
    const file = getStringArg(arguments, "file") orelse return error.InvalidParams;
    const source = readFileInWorkspace(ctx, file) orelse return error.FileNotFound;

    // Run zig ast-check if zig_path is available
    const diagnostics = runAstCheck(ctx, file);

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);

    if (diagnostics) |diag| {
        aw.writer.print(
            \\You are a Zig diagnostics expert. The following Zig source file has diagnostics from `zig ast-check`.
            \\
            \\For each diagnostic:
            \\1. Explain **why** the error occurs (root cause, not just restating the message)
            \\2. Provide the **corrected code** for the affected lines
            \\3. Note if the fix might have **cascading effects** on other code
            \\
            \\If multiple diagnostics share a root cause, group them together.
            \\
            \\**Diagnostics:**
            \\```
            \\{s}
            \\```
            \\
            \\File: `{s}`
            \\
            \\```zig
            \\{s}
            \\```
        , .{ diag, file, source }) catch return error.OutOfMemory;
    } else {
        aw.writer.print(
            \\Analyze the following Zig source file for potential issues. No `zig ast-check` output was available (zig binary not configured).
            \\Please review for syntax errors, type mismatches, and common mistakes.
            \\
            \\File: `{s}`
            \\
            \\```zig
            \\{s}
            \\```
        , .{ file, source }) catch return error.OutOfMemory;
    }

    return singleUserMessage(ctx.allocator, &aw);
}

fn handleOptimize(ctx: PromptContext, arguments: std.json.Value) PromptError![]const mcp_types.PromptMessage {
    const file = getStringArg(arguments, "file") orelse return error.InvalidParams;
    const source = readFileInWorkspace(ctx, file) orelse return error.FileNotFound;

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    aw.writer.print(
        \\Analyze the following Zig source file for optimization opportunities. Consider:
        \\
        \\1. **Comptime**: Can runtime computation be moved to compile time? Look for: constant table lookups, format string construction from literals, type-level computations, `inline for` over comptime-known slices
        \\2. **SIMD**: Are there loops over arrays of primitives that could use `@Vector(N, T)`? Check alignment requirements (`align(N)`)
        \\3. **Allocations**: Can heap allocations be replaced with stack buffers (`var buf: [N]u8 = undefined`), `FixedBufferAllocator`, or arena allocators? Are arenas being `.reset()` in loops instead of recreated?
        \\4. **Cache locality**: Would Struct-of-Arrays layout improve cache performance for hot loops that access single fields? Are related data placed adjacently?
        \\5. **Unnecessary copies**: Large structs passed by value that should be `*const T`? Redundant `dupe`/`clone` calls? Slices that could be borrowed instead of owned?
        \\6. **Algorithm complexity**: Better data structures or algorithms for the task?
        \\
        \\For each opportunity, estimate impact (HIGH/MEDIUM/LOW) and provide a concrete before/after code example. Do not suggest micro-optimizations that reduce readability for negligible gain.
        \\
        \\File: `{s}`
        \\
        \\```zig
        \\{s}
        \\```
    , .{ file, source }) catch return error.OutOfMemory;

    return singleUserMessage(ctx.allocator, &aw);
}

fn handleTestScaffold(ctx: PromptContext, arguments: std.json.Value) PromptError![]const mcp_types.PromptMessage {
    const file = getStringArg(arguments, "file") orelse return error.InvalidParams;
    const source = readFileInWorkspace(ctx, file) orelse return error.FileNotFound;

    // Try to get document symbols from ZLS
    const symbols = getDocumentSymbols(ctx, file);

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);

    if (symbols) |syms| {
        aw.writer.print(
            \\Generate test scaffolding for the following Zig source file. The ZLS document symbols are listed below to help identify public functions and types.
            \\
            \\**Discovered symbols:**
            \\```
            \\{s}
            \\```
            \\
            \\For each public function, create a test block that:
            \\- Tests the happy path with representative inputs
            \\- Tests edge cases (empty input, zero, null, boundary values)
            \\- Tests error cases using `std.testing.expectError`
            \\- Uses `std.testing.allocator` to detect leaks and use-after-free
            \\- Uses `errdefer std.debug.print(...)` for diagnostic output on failure
            \\- For functions with multiple test cases, use `inline for` over a comptime tuple for table-driven tests
            \\- Consider testing allocation failure with `std.testing.FailingAllocator` for allocation-heavy code
            \\
            \\Name each test descriptively: `test "functionName returns error on empty input"` — describe behavior, not implementation.
            \\
            \\File: `{s}`
            \\
            \\```zig
            \\{s}
            \\```
        , .{ syms, file, source }) catch return error.OutOfMemory;
    } else {
        aw.writer.print(
            \\Generate test scaffolding for the following Zig source file.
            \\
            \\For each public function, create a test block that:
            \\- Tests the happy path with representative inputs
            \\- Tests edge cases (empty input, zero, null, boundary values)
            \\- Tests error cases using `std.testing.expectError`
            \\- Uses `std.testing.allocator` to detect leaks and use-after-free
            \\- Uses `errdefer std.debug.print(...)` for diagnostic output on failure
            \\- For functions with multiple test cases, use `inline for` over a comptime tuple for table-driven tests
            \\- Consider testing allocation failure with `std.testing.FailingAllocator` for allocation-heavy code
            \\
            \\Name each test descriptively: `test "functionName returns error on empty input"` — describe behavior, not implementation.
            \\
            \\File: `{s}`
            \\
            \\```zig
            \\{s}
            \\```
        , .{ file, source }) catch return error.OutOfMemory;
    }

    return singleUserMessage(ctx.allocator, &aw);
}

// ── Helpers ──

fn getStringArg(args: std.json.Value, key: []const u8) ?[]const u8 {
    return switch (args) {
        .object => |obj| if (obj.get(key)) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null,
        else => null,
    };
}

fn getIntArg(args: std.json.Value, key: []const u8) ?i64 {
    return switch (args) {
        .object => |obj| if (obj.get(key)) |v| switch (v) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => null,
        } else null,
        else => null,
    };
}

fn readFileInWorkspace(ctx: PromptContext, file_path: []const u8) ?[]const u8 {
    const abs_path = uri_util.resolvePathWithinWorkspace(ctx.allocator, ctx.workspace.root_path, file_path, ctx.fs) catch return null;
    defer ctx.allocator.free(abs_path);
    return ctx.fs.readFileAlloc(ctx.allocator, abs_path, 4 * 1024 * 1024) catch null;
}

fn singleUserMessage(allocator: std.mem.Allocator, aw: *std.Io.Writer.Allocating) PromptError![]const mcp_types.PromptMessage {
    const text = aw.toOwnedSlice() catch return error.OutOfMemory;
    const messages = allocator.alloc(mcp_types.PromptMessage, 1) catch return error.OutOfMemory;
    messages[0] = .{
        .role = "user",
        .content = .{ .text = text },
    };
    return messages;
}

/// Try to get hover info from ZLS. Returns null on any failure (graceful degradation).
fn getHoverInfo(ctx: PromptContext, file: []const u8, line: i64, char: i64) ?[]const u8 {
    const file_uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch return null;
    defer ctx.allocator.free(file_uri);

    const HoverParams = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
    };

    const response = ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/hover", HoverParams{
        .textDocument = .{ .uri = file_uri },
        .position = .{ .line = line, .character = char },
    }) catch return null;
    defer ctx.allocator.free(response);

    return extractHoverText(ctx.allocator, response);
}

fn extractHoverText(allocator: std.mem.Allocator, response: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return null;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const result = obj.get("result") orelse return null;
    if (result == .null) return null;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return null,
    };
    const contents = result_obj.get("contents") orelse return null;
    switch (contents) {
        .string => |s| return allocator.dupe(u8, s) catch null,
        .object => |o| {
            if (o.get("value")) |v| switch (v) {
                .string => |s| return allocator.dupe(u8, s) catch null,
                else => return null,
            };
            return null;
        },
        else => return null,
    }
}

/// Try to get document symbols from ZLS. Returns null on any failure (graceful degradation).
fn getDocumentSymbols(ctx: PromptContext, file: []const u8) ?[]const u8 {
    const file_uri = ctx.doc_state.ensureOpen(ctx.lsp_client, file, ctx.allocator) catch return null;
    defer ctx.allocator.free(file_uri);

    const Params = struct {
        textDocument: struct { uri: []const u8 },
    };

    const response = ctx.lsp_client.sendRequest(ctx.allocator, "textDocument/documentSymbol", Params{
        .textDocument = .{ .uri = file_uri },
    }) catch return null;
    defer ctx.allocator.free(response);

    return extractSymbolNames(ctx.allocator, response);
}

fn extractSymbolNames(allocator: std.mem.Allocator, response: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return null;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const result = obj.get("result") orelse return null;
    if (result == .null) return null;
    const symbols = switch (result) {
        .array => |a| a,
        else => return null,
    };

    if (symbols.items.len == 0) return null;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    for (symbols.items) |sym| {
        const sym_obj = switch (sym) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (sym_obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const kind = switch (sym_obj.get("kind") orelse continue) {
            .integer => |k| k,
            else => continue,
        };
        const kind_name = symbolKindName(kind);
        aw.writer.print("- {s} ({s})\n", .{ name, kind_name }) catch return null;
    }
    return aw.toOwnedSlice() catch null;
}

fn symbolKindName(kind: i64) []const u8 {
    return switch (kind) {
        1 => "File",
        2 => "Module",
        5 => "Class",
        6 => "Method",
        8 => "Field",
        9 => "Constructor",
        10 => "Enum",
        12 => "Function",
        13 => "Variable",
        14 => "Constant",
        23 => "Struct",
        25 => "TypeParameter",
        else => "Symbol",
    };
}

/// Try to run zig ast-check on a file. Returns null on any failure.
fn runAstCheck(ctx: PromptContext, file: []const u8) ?[]const u8 {
    const zig_path = ctx.zig_path orelse return null;
    const abs_path = uri_util.resolvePathWithinWorkspace(ctx.allocator, ctx.workspace.root_path, file, ctx.fs) catch return null;
    defer ctx.allocator.free(abs_path);

    const result = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = &.{ zig_path, "ast-check", abs_path },
        .cwd = ctx.workspace.root_path,
        .max_output_bytes = 512 * 1024,
    }) catch return null;
    defer ctx.allocator.free(result.stdout);

    if (result.term == .Exited and result.term.Exited == 0) {
        // No errors — clean ast-check
        ctx.allocator.free(result.stderr);
        return ctx.allocator.dupe(u8, "No errors found.") catch null;
    }

    // Return stderr which contains the diagnostics
    if (result.stderr.len > 0) {
        return result.stderr;
    }
    ctx.allocator.free(result.stderr);
    return null;
}

// ── Tests ──

test "listPrompts returns 5 prompts" {
    const prompts = listPrompts();
    try std.testing.expectEqual(@as(usize, 5), prompts.len);
    try std.testing.expectEqualStrings("review", prompts[0].name);
    try std.testing.expectEqualStrings("explain", prompts[1].name);
    try std.testing.expectEqualStrings("fix-diagnostics", prompts[2].name);
    try std.testing.expectEqualStrings("optimize", prompts[3].name);
    try std.testing.expectEqualStrings("test-scaffold", prompts[4].name);
}

test "listPrompts review has required file argument" {
    const prompts = listPrompts();
    const review = prompts[0];
    try std.testing.expect(review.arguments != null);
    const args = review.arguments.?;
    try std.testing.expectEqual(@as(usize, 1), args.len);
    try std.testing.expectEqualStrings("file", args[0].name);
    try std.testing.expect(args[0].required.? == true);
}

test "listPrompts explain has optional line/character" {
    const prompts = listPrompts();
    const explain = prompts[1];
    const args = explain.arguments.?;
    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expect(args[1].required == null);
    try std.testing.expect(args[2].required == null);
}

test "getPrompt returns PromptNotFound for unknown name" {
    const workspace = @import("../state/workspace.zig").Workspace{
        .root_path = "/tmp",
        .root_uri = "file:///tmp",
        .allocator = std.testing.allocator,
    };
    var lsp_client = @import("../lsp/client.zig").LspClient.init(std.testing.allocator);
    defer lsp_client.deinit();
    const TestFileSystem = @import("../fs.zig").TestFileSystem;
    var tfs = TestFileSystem{};
    var doc_state = @import("../state/documents.zig").DocumentState.init(std.testing.allocator, "/tmp", tfs.filesystem());
    defer doc_state.deinit();

    const ctx = PromptContext{
        .allocator = std.testing.allocator,
        .workspace = &workspace,
        .lsp_client = &lsp_client,
        .doc_state = &doc_state,
        .zig_path = null,
        .fs = tfs.filesystem(),
    };
    try std.testing.expectError(error.PromptNotFound, getPrompt(ctx, "nonexistent", .null));
}

test "getPrompt review returns InvalidParams without file" {
    const workspace = @import("../state/workspace.zig").Workspace{
        .root_path = "/tmp",
        .root_uri = "file:///tmp",
        .allocator = std.testing.allocator,
    };
    var lsp_client = @import("../lsp/client.zig").LspClient.init(std.testing.allocator);
    defer lsp_client.deinit();
    const TestFileSystem2 = @import("../fs.zig").TestFileSystem;
    var tfs2 = TestFileSystem2{};
    var doc_state = @import("../state/documents.zig").DocumentState.init(std.testing.allocator, "/tmp", tfs2.filesystem());
    defer doc_state.deinit();

    const ctx = PromptContext{
        .allocator = std.testing.allocator,
        .workspace = &workspace,
        .lsp_client = &lsp_client,
        .doc_state = &doc_state,
        .zig_path = null,
        .fs = tfs2.filesystem(),
    };
    try std.testing.expectError(error.InvalidParams, getPrompt(ctx, "review", .null));
}

test "getStringArg extracts string" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"file\":\"src/main.zig\"}", .{});
    defer parsed.deinit();
    const result = getStringArg(parsed.value, "file");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("src/main.zig", result.?);
}

test "getStringArg returns null for missing key" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{}", .{});
    defer parsed.deinit();
    try std.testing.expect(getStringArg(parsed.value, "file") == null);
}

test "getIntArg extracts integer" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"line\":42}", .{});
    defer parsed.deinit();
    const result = getIntArg(parsed.value, "line");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 42), result.?);
}

test "symbolKindName returns correct names" {
    try std.testing.expectEqualStrings("Function", symbolKindName(12));
    try std.testing.expectEqualStrings("Struct", symbolKindName(23));
    try std.testing.expectEqualStrings("Variable", symbolKindName(13));
    try std.testing.expectEqualStrings("Symbol", symbolKindName(999));
}

test "extractHoverText handles null result" {
    const alloc = std.testing.allocator;
    const response = "{\"result\":null}";
    try std.testing.expect(extractHoverText(alloc, response) == null);
}

test "extractHoverText handles string contents" {
    const alloc = std.testing.allocator;
    const response = "{\"result\":{\"contents\":\"fn main() void\"}}";
    const result = extractHoverText(alloc, response);
    try std.testing.expect(result != null);
    defer alloc.free(result.?);
    try std.testing.expectEqualStrings("fn main() void", result.?);
}

test "extractHoverText handles markup contents" {
    const alloc = std.testing.allocator;
    const response = "{\"result\":{\"contents\":{\"kind\":\"markdown\",\"value\":\"fn main() void\"}}}";
    const result = extractHoverText(alloc, response);
    try std.testing.expect(result != null);
    defer alloc.free(result.?);
    try std.testing.expectEqualStrings("fn main() void", result.?);
}

test "extractSymbolNames handles empty array" {
    const alloc = std.testing.allocator;
    const response = "{\"result\":[]}";
    try std.testing.expect(extractSymbolNames(alloc, response) == null);
}

test "extractSymbolNames formats symbols" {
    const alloc = std.testing.allocator;
    const response = "{\"result\":[{\"name\":\"main\",\"kind\":12},{\"name\":\"Config\",\"kind\":23}]}";
    const result = extractSymbolNames(alloc, response);
    try std.testing.expect(result != null);
    defer alloc.free(result.?);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "main (Function)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "Config (Struct)") != null);
}
