# Architecture

## How it works

zig-mcp spawns ZLS as a child process and talks to it over stdin/stdout using the LSP protocol (Content-Length framing). On the other side, it speaks MCP (newline-delimited JSON-RPC) to the AI assistant.

```
AI assistant  <--(MCP stdio)-->  zig-mcp  <--(LSP pipes)-->  ZLS
                                    |
                             zig build / test / check
```

## Threads

Three threads:
- **main** — reads MCP requests, dispatches tool calls, writes responses
- **reader** — reads LSP responses from ZLS, correlates by request ID
- **stderr** — forwards ZLS stderr to the server log

## Key internals

### Degraded mode & auto-reconnect

If ZLS crashes, zig-mcp automatically restarts it and re-opens all tracked documents. Code intelligence tools are temporarily unavailable during restart but the server stays alive.

### Diagnostics cache & BLAKE3 hashing

File diagnostics are cached and invalidated using BLAKE3 content hashing. When a file hasn't changed, cached diagnostics are returned immediately without re-querying ZLS.

### Lazy document tracking

Files are opened in ZLS lazily on first access — no need to manage document state manually.

### Dynamic tool registration

LSP-backed tools are registered dynamically based on what the connected ZLS instance reports in its server capabilities. If ZLS doesn't advertise a capability, the corresponding tool won't appear.
