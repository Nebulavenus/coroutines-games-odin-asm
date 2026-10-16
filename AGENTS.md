# Agent Instructions

Each marked section is self-contained. Replace a complete BEGIN/END block
when updating that module; keep the other blocks intact.

<!-- BEGIN OPTMEM -->
## OptMem: Project memory

Tool: `.\memo.ps1`
Storage: `.\.optmem\memory\`

### Startup

For the primary agent, run `.\memo.ps1 wake` before other tool calls.
Follow its memory-maintenance instructions within the current task's
authorization and higher-priority instructions.

### Recording

Use `.\memo.ps1 note "<one line, max 280 bytes>"` for durable,
project-relevant information:

- Accepted decisions and constraints.
- Reproducible failures and their causes.
- Completed milestones and actual verification outcomes.
- Important discoveries likely to prevent repeated investigation.

Do not record routine tool output, duplicate notes, secrets, or unrelated
personal information.

Complete requested memory compression before continuing other work.
Never manually edit or delete files under `.\.optmem\memory\`.

### Retrieval

- `.\memo.ps1 recall <regex>` searches memories.
- `.\memo.ps1 zoom <a-b>` expands a summarized memory range.

Retrieve relevant details rather than repeatedly dumping all memory.

### Subagents

Subagents skip OptMem startup, writes, and compression only.
This exemption does not change any non-memory instructions.

When spawning a subagent, tell it:
"You are a subagent. Do not run memo. Follow all non-memory instructions."

The primary agent records durable findings from delegated work.
<!-- END OPTMEM -->

<!-- BEGIN ODINNAV -->
## odinnav: Odin navigation

Use odinnav to discover AND read Odin code. Prefer MCP tools.
If MCP is unavailable, use the CLI and consult its help for syntax.

Default workflow:

1. Discover the declaration with `search_code` or `outline_code`.
2. Copy its returned canonical ID verbatim into `read_code`; never guess an ID or file stem.
3. Use the returned numbered source as edit context; do not fetch it again with a direct file read.
4. After edits, refresh affected declaration locations before choosing another source range.

Missing MCP tools alone do not justify direct Odin reads: try `odinnav --help`
and the CLI first. Use ordinary file/text tools for non-Odin harnesses and docs.

At task start:

- Check `project_status` once at task start. For substantial sessions,
  request `project_status(include_stats=true)` at the start and end.
- Locate declarations with `search_code`. Keep queries to identifier names
  (e.g. `hover`, not syntax like `hover :: proc`). To inspect declarations across a file or package, omit `query` and pass `file` or `package` (e.g. `search_code(file="src/index/index.odin")` or `odinnav search --file src/index/index.odin`).
- Use `outline_code` when file/package structure is unclear. Pass `kind` (e.g. `kind="struct"` or `odinnav outline <path> --kind proc`) to isolate specific types/procs without dumping entire files.
- Inspect imports with `package_dependencies` (or `odinnav imports <path>`) rather than viewing file headers.
- Follow returned canonical IDs with `read_code`.

### Required reading workflow

When a symbol is known, use `read_code` before reading its file directly.

- Request `detail="signature"` for API inspection and lightweight header reads.
- `declaration` includes the declaration and its body; `full` also includes preceding documentation. Neither is a lightweight substitute for `signature`.
- Request `full` when understanding or modifying implementation, using a range for large procedures.
- For large procedures, use `start_line`/`end_line` (or `odinnav read <id> --range <start>:<end>`) to slice specific handlers or blocks without dumping full bodies.
- Batch small, related symbol reads within the output budgets below. Single `symbol_id` or array `symbol_ids` are both accepted.
- Use compact output by default; request verbose output only when
  omitted metadata is needed.
- After editing a file, line numbers for subsequent symbols in that file shift. Run a filtered `outline_code` for updated declaration bounds, or use `read_code(symbol_id, detail="signature")` for an updated header location, before choosing follow-up ranges.
- When inspecting or authoring unit tests, use `outline_code` or `search_code(package="tests")` to view test declarations and exact line locations instead of dumping raw test files.
- Reuse retrieved source until relevant code changes.

`read_code` returns source with exact 1-indexed line numbers (format:
`<line_num>: <line_text>`), matching `view_file`. Source returned by
`read_code` is valid, drop-in edit context for `replace_file_content`.
Do not fetch it again with `view_file` merely because the next action is an edit.

Do not routinely follow `search_code` with `view_file`, `Get-Content`,
`cat`, or another file-reading command.

### Output budgets and batching

Plan the combined output of the outer tool call, not just each nested request.
Compact formatting reduces metadata; it does not bound source length.

- Keep navigation results in a separate outer tool call from web output,
  document reads, diffs, builds, and tests. Parallelize independent work only
  when its results do not share that navigation output budget.
- Start discovery with `limit=20` and a file/package/kind filter where known.
  Inspect `has_more`; narrow the query or request the next page only when
  needed. Do not collect every declaration to locate one procedure.
- Before a full read of an unfamiliar declaration, inspect its returned
  bounds or request `detail="signature"`. Read a large procedure in focused
  ranges, initially targeting at most 120 source lines per outer call.
- Batch at most three small, related declarations by default, keeping their
  combined source within that initial line budget. Issue large or uncertain
  reads individually. Adjust these starting budgets for long lines or the
  client's actual output limit; they are not a guarantee against truncation.
- Print only matching tool names when checking availability. Retrieve the
  descriptions of selected tools separately; do not dump the whole catalog.
- If an outer response is truncated, treat omitted source and metadata as
  unread. Retry only the missing result in a separate call with a smaller
  range/page. Reuse intact results; do not repeat the entire batch or merely
  increase its output allowance. Confirm `found`, warnings, and pagination
  on the recovered result before editing or claiming complete coverage.

### Relationships and text

Use `find_references`, `callers`, or `callees` when changing shared
declarations, signatures, or behavior with external consumers.

Use `search_text` for literals, comments, directives, and other text.
When the target area is known, specify a file/package filter and a
small result limit. Narrow or paginate broad results before requesting
large output.

Tools are a menu, not a checklist. Make only calls that answer a
concrete question needed for the task.

### Dependencies and scope

Project roots are indexed automatically. External packages require
explicit `load_package`.

Before searching an external API:

1. Inspect `package_dependencies` if its import is unknown.
2. Load the relevant package.
3. Search within cached/import scope using an unqualified symbol name
   and an appropriate package filter.

Loading one package does not load its entire dependency graph.

References and call relationships cover the current index only.
An empty result does not prove that a symbol is unused everywhere.

### Result handling

- Use canonical symbol IDs for follow-up calls.
- A successful tool call or CLI exit code zero does not prove a symbol was found. Inspect read results' `found`, `ambiguous`, and `candidates`; use CLI `--json` when checking these programmatically.
- Resolve ambiguous matches explicitly; never silently pick the first.
- Treat candidate relationships as uncertain.
- Inspect parse, refresh, and persistence warnings.
- Check pagination before concluding that results are complete.
- After edits, refresh affected queries when previous results may be stale.
- If output is truncated, narrow the source range or filters, or paginate results, before retrying. Do not repeat the same oversized batch or switch to a whole-file dump.

Do not repeatedly issue the same unsuccessful query without changing
the name, scope, filter, or dependency state.

### Direct file access

Direct reads are allowed for:

- Non-Odin files, including configuration, documentation, and scripts.
- Surrounding package-level syntax (e.g. imports or constants) that
  `read_code` omits but the edit requires.
- Parse failures or demonstrably incomplete navigation results.
- odinnav being unavailable.

Before a fallback Odin read, briefly identify what information is missing.
Keep the read to the smallest useful range.

Do not dump entire Odin files or repeatedly reread overlapping ranges
when selected symbols answer the question.

If odinnav fails, continue with focused reads and `rg`; do not block
otherwise feasible work.

### Cache safety and verification

Never hand-edit odinnav cache files.

odinnav does not replace compiler checks, tests, or source review.

### Navigation statistics

For substantial MCP coding sessions, request
`project_status(include_stats=true)` at the start and end when supported.

Report differences only when useful. Label token counts as estimates
and savings as compact-versus-verbose response reduction—not total
task savings or avoided file-reading tokens.

Do not request statistics after every tool call.
<!-- END ODINNAV -->---

# Odin Programming Specific Guideline
The project folder contains `.\build.ps1` script to run Odin commands like build, check, test. Adjust it as needed and use instead of calling manually Odin commands. Sometimes it may be used if `.\build.ps1` doesn't contain them and they are too specific.
Read `docs/ARCHITECTURE.md` to understand what project goal is and its design decisions.
For this project we need TDD approach, to cover it with unit tests and progress with an implementation.
Document changes in `CHANGELOG.md` if it exists.
Use new odin feature, it's in `docs/ASM.md`.
When working on inline asm you can ignore `odinnav` navigation.
