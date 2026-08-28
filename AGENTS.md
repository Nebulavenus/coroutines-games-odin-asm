# Universal TokToken MCP Enforcement, Navigation & Engineering Directives

> **MANDATORY DIRECTIVE FOR ALL CODING AGENTS**:
> This repository is semantically indexed and managed by **TokToken MCP**. You are **STRICTLY PROHIBITED** from using native file reading tools (`view_file`) or unconstrained pattern searches (`grep_search`) on source code files. All code exploration, symbol navigation, context assembly, dependency tracing, and impact analysis **MUST** be performed via the `toktoken` MCP gateway (`call_mcp_tool`).

---

## 1. File Routing & Tool Prohibitions

Native tool usage on source files causes severe context dilution, token exhaustion, and lost reasoning fidelity. Follow these routing boundaries without exception:

### 🚫 Strictly Banned for `view_file` & Native `grep_search`
Never use native inspection tools on any indexed source language files:
* **Compiled / Systems**: `.c`, `.h`, `.cpp`, `.hpp`, `.cc`, `.cxx`, `.rs`, `.go`, `.odin`, `.zig`, `.d`, `.nim`
* **Managed / Enterprise**: `.cs`, `.java`, `.kt`, `.kts`, `.scala`, `.swift`
* **Scripting / Dynamic**: `.py`, `.rb`, `.php`, `.lua`, `.pl`, `.sh`, `.bash`, `.zsh`
* **Web / Frontend**: `.js`, `.jsx`, `.mjs`, `.ts`, `.tsx`, `.vue`, `.svelte`

### ✅ Permitted `view_file` Exceptions (Non-Code Documentation & Configs Only)
`view_file` is authorized **ONLY** for static text, project meta-documentation, and configuration manifests:
* `*.md`, `*.markdown`, `*.txt`, `*.rst`
* `*.json`, `*.toml`, `*.yaml`, `*.yml`, `*.ini`, `*.env*`
* Build scripts / CLI wrappers: `*.ps1`, `*.sh`, `Makefile`, `Justfile`, `CMakeLists.txt`

### ⚡ Universal Intent-to-Tool Dispatch Matrix

| Intent / Action | ❌ FORBIDDEN Native Tool | ✅ MANDATORY TokToken MCP Tool | Invocation Arguments |
| :--- | :--- | :--- | :--- |
| **Locate symbol / function / type** | `grep_search` | `search_symbols` | `{"query": "name", "kind": "function,class", "compact": true}` |
| **Inspect complete symbol + context** | `view_file` | `inspect_bundle` | `{"id": "path/file.ext::symbol#kind", "compact": true}` |
| **Read exact symbol source body** | `view_file` | `inspect_symbol` | `{"id": "path/file.ext::symbol#kind", "compact": true}` |
| **Search string literals / comments** | `grep_search` | `search_text` | `{"query": "literal", "filter": "src", "group_by": "file"}` |
| **Explore file outline / signatures** | `view_file` | `inspect_outline` | `{"file": "path/file.ext", "compact": true}` |
| **Read non-symbol bounded lines** | `view_file` | `inspect_file` | `{"file": "path/file.ext", "lines": "10-45"}` |
| **Find call-sites of function** | `grep_search` | `find_callers` | `{"id": "path/file.ext::symbol#kind"}` |
| **Trace import references** | `grep_search` | `find_references` | `{"id": "path/file.ext::symbol#kind"}` |
| **Trace file import dependencies** | `grep_search` | `inspect_dependencies` | `{"file": "path/file.ext", "depth": 2}` |
| **Impact analysis before editing** | `grep_search` | `inspect_blast_radius` | `{"id": "path/file.ext::symbol#kind"}` |
| **Explore workspace / project tree** | `list_dir` | `suggest` / `inspect_tree` | `{"depth": 2}` |
| **Re-index single file after edit** | *None* | `index_file` | `{"file": "path/file.ext"}` |

---

## 2. Complete 27-Tool TokToken MCP Catalog

All tools are executed via `call_mcp_tool(ServerName="toktoken", ToolName="", Arguments={})`. Always pass `"compact": true` to minimize token payload overhead.

