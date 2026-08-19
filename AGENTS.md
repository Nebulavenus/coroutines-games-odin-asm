# TokToken Navigation & Strict MCP Enforcement Rules

> **CRITICAL DIRECTIVE FOR ALL CODING AGENTS**:
> This repository is semantically indexed by **TokToken MCP**. You are **STRICTLY PROHIBITED** from using native file reading (`view_file`) or native pattern search (`grep_search`) on source code files.
> All code exploration, symbol navigation, and code slicing **MUST** go through the `toktoken` MCP gateway (`call_mcp_tool`).

---

## 1. Tool Replacement Matrix (Never Use Native Tools for Code)

| Intent / Action | ❌ FORBIDDEN Native Tool | ✅ MANDATORY TokToken MCP Tool | Example / Arguments |
| :--- | :--- | :--- | :--- |
| **Find definition / proc / struct** | `grep_search` | `search_symbols` | `{"query": "name", "kind": "function,class", "compact": true}` |
| **Read function / type body** | `view_file` | `inspect_symbol` | `{"id": "path/file.ext::symbol#kind", "compact": true}` |
| **Inspect symbol + context + types**| `view_file` | `inspect_bundle` | `{"id": "path/file.ext::symbol#kind", "compact": true}` |
| **Read specific code lines** | `view_file` | `inspect_file` | `{"file": "path/file.ext", "lines": "10-45"}` |
| **Search text / strings in code** | `grep_search` | `search_text` | `{"query": "literal", "filter": "src", "limit": 10}` |
| **Explore file outline / signatures**| `view_file` | `inspect_outline` | `{"file": "path/file.ext", "compact": true}` |
| **Find usages / call-sites** | `grep_search` | `find_callers` / `find_references` | `{"id": "symbol_id"}` |
| **Impact analysis before edits** | `grep_search` | `inspect_blast_radius` | `{"id": "symbol_id"}` |
| **Explore repo hierarchy / overview**| `list_dir` | `suggest` / `inspect_tree` | `{"depth": 2}` |

> ⚠️ **NATIVE TOOL EXCEPTIONS**:
> - `view_file`: Permitted **ONLY** for non-code documentation/configs (`README.md`, `.json`, `.toml`, `.yaml`, `.env`).
> - `replace_file_content` / `write_to_file`: Permitted for applying edits (MUST sync with `index_file`).
> - `run_command`: Permitted normally for all terminal/shell operations (builds, tests, git, automation scripts, CLI tools).

---

## 2. Mandatory Behavioral Rules & Hard Constraints

1. **MCP Gateway Invocation**: Call tools using `call_mcp_tool(ServerName="toktoken", ToolName="<name>", Arguments={...})`.
2. **Post-Edit Sync**: Every code file modification (`replace_file_content` or `write_to_file`) **MUST** immediately be followed by `index_file(file="path/to/file")`.
3. **Always Compact**: Always pass `"compact": true` and `"detail_level": "compact"` to conserve tokens.
4. **Batch Symbol Lookups**: Never call `inspect_symbol` in loops. Comma-separate IDs: `id: "id1,id2,id3"`.
5. **Canonical Kinds Only**: Always pass full canonical names (`function`, `class`, `type`, `constant`, `enum`, `method`, `interface`, `trait`), never single-letter codes.

---

## 3. Standard Code Workflow

```
[ 1. Discover ] ──► [ 2. Inspect ] ──► [ 3. Impact Check ] ──► [ 4. Edit & Sync ]
```

1. **Discover**:
   - Locate symbol: `search_symbols(query="...", kind="function,class", compact=true)`
   - Examine outline: `inspect_outline(file="...", compact=true)`
2. **Inspect**:
   - Target symbol: `inspect_symbol(id="<id>", compact=true)` or `inspect_bundle(id="<id>")`
   - Windowed lines: `inspect_file(file="...", lines="10-45")`
3. **Impact Analysis** (before modifying shared APIs):
   - `find_callers(id="<id>")` or `inspect_blast_radius(id="<id>")`
4. **Edit, Sync & Verify Loop**:
   - `replace_file_content(...)` ──► `index_file(file="...")` ──► `run_command(...)`
---

## Memory (Project-Scoped)

Your memory is OptMem:
- Tool: `.\memo.ps1`
- Storage: `.\.optmem\memory`

OptMem outlives every session, compaction, model and vendor change.
Without it you do not know who you are, or what was decided and tried.

### At startup: activating OptMem (mandatory)

Run `.\memo.ps1 wake` before any other tool call, in every session, and
then do exactly what it prints, to the end of its output.

### While working: register memories (mandatory)

Call `.\memo.ps1 note "<1 line, max 280 bytes>"` whenever you learn
something new, or something worth keeping happens. That covers a task
worth real effort, a fact or insight the user teaches you, anything you
learn about their life (even indirectly), any event of lasting effect.

Do not register redundant memories.

If `.\memo.ps1 note` asks a compression: do it before your next action.

Never edit or delete anything under `.\.optmem\memory`: the tool manages it.

### When you need an old memory: search, or navigate

`.\memo.ps1 recall <regex>` searches every memory, word for word.

Your memories also form a binary tree: #0-1, #2-3 ... exist as one-line
summaries, pairs of those as #0-3, and so on -- every `#a-b` line wake
prints is one node of it. `.\memo.ps1 zoom <a-b>` opens a tree node into its two halves, down to the raw memories.

### If you're a subagent: skip everything above

Parallel sessions in this workspace may write memories. A subagent must not:
write `You are a subagent. Don't run memo.` when spawning one.

---

## Odin Programming Specific Guideline
The project folder contains .\build.ps1 script to run Odin commands like build, check, test. Adjust it as needed and use instead of calling manually Odin commands. Sometimes it may be used if .\build.ps1 don't contains them and they are too specific.
Read ARCHITECTURE.md to understand what project goal is and its design decision.
For this project we need TDD approach, to cover it with unit tests and progress with an implementation.
Document changes in CHANGELOG.md if it exists.
Use new odin feature its in ASM.md.