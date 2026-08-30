# Universal TokToken MCP Enforcement & Engineering Manual

> [!IMPORTANT]
> **CRITICAL RUNTIME DIRECTIVE & CONTEXT TAX LAW**:
> Language models are stateless; every step re-transmits the entire session history ($T \approx n \cdot S + \frac{g \cdot n^2}{2}$). Every token ingested at step $k$ incurs a cumulative cost across all remaining turns $n - k$.
> 
> This repository is indexed and managed by **TokToken v0.6.0**. You are **STRICTLY PROHIBITED** from using native whole-file reading tools (`view_file`), unbounded line inspection (`inspect_file`), or unconstrained pattern searches (`grep_search`) on source code files. All code exploration, symbol navigation, context assembly, dependency tracing, and impact analysis **MUST** be performed via the `toktoken` Dynamic Universal MCP Gateway (`call_mcp_tool`).

---

## 1. Tool Routing & Inspection Boundaries

### 🚫 Strictly Banned on Source Code Files
Never use linear file inspection (`inspect_file`, `view_file`) or raw text scanning (`grep_search`, `find_by_name`) on indexed source files:
* **Compiled / Systems**: `.odin`, `.c`, `.h`, `.cpp`, `.hpp`, `.rs`, `.go`, `.zig`
* **Managed / Enterprise**: `.cs`, `.java`, `.kt`, `.swift`
* **Scripting / Web**: `.py`, `.ts`, `.tsx`, `.js`, `.jsx`, `.rb`, `.php`, `.sh`

### ✅ Permitted Native & File Inspection Exceptions (Non-Code Manifests Only)
`inspect_file` / `view_file` is authorized **ONLY** for non-symbol configuration manifests, documentation, and data tables:
* Documentation & Notes: `*.md`, `*.txt`, `*.rst`
* Configurations: `*.toml`, `*.json`, `*.yaml`, `*.yml`, `*.ini`, `.env*`
* Build Manifests: `CMakeLists.txt`, `Makefile`, `Justfile`
* **Hard Window Ceiling**: Never request more than **35 lines** per `inspect_file` call. Linear reading of entire files is prohibited.

### ✅ Permitted Native Operations
* `replace_file_content`: Surgical, atomic source modifications.
* `run_command`: Subprocess, build, test, and shell executions (wrapped with `toktoken exec -- <cmd>` or quiet flags).

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

---

## 3. Mandatory AST Retrieval Protocols (The 2-Turn Resolution Law)

Every code exploration task MUST follow a deterministic 2-turn cycle: **Discovery**, followed by **Context Retrieval**.

```
   [TURN 1: DISCOVER]                   [TURN 2: RETRIEVE]
   • search_symbols(query="...")   ──►  • inspect_bundle(target="...")
   • inspect_outline(target="...") ──►  • inspect_symbol(target="id1,id2,id3")
```

### Turn 1: Symbol Identification (Zero Code Bodies)
Locate exact symbol identifiers without pulling source code implementations into context:
1. **Find symbol by identifier/name**:
   `toktoken(action="search_symbols", target="target_name", options={"kind": "function,class", "limit": 5, "compact": true})`
2. **Explore a module's public interface / structure**:
   `toktoken(action="inspect_outline", target="src/module.odin", options={"compact": true})`
3. **Find string literals, constants, or log messages**:
   `toktoken(action="search_text", target="ERROR_BUFFER_FULL", options={"filter": "src", "group_by": "file", "limit": 5})`

### Turn 2: Exact Context Retrieval (Single Turn)
Once the canonical symbol ID (`path/file.ext::symbol_name#kind`) is identified, retrieve the exact definition:
1. **Primary Symbol Inspection (Bundle)**:
   `toktoken(action="inspect_bundle", target="src/engine.odin::init_engine#function", options={"compact": true})`
   *(Retrieves definition source, parameters, outbound imports, and immediate module outline in 1 step).*
