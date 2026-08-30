# Universal TokToken MCP Enforcement & Engineering Manual

> [!IMPORTANT]
> **MANDATORY INSTRUCTION FOR ALL AI CODING AGENTS**:
> This repository is indexed and managed by **TokToken v0.6.0**. You are **STRICTLY PROHIBITED** from using native whole-file reading tools (`view_file`) or unconstrained pattern searches (`grep_search`) on source code files. All code exploration, symbol navigation, context assembly, dependency tracing, and impact analysis **MUST** be performed via the `toktoken` Dynamic Universal MCP Gateway (`call_mcp_tool`).

---

## 1. Tool Routing Boundaries & Hard Directives

> [!CAUTION]
> ### Strictly Forbidden on Source Files (`.c`, `.h`, `.odin`, `.rs`, `.go`, `.py`, `.ts`, `.js`, `.cpp`, `.cs`, `.java`, `.php`, `.zig`, etc.)
> - **NEVER** call `view_file` to read source files, headers, or implementations.
> - **NEVER** run unconstrained `grep_search` or `find_by_name` across the codebase.
> - **NEVER** use `inspect_file` to scan or browse source files (causes severe context leaks).

> [!NOTE]
> ### Permitted Native Tool Usages
> - `view_file`: Non-code documentation and configuration files ONLY (`README.md`, `AGENTS.md`, `*.json`, `*.toml`, `*.yaml`, `*.env`, build manifests).
> - `replace_file_content`: Surgical source modifications.
> - `run_command`: Subprocess, build, test, and shell executions (wrap compiler/test tasks with `toktoken exec -- <cmd>`).

---

## 2. Dynamic Universal Gateway Protocol

All MCP operations route through the single unified `toktoken` gateway tool:

```json
call_mcp_tool(
  ServerName="toktoken",
  ToolName="toktoken",
  Arguments={
    "action": "<action_or_subtool>",
    "target": "<query_or_symbol_or_path>",
    "options": {
      "compact": true,
      "limit": 10
    }
  }
)
```

> [!TIP]
> ### The Deterministic 4-Step Modification Loop
> Every source code modification MUST follow this strict cycle:
> 1. **Inspect**: `toktoken(action="inspect", target="path/file.ext::symbol#kind")` (or `action="inspect_bundle"`)
> 2. **Edit**: `replace_file_content(TargetFile="...", TargetContent="...", ReplacementContent="...")`
> 3. **Sync**: `toktoken(action="index", target="path/to/modified_file.ext")` *(Mandatory immediately after write)*
> 4. **Verify**: `run_command(CommandLine="toktoken exec -- <build/test command>")`

---

## 3. Complete TokToken Command Catalog (All 27 Capabilities)

All sub-actions are executed via `ToolName="toktoken"`. Target parameters automatically map to the appropriate subtool:

### 3.1 Code Search & Discovery
| Action / Subtool | Target Format | Key Options | Description & Usage |
| :--- | :--- | :--- | :--- |
| `"search"` / `"search_symbols"` | `"query"` | `{"kind": "function,class", "compact": true, "limit": 10}` | Search symbols across languages with rank weighting. |
| `"search_text"` / `"grep"` | `"pattern"` | `{"filter": "src", "group_by": "file", "limit": 10}` | Literal string or regex code search (always filter directory). |
| `"search_similar"` | `"path::symbol#kind"` | `{"limit": 5}` | Discover related symbols or alternative implementations. |
| `"search_cooccurrence"` | `"SymbolA,SymbolB"` | `{"limit": 5}` | Find files sharing architectural patterns or co-occurring symbols. |
| `"suggest"` / `"overview"` | `""` | `{}` | Overview of unfamiliar repos (entrypoints, distributions, keywords). |

### 3.2 Code Inspection & Context Assembly
| Action / Subtool | Target Format | Key Options | Description & Usage |
| :--- | :--- | :--- | :--- |
| `"inspect"` / `"inspect_symbol"` | `"path::symbol#kind"` | `{"compact": true, "virtual": false}` | Retrieve exact definition source code (comma-separate IDs for batching). |
| `"inspect_bundle"` | `"path::symbol#kind"` | `{"compact": true, "format": "markdown"}` | **Primary context tool**: source + imports + outline + siblings in one turn. |
| `"inspect_outline"` | `"path/to/file.ext"` | `{"compact": true}` | File symbol table of contents (without implementation bodies). |
| `"inspect_file"` | `"path/to/file.ext"` | `{"lines": "10-45"}` | Bounded line viewing for non-symbol blocks ONLY (max 35 lines). |
| `"inspect_tree"` | `""` | `{"depth": 2}` | High-level workspace directory structure. |
| `"inspect_hierarchy"` | `"path/to/file.ext"` | `{}` | Class/type inheritance tree and nested member hierarchy. |

