# Feature Ideas for zig-mcp

> Research report compiled 2026-03-04, updated with client support research.
> Sources: [MCP Specification 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/),
> [Everything Server](https://mcpservers.org/servers/modelcontextprotocol/everything),
> [zig-wasm/zig-mcp](https://github.com/zig-wasm/zig-mcp),
> [openSVM/zig-mcp-server](https://github.com/openSVM/zig-mcp-server),
> [mcp.zig](https://muhammad-fiaz.github.io/mcp.zig/),
> [MCP Official Servers](https://github.com/modelcontextprotocol/servers),
> [VS Code Full MCP Spec](https://code.visualstudio.com/blogs/2025/06/12/full-mcp-spec-support),
> [Cursor MCP Docs](https://docs.cursor.com/context/model-context-protocol),
> [OpenAI Codex MCP](https://developers.openai.com/codex/mcp/),
> [Windsurf MCP Docs](https://docs.windsurf.com/windsurf/cascade/mcp),
> [Zed MCP Docs](https://zed.dev/docs/ai/mcp),
> [ZLS Source](https://github.com/zigtools/zls)

---

## Current State

zig-mcp v0.1.0 currently provides:
- **18 tools**: 13 LSP-backed code intelligence tools + 5 command execution tools
- **stdio transport** only (newline-delimited JSON-RPC)
- **3 protocol versions**: 2025-11-25, 2025-06-18, 2024-11-05
- **2 resources**: `zig://project-info` (versions + build.zig.zon) and `file:///{path}` workspace file template
- **5 prompts**: `review`, `explain`, `fix-diagnostics`, `optimize`, `test-scaffold`
- No sampling, no logging capability
- **Auto-reconnect** to ZLS (up to 5 restarts), lazy document loading, degraded mode
- **Security**: workspace-scoped paths, trusted binary policy, canonical path enforcement

---

## MCP Client Support Matrix

Which clients actually support each MCP feature (as of March 2026):

| Feature | VS Code/Copilot | Claude Code | Cursor | Windsurf | Codex CLI | Zed |
|---------|:-:|:-:|:-:|:-:|:-:|:-:|
| **Tools** | Yes | Yes | Yes | Yes | Yes | Yes |
| **Resources** | Yes | Yes | Yes | Yes | Broken¹ | No |
| **Prompts** | Yes | Yes | Yes | Yes | No² | Yes |
| **Tool Annotations** | Yes | ? | No | No | No | No |
| **Sampling** | Yes | No | No | No | No | No |
| **Elicitation** | Yes | No | Yes | No | No | No |
| **Logging** | Yes | ? | No | No | No | No |
| **Progress** | Yes³ | ? | No | No | No | No |
| **Cancellation** | Yes³ | ? | No | No | No | No |
| **Completion** | Yes | ? | No | No | No | No |
| **Subscriptions** | Yes | ? | Partial | No | No | No |
| **Pagination** | ? | ? | No | No | No | No |
| **Streamable HTTP** | Yes | Yes | ? | Yes | Yes | No |
| **stdio** | Yes | Yes | Yes | Yes | Yes | Yes |

¹ Codex calls `resources/list` during init and treats failure as server unavailability ([issue #8565](https://github.com/openai/codex/issues/8565)).
² Open feature request ([issue #8342](https://github.com/openai/codex/issues/8342)).
³ Part of VS Code's "full spec" claim; not independently verified.

**Key takeaway**: Only **tools** are universally supported. **Resources** and **prompts** have strong support (4/6 and 5/6 clients). Everything else is VS Code-only or unsupported. Prioritize features that work for the tools+resources+prompts tier.

---

## ZLS LSP Capabilities (Relevant to Feature Planning)

| LSP Feature | ZLS Support | Impact on Ideas |
|---|---|---|
| `textDocument/publishDiagnostics` (push) | Yes | #16 must aggregate from push notifications, not pull |
| `workspace/diagnostic` (pull) | **No** | #16 effort is **Medium**, not Low — must track open files |
| `textDocument/inlayHint` | Yes | New tool opportunity → #21 |
| `textDocument/semanticTokens` (full + range) | Yes | Evaluated but not recommended (see below) |
| `workspace/applyEdit` | Yes (server→client) | Enables #18 code action application |
| `$/cancelRequest` | **No** | #7 can only cancel child processes, not LSP requests |
| `textDocument/selectionRange` | Yes | Minor; not worth a dedicated tool |
| `textDocument/prepareCallHierarchy` | **No** | Rules out call hierarchy tool |

---

## Feature Ideas

### 1. Workspace Resources — DONE

**Implemented**: `zig://project-info` (Zig/ZLS versions + `build.zig.zon` contents) and `file:///{path}` resource template for reading any workspace file with path sandboxing.

**Deferred items**:
- `zig://diagnostics` — Requires a diagnostics cache in `LspClient` since ZLS only pushes diagnostics via `textDocument/publishDiagnostics` (no pull API). Better implemented as a tool (`zig_diagnostics_all`, see #16) than a resource, since diagnostics change constantly and resources are typically read once for context.
- `zig://build-graph` — Redundant with `zig://project-info` which already includes the full `build.zig.zon` contents. Not worth a separate resource.

**Spec reference**: [MCP Resources](https://modelcontextprotocol.io/specification/2025-11-25/server/resources)

---

### 2. Resource Subscriptions

**What**: Implement `resources/subscribe` so clients receive `notifications/resources/updated` when workspace files change on disk or when diagnostics change after a build.

**Benefit**: Enables real-time, reactive workflows. The AI assistant is notified when a file changes or new diagnostics appear, rather than polling. For example, after the user saves a file, the client could automatically re-check diagnostics without the user asking.

**Productivity gain**: **Medium**. Saves the "run diagnostics again" round-trip after edits. Most impactful in long coding sessions where diagnostics drift.

**Spec reference**: [Resource Subscriptions](https://modelcontextprotocol.io/specification/2025-11-25/server/resources#subscriptions)

---

### 3. Resource Templates — PARTIAL

**Implemented**: `file:///{path}` template shipped with #1.

**Remaining**: `zig://symbol/{name}` and `zig://diagnostics/{file}` templates depend on #16 (diagnostics cache) and would benefit from #12 (completion/autocomplete). Low standalone value — revisit when those prerequisites are built.

**Spec reference**: [Resource Templates](https://modelcontextprotocol.io/specification/2025-11-25/server/resources#resource-templates)

---

### 4. Prompts (Reusable Interaction Templates) — DONE

**Implemented**: 5 server-side prompt templates that clients invoke as slash commands:
- **`/review`** — Code review: reads file, returns structured review prompt (correctness, memory safety, error handling, idiomatic Zig)
- **`/explain`** — Explain code: reads file + optional ZLS hover at a position for symbol-specific context
- **`/fix-diagnostics`** — Auto-fix: runs `zig ast-check`, includes diagnostics + source in a fix prompt
- **`/optimize`** — Performance review: analyzes for comptime, SIMD, allocation, and cache optimization opportunities
- **`/test-scaffold`** — Test generation: uses ZLS document symbols to discover public API, builds test scaffolding prompt

LSP-dependent prompts (`explain`, `test-scaffold`) gracefully degrade to file-content-only when ZLS is unavailable.

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

**What**: Handle `notifications/cancelled` to abort in-progress tool calls. For command tools (`zig_build`, `zig_test`), terminate the child process. For LSP-backed tools, drop the pending response and free resources.

**Caveat**: ZLS does **not** handle `$/cancelRequest` — it silently ignores cancellation notifications. This means LSP requests (hover, references, completions) cannot be truly cancelled server-side; only the MCP response can be dropped. The primary value is for **command tools** where the child process can actually be killed.

**Benefit**: Currently, if a user triggers a long `zig_build` or `zig_test` and changes their mind, there's no way to stop it — they must wait for the timeout or the command to finish. Cancellation lets users abort command executions immediately.

**Productivity gain**: **Medium**. Useful mainly for long builds/tests. LSP requests are typically fast enough that cancellation doesn't matter. Downgraded from Medium-High since LSP forwarding isn't possible.

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

### 14. Tool Annotations (Read-Only, Destructive, Open-World Hints) — DONE

**Implemented**: All 18 tools now have `annotations` in their tool definitions:
- 13 read-only tools (`readOnlyHint: true, openWorldHint: false`): hover, definition, declaration, type_definition, references, completion, diagnostics, document_symbols, workspace_symbols, code_action, signature_help, check, version
- 2 local-write tools (`destructiveHint: false, openWorldHint: false`): format, rename
- 2 local-command tools (`destructiveHint: false, openWorldHint: false`): build, test
- 1 network tool (`destructiveHint: false, openWorldHint: true`): manage (may fetch from network)

Annotations are serialized in `tools/list` responses, omitting unset fields so clients fall back to MCP spec defaults.

**Spec reference**: [MCP Tool Annotations](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)

---

### 15. Sampling (Server-Initiated LLM Calls)

**What**: Use the `sampling/createMessage` capability to enable the server to invoke the client's LLM for intelligent operations:
- Automatic error explanation: when `zig_diagnostics` returns errors, the server could ask the LLM to explain them in plain English
- Suggested fixes: the server could ask the LLM to propose code fixes for common Zig errors
- Code generation: the server could orchestrate multi-step code generation with ZLS validation in the loop

**Benefit**: Enables agentic workflows where the server can leverage the LLM's reasoning without the user orchestrating every step. The server has deep knowledge of the Zig context (diagnostics, types, symbols) and can craft much better prompts than the user would manually.

**Productivity gain**: **High in theory, near-zero in practice**. Only VS Code/Copilot supports sampling. Claude Code, Codex, Cursor, Windsurf, and Zed do not. This feature would be invisible to the vast majority of users. Also creates confusing agency boundaries — the client already *is* the LLM orchestrator, so having the server also invoke the LLM leads to unclear ownership of reasoning.

**Spec reference**: [MCP Sampling](https://modelcontextprotocol.io/specification/2025-11-25/client/sampling)

---

### 16. Multi-File Diagnostics Aggregation Tool

**What**: Add a `zig_diagnostics_all` tool that returns diagnostics across all open/modified files in the workspace in a single call, rather than requiring per-file `zig_diagnostics` calls.

**Caveat**: ZLS does **not** support `workspace/diagnostic` (pull diagnostics). It only pushes diagnostics via `textDocument/publishDiagnostics`. Implementation requires zig-mcp to: (1) track which files have been opened in ZLS, (2) collect and cache diagnostics from push notifications, and (3) return the latest cached state on request. This makes the effort **Medium**, not Low — it requires a diagnostics cache and notification listener.

**Benefit**: Currently, checking diagnostics across a project requires N separate tool calls (one per file). A single aggregated call reduces round-trips and gives the AI a complete picture of the project's health. This is especially valuable after a refactor that may break multiple files.

**Productivity gain**: **High**. Reduces N tool calls to 1. In a typical refactoring session, the AI might need to check 5-20 files for breakage. This feature turns that from 5-20 round-trips into 1.

**Source**: Common pattern in LSP-based MCP servers. Requires `textDocument/publishDiagnostics` listener (push model).

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

### 21. Inlay Hints Tool

**What**: Add a `zig_inlay_hints` tool that exposes ZLS's `textDocument/inlayHint` results. Returns inferred type annotations, parameter name hints, and other inline information for a given file or range.

**Benefit**: Zig's type inference is powerful but can make code opaque — `const x = foo();` tells the AI nothing about what `x` is without hovering. Inlay hints provide this information in bulk for an entire file, giving the AI a richer understanding of types flowing through the code. This is more efficient than calling `zig_hover` on every variable individually.

**Productivity gain**: **Medium-High**. Particularly valuable for understanding generic/comptime-heavy code where types are rarely explicit. One `zig_inlay_hints` call on a file replaces potentially dozens of `zig_hover` calls. Directly backed by ZLS — no additional analysis engine needed.

**ZLS support**: `textDocument/inlayHint` is fully implemented.

---

### 22. Apply Code Action Tool

**What**: Add a `zig_apply_code_action` tool that executes a code action returned by `zig_code_action`, applying the resulting workspace edits. ZLS supports `workspace/applyEdit`, which zig-mcp can intercept to capture the edits and return them as diffs.

**Benefit**: Currently `zig_code_action` lists available fixes but provides no way to apply them. The AI must manually reproduce the fix, which is error-prone. This tool closes the loop: list actions → choose one → apply it. Enables automated fix-all workflows.

**Productivity gain**: **Medium-High**. The most common code action workflow is "remove unused variable" or "add discard" — operations that are tedious when done manually across many locations. Automating application saves significant time in refactoring sessions.

**ZLS support**: `workspace/applyEdit` is implemented (ZLS sends edit requests to the client). zig-mcp would need to act as the "client" that receives and records these edits.

---

## Evaluated but Not Recommended

### Semantic Tokens Tool

ZLS supports `textDocument/semanticTokens` (full + range), but this was evaluated and **not recommended** as an MCP tool. Semantic tokens provide syntax-level classification (keyword, function, type, variable, etc.) — information the AI can already infer from reading source code. The token data is encoded as delta arrays optimized for syntax highlighting, not human/AI consumption. Converting it to something useful would add complexity for marginal benefit. The same information is better obtained through `zig_hover` (for specific symbols) or `zig_inlay_hints` (for bulk type info).

### Call Hierarchy Tool

ZLS does **not** support `textDocument/prepareCallHierarchy`. This rules out a call hierarchy tool. The same information can be partially obtained through `zig_references` (finding all callers of a function).

---

## Priority Matrix

Revised with client support research and ZLS capability verification. Features are prioritized by: (1) how many clients can actually use them, (2) real productivity gain, (3) implementation effort accounting for ZLS limitations.

| # | Feature | Clients | Productivity | Effort | Recommendation |
|---|---------|---------|-------------|--------|----------------|
| 14 | Tool Annotations | 1-2/6 | Medium | **Very Low** | **Done** — all 18 tools annotated |
| 4 | Prompts | 5/6 | High | Medium | **Done** — 5 prompts: review, explain, fix-diagnostics, optimize, test-scaffold |
| 1 | Workspace Resources | 4/6 | High | Medium | **Done** — `zig://project-info` + `file:///{path}` template |
| 21 | Inlay Hints Tool | 6/6¹ | Medium-High | Low | **Do first** — tool, so universally supported; backed by ZLS |
| 22 | Apply Code Action | 6/6¹ | Medium-High | Medium | **Do soon** — completes code action workflow |
| 16 | Multi-File Diagnostics | 6/6¹ | High | Medium² | **Do soon** — high payoff but needs diagnostics cache |
| 7 | Request Cancellation | ?/6 | Medium | Low | **Do soon** — command-tool cancellation only (ZLS ignores `$/cancelRequest`) |
| 5 | Structured Logging | 1-2/6 | Medium | Low-Medium | **Do soon** — aids debugging, low client support but useful on stderr too |
| 6 | Progress Notifications | 1-2/6 | Medium | Medium | **Do soon** — improves perceived speed |
| 9 | Std Library Docs | 4-6/6³ | High | **High**⁴ | **Reassess** — high value but high effort; `zig_hover` already provides per-symbol docs |
| 3 | Resource Templates | 4/6 | Medium | Medium | **Partial** — `file:///{path}` shipped with #1; symbol/diagnostics templates later |
| 2 | Resource Subscriptions | 1-2/6 | Medium | Medium | **Later** — builds on #1, few clients support it |
| 12 | Completion/Autocomplete | 1-2/6 | Medium | Medium | **Later** — builds on #3, #4; VS Code only |
| 17 | Symbol Search Filtering | 6/6¹ | Medium | Low | **Later** — incremental improvement |
| 10 | Build Analysis | 6/6¹ | Medium | Medium | **Later** — nice-to-have |
| 18 | Code Action Preview | 6/6¹ | Medium | Medium | **Later** — partially superseded by #22 |
| 8 | HTTP Transport | 4/6 | Medium | High | **Later** — only needed for remote workflows |
| 20 | Elicitation | 2/6 | Low-Medium | Medium | **Later** — VS Code + Cursor only |
| 19 | Dependency Graph | 4/6 | Low-Medium | Low | **Later** — convenience feature |
| 13 | Pagination | ?/6 | Low-Medium | Medium | **Later** — robustness improvement |
| 11 | Code Optimization | 6/6¹ | Low | High | **Deprioritize** — overlaps with what the LLM already does |
| 15 | Sampling | 1/6 | Near-zero⁵ | High | **Deprioritize** — VS Code only, confusing agency model |

¹ Tool-based features work with all clients since all support tools.
² Upgraded from Low — ZLS lacks pull diagnostics; requires push notification cache.
³ Could be tools (6/6) or resources (4/6) depending on implementation.
⁴ Upgraded from Medium — requires HTML doc scraping/parsing, version matching, caching infrastructure. This is effectively a standalone subsystem.
⁵ Downgraded — only VS Code supports sampling; all other clients ignore this capability entirely.