2. **Batched Symbol Retrieval**:
   `toktoken(action="inspect_symbol", target="src/a.odin::symA#function,src/b.odin::symB#class", options={"compact": true})`

---

## 4. Mandatory Batching & Single-Turn Multi-Symbol Rules

Never emit sequential symbol requests across consecutive conversational turns.
* **Forbidden**: Turn 1 (`inspect_symbol(A)`) $\rightarrow$ Turn 2 (`inspect_symbol(B)`) $\rightarrow$ Turn 3 (`inspect_symbol(C)`).
* **Mandatory**: Pass comma-separated symbol IDs in a single turn:
  `toktoken(action="inspect_symbol", target="src/net.odin::listen#function,src/net.odin::accept#function,src/net.odin::Socket#class", options={"compact": true})`

---

## 5. Terminal & Shell Command Execution Hygiene (`run_command`)

Shell command output is the largest single source of unpruned context bloat. All terminal commands MUST adhere to strict output suppression:

1. **Quiet Flags on Builds & Compilers**:
   * Odin: `odin test src/ -quiet` or `odin build src/ -error-pos-style:unix`
   * C/C++ / CMake: `toktoken exec -- cmake --build build --config Debug` or `ctest --test-dir build --output-on-failure`
   * Rust / Cargo: `cargo test --quiet` or `cargo check --quiet`
   * Go: `go test -short ./...`
   * Python: `pytest -q --tb=short`
2. **Output Truncation & Filtering**:
   * Never execute unconstrained commands (`git log`, `find`, `cat`, raw test logs).
   * Pipe multi-line outputs through filters: `git status -s`, `git diff --stat`, or pipe through `head -n 25`.
3. **Compiler Error Handling**:
   * If a build fails with multiple errors, focus **only on the first 2 actionable compiler errors**. Do not inspect or re-print subsequent cascade errors.

---

## 6. Session Turn Budget & The 50-Step Circuit Breaker

The cumulative context cost scales quadratically ($T \approx n \cdot S + \frac{g \cdot n^2}{2}$). Extended threads (>50 turns) waste millions of tokens on repetitive prompt cache reads:

1. **Step Budget Awareness**: Maintain internal awareness of session turn depth. Keep single task executions under **40 to 50 turns**.
2. **Checkpoint & Reset Trigger**: If turn count crosses **50 turns**, or when completing a distinct sub-feature:
   * Write pending tasks, decisions, and current architectural state to a persistent markdown file (`PLAN.md` or `REPORTS.md`).
   * Explicitly notify the user:
     > *"Sub-feature complete. To prevent quadratic context degradation and prompt cache tax, please start a fresh session to continue."*

---

## 7. Zero-Loop Error Recovery Directives

Failed tool calls remain in conversational history and are re-transmitted on every subsequent turn.
1. **No Blind Retries**: If a symbol ID lookup returns `not_found`, do NOT guess line numbers or call `inspect_file` on the source file.
2. **Fuzzy Discovery Fallback (Max 1 Turn)**:
   * If TokToken returns a `"did_you_mean"` field, immediately re-invoke using the suggested canonical ID.
   * Otherwise, issue a single wildcard query: `toktoken(action="search_symbols", target="fuzzy_prefix*", options={"compact": true, "limit": 5})`
   * If the symbol is still not found, check `toktoken(action="inspect_outline", target="path/to/file.ext", options={"compact": true})`.
3. **Fail Fast**: If a tool fails twice consecutively, STOP and ask the user for clarification rather than consuming turns in trial-and-error loops.

---

## 8. Atomic Modification & Synchronization Cycle

