# Feature Ideas for zig-mcp

> Research report compiled 2026-03-04.
> Sources: [MCP Specification 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/),
> [Everything Server](https://mcpservers.org/servers/modelcontextprotocol/everything),
> [zig-wasm/zig-mcp](https://github.com/zig-wasm/zig-mcp),
> [openSVM/zig-mcp-server](https://github.com/openSVM/zig-mcp-server),
> [mcp.zig](https://muhammad-fiaz.github.io/mcp.zig/),
> [MCP Official Servers](https://github.com/modelcontextprotocol/servers)

---

## Current State

zig-mcp v0.1.0 currently provides:
- **18 tools**: 13 LSP-backed code intelligence tools + 5 command execution tools
- **stdio transport** only (newline-delimited JSON-RPC)
- **3 protocol versions**: 2025-11-25, 2025-06-18, 2024-11-05
- **Empty resources list**, no prompts, no sampling, no logging capability
- **Auto-reconnect** to ZLS (up to 5 restarts), lazy document loading, degraded mode
- **Security**: workspace-scoped paths, trusted binary policy, canonical path enforcement

---

## Feature Ideas

### 1. Workspace Resources

**What**: Expose workspace files, project structure, and diagnostics summaries as MCP resources via `resources/list` and `resources/read`. Examples:
- `file:///<workspace>/src/main.zig` — read source files
- `zig://diagnostics` — aggregated diagnostics summary
- `zig://build-graph` — dependency/build graph
- `zig://project-info` — compiler version, build targets, dependencies from `build.zig.zon`

**Benefit**: Allows the AI to pull in relevant context *without* needing a tool call round-trip. Resources are designed for **application-driven** context inclusion — the client can automatically attach relevant file contents, diagnostics, or project metadata to prompts. This reduces token waste from repeatedly calling `zig_hover` or `zig_diagnostics` on many files.

**Productivity gain**: **High**. Clients like Claude Desktop can show a resource picker UI, letting users attach entire files or diagnostics snapshots to the conversation in one click. Eliminates multi-step "read file → analyze → read next file" loops.

**Spec reference**: [MCP Resources](https://modelcontextprotocol.io/specification/2025-11-25/server/resources)

---

### 2. Resource Subscriptions

**What**: Implement `resources/subscribe` so clients receive `notifications/resources/updated` when workspace files change on disk or when diagnostics change after a build.

**Benefit**: Enables real-time, reactive workflows. The AI assistant is notified when a file changes or new diagnostics appear, rather than polling. For example, after the user saves a file, the client could automatically re-check diagnostics without the user asking.

**Productivity gain**: **Medium**. Saves the "run diagnostics again" round-trip after edits. Most impactful in long coding sessions where diagnostics drift.

**Spec reference**: [Resource Subscriptions](https://modelcontextprotocol.io/specification/2025-11-25/server/resources#subscriptions)

---

### 3. Resource Templates

**What**: Expose parameterized resource URIs using RFC 6570 URI templates, e.g.:
- `file:///{path}` — access any workspace file by path
- `zig://symbol/{name}` — look up a symbol's documentation
- `zig://diagnostics/{file}` — diagnostics for a specific file

**Benefit**: Templates let clients dynamically construct resource URIs without needing to list every possible resource upfront. Combined with the completion API (see idea #12), clients can offer autocomplete as the user types a file path or symbol name.

**Productivity gain**: **Medium**. Particularly useful for large workspaces where listing all resources is impractical.

**Spec reference**: [Resource Templates](https://modelcontextprotocol.io/specification/2025-11-25/server/resources#resource-templates)

---

### 4. Prompts (Reusable Interaction Templates)

**What**: Define server-side prompt templates that clients can invoke, such as:
- **`/review`** — Code review prompt: takes a file path, reads the file, and returns a structured review prompt with Zig best practices
- **`/explain`** — Explain code: takes a symbol or file, gathers hover info and references, returns an explanation prompt
- **`/fix-diagnostics`** — Auto-fix: gathers current diagnostics and returns a prompt asking the LLM to generate fixes
- **`/optimize`** — Performance review: analyzes code and suggests Zig-specific optimizations (comptime, SIMD, allocation patterns)
- **`/test-scaffold`** — Generate test scaffolding for a given function or module

**Benefit**: Prompts are **user-controlled** — they appear as slash commands in client UIs. They package domain expertise (Zig best practices, common patterns) into reusable workflows that the user can trigger with one command. Unlike tools (which the AI invokes), prompts are explicitly chosen by the user, giving them control over when expensive operations happen.

**Productivity gain**: **High**. Each prompt encapsulates a multi-step workflow (read file → gather context → format prompt) into a single action. The `/fix-diagnostics` prompt alone could save significant time by automatically gathering all errors and proposing fixes in one shot.

**Spec reference**: [MCP Prompts](https://modelcontextprotocol.io/specification/2025-11-25/server/prompts)

---

### 5. Structured Logging

**What**: Declare the `logging` capability and emit `notifications/message` with structured log data. Support `logging/setLevel` so clients can control verbosity. Log categories:
- ZLS lifecycle events (start, crash, restart)
- Tool execution timing and outcomes
- LSP request/response diagnostics
- Build and test output summaries

**Benefit**: Gives clients (and by extension users) visibility into what the server is doing. Currently all logging goes to stderr and is invisible to the AI client. Structured logs allow the client to surface issues like "ZLS crashed and restarted" or "LSP request timed out after 30s" directly in the UI, so users understand *why* a tool call was slow or failed.

**Productivity gain**: **Medium**. Most useful for debugging when things go wrong. Reduces time spent investigating "why did that fail?" from minutes to seconds.

**Spec reference**: [MCP Logging](https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/logging)

---

### 6. Progress Notifications

**What**: Send `notifications/progress` during long-running operations like `zig_build`, `zig_test`, and `zig_references` (which can be slow on large codebases). Include progress tokens in tool call responses.

**Benefit**: Long builds or test suites currently block with no feedback. Progress notifications let the client show a progress bar or streaming status, so the user knows the operation is alive and roughly how far along it is.

**Productivity gain**: **Medium**. Doesn't speed up operations, but dramatically improves perceived responsiveness. Users won't cancel-and-retry operations that are actually making progress.

**Spec reference**: [MCP Progress](https://modelcontextprotocol.io/specification/2025-11-25/server/utilities)

---

### 7. Request Cancellation

**What**: Handle `notifications/cancelled` to abort in-progress tool calls. When a cancellation is received for a pending LSP request, forward a cancellation to ZLS (`$/cancelRequest`) and clean up. For command tools, terminate the child process.

**Benefit**: Currently, if a user triggers a long `zig_build` or `zig_references` and changes their mind, there's no way to stop it — they must wait for the 30s timeout or the command to finish. Cancellation lets users abort immediately.

**Productivity gain**: **Medium-High**. Eliminates wasted time waiting for operations the user no longer needs. Especially impactful during iterative development where the user may trigger a build, realize they forgot something, and want to cancel.

**Spec reference**: [MCP Cancellation](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation)

---

### 8. Streamable HTTP Transport

**What**: Add an HTTP/SSE transport alongside stdio, implementing the current MCP Streamable HTTP transport spec. This would allow zig-mcp to run as a persistent HTTP server that multiple clients can connect to.

**Benefit**: Enables remote development scenarios — the server runs on a build machine or in a container, and the client connects over HTTP. Also enables multi-client access (e.g., two editors sharing the same ZLS instance). The "Everything" reference server supports both stdio and Streamable HTTP, and this is the direction the ecosystem is moving (the older SSE transport is deprecated).

**Productivity gain**: **Medium**. Primary benefit is architectural flexibility. Essential for remote/containerized development environments. Not needed for the common single-editor local workflow.

**Spec reference**: [Everything Server transports](https://mcpservers.org/servers/modelcontextprotocol/everything), MCP Transports spec

---

### 9. Zig Standard Library Documentation Resources

**What**: Expose Zig standard library documentation as MCP resources, similar to the [zig-wasm/zig-mcp](https://github.com/zig-wasm/zig-mcp) server which provides `list_builtin_functions`, `get_builtin_function`, `search_std_lib`, and `get_std_lib_item` tools. Could be implemented as:
- Tools: `zig_builtin_docs` (builtin function documentation), `zig_std_docs` (std library item documentation)
- Resources: `zig://std/{module}/{item}`, `zig://builtin/{name}`

**Benefit**: Currently the AI has no direct access to Zig documentation. It must rely on its training data, which may be outdated or incomplete. Providing documentation that matches the user's installed Zig version ensures accurate, version-specific guidance. The zig-wasm/zig-mcp server converts HTML docs to Markdown, reducing token usage by ~60% compared to raw HTML.

**Productivity gain**: **High**. Zig's standard library documentation is essential for productive development. Having accurate, version-matched docs available directly in the AI context eliminates web searches and reduces hallucinated API suggestions. Particularly valuable because Zig's API surface changes between versions.

**Source**: [zig-wasm/zig-mcp](https://github.com/zig-wasm/zig-mcp)

---

### 10. Build System Analysis & Generation Tools

**What**: Add tools inspired by [openSVM/zig-mcp-server](https://github.com/openSVM/zig-mcp-server):
- `zig_analyze_build` — Analyze an existing `build.zig` for outdated patterns, missing best practices, and migration opportunities
- `zig_generate_build` — Generate a `build.zig` from a description (cross-compilation targets, dependencies, test setup)

**Benefit**: Build system configuration is one of the most common pain points for Zig users. An analysis tool that detects outdated patterns (e.g., pre-0.15 APIs) and suggests modern replacements would be highly valuable. Generation saves time when bootstrapping new projects.

**Productivity gain**: **Medium**. Build files are written infrequently but are high-friction when they need changes. Most impactful for users migrating between Zig versions.

**Source**: [openSVM/zig-mcp-server](https://github.com/openSVM/zig-mcp-server) (`analyze_build_zig`, `generate_build_zig`)

---

### 11. Code Optimization Analysis Tool

**What**: Add a `zig_optimize` tool that analyzes Zig code and suggests optimizations:
- Identify missed `comptime` opportunities
- Suggest SIMD-friendly patterns
- Flag unnecessary allocations (prefer stack over heap)
- Recommend `@prefetch`, alignment hints, and cache-friendly data layouts
- Analyze across build modes (Debug vs ReleaseFast vs ReleaseSmall)

**Benefit**: Zig is chosen for performance-critical work, but leveraging its full optimization potential requires deep expertise. An optimization analysis tool bridges this knowledge gap, surfacing actionable suggestions that many developers wouldn't discover on their own.

**Productivity gain**: **Medium**. Useful for performance-sensitive code. The AI already provides optimization advice, but tool-backed analysis grounded in actual code structure is more reliable than general suggestions.

**Source**: [openSVM/zig-mcp-server](https://github.com/openSVM/zig-mcp-server) (`optimize_code`)

---

### 12. Completion/Autocomplete for Prompt and Resource Arguments

**What**: Implement the `completion/complete` method so clients can offer autocomplete when users are typing arguments for prompts or resource templates. For example:
- Typing a file path in a resource template → suggest matching workspace files
- Typing a symbol name in a prompt argument → suggest matching symbols from `zig_workspace_symbols`

**Benefit**: Makes prompts and resource templates much more usable. Without autocomplete, users must remember exact file paths and symbol names. With it, they get IDE-like suggestions as they type.

**Productivity gain**: **Medium**. Quality-of-life improvement that makes other features (prompts, resource templates) more accessible. Minimal value on its own.

**Spec reference**: [MCP Completion](https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/completion)

---

### 13. Pagination for Large Result Sets

**What**: Implement cursor-based pagination for `tools/list`, `resources/list`, and `prompts/list` responses. Also paginate large tool results like `zig_references` and `zig_workspace_symbols` which can return hundreds of results.

**Benefit**: Prevents memory issues and message size limits when dealing with large workspaces. Currently `zig_completion` truncates at 50 items and `zig_workspace_symbols` returns everything. Pagination gives clients control over how much data to fetch.

**Productivity gain**: **Low-Medium**. Mostly a robustness improvement. Current limits (1MB message max) haven't been a problem in practice, but pagination future-proofs against larger workspaces.

**Spec reference**: [MCP Pagination](https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/pagination)

---

### 14. Tool Annotations (Read-Only, Destructive, Open-World Hints)

**What**: Add `annotations` to tool definitions to hint at their behavior:
- `readOnlyHint: true` for tools like `zig_hover`, `zig_references`, `zig_diagnostics`
- `destructiveHint: false` for `zig_format` (modifies files but safely)
- `openWorldHint: false` for LSP tools (no network), `true` for tools that might fetch dependencies

**Benefit**: Allows clients to make better auto-approval decisions. A client could auto-approve all `readOnlyHint: true` tools without user confirmation, while always prompting for destructive operations. This reduces the click-to-approve friction for safe operations.

**Productivity gain**: **Medium**. Directly reduces the number of permission prompts users see. In a typical session, most tool calls are reads (hover, definition, references), so marking them read-only could eliminate 70%+ of approval dialogs.

**Spec reference**: [MCP Tool Annotations](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)

---

### 15. Sampling (Server-Initiated LLM Calls)

**What**: Use the `sampling/createMessage` capability to enable the server to invoke the client's LLM for intelligent operations:
- Automatic error explanation: when `zig_diagnostics` returns errors, the server could ask the LLM to explain them in plain English
- Suggested fixes: the server could ask the LLM to propose code fixes for common Zig errors
- Code generation: the server could orchestrate multi-step code generation with ZLS validation in the loop

**Benefit**: Enables agentic workflows where the server can leverage the LLM's reasoning without the user orchestrating every step. The server has deep knowledge of the Zig context (diagnostics, types, symbols) and can craft much better prompts than the user would manually.

**Productivity gain**: **High** (if supported by the client). This is the most powerful feature for enabling autonomous workflows. However, not all clients support sampling, and it requires human-in-the-loop approval for safety.

**Spec reference**: [MCP Sampling](https://modelcontextprotocol.io/specification/2025-11-25/client/sampling)

---

### 16. Multi-File Diagnostics Aggregation Tool

**What**: Add a `zig_diagnostics_all` tool that returns diagnostics across all open/modified files in the workspace in a single call, rather than requiring per-file `zig_diagnostics` calls.

**Benefit**: Currently, checking diagnostics across a project requires N separate tool calls (one per file). A single aggregated call reduces round-trips and gives the AI a complete picture of the project's health. This is especially valuable after a refactor that may break multiple files.

**Productivity gain**: **High**. Reduces N tool calls to 1. In a typical refactoring session, the AI might need to check 5-20 files for breakage. This feature turns that from 5-20 round-trips into 1.

**Source**: Common pattern in LSP-based MCP servers; the "Everything" reference server demonstrates comprehensive result aggregation.

---

### 17. Workspace Symbol Search with Filtering

**What**: Enhance `zig_workspace_symbols` (if not already present) or add a new `zig_symbol_search` tool with richer filtering:
- Filter by symbol kind (function, struct, enum, const, etc.)
- Filter by module/file path pattern
- Return symbol documentation alongside names
- Support fuzzy matching

**Benefit**: Finding the right symbol in a large Zig codebase is a common task. Filtered search reduces noise — if you want all structs matching "Config", you don't need to sift through functions and constants too.

**Productivity gain**: **Medium**. Improves precision of codebase navigation. Most impactful in large projects with many similarly-named symbols.

**Source**: Enhancement of existing ZLS `workspace/symbol` capability.

---

### 18. Inline Code Actions with Preview

**What**: Enhance `zig_code_action` to not just list available actions but also preview what each action would do (the resulting diff) before applying it. Add a `zig_apply_code_action` tool that executes a chosen action.

**Benefit**: Currently `zig_code_action` returns titles and kinds but the AI must apply edits blindly. Preview lets the AI (and by extension the user) see the exact changes before committing, reducing risk of unwanted modifications.

**Productivity gain**: **Medium**. Safer refactoring workflow. Most impactful for automated fix-all workflows where multiple code actions are applied in sequence.

**Source**: Enhancement of existing ZLS `textDocument/codeAction` with `workspace/applyEdit` support.

---

### 19. Zig Dependency Graph Resource

**What**: Parse `build.zig.zon` and expose a dependency graph as a resource:
- `zig://dependencies` — list all declared dependencies with versions and sources
- `zig://dependency/{name}` — details for a specific dependency

**Benefit**: Dependency management is a growing pain point in the Zig ecosystem. Making the dependency graph visible to the AI enables questions like "what version of zlib are we using?" and "are there any outdated dependencies?" without manual `build.zig.zon` parsing.

**Productivity gain**: **Low-Medium**. Convenience feature. Zig projects tend to have few dependencies compared to npm/cargo ecosystems, so the absolute time savings are modest.

**Source**: [openSVM/zig-mcp-server](https://github.com/openSVM/zig-mcp-server) (`generate_build_zon`)

---

### 20. Elicitation (Interactive User Input)

**What**: Use `elicitation/create` to request information from the user during tool execution. For example:
- During `zig_rename`: ask the user to confirm the new name when the AI picks one
- During `zig_build` failure: ask the user which build target they want to try
- During ambiguous code actions: present multiple options for the user to choose from

**Benefit**: Currently, server-side operations are fire-and-forget — there's no way to ask the user for clarification mid-operation. Elicitation enables interactive workflows where the server can gather input at the point of need rather than requiring all parameters upfront.

**Productivity gain**: **Low-Medium**. Nice-to-have for edge cases. Most tool calls have unambiguous parameters. Main benefit is for rename and refactoring workflows where user confirmation adds safety.

**Spec reference**: [MCP Elicitation](https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation)

---

## Priority Matrix

| # | Feature | Productivity | Effort | Recommendation |
|---|---------|-------------|--------|----------------|
| 1 | Workspace Resources | High | Medium | **Do first** — unlocks resources capability |
| 4 | Prompts | High | Medium | **Do first** — high user visibility |
| 9 | Std Library Docs | High | Medium | **Do first** — fills critical knowledge gap |
| 16 | Multi-File Diagnostics | High | Low | **Do first** — low effort, high payoff |
| 7 | Request Cancellation | Medium-High | Low | **Do soon** — small change, big UX win |
| 14 | Tool Annotations | Medium | Low | **Do soon** — trivial to add, reduces friction |
| 5 | Structured Logging | Medium | Low-Medium | **Do soon** — aids debugging |
| 6 | Progress Notifications | Medium | Medium | **Do soon** — improves perceived speed |
| 15 | Sampling | High | High | **Explore** — powerful but complex, client support varies |
| 2 | Resource Subscriptions | Medium | Medium | **Later** — builds on #1 |
| 3 | Resource Templates | Medium | Medium | **Later** — builds on #1 |
| 12 | Completion/Autocomplete | Medium | Medium | **Later** — builds on #3, #4 |
| 10 | Build Analysis | Medium | Medium | **Later** — nice-to-have |
| 17 | Symbol Search Filtering | Medium | Low | **Later** — incremental improvement |
| 18 | Code Action Preview | Medium | Medium | **Later** — incremental improvement |
| 11 | Code Optimization | Medium | High | **Later** — complex, overlaps with AI advice |
| 8 | HTTP Transport | Medium | High | **Later** — only needed for remote workflows |
| 13 | Pagination | Low-Medium | Medium | **Later** — robustness improvement |
| 19 | Dependency Graph | Low-Medium | Low | **Later** — convenience feature |
| 20 | Elicitation | Low-Medium | Medium | **Later** — edge case improvement |
