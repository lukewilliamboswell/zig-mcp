const std = @import("std");
const mcp_types = @import("../mcp/types.zig");
const uri_util = @import("../types/uri.zig");
const Workspace = @import("../state/workspace.zig").Workspace;
const FileSystem = @import("../fs.zig").FileSystem;

/// Context passed to resource handlers.
pub const ResourceContext = struct {
    allocator: std.mem.Allocator,
    workspace: *const Workspace,
    zig_path: ?[]const u8,
    zls_path: ?[]const u8,
    fs: FileSystem,
};

pub const ResourceError = error{
    ResourceNotFound,
    OutOfMemory,
    ReadFailed,
    PathOutsideWorkspace,
};

/// List static MCP resources.
pub fn listResources() []const mcp_types.Resource {
    return &.{
        .{
            .uri = "zig://project-info",
            .name = "Project Info",
            .description = "Zig/ZLS versions and build.zig.zon contents",
            .mimeType = "text/plain",
        },
    };
}

/// List MCP resource templates.
pub fn listResourceTemplates() []const mcp_types.ResourceTemplate {
    return &.{
        .{
            .uriTemplate = "file:///{path}",
            .name = "Workspace File",
            .description = "Read any file within the workspace by path",
        },
    };
}

/// Read a resource by URI. Returns the text content.
pub fn readResource(ctx: ResourceContext, resource_uri: []const u8) ResourceError![]const u8 {
    if (std.mem.eql(u8, resource_uri, "zig://project-info")) {
        return readProjectInfo(ctx);
    }
    if (std.mem.startsWith(u8, resource_uri, "file://")) {
        return readFileResource(ctx, resource_uri);
    }
    return error.ResourceNotFound;
}

fn readProjectInfo(ctx: ResourceContext) ResourceError![]const u8 {
    const zig_ver = if (ctx.zig_path) |zp|
        runVersionCommand(ctx.allocator, zp, "version") catch "unknown"
    else
        "unknown";
    defer if (!std.mem.eql(u8, zig_ver, "unknown")) ctx.allocator.free(zig_ver);

    const zls_ver = if (ctx.zls_path) |zp|
        runVersionCommand(ctx.allocator, zp, "--version") catch "unknown"
    else
        "unknown";
    defer if (!std.mem.eql(u8, zls_ver, "unknown")) ctx.allocator.free(zls_ver);

    // Try to read build.zig.zon
    const zon_path = std.fs.path.join(ctx.allocator, &.{ ctx.workspace.root_path, "build.zig.zon" }) catch return error.OutOfMemory;
    defer ctx.allocator.free(zon_path);
    const zon_content: []const u8 = ctx.fs.readFileAlloc(ctx.allocator, zon_path, 1024 * 1024) catch
        (ctx.allocator.dupe(u8, "(not found)") catch return error.OutOfMemory);
    defer ctx.allocator.free(zon_content);

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    aw.writer.print("Zig: {s}\nZLS: {s}\n\n--- build.zig.zon ---\n{s}", .{
        std.mem.trimRight(u8, zig_ver, "\n\r "),
        std.mem.trimRight(u8, zls_ver, "\n\r "),
        zon_content,
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

fn readFileResource(ctx: ResourceContext, resource_uri: []const u8) ResourceError![]const u8 {
    const file_path = uri_util.uriToPath(ctx.allocator, resource_uri) catch return error.ReadFailed;
    defer ctx.allocator.free(file_path);

    const canonical = uri_util.resolvePathWithinWorkspace(ctx.allocator, ctx.workspace.root_path, file_path, ctx.fs) catch |err| switch (err) {
        error.PathOutsideWorkspace => return error.PathOutsideWorkspace,
        else => return error.ReadFailed,
    };
    defer ctx.allocator.free(canonical);

    return ctx.fs.readFileAlloc(ctx.allocator, canonical, 4 * 1024 * 1024) catch return error.ReadFailed;
}

fn runVersionCommand(allocator: std.mem.Allocator, binary: []const u8, arg: []const u8) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ binary, arg },
        .max_output_bytes = 4096,
    });
    defer allocator.free(result.stderr);

    if (result.term == .Exited and result.term.Exited == 0) {
        return result.stdout;
    }
    allocator.free(result.stdout);
    return error.CommandFailed;
}

// ── Tests ──

test "listResources returns project-info" {
    const resources = listResources();
    try std.testing.expectEqual(@as(usize, 1), resources.len);
    try std.testing.expectEqualStrings("zig://project-info", resources[0].uri);
}

test "listResourceTemplates returns file template" {
    const templates = listResourceTemplates();
    try std.testing.expectEqual(@as(usize, 1), templates.len);
    try std.testing.expectEqualStrings("file:///{path}", templates[0].uriTemplate);
}

test "readResource returns error for unknown URI" {
    const workspace = @import("../state/workspace.zig").Workspace{
        .root_path = "/tmp",
        .root_uri = "file:///tmp",
        .allocator = std.testing.allocator,
    };
    const OsFileSystem = @import("../fs.zig").OsFileSystem;
    const os_fs: OsFileSystem = .{};
    const ctx = ResourceContext{
        .allocator = std.testing.allocator,
        .workspace = &workspace,
        .zig_path = null,
        .zls_path = null,
        .fs = os_fs.filesystem(),
    };
    try std.testing.expectError(error.ResourceNotFound, readResource(ctx, "zig://unknown"));
}
