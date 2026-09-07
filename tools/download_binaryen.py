#!/usr/bin/env python3
"""
Cross-Platform Binaryen Downloader & Installer
Supported Platforms:
  - Windows (x86_64)
  - Linux (x86_64, aarch64)
  - macOS (arm64 Apple Silicon, x86_64 Intel)
"""

import os
import sys
import platform
import shutil
import tempfile
import urllib.request
import tarfile
import subprocess

DEFAULT_VERSION = "version_132"

def get_platform_info():
    sys_name = platform.system().lower()
    machine = platform.machine().lower()

    # Determine OS
    if sys_name == "windows":
        os_target = "windows"
        exe_ext = ".exe"
    elif sys_name == "darwin":
        os_target = "macos"
        exe_ext = ""
    elif "linux" in sys_name:
        os_target = "linux"
        exe_ext = ""
    else:
        raise RuntimeError(f"Unsupported operating system: {platform.system()}")

    # Determine Architecture
    if machine in ("amd64", "x86_64"):
        arch_target = "x86_64"
    elif machine in ("arm64", "aarch64"):
        if os_target == "linux":
            arch_target = "aarch64"
        else:
            arch_target = "arm64"
    else:
        raise RuntimeError(f"Unsupported processor architecture: {platform.machine()}")

    return os_target, arch_target, exe_ext

def download_and_install(version=DEFAULT_VERSION, force=False):
    tools_dir = os.path.dirname(os.path.abspath(__file__))
    target_dir = os.path.join(tools_dir, "binaryen")
    bin_dir = os.path.join(target_dir, "bin")

    os_target, arch_target, exe_ext = get_platform_info()
    opt_binary = os.path.join(bin_dir, f"wasm-opt{exe_ext}")

    if not force and os.path.exists(opt_binary):
        print(f"[OK] wasm-opt already present at: {opt_binary}")
        try:
            res = subprocess.run([opt_binary, "--version"], capture_output=True, text=True, check=True)
            print(f"     Version: {res.stdout.strip()}")
            return opt_binary
        except Exception:
            print("[INFO] Existing binary failed verification. Re-downloading...")

    archive_name = f"binaryen-{version}-{arch_target}-{os_target}.tar.gz"
    url = f"https://github.com/WebAssembly/binaryen/releases/download/{version}/{archive_name}"

    print(f"[INFO] Target Platform: {os_target} ({arch_target})")
    print(f"[INFO] Downloading Binaryen {version} from:")
    print(f"       {url}")

    with tempfile.TemporaryDirectory() as tmp_dir:
        tar_path = os.path.join(tmp_dir, archive_name)

        def report_hook(block_num, block_size, total_size):
            if total_size > 0:
                percent = min(100.0, (block_num * block_size / total_size) * 100.0)
                downloaded_mb = (block_num * block_size) / (1024 * 1024)
                total_mb = total_size / (1024 * 1024)
                sys.stdout.write(f"\r[INFO] Progress: {percent:.1f}% ({downloaded_mb:.1f} MB / {total_mb:.1f} MB)")
                sys.stdout.flush()

        urllib.request.urlretrieve(url, tar_path, reporthook=report_hook)
        print("\n[INFO] Download complete. Extracting archive...")

        extract_dir = os.path.join(tmp_dir, "extracted")
        os.makedirs(extract_dir, exist_ok=True)

        with tarfile.open(tar_path, "r:gz") as tar:
            tar.extractall(path=extract_dir)

        # Locate extracted bin directory
        extracted_bin = None
        for root, dirs, files in os.walk(extract_dir):
            if os.path.basename(root) == "bin" and any(f.startswith("wasm-opt") for f in files):
                extracted_bin = root
                break

        if not extracted_bin:
            raise RuntimeError(f"Could not find bin directory in extracted archive {archive_name}")

        os.makedirs(bin_dir, exist_ok=True)

        # Copy all binaries
        for fname in os.listdir(extracted_bin):
            src_file = os.path.join(extracted_bin, fname)
            dst_file = os.path.join(bin_dir, fname)
            if os.path.isfile(src_file):
                shutil.copy2(src_file, dst_file)
                if exe_ext == "":
                    try:
                        os.chmod(dst_file, 0o755)
                    except OSError:
                        pass

    if not os.path.exists(opt_binary):
        raise RuntimeError(f"Installation failed: {opt_binary} not found after extraction.")

    # Mark executable on Unix
    if exe_ext == "":
        try:
            os.chmod(opt_binary, 0o755)
        except OSError:
            pass

    print(f"[OK] Binaryen installed successfully to: {bin_dir}")
    try:
        res = subprocess.run([opt_binary, "--version"], capture_output=True, text=True, check=True)
        print(f"     Verified: {res.stdout.strip()}")
    except Exception as e:
        print(f"[WARNING] Could not execute {opt_binary}: {e}")

    return opt_binary

if __name__ == "__main__":
    force_flag = "--force" in sys.argv or "-f" in sys.argv
    ver = DEFAULT_VERSION
    for arg in sys.argv[1:]:
        if arg.startswith("version_") or arg.startswith("v"):
            ver = arg
    download_and_install(version=ver, force=force_flag)
