param (
    [Parameter(Mandatory=$false, Position=0)]
    [ValidateSet("amd64", "arm64", "riscv64", "test", "bench", "all")]
    [string]$Target = "test"
)

function Run-Linux-AMD64-Tests {
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host "  [Linux AMD64] Compiling & Executing Natively in WSL2      " -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    Remove-Item -Force -ErrorAction SilentlyContinue "build\test_runner_linux_amd64-*.o"
    New-Item -ItemType Directory -Force -Path "build" | Out-Null
    odin build examples/test_runner -target:linux_amd64 -build-mode:obj -out:build/test_runner_linux_amd64.o
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Linux AMD64 test compilation failed!" -ForegroundColor Red
        return
    }

    wsl bash -c "cd /mnt/e/OdinLang/Projects/coroutines_asm && gcc -no-pie build/test_runner_linux_amd64-*.o -o build/test_runner_linux_amd64.elf -lm -lpthread"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Linux AMD64 test linking failed!" -ForegroundColor Red
        return
    }

    wsl bash -c "cd /mnt/e/OdinLang/Projects/coroutines_asm && ./build/test_runner_linux_amd64.elf"
}

function Run-ARM64-Tests {
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host "  [ARM64] Cross-Compiling & Executing Unit Tests via QEMU   " -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    Remove-Item -Force -ErrorAction SilentlyContinue "build\test_runner_arm64-*.o"
    New-Item -ItemType Directory -Force -Path "build" | Out-Null
    odin build examples/test_runner -target:linux_arm64 -build-mode:obj -out:build/test_runner_arm64.o
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ARM64 test compilation failed!" -ForegroundColor Red
        return
    }

    wsl bash -c "cd /mnt/e/OdinLang/Projects/coroutines_asm && aarch64-linux-gnu-gcc -no-pie build/test_runner_arm64-*.o -o build/test_runner_arm64.elf -lm -lpthread"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ARM64 test linking failed!" -ForegroundColor Red
        return
    }

    wsl bash -c "cd /mnt/e/OdinLang/Projects/coroutines_asm && qemu-aarch64 -L /usr/aarch64-linux-gnu ./build/test_runner_arm64.elf"
}

function Run-RISCV64-Tests {
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host "  [RISC-V 64] Cross-Compiling & Executing Tests via QEMU     " -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    Remove-Item -Force -ErrorAction SilentlyContinue "build\test_runner_riscv64-*.o"
    New-Item -ItemType Directory -Force -Path "build" | Out-Null
    odin build examples/test_runner -target:linux_riscv64 -build-mode:obj -out:build/test_runner_riscv64.o
    if ($LASTEXITCODE -ne 0) {
        Write-Host "RISC-V 64 test compilation failed!" -ForegroundColor Red
        return
    }

    wsl bash -c "cd /mnt/e/OdinLang/Projects/coroutines_asm && riscv64-linux-gnu-gcc -no-pie build/test_runner_riscv64-*.o -o build/test_runner_riscv64.elf -lm -lpthread"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "RISC-V 64 test linking failed!" -ForegroundColor Red
        return
    }

    wsl bash -c "cd /mnt/e/OdinLang/Projects/coroutines_asm && qemu-riscv64 -L /usr/riscv64-linux-gnu ./build/test_runner_riscv64.elf"
}

function Run-Linux-AMD64-Bench {
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host "  [Linux AMD64] Compiling & Executing Bench Natively in WSL2" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    Remove-Item -Force -ErrorAction SilentlyContinue "build\bench_linux_amd64-*.o"
    New-Item -ItemType Directory -Force -Path "build" | Out-Null
    odin build examples/bench -target:linux_amd64 -build-mode:obj -out:build/bench_linux_amd64.o
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Linux AMD64 bench compilation failed!" -ForegroundColor Red
        return
    }

    wsl bash -c "cd /mnt/e/OdinLang/Projects/coroutines_asm && gcc -no-pie build/bench_linux_amd64-*.o -o build/bench_linux_amd64.elf -lm -lpthread"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Linux AMD64 bench linking failed!" -ForegroundColor Red
        return
    }

    wsl bash -c "cd /mnt/e/OdinLang/Projects/coroutines_asm && ./build/bench_linux_amd64.elf"
}

function Run-ARM64-Bench {
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host "  [ARM64] Cross-Compiling & Executing Benchmarks via QEMU   " -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    Remove-Item -Force -ErrorAction SilentlyContinue "build\bench_arm64-*.o"
    New-Item -ItemType Directory -Force -Path "build" | Out-Null
    odin build examples/bench -target:linux_arm64 -build-mode:obj -out:build/bench_arm64.o
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ARM64 bench compilation failed!" -ForegroundColor Red
        return
    }

    wsl bash -c "cd /mnt/e/OdinLang/Projects/coroutines_asm && aarch64-linux-gnu-gcc -no-pie build/bench_arm64-*.o -o build/bench_arm64.elf -lm -lpthread"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ARM64 bench linking failed!" -ForegroundColor Red
        return
    }

    wsl bash -c "cd /mnt/e/OdinLang/Projects/coroutines_asm && qemu-aarch64 -L /usr/aarch64-linux-gnu ./build/bench_arm64.elf"
}

function Run-RISCV64-Bench {
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host "  [RISC-V 64] Cross-Compiling & Executing Bench via QEMU    " -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    Remove-Item -Force -ErrorAction SilentlyContinue "build\bench_riscv64-*.o"
    New-Item -ItemType Directory -Force -Path "build" | Out-Null
    odin build examples/bench -target:linux_riscv64 -build-mode:obj -out:build/bench_riscv64.o
    if ($LASTEXITCODE -ne 0) {
        Write-Host "RISC-V 64 bench compilation failed!" -ForegroundColor Red
        return
    }

    wsl bash -c "cd /mnt/e/OdinLang/Projects/coroutines_asm && riscv64-linux-gnu-gcc -no-pie build/bench_riscv64-*.o -o build/bench_riscv64.elf -lm -lpthread"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "RISC-V 64 bench linking failed!" -ForegroundColor Red
        return
    }

    wsl bash -c "cd /mnt/e/OdinLang/Projects/coroutines_asm && qemu-riscv64 -L /usr/riscv64-linux-gnu ./build/bench_riscv64.elf"
}

switch ($Target) {
    "amd64"   { Run-Linux-AMD64-Tests }
    "arm64"   { Run-ARM64-Tests }
    "riscv64" { Run-RISCV64-Tests }
    "test"    { Run-Linux-AMD64-Tests; Run-ARM64-Tests; Run-RISCV64-Tests }
    "bench"   { Run-Linux-AMD64-Bench; Run-ARM64-Bench; Run-RISCV64-Bench }
    "all"     { Run-Linux-AMD64-Tests; Run-ARM64-Tests; Run-RISCV64-Tests; Run-Linux-AMD64-Bench; Run-ARM64-Bench; Run-RISCV64-Bench }
}
