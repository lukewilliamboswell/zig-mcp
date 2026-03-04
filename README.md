# zig-mcp

MCP server for Zig that connects AI coding assistants to [ZLS](https://github.com/zigtools/zls) via the Language Server Protocol.

Works with [Claude Code](https://docs.anthropic.com/en/docs/claude-code), Cursor, Windsurf, and any MCP-compatible client.

```
AI assistant  <--(MCP stdio)-->  zig-mcp  <--(LSP pipes)-->  ZLS
                                    |
                             zig build / test / check
```

## Requirements

- [Zig](https://ziglang.org/download/) 0.15.2+
- [ZLS](https://github.com/zigtools/zls/releases) (auto-detected from trusted fixed locations, or specify with `--zls-path`)

When you set `--zig-path`, point it to a Zig binary from a full Zig distribution directory (with sibling `lib/`), not a standalone copied binary.

## Install

### Claude Code plugin (recommended)

Install directly from the Claude Code interface — no manual build needed:

```bash
# 1. Add the marketplace
/plugin marketplace add nzrsky/zig-mcp

# 2. Install the plugin
/plugin install zig-mcp@zig
```

Or as a one-liner from the terminal:

```bash
claude plugin marketplace add nzrsky/zig-mcp && claude plugin install zig-mcp@zig
```

The binary is built automatically on first use. Just make sure `zig` and `zls` are in your PATH.

### Manual build

```bash
git clone https://github.com/nzrsky/zig-mcp.git
cd zig-mcp
zig build -Doptimize=ReleaseFast
```

Binary is at `zig-out/bin/zig-mcp`.

## Setup (manual install only)

If you installed via the plugin system, skip this section — everything is configured automatically.

### Claude Code

The recommended approach is to add a `.mcp.json` file to your project root:

```json
{
  "mcpServers": {
    "zig-mcp": {
      "type": "stdio",
      "command": "/absolute/path/to/zig-mcp",
      "args": [
        "--workspace", "/path/to/your/zig/project",
        "--allow-command-tools",
        "--zig-path", "/path/to/zig",
        "--zls-path", "/path/to/zls"
      ]
    }
  }
}
```

Alternatively, use the CLI to write directly to `.mcp.json`:

```bash
claude mcp add --scope project zig-mcp -- /absolute/path/to/zig-mcp --workspace /path/to/your/zig/project
```

> If you omit `--workspace`, zig-mcp uses the current working directory.

For Cursor, Windsurf, Codex, see [docs/setup.md](docs/setup.md).

## Options

```
--workspace, -w <path>   Project root directory (default: cwd)
--zls-path <path>        Path to ZLS binary (default: trusted fixed locations)
--zig-path <path>        Path to zig binary (required with --allow-command-tools)
--zvm-path <path>        Path to zvm binary (optional, enables zig_manage)
--allow-command-tools    Enable command execution tools (disabled by default)
--help, -h               Show help
--version                Show version
```

## Tools

### Code intelligence (via ZLS)

hover, definition, declaration, type_definition, references, completion, diagnostics, diagnostics_all, format, rename, document_symbols, workspace_symbols, code_action, apply_code_action, signature_help, inlay_hints

### Build & run (requires `--allow-command-tools`)

build, test, check, version, manage

### Resources

`zig://project-info`, `file:///{path}` template

### Prompts

review, explain, fix-diagnostics, optimize, test-scaffold

See [docs/tools.md](docs/tools.md) for details.

## Development

```bash
# build
zig build

# run tests
zig build test

# run lints
zig build lint

# run manually
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' | \
  zig-out/bin/zig-mcp --workspace . 2>/dev/null
```

## License

MIT
