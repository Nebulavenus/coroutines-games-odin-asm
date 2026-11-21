# Agent Instructions

Each marked section is self-contained. Replace a complete BEGIN/END block
when updating that module; keep the other blocks intact.

<!-- BEGIN ODINNAV -->
## odinnav: Odin navigation

Use odinnav to discover AND read Odin code. **Always prefer MCP first**:
if `odinnav` tools are lazy-loaded (not registered natively as `mcp_odinnav_*`),
read the schema files in `<appDataDir>\mcp\odinnav\*.json` and invoke them via
`call_mcp_tool(ServerName="odinnav", ToolName="...", Arguments={...})`.
Do NOT treat lazy MCP tools as missing—use the `odinnav` CLI (consult
`odinnav --help` for syntax) only if the `odinnav` MCP server / `call_mcp_tool`
is actually absent or failing.
All odinnav MCP and CLI outputs are plain text (no JSON mode).

Default workflow:

1. Discover declarations with `search_code` or `outline_code`.
2. Copy the returned canonical ID (or unambiguous `scope::name`) into `read_code`; never guess an ID or file stem.
3. Use the returned numbered source as edit context; do not fetch it again with a direct file read.
4. After edits, refresh affected declaration locations before choosing another source range.

Neither lazy MCP loading nor missing native `mcp_odinnav_*` tools justify
skipping MCP for CLI or direct reads: use `call_mcp_tool` with `odinnav` first,
then the `odinnav` CLI if needed. Use the escape hatches below when code is
non-Odin or unreachable via `odinnav`.

### MCP tools (6 plain-text tools)

- `project_status(include_stats=false)`: index health, files, packages, symbols, diagnostics; pass `include_stats=true` at the start and end of substantial sessions.
- `outline_code(path, kind?, exclude_tests?, offset?, limit?)`: package or file outline (default `limit=20`). Pass `kind` (e.g. `struct`, `proc`) to focus output, or `exclude_tests=true` to omit test files/`@(test)`. Auto-loads external `core:`/`vendor:`/`base:`/`shared:` packages (including `core:pkg/file.odin`) when targeted.
- `search_code(query?, package?, file?, kind?, os?, exclude_tests?, offset?, limit?)`: identifier/declaration search (default `limit=20`). Keep `query` to plain identifier names (use `package`/`file`/`kind`/`os` for filters); auto-loads external packages when specified via `package`/`file`.
- `read_code(symbol_id | symbol_ids, detail?, start_line?, end_line?)`: read numbered source by canonical ID, `scope::name`, or `.odin` file path (auto-loads external packages; up to 3 related declarations per call, initial budget ~120 source lines). Unranged `.odin` file paths return only the top-of-file header/imports; passing `start_line`/`end_line` slices lines directly. `detail`: `"signature"` | `"declaration"` | `"full"` (default `"declaration"`).
- `find_references(query, exclude_tests?, offset?, limit?)`: references to a symbol (default `limit=20`; auto-loads external `scope::name` targets).
- `call_graph(symbol_id, direction?, exclude_tests?, offset?, limit?)`: `"callers"` | `"callees"` | `"both"` (default `"both"`, default `limit=20`; auto-loads external `scope::name` targets).

### CLI commands

`odinnav` CLI subcommands mirror the MCP surface 1:1 (default `limit=20`):

- `odinnav status [--stats]`
- `odinnav outline <path> [--kind <k>] [--no-tests] [--offset <n>] [--limit <n>]`
- `odinnav search [query] [--pkg <p>] [--file <f>] [--kind <k>] [--os <t>] [--no-tests] [--offset <n>] [--limit <n>]`
- `odinnav read <sym...> [--detail signature|declaration|full] [--range <s:e>]`
- `odinnav refs <query> [--no-tests] [--offset <n>] [--limit <n>]`
- `odinnav calls <sym> [--dir callers|callees|both] [--no-tests] [--offset <n>] [--limit <n>]`
- `odinnav init` / `odinnav index` / `odinnav mcp`

### Required reading workflow

When a symbol is known, use `read_code` before reading its file directly.

- Request `detail="signature"` for API inspection and lightweight header reads.
- `declaration` includes the declaration and its body; `full` also includes preceding documentation. Neither is a lightweight substitute for `signature`.
- For large procedures, use `start_line`/`end_line` (or `odinnav read <id> --range <start>:<end>`) to slice specific handlers or blocks without dumping full bodies.
- Batch small, related symbol reads within ~120 lines per call.
- After editing a file, line numbers for subsequent symbols in that file shift. Run `outline_code` (with `kind` filter) or `read_code(symbol_id, detail="signature")` for updated bounds before choosing follow-up ranges.
- When inspecting or authoring unit tests, use `outline_code` or `search_code` scoped to the test file/package (e.g. `src/*/*_test.odin` or `tests` if dedicated) to inspect test declarations and exact bounds instead of dumping raw test files.
- Reuse retrieved source until relevant code changes; when needing context across multiple procedures during implementation/editing, batch `read_code` calls instead of chunk-reading `.odin` files with `read_file`.

`read_code` returns source with exact 1-indexed line numbers (`<line_num>: <line_text>`), matching `read_file`. Do not fetch it again with `read_file` merely because the next action is an edit.

### Output budgets and batching

