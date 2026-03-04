# Tools, Resources & Prompts

## Code intelligence tools (via ZLS)

Tools are registered dynamically based on what the connected ZLS instance supports.

| Tool | Description |
|------|-------------|
| `zig_hover` | Type info and docs for a symbol |
| `zig_definition` | Go to definition |
| `zig_declaration` | Go to declaration |
| `zig_type_definition` | Go to type definition |
| `zig_references` | Find all references |
| `zig_completion` | Completion suggestions |
| `zig_diagnostics` | Errors and warnings for a file |
| `zig_diagnostics_all` | Errors and warnings for all previously opened files |
| `zig_format` | Format a file |
| `zig_rename` | Rename a symbol across the workspace |
| `zig_document_symbols` | List all symbols in a file |
| `zig_workspace_symbols` | Search symbols across the project |
| `zig_code_action` | Quick fixes and refactors for a range |
| `zig_apply_code_action` | Apply a code action by index (use `zig_code_action` first) |
| `zig_signature_help` | Function signature at cursor |
| `zig_inlay_hints` | Inferred types and parameter names for a file |

## Build & run tools

Command execution tools are disabled by default. Start zig-mcp with `--allow-command-tools` to enable them.
`--allow-command-tools` requires `--zig-path`.
`zig_manage` requires `--zvm-path`.

| Tool | Description |
|------|-------------|
| `zig_build` | Run `zig build` with optional args |
| `zig_test` | Run tests (whole project or single file, with optional filter) |
| `zig_check` | Run `zig ast-check` on a file |
| `zig_version` | Show Zig and ZLS versions |
| `zig_manage` | Manage Zig versions via [zvm](https://github.com/marler/zvm) |

## Resources

| Resource | URI | Description |
|----------|-----|-------------|
| Project Info | `zig://project-info` | Zig/ZLS versions and `build.zig.zon` contents |
| Workspace File | `file:///{path}` (template) | Read any file within the workspace by path |

## Prompts

| Prompt | Arguments | Description |
|--------|-----------|-------------|
| `review` | `file` (required) | Review a Zig file for correctness, memory safety, error handling, and idiomatic style |
| `explain` | `file` (required), `line`, `character` (optional) | Explain a file or a specific symbol at a given position |
| `fix-diagnostics` | `file` (required) | Run `zig ast-check` and provide diagnostics with fix suggestions |
| `optimize` | `file` (required) | Analyze for optimization opportunities (comptime, SIMD, allocations, cache) |
| `test-scaffold` | `file` (required) | Generate test scaffolding for public symbols |

## Tool annotations

All tools include MCP [tool annotations](https://modelcontextprotocol.io/docs/concepts/tools#tool-annotations) (`readOnlyHint`, `destructiveHint`, `openWorldHint`) so clients can make informed decisions about tool usage.
