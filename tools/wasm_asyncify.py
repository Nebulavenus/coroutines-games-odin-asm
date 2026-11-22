#!/usr/bin/env python3
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def find_binaryen_tool(name: str, wasm_opt_hint: str | None) -> Path:
    ext = ".exe" if os.name == "nt" else ""
    if wasm_opt_hint:
        hint_path = Path(wasm_opt_hint)
        candidate = hint_path if name == "wasm-opt" else hint_path.with_name(f"{name}{ext}")
        if candidate.exists():
            return candidate
    repo_root = Path(__file__).resolve().parent.parent
    local_bin = repo_root / "tools" / "binaryen" / "bin" / f"{name}{ext}"
    if local_bin.exists():
        return local_bin
    found = shutil.which(name)
    if found:
        return Path(found)
    raise FileNotFoundError(f"Binaryen tool '{name}' not found")


def find_stack_pointer_global(wat: str) -> str:
    preferred = re.search(r"\(global\s+(\$__stack_pointer)\s+\(mut\s+i32\)", wat)
    if preferred:
        return preferred.group(1)
    fallback = re.search(r"\(global\s+(\$[^\s]+)\s+\(mut\s+i32\)", wat)
    if fallback:
        return fallback.group(1)
    raise RuntimeError("Could not locate mutable i32 $__stack_pointer global in Wasm module")


def patch_coro_sp_wat(wat: str) -> tuple[str, int]:
    get_re = re.compile(
        r'^[ \t]*\(import\s+"coro_sp"\s+"get_sp"\s+\(func\s+(\$[^\s)]+)[^\r\n]*\r?\n?',
        re.MULTILINE,
    )
    set_re = re.compile(
        r'^[ \t]*\(import\s+"coro_sp"\s+"set_sp"\s+\(func\s+(\$[^\s)]+)[^\r\n]*\r?\n?',
        re.MULTILINE,
    )

    get_match = get_re.search(wat)
    set_match = set_re.search(wat)
    if not get_match and not set_match:
        return wat, 0

    sp_global = find_stack_pointer_global(wat)
    injected_funcs: list[str] = []
    patched = wat
    count = 0

    if get_match:
        get_name = get_match.group(1)
        patched = get_re.sub("", patched, count=1)
        injected_funcs.append(
            f" (func {get_name} (result i32)\n  (global.get {sp_global})\n )"
        )
        count += 1

    if set_match:
        set_name = set_match.group(1)
        patched = set_re.sub("", patched, count=1)
        injected_funcs.append(
            f" (func {set_name} (param $0 i32)\n  (global.set {sp_global}\n   (local.get $0)\n  )\n )"
        )
        count += 1

    close_matches = list(re.finditer(r"^\)\s*$", patched, re.MULTILINE))
    if not close_matches:
        raise RuntimeError("Malformed WAT output from wasm-dis")

    close_pos = close_matches[-1].start()
    insertion = "\n".join(injected_funcs) + "\n"
    patched = patched[:close_pos] + insertion + patched[close_pos:]
    return patched, count


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Patch coro_sp stack-pointer intrinsics and run Binaryen Asyncify."
    )
    parser.add_argument("input", help="Input .wasm file compiled by Odin")
    parser.add_argument("output", help="Output Asyncify-processed .wasm file")
    parser.add_argument("--wasm-opt", dest="wasm_opt", default=None, help="Optional path to wasm-opt")
    args = parser.parse_args()

    wasm_opt = find_binaryen_tool("wasm-opt", args.wasm_opt)
    wasm_dis = find_binaryen_tool("wasm-dis", args.wasm_opt)

    dis = subprocess.run(
        [str(wasm_dis), args.input],
        capture_output=True,
        text=True,
        check=False,
    )
    if dis.returncode != 0:
        sys.stderr.write(dis.stderr)
        return dis.returncode

    patched_wat, count = patch_coro_sp_wat(dis.stdout)
    if count == 0:
        opt = subprocess.run([str(wasm_opt), "--asyncify", args.input, "-o", args.output], check=False)
        return opt.returncode

    out_path = Path(args.output).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_wat_name = tempfile.mkstemp(prefix="coro_sp_", suffix=".wat", dir=str(out_path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write(patched_wat)
        opt = subprocess.run(
            [
                str(wasm_opt),
                "--enable-bulk-memory",
                "--enable-bulk-memory-opt",
                "--enable-nontrapping-float-to-int",
                "--enable-sign-ext",
                "--enable-mutable-globals",
                "--enable-multivalue",
                "--enable-simd",
                "--enable-reference-types",
                "--asyncify",
                tmp_wat_name,
                "-o",
                str(out_path),
            ],
            check=False,
        )
        return opt.returncode
    finally:
        try:
            os.remove(tmp_wat_name)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
