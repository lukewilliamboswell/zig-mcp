# Editor Setup

If you installed via the [Claude Code plugin](../README.md#claude-code-plugin-recommended), skip this page — everything is configured automatically.

These instructions are for **manual builds** only.

## Claude Code

See the [README](../README.md#setup-manual-install-only) for Claude Code setup.

## Cursor

Add to `.cursor/mcp.json` in your project:

```json
{
  "mcpServers": {
    "zig-mcp": {
      "command": "/absolute/path/to/zig-mcp",
      "args": ["--workspace", "/path/to/your/zig/project"]
    }
  }
}
```

## Windsurf

Add to `~/.codeium/windsurf/mcp_config.json`:

```json
{
  "mcpServers": {
    "zig-mcp": {
      "command": "/absolute/path/to/zig-mcp",
      "args": ["--workspace", "/path/to/your/zig/project"]
    }
  }
}
```

## Codex

Add to `~/.codex/config.toml`:

```toml
[mcp_servers.zig-mcp]
command = "/absolute/path/to/zig-mcp"
args = [
  "--workspace", "/path/to/your/zig/project",
  "--allow-command-tools",
  "--zig-path", "/usr/bin/zig",
]
```

## Scope precedence warning (Claude Code)

> **Avoid `claude mcp add` without `--scope project`.** The default scope is `local`, which stores the config in `~/.claude.json` (under a per-project key). Local-scoped entries take precedence over `.mcp.json`, so if you later create a `.mcp.json` with different flags, the stale local entry silently wins. If this happens, remove it with `claude mcp remove zig-mcp` and restart Claude Code.