### 2.1 Index Lifecycle & Workspace Management
* **`codebase_detect`**: Verify if a given directory is an indexed codebase.
  * *Arguments*: `{"path": "optional/project/path"}`
* **`index_create`**: Initialize and generate a full SQLite symbol index.
  * *Arguments*: `{"path": ".", "full": false, "include": ["vendor"], "languages": "c,cpp,odin,rust"}`
* **`index_update`**: Perform incremental re-indexing based on file content hashing.
  * *Arguments*: `{"path": "."}`
* **`index_file`**: **Mandatory post-edit sync.** Re-indexes a single modified file in-place immediately.
  * *Arguments*: `{"file": "src/core/engine.ext"}`
* **`index_github`**: Clone and build an index for any remote public GitHub repository without polluting local workspace.
  * *Arguments*: `{"repository": "owner/repo"}`
* **`projects_list`**: Enumerate all indexed projects, cache database paths, and index timestamps.
  * *Arguments*: `{}`
* **`cache_clear`**: Purge project index or entire global TokToken cache.
  * *Arguments*: `{"path": "..."}` or `{"all": true, "force": true}`

### 2.2 Semantic Code Discovery & Search
* **`suggest`**: Repository onboarding metadata (language distribution, symbol density, top entrypoints, key imports).
  * *Arguments*: `{}`
* **`search_symbols`**: FTS5 symbol lookup with centrality scoring, kind filtering, and ranking.
  * *Arguments*: `{"query": "init_session", "kind": "function,method", "limit": 10, "compact": true}`
* **`search_text`**: Fast ripgrep-backed literal/regex search with file grouping and context lines.
  * *Arguments*: `{"query": "TODO:", "group_by": "file", "filter": "src", "context": 2, "limit": 15}`
* **`search_similar`**: Discover symbols with structural, naming, or signature similarity to a target symbol ID.
  * *Arguments*: `{"id": "src/auth.py::TokenValidator#class", "limit": 5}`
* **`search_cooccurrence`**: Find files where two or more architectural concepts/symbols appear together.
  * *Arguments*: `{"query": "Mutex,ThreadPool", "limit": 10}`

### 2.3 Inspection, Slicing & Context Assembly
* **`inspect_bundle`**: **Primary context retrieval tool.** Returns definition source, import list, type dependencies, and local outline in one call.
  * *Arguments*: `{"id": "src/parser.rs::parse_expr#function", "format": "markdown", "compact": true}`
* **`inspect_symbol`**: Retrieve the exact source implementation of one or more symbols. Comma-separate IDs for batching.
  * *Arguments*: `{"id": "path/file.ext::symA#function,path/file.ext::symB#type", "compact": true}`
* **`inspect_outline`**: Retrieve hierarchical symbol table of a file without source code bodies.
  * *Arguments*: `{"file": "src/pipeline.cpp", "compact": true}`
* **`inspect_file`**: Windowed line-range viewing for non-symbol blocks (e.g. constant arrays, header directives).
  * *Arguments*: `{"file": "src/config.h", "lines": "25-60"}`
* **`inspect_tree`**: Render directory and file hierarchy up to a defined depth.
  * *Arguments*: `{"depth": 2, "compact": true}`
* **`inspect_hierarchy`**: Class/type inheritance tree and nested member relationships.
  * *Arguments*: `{"file": "src/models/user.ts"}`

### 2.4 Graph, Dependency & Impact Analysis
* **`find_callers`**: Identify all functions, methods, or symbols calling a target symbol ID.
  * *Arguments*: `{"id": "src/db.go::Connect#function"}`
* **`find_references`**: Identify all direct import statements and identifier references targeting a symbol.
  * *Arguments*: `{"id": "src/utils.py::format_date#function", "check": false}`
* **`find_importers`**: List all files across the project that directly import the specified file.
  * *Arguments*: `{"file": "src/types.h"}`
* **`inspect_dependencies`**: Recursively trace the entire outbound import graph of a file.
  * *Arguments*: `{"file": "src/main.rs", "depth": 3}`