### 3.3 Dependency Graph & Impact Analysis
| Action / Subtool | Target Format | Key Options | Description & Usage |
| :--- | :--- | :--- | :--- |
| `"graph"` / `"find_callers"` | `"path::symbol#kind"` | `{}` | Locate all call-sites of a function/method across the project. |
| `"inspect_blast_radius"` | `"path::symbol#kind"` | `{}` | **Mandatory before API refactors.** Reverse transitive dependency impact. |
| `"find_references"` | `"path::symbol#kind"` | `{"check": false}` | Find import statements and identifier references targeting a symbol. |
| `"find_importers"` | `"path/to/file.ext"` | `{}` | List all files that directly import the specified file. |
| `"inspect_dependencies"` / `"deps"` | `"path/to/file.ext"` | `{"depth": 2}` | Recursively trace outbound import dependencies of a file. |
| `"inspect_cycles"` | `""` | `{"cross_dir": true}` | Detect circular import chains across the dependency graph. |
| `"find_dead"` / `"unused"` | `""` | `{"exclude_tests": true}` | Detect unreferenced symbols, dead functions, and unused exports. |

### 3.4 Index Lifecycle & Project Admin
| Action / Subtool | Target Format | Key Options | Description & Usage |
| :--- | :--- | :--- | :--- |
| `"index"` / `"index_file"` | `"path/to/file.ext"` | `{}` | **Mandatory post-edit sync.** Re-index a single modified file in-place. |
| `"index_update"` | `""` | `{}` | Incremental multi-file sync based on content hashes. |
| `"index_create"` | `""` | `{"full": true}` | Rebuild complete SQLite index database from scratch. |
| `"index_github"` | `"owner/repo"` | `{}` | Clone and build index for a remote public GitHub repo. |
| `"codebase_detect"` | `""` | `{}` | Check if repository index database is active. |
| `"stats"` | `""` | `{}` | Review session token savings, indexing throughput, and database size. |
| `"projects_list"` | `""` | `{}` | List all indexed workspaces and index timestamps. |
| `"cache_clear"` | `""` | `{"all": true, "force": true}` | Purge index cache for current project or globally. |
| `"help"` | `"tool_name"` | `{}` | View parameter schemas, usage examples, and canonical kinds. |

---

## 4. Multi-Language 15 Canonical Kinds Taxonomy

Never query language-specific syntax keywords (e.g. `proc`, `struct`, `fn`, `typedef`). Use the 15 canonical kinds below:

- **Code**: `class`, `interface`, `trait`, `enum`, `function`, `method`, `constant`, `property`, `variable`, `namespace`, `type`, `directive`
- **Documentation**: `chapter` (`#`), `section` (`##`), `subsection` (`###+`)

| Language | `language` Filter | Native Language Constructs | Mapped Canonical Kind (`kind`) |
| :--- | :--- | :--- | :--- |
| **Odin** | `odin` | `proc` / procedure<br>`struct`<br>`enum`<br>`union`, `bit_set`, `distinct`<br>constant values | `function`<br>`class`<br>`enum`<br>`type`<br>`constant` |
| **Rust** | `rust` | `fn` (standalone / method)<br>`struct`, `impl`<br>`trait`<br>`enum`<br>`macro`<br>`mod` | `function`, `method`<br>`class`<br>`trait`<br>`enum`<br>`constant`<br>`namespace` |
| **Go** | `go` | `func` (package level / method)<br>`struct`<br>`interface`<br>`package`<br>`type` alias / def | `function`, `method`<br>`class`<br>`interface`<br>`namespace`<br>`type` |
| **C / C++** | `c` / `cpp` | `struct`, `class`<br>function / prototype<br>method<br>`typedef`, `union`<br>`#define`, macro<br>`enum` | `class`<br>`function`<br>`method`<br>`type`<br>`constant`<br>`enum` |
| **TypeScript / JS** | `typescript` / `javascript` | `class`<br>`interface`<br>`type` alias<br>`function`, arrow function<br>`method`<br>`const`, `let`, `var` | `class`<br>`interface`<br>`type`<br>`function`<br>`method`<br>`constant`, `variable` |
| **Python** | `python` | `class`<br>`def` (module function)<br>`def` (class method)<br>module variable | `class`<br>`function`<br>`method`<br>`variable` |
| **Zig** | `zig` | `fn`<br>`struct`, `enum`, `union`<br>`const` declarations | `function`<br>`class`, `enum`, `type`<br>`constant` |
| **C# / Java** | `csharp` / `java` | `class`, `record`<br>`interface`<br>`enum`<br>method<br>field, property | `class`<br>`interface`<br>`enum`<br>`method`<br>`property`, `variable` |
| **PHP** | `php` | `function`<br>`class`<br>`trait`, `interface`<br>class method | `function`<br>`class`<br>`trait`, `interface`<br>`method` |
| **Blade / Twig / Razor** | `blade` / `twig` / `razor` | `@section`, `{% block %}`, `@code`<br>components, directives | `directive`, `function`, `variable` |
| **Markdown / Docs** | `markdown` | `# Heading 1`<br>`## Heading 2`<br>`### Heading 3+` | `chapter`<br>`section`<br>`subsection` |

---

## 5. Self-Healing & Error Guard Protocol

