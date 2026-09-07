#!/usr/bin/env python3
"""
Odin Stackful Coroutine Engine — Single-File Amalgamation Tool

Unifies all modular library source files into a single standalone drop-in:
  dist/coroutine.odin

Usage:
  python tools/amalgamate.py [--verify] [--all-targets] [--output dist/coroutine.odin]
"""

import argparse
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

NATIVE_SOURCE_FILES = [
    "config.odin",
    "types.odin",
    "asm_amd64.odin",
    "asm_arm64.odin",
    "asm_riscv64.odin",
    "pool.odin",
    "scheduler.odin",
    "api.odin",
]

WASM_SOURCE_FILES = [
    "config.odin",
    "types.odin",
    "asm_wasm32.odin",
    "pool.odin",
    "scheduler.odin",
    "api.odin",
]

UNIFIED_IMPORTS = [
    'import "base:runtime"',
    'import "base:intrinsics"',
    'import "core:fmt"',
    'import "core:time"',
    'import "core:math"',
    'import "core:mem"',
    'import win32 "core:sys/windows"',
    'import "core:sys/posix"',
]

HEADER_TEMPLATE_NATIVE = """#+build !js
// ============================================================================
// Odin Stackful Coroutine Engine (coroutines_asm) — Amalgamated Multi-ISA Build
//
// Multi-ISA Cooperative Concurrency Runtime for Games and Systems in Odin.
// Supports AMD64 (Win64 & SysV), ARM64 (AAPCS64), and RISC-V 64 (LP64D).
// Zero heap allocations per frame, True ZII, OS kernel intrusive wait queues,
// CSP channels, multi-domain clocks, and structured concurrency scopes.
//
// Repository: https://github.com/Nebulavenus/coroutines-games-odin-asm
// Generated : {timestamp}
// License    : MIT
// ============================================================================

package coroutine

{imports}
"""

HEADER_TEMPLATE_WASM = """#+build wasm32
// ============================================================================
// Odin Stackful Coroutine Engine (coroutines_asm) — WebAssembly (js_wasm32) Build
//
// WebAssembly Asyncify Cooperative Concurrency Runtime for Games and Systems in Odin.
// Retains 100% API parity with native engine: wait, sync, race, CSP channels, clocks.
//
// Repository: https://github.com/Nebulavenus/coroutines-games-odin-asm
// Generated : {timestamp}
// License    : MIT
// ============================================================================

package coroutine

{imports}
"""

TARGETS_TO_VERIFY = [
    "windows_amd64",
    "linux_amd64",
    "darwin_arm64",
    "linux_arm64",
    "linux_riscv64",
    "js_wasm32",
]


def clean_file_content(content: str) -> str:
    """Strip 'package <name>', '#+build ...' and top-level 'import ...' declarations."""
    lines = content.splitlines()
    cleaned = []

    for line in lines:
        stripped = line.strip()
        # Skip build tags like #+build ...
        if stripped.startswith("#+build"):
            continue
        # Skip package declarations
        if re.match(r"^package\s+\w+", stripped):
            continue
        # Skip top-level import lines (single line imports)
        if re.match(r"^import\s+(\w+\s+)?\"[^\"]+\"", stripped):
            continue
        cleaned.append(line)

    result = "\n".join(cleaned).strip()
    return result


def build_amalgamation(root_dir: Path, source_files: list[str], header_template: str, output_path: Path) -> int:
    """Helper to assemble a set of source files into a target destination."""
    output_path.parent.mkdir(parents=True, exist_ok=True)

    header = header_template.format(
        timestamp=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        imports="\n".join(UNIFIED_IMPORTS),
    )

    sections = [header]
    total_lines = 0

    for filename in source_files:
        filepath = root_dir / filename
        if not filepath.exists():
            print(f"[ERROR] Required source file not found: {filepath}", file=sys.stderr)
            return 1

        with open(filepath, "r", encoding="utf-8") as f:
            raw_code = f.read()

        cleaned_code = clean_file_content(raw_code)
        file_lines = len(cleaned_code.splitlines())
        total_lines += file_lines

        banner = (
            f"\n// ============================================================================\n"
            f"// SECTION: {filename} ({file_lines} lines)\n"
            f"// ============================================================================\n"
        )
        sections.append(banner)
        sections.append(cleaned_code)

    final_content = "\n".join(sections) + "\n"

    with open(output_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(final_content)

    print(f"  + Generated {output_path.name} ({len(final_content.splitlines())} lines)")
    return 0


def amalgamate(root_dir: Path, target: Path) -> int:
    """Generate both native multi-ISA and wasm32 single-file builds in dist/."""
    dist_dir = target if target.is_dir() or target.suffix == "" else target.parent
    print(f"[amalgamate] Root directory: {root_dir}")
    print(f"[amalgamate] Target dist   : {dist_dir}")

    native_out = dist_dir / "coroutine.odin"
    wasm_out = dist_dir / "coroutine_wasm32.odin"

    ret = build_amalgamation(root_dir, NATIVE_SOURCE_FILES, HEADER_TEMPLATE_NATIVE, native_out)
    if ret != 0:
        return ret

    ret = build_amalgamation(root_dir, WASM_SOURCE_FILES, HEADER_TEMPLATE_WASM, w_out := wasm_out)
    if ret != 0:
        return ret

    print(f"[amalgamate] Successfully written: {native_out} & {wasm_out}")
    return 0


def verify_build(root_dir: Path, output_dir: Path, all_targets: bool = False) -> bool:
    """Verify that the amalgamated file compiles cleanly with Odin."""
    targets = TARGETS_TO_VERIFY if all_targets else [TARGETS_TO_VERIFY[0]]
    print(f"[amalgamate] Verifying {output_dir} with 'odin check -no-entry-point'...")

    all_passed = True
    for tgt in targets:
        print(f"  - Checking target '{tgt}'...", end="", flush=True)
        cmd = ["odin", "check", str(output_dir), "-no-entry-point", f"-target:{tgt}"]
        result = subprocess.run(cmd, cwd=str(root_dir), capture_output=True, text=True)
        if result.returncode != 0:
            print(" [FAIL]")
            print(f"[ERROR] Target {tgt} failed:\n{result.stderr}\n{result.stdout}", file=sys.stderr)
            all_passed = False
        else:
            print(" [PASS]")

    return all_passed


def main():
    parser = argparse.ArgumentParser(description="Amalgamate coroutine library into a single .odin file")
    parser.add_argument(
        "--output",
        "-o",
        type=str,
        default="dist/coroutine.odin",
        help="Path to output file (default: dist/coroutine.odin)",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Verify the generated file using 'odin check -no-entry-point'",
    )
    parser.add_argument(
        "--all-targets",
        action="store_true",
        help="Verify across all 5 supported target ISAs/OSes",
    )
    args = parser.parse_args()

    # Determine project root (directory containing this script is tools/)
    script_dir = Path(__file__).resolve().parent
    root_dir = script_dir.parent

    output_path = root_dir / args.output if not Path(args.output).is_absolute() else Path(args.output)

    ret = amalgamate(root_dir, output_path)
    if ret != 0:
        sys.exit(ret)

    if args.verify or args.all_targets:
        if not verify_build(root_dir, output_path.parent, all_targets=args.all_targets):
            sys.exit(1)


if __name__ == "__main__":
    main()