* **`inspect_blast_radius`**: **Mandatory refactor check.** Transitive reverse dependency analysis showing all files/symbols affected by modifying target.
  * *Arguments*: `{"id": "src/api.ts::UserSchema#type"}`
* **`inspect_cycles`**: Detect circular import chains across the workspace dependency graph.
  * *Arguments*: `{}`
* **`find_dead`**: Identify unreferenced symbols, dead functions, and unused exports across the codebase.
  * *Arguments*: `{"exclude_tests": true}`

### 2.5 Metrics & Documentation
* **`stats`**: Retrieve session token savings, indexing throughput, and database size.
  * *Arguments*: `{}`
* **`help`**: Inspect schemas, parameter definitions, and CLI documentation for any TokToken tool.
  * *Arguments*: `{"command": "search_symbols"}`

---

## 3. Multi-Language AST to Canonical Kind Taxonomy

TokToken normalizes language-specific syntax into **15 canonical kinds**. Never query language-specific syntax terms (e.g., `proc`, `struct`, `fn`, `typedef`). Use the taxonomy below:

| Language | `language` Filter | Native Language Construct | Mapped Canonical Kind (`kind`) |
| :--- | :--- | :--- | :--- |
| **C / C++** | `c`, `cpp` | `struct`, `class``function`, prototypemethod`typedef`, `union``#define`, macro`enum` | `class``function``method``type``constant``enum` |
| **Rust** | `rust` | `fn` (standalone)`fn` (inside `impl`)`struct`, `enum``trait``type` alias`macro_rules!` | `function``method``class`, `enum``trait``type``constant` |
| **Go** | `go` | `func` (package level)`func` (receiver method)`struct``interface``type` alias / def | `function``method``class``interface``type` |
| **Python** | `python` | `def` (module function)`def` (class method)`class`module-level constant / variable | `function``method``class``constant`, `variable` |
| **TypeScript / JS**| `typescript`, `javascript` | `function`, arrow function`class``interface`, `type`class method / getter`const`, `let` | `function``class``interface`, `type``method``constant`, `variable` |
| **Odin** | `odin` | `proc` / procedure`struct``enum``union`, `bit_set`, `distinct`constant values | `function``class``enum``type``constant` |
| **Zig** | `zig` | `fn``struct`, `enum`, `union``const` declarations | `function``class`, `enum`, `type``constant` |
| **C# / Java** | `csharp`, `java` | `class`, `record``interface``enum`methodfield, property | `class``interface``enum``method``property`, `variable` |
| **PHP** | `php` | `function``class``trait`, `interface`class method | `function``class``trait`, `interface``method` |
| **Markdown / Docs**| `markdown` | `# Heading 1``## Heading 2``### Heading 3+` | `chapter``section``subsection` |

---

## 4. Standard Operational Protocols

### Protocol 1: Targeted Symbol Discovery (2 Steps)
```json
// Step 1: Discover the precise symbol identifier
call_mcp_tool(
  ServerName="toktoken",
  ToolName="search_symbols",
  Arguments={"query": "process_event", "kind": "function,method", "limit": 5, "compact": true}
)

// Step 2: Inspect full definition, dependencies, and enclosing context
call_mcp_tool(
  ServerName="toktoken",
  ToolName="inspect_bundle",
  Arguments={"id": "src/events/dispatcher.ext::process_event#function", "compact": true}
)

```

### Protocol 2: Safe Modification & Synchronization Loop (Strict 4-Step Cycle)

```
1. Inspect   ──► inspect_bundle(id="...") OR inspect_file(file="...", lines="START-END")
2. Modify    ──► replace_file_content(...) OR write_to_file(...)
3. Sync Index──► index_file(file="path/to/modified_file.ext")  <-- MANDATORY BEFORE PROCEEDING
4. Verify    ──► Execute project test/build command via task runner / shell

```

### Protocol 3: Refactoring & Blast Radius Analysis (Pre-Edit Check)

Before altering any exported function signature, struct field, or public API:

1. **Trace Callers**: `find_callers(id="path/file.ext::target_symbol#kind")`
2. **Compute Impact**: `inspect_blast_radius(id="path/file.ext::target_symbol#kind")`
3. **Batch Inspect Usages**: `inspect_symbol(id="site1#method,site2#function", compact=true)`
4. **Execute edits and sync each modified file with index_file**.

## 5. Strict Behavioral Rules & Anti-Patterns

1. **No Guesswork Inspection (inspect_file Abuse)**:
- Never use `inspect_file` to search for functions or scan files sequentially.
- Locate symbols with `search_symbols`, then retrieve definitions using `inspect_bundle` or `inspect_symbol`.
- Use `inspect_file` **only** when exact line boundaries are known for non-symbol blocks (e.g. data arrays, license headers).
2. **Mandatory Post-Edit Index Sync**:
- Every file write (`replace_file_content` / `write_to_file`) **MUST** immediately be followed by `index_file` on that file path. Stale indexes cause symbol lookup failures and corrupted line calculations.
3. **Batch Symbol Retrievals**:
- Never issue individual `inspect_symbol` calls in consecutive turns. Pass comma-separated IDs: `id: "id_1,id_2,id_3"`.
4. **Mandatory Compact Payloads**:
- Always set `"compact": true` on all search and inspection calls.
- Always set explicit limits (`"limit": 10`) on discovery queries to avoid context pollution.
5. **No Blind Full-File Dumps**:
- Never dump more than 60 lines of source code into the conversational context. Present surgical diffs and targeted excerpts.

## Memory (Project-Scoped Durable Memory)

Your memory is OptMem:
- Tool: `.\memo.ps1`
- Storage: `.\.optmem\memory`

OptMem outlives sessions, context compactions, model changes, and tool reboots.
Without it you do not know prior architectural decisions, invariant rules, or previous diagnoses.

### At startup: activating OptMem (mandatory)

Run `.\memo.ps1 wake` before any other tool call in every session, and follow its output to completion.

### Proactive Recall & Zoom (Mandatory Action Triggers)

1. **Before modifying any existing subsystem or file:**
   Run `.\memo.ps1 recall <keyword>` (e.g., `.\memo.ps1 recall scheduler`, `.\memo.ps1 recall coroutine`) to check for historic invariant rules, previous regressions, and design rationale.
2. **When working on an area covered by a summary block:**
   If `wake` lists a compressed block relevant to your task (e.g., `#0-7` or `#8-15`), run `.\memo.ps1 zoom <a-b>` to reveal the exact decisions made during that phase.
3. **Before asking the user about past architectural choices:**
   Run `.\memo.ps1 recall <topic>` first. Never ask about something already resolved in memory.

### While working: register durable memories (selective)

Call `.\memo.ps1 note "<1 line, max 280 bytes>"` ONLY when establishing durable project knowledge.

Apply the **30-Day Test**: *Will this fact affect an engineering decision 30 days from now?*
- **DO NOTE:** Architectural decisions with rationale, invariant constraints, root causes of non-obvious bugs, user workflow preferences, breaking API modifications, and end-of-turn handoffs.
- **DO NOT NOTE:** Transient task status, commit SHAs, PR review threads, temporary file paths, raw unit test counts, or step-by-step WIP progress logs.
- **DO NOT** prepend dates or `#id` numbers (the tool manages indexing automatically).

If `.\memo.ps1 note` prompts for a compression (`nap`): complete it before proceeding with other work.
Never edit or delete anything under `.\.optmem\memory` manually: the tool manages it.

### Subagents

Parallel primary sessions in this workspace may write memories. A subagent must not:
When spawning a subagent, explicitly instruct: `You are a subagent. Don't run memo.`---

## Odin Programming Specific Guideline
The project folder contains .\build.ps1 script to run Odin commands like build, check, test. Adjust it as needed and use instead of calling manually Odin commands. Sometimes it may be used if .\build.ps1 don't contains them and they are too specific.
Read ARCHITECTURE.md to understand what project goal is and its design decision.
For this project we need TDD approach, to cover it with unit tests and progress with an implementation.
Document changes in CHANGELOG.md if it exists.
Use new odin feature its in ASM.md.