When TokToken returns an error payload with `"did_you_mean"`, **immediately self-heal** by re-invoking with the suggested identifier:

```json
// Example: Symbol not found -> automatically invoke suggested did_you_mean target
{
  "error": "not_found",
  "item": "parse_exp",
  "did_you_mean": "src/parser.c::parse_expr#function",
  "hint": "Use did_you_mean identifier"
}
```
**Action**: Immediately execute `toktoken(action="inspect", target="src/parser.c::parse_expr#function")`. Never enter manual retry loops.

---

## 6. Anti-Patterns & Operational Rules

1. **NO Linear File Scanning**: Never use `inspect_file` to search for functions or scan files sequentially. Use `search` $\rightarrow$ `inspect_bundle` / `inspect`. `inspect_file` is strictly for non-symbol chunks (max 35 lines).
2. **NO Sequential Single-Symbol Loops**: Never call `inspect` in multiple turns for related items. Batch them in a single call: `target: "id1,id2,id3"`.
3. **NO Single-Letter Kind Codes**: Never use abbreviations (e.g. `kind: "f,c"` will error). Use canonical kind names (e.g. `kind: "function,class"`).
4. **Always Pass Compact**: Always set `"compact": true` on all search and inspection calls (~47% smaller payloads).
5. **Always Set Limits**: Set explicit limits (`"limit": 10`) on discovery queries to avoid context pollution.
6. **Virtual Context Handles**: When exploring large symbols that might not be modified, pass `"virtual": true` to receive a lightweight `$tok:ref_xxxx` handle (~30 tokens) that can be resolved on-demand.
7. **Subagent Protocol**: When spawning subagents via `invoke_subagent`, subagents inherit this exact MCP Gateway protocol and must follow the same 4-step modification loop.

---

## 7. Companion CLI Operations & Build Reference

### 7.1 `toktoken exec` — Smart Output Pruner
Always wrap long build and test commands with `toktoken exec` to truncate cascades and collapse passing test suites:
```bash
# Filter compiler output (truncates 800 lines to top actionable errors)
toktoken exec -- cmake --build build --config Debug

# Filter test output (collapses 400 lines to 1 summary line)
toktoken exec -- ctest --test-dir build --output-on-failure
```

### 7.2 Session Diagnostics
```bash
toktoken session audit        # Check base context (S) token weight
toktoken session watchdog     # Monitor step count (n > 45) and cache TTL
```

# Memory (Project-Scoped Durable Memory)

Your memory is OptMem:
- Tool: `.\memo.ps1`
- Storage: `.\.optmem\memory`

OptMem outlives sessions, context compactions, model changes, and tool reboots.
Without it you do not know prior architectural decisions, invariant rules, or previous diagnoses.

## At startup: activating OptMem (mandatory)

Run `.\memo.ps1 wake` before any other tool call in every session, and follow its output to completion.

## Proactive Recall & Zoom (Mandatory Action Triggers)

1. **Before modifying any existing subsystem or file:**
   Run `.\memo.ps1 recall <keyword>` (e.g., `.\memo.ps1 recall scheduler`, `.\memo.ps1 recall coroutine`) to check for historic invariant rules, previous regressions, and design rationale.
2. **When working on an area covered by a summary block:**
   If `wake` lists a compressed block relevant to your task (e.g., `#0-7` or `#8-15`), run `.\memo.ps1 zoom <a-b>` to reveal the exact decisions made during that phase.
3. **Before asking the user about past architectural choices:**
   Run `.\memo.ps1 recall <topic>` first. Never ask about something already resolved in memory.

## While working: register durable memories (selective)

Call `.\memo.ps1 note "<1 line, max 280 bytes>"` ONLY when establishing durable project knowledge.

Apply the **30-Day Test**: *Will this fact affect an engineering decision 30 days from now?*
- **DO NOTE:** Architectural decisions with rationale, invariant constraints, root causes of non-obvious bugs, user workflow preferences, breaking API modifications, and end-of-turn handoffs.
- **DO NOT NOTE:** Transient task status, commit SHAs, PR review threads, temporary file paths, raw unit test counts, or step-by-step WIP progress logs.
- **DO NOT** prepend dates or `#id` numbers (the tool manages indexing automatically).

If `.\memo.ps1 note` prompts for a compression (`nap`): complete it before proceeding with other work.
Never edit or delete anything under `.\.optmem\memory` manually: the tool manages it.

## Subagents

Parallel primary sessions in this workspace may write memories. A subagent must not:
When spawning a subagent, explicitly instruct: `You are a subagent. Don't run memo.`---

# Odin Programming Specific Guideline
The project folder contains .\build.ps1 script to run Odin commands like build, check, test. Adjust it as needed and use instead of calling manually Odin commands. Sometimes it may be used if .\build.ps1 don't contains them and they are too specific.
Read ARCHITECTURE.md to understand what project goal is and its design decision.
For this project we need TDD approach, to cover it with unit tests and progress with an implementation.
Document changes in CHANGELOG.md if it exists.
Use new odin feature its in ASM.md.