Every source code modification MUST follow the strict 4-step cycle:
1. **Inspect AST**: `toktoken(action="inspect_bundle", target="path/file.ext::symbol#kind", options={"compact": true})`
2. **Check Blast Radius**: `toktoken(action="inspect_blast_radius", target="path/file.ext::symbol#kind")` *(Mandatory for public/exported APIs)*
3. **Atomic Edit**: `replace_file_content(TargetFile="...", TargetContent="...", ReplacementContent="...")`
4. **Sync Index**: `toktoken(action="index_file", target="path/to/modified_file.ext")` *(Mandatory immediately after write)*
5. **Verify**: `run_command(CommandLine="toktoken exec -- <build/test command>")`

---

## 9. Complete TokToken Command Catalog (All 27 Capabilities)

All sub-actions are executed via `ToolName="toktoken"`. Target parameters automatically map to the appropriate subtool:

### 9.1 Code Search & Discovery
| Action / Subtool | Target Format | Key Options | Description & Usage |
| :--- | :--- | :--- | :--- |
| `"search"` / `"search_symbols"` | `"query"` | `{"kind": "function,tats
lass", "compact": true, "limit": 10}` | Search symbols across languages with rank weighting. |
| `"search_text"` / `"grep"` | `"pattern"` | `{"filter": "src", "group_by": "file", "limit": 10}` | Literal string or regex code search (always filter directory). |
| `"search_similar"` | `"path::symbol#kind"` | `{"limit": 5}` | Discover related symbols or alternative implementations. |
| `"search_cooccurrence"` | `"SymbolA,SymbolB"` | `{"limit": 5}` | Find files sharing architectural patterns or co-occurring symbols. |
| `"suggest"` / `"overview"` | `""` | `{}` | Overview of unfamiliar repos (entrypoints, distributions, keywords). |

### 9.2 Code Inspection & Context Assembly
| Action / Subtool | Target Format | Key Options | Description & Usage |
| :--- | :--- | :--- | :--- |
| `"inspect"` / `"inspect_symbol"` | `"path::symbol#kind"` | `{"compact": true, "virtual": false}` | Retrieve exact definition source code (comma-separate IDs for batching). |
| `"inspect_bundle"` | `"path::symbol#kind"` | `{"compact": true, "format": "markdown"}` | **Primary context tool**: source + imports + outline + siblings in one turn. |
| `"inspect_outline"` | `"path/to/file.ext"` | `{"compact": true}` | File symbol table of contents (without implementation bodies). |
| `"inspect_file"` | `"path/to/file.ext"` | `{"lines": "10-45"}` | Bounded line viewing for non-symbol blocks ONLY (max 35 lines). |
| `"inspect_tree"` | `""` | `{"depth": 2}` | High-level workspace directory structure. |
| `"inspect_hierarchy"` | `"path/to/file.ext"` | `{}` | Class/type inheritance tree and nested member hierarchy. |

### 9.3 Dependency Graph & Impact Analysis
| Action / Subtool | Target Format | Key Options | Description & Usage |
| :--- | :--- | :--- | :--- |
| `"graph"` / `"find_callers"` | `"path::symbol#kind"` | `{}` | Locate all call-sites of a function/method across the project. |
| `"inspect_blast_radius"` | `"path::symbol#kind"` | `{}` | **Mandatory before API refactors.** Reverse transitive dependency impact. |
| `"find_references"` | `"path::symbol#kind"` | `{"check": false}` | Find import statements and identifier references targeting a symbol. |
| `"find_importers"` | `"path/to/file.ext"` | `{}` | List all files that directly import the specified file. |
| `"inspect_dependencies"` / `"deps"` | `"path/to/file.ext"` | `{"depth": 2}` | Recursively trace outbound import dependencies of a file. |
| `"inspect_cycles"` | `""` | `{"cross_dir": true}` | Detect circular import chains across the dependency graph. |
| `"find_dead"` / `"unused"` | `""` | `{"exclude_tests": true}` | Detect unreferenced symbols, dead functions, and unused exports. |

### 9.4 Index Lifecycle & Project Admin
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

## 10. Multi-Language 15 Canonical Kinds Taxonomy

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