- Keep navigation results in a separate outer tool call from web output, document reads, diffs, builds, and tests.
- When using the CLI fallback (`run_command`), avoid chaining multiple `outline` or large `read` commands in a single shell invocation (CLI stdout truncates around ~10 KB) and keep `outline` `--limit 20`.
- Pass `--range` / `start_line` / `end_line` only with a single symbol ID.
- Start discovery with `limit=20` and a `file`/`package`/`kind` filter where known. Inspect pagination metadata (`showing ... of ...`); narrow or advance `offset` only when needed.
- If a tool response is truncated, treat omitted output as unread and retry only the missing slice with a smaller range or `limit`.

### Dependencies and result handling

- External SDK/shared/vendor packages (`core:*`, `vendor:*`, `base:*`, `shared:*`) are auto-loaded on demand across `outline_code`, `search_code`, `read_code`, `find_references`, and `call_graph`.
- References and call graph edges cover the current index only; an empty result does not prove a symbol is unused everywhere.
- Check read output for not-found, ambiguous candidates, and stale warnings before editing. Resolve ambiguous matches explicitly using canonical IDs.
- Report call counts, output bytes, and durations from `project_status(include_stats=true)` only when useful.

### Escape hatches, direct file access, and cache safety

When `odinnav` cannot resolve or reach Odin code cleanly, use a two-step escape hatch:

1. **Try a bounded file slice via `odinnav` first**: If symbol lookup fails or a construct is anonymous/cross-declaration (e.g., `when` blocks, `#assert`, inline procs, local/dynamic call sites whose file is known), call `read_code("<file>.odin", start_line, end_line)` when the file is accessible in the index or SDK (or unranged for `package`/`#+build`/`import` headers).
2. **Fall back directly to `rg` and bounded `read_file(StartLine, EndLine)`** when any of these apply:
   - **Unavailable / incomplete / broken**: `odinnav` is unavailable, a file has parse errors in `project_status`, or symbol/range output is missing, truncated, or stale.
   - **Unindexed or excluded code**: Paths excluded by `.odin-nav/config.json`, unconfigured collections, `#load` assets, or newly added unindexed files.
   - **No-typechecking AST limits**: Dynamic calls (`cb()`, `vtable.fn()`), local-receiver selectors (`local.fn()` / `local->fn()`), `using` promotion, `proc` group overload selection, `when #config(...)` branches, inline `asm`, comments, directives/attributes, and string literals.
   - **External package internals**: `core:*` / `vendor:*` / `base:*` / `shared:*` bodies, internal references, and `callees` are not indexed.
   - **Non-Odin files**: Docs, configs, build scripts, C/shader/foreign headers.

Keep direct `rg` / `read_file` fallbacks scoped to the narrowest path and smallest useful line range (do not dump whole Odin files speculatively), and note why `odinnav` could not reach the code when relevant. Never hand-edit `.odin-nav/` cache files.
<!-- END ODINNAV -->

<!-- BEGIN PROJECT -->
## Project

### Architecture and conventions

Read `ARCHITECTURE.md` for relevant architecture and conventions.

### Additional info

Use new odin feature, it's in `docs/ASM.md`.
When working on inline asm you can ignore `odinnav` navigation.

### Editing

Use normal editing tools to modify source.

- Follow existing conventions and architecture.
- Preserve unrelated user changes.
- Make the smallest coherent change.
- Avoid speculative refactoring and unnecessary dependencies.

### Code style and git discipline

1. Never write any comments in the code.
   The human will review the code and write any comments themselves.
   If you change any code that invalidates an existing comment, then
   prefix the comment with
   `// TODO-UPDATE-COMMENT: Reason\n// ---`.

2. Write imperative, procedural code.

3. No backwards-compatibility shims, magic constants, hardcoded host
   values, or half-baked workarounds with sprawling edge-case handling.
   Fix root causes directly, keep one canonical form, and centralize shared
   limits/tunables as named constants or `Config` fields.

4. Never commit or push unless explicitly told to do so.

### Windows build and verification

Windows is the target. Do not introduce Linux or WSL work unless requested.

Use `.\build.ps1` for `build`, `run`, `test`, `check`, and `debug`.
Inspect script usage when needed; do not guess flags or bypass the script
with manual Odin commands.

Follow Boundary & Invariant Testing:

- Test public contracts and system invariants (CLI/MCP, package APIs,
  cache round-trips, failure resilience), not internal helpers. Never
  add test-only wrappers to production code.
- For new features or architecture upgrades: implement and stabilize the
  design first, then add/update focused invariant tests at the boundary.
- For bug fixes: write a minimal boundary repro test confirming the
  failure first when practical, fix it, and keep the test.
- Run `.\build.ps1 check` and `.\build.ps1 test`, verifying 0 leaks under
  Odin's tracking allocator.

Use stress tests when the change concerns concurrency, lifetimes, or
repeated operations.

Keep required tests passing. Report unrelated pre-existing failures
separately. Inspect the final diff and document notable changes in
`CHANGELOG.md`.

Never claim verification that was not actually performed.

### Completion

Summarize:

- What changed.
- What checks actually ran and their results.
- Any material limitations or unresolved issues.

Keep the response concise. Distinguish implemented changes, static
inspection, and successful runtime verification.
<!-- END PROJECT -->
