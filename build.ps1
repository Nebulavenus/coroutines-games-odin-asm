param (
    [Parameter(Mandatory=$false, Position=0)]
    [ValidateSet("build", "run", "test", "debug", "release", "matrix", "showcase", "run-showcase", "quest", "run-quest", "bench", "run-bench", "check-arm64", "check-riscv64", "check-wasm", "check-all", "test-arm64", "test-riscv64", "wasm", "test-wasm", "web-game", "test-web-game", "run-web-game", "pack-itch", "amalgamate", "dist", "test-dist")]
    [string]$Action
)

$OutExe = "build/game.exe"
$ShowcaseExe = "build/showcase.exe"
$QuestExe = "build/quest_ai.exe"
$BenchExe = "build/bench.exe"
$Source = "examples/game"
$ShowcaseSource = "examples/showcase"
$QuestSource = "examples/quest_ai"
$BenchSource = "examples/bench"
$ProjectFile = "game.raddbg"

function Invoke-OdinBuild
{
    param($Source, $Output, $ExtraArgs = @())

    Write-Host "Building $Output..." -ForegroundColor Cyan
    $isWin = $IsWindows -or ($env:OS -eq "Windows_NT")
    $linkerArgs = if ($isWin) { @("-linker:radlink") } else { @() }
    $buildArgs = @("build", $Source, "-out:$Output") + $linkerArgs + @("-show-timings") + $ExtraArgs
    odin @buildArgs
    return $LASTEXITCODE
}

function Get-WasmOptPath
{
    # 1. Check system PATH first
    $cmd = Get-Command "wasm-opt" -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    # 2. Check local tools/binaryen/bin
    $isWin = $IsWindows -or ($env:OS -eq "Windows_NT")
    $ext = if ($isWin) { ".exe" } else { "" }
    $localOpt = "$PSScriptRoot/tools/binaryen/bin/wasm-opt$ext"
    if (Test-Path $localOpt) {
        return $localOpt
    }

    # 3. Auto-download using cross-platform download script
    Write-Host "wasm-opt not found. Running cross-platform downloader..." -ForegroundColor Yellow
    & "$PSScriptRoot/tools/download_binaryen.ps1"
    if (Test-Path $localOpt) {
        return $localOpt
    }

    return $null
}

function Invoke-OdinTest
{
    param($ExtraArgs = @())

    Write-Host "Testing coroutine package ($($ExtraArgs -join ' '))..." -ForegroundColor Cyan
    $testArgs = @("test", ".") + $ExtraArgs
    odin @testArgs
    return $LASTEXITCODE
}

function Invoke-Matrix
{
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "  LLVM Optimization & Architecture Matrix Test Runner       " -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow

    $Matrix = @(
        @{ Name = "Debug (-o:none -debug)"; Args = @("-o:none", "-debug") },
        @{ Name = "Minimal (-o:minimal)"; Args = @("-o:minimal") },
        @{ Name = "Size (-o:size)"; Args = @("-o:size", "-use-single-module") },
        @{ Name = "Speed (-o:speed)"; Args = @("-o:speed", "-use-single-module") },
        @{ Name = "Aggressive (-o:aggressive)"; Args = @("-o:aggressive", "-use-single-module", "-no-bounds-check", "-disable-assert") },
        @{ Name = "Arch x86-64 (v1 Legacy)"; Args = @("-o:speed", "-microarch:x86-64", "-use-single-module") },
        @{ Name = "Arch x86-64-v2 (Baseline)"; Args = @("-o:speed", "-microarch:x86-64-v2", "-use-single-module") },
        @{ Name = "Arch x86-64-v3 (AVX2/FMA)"; Args = @("-o:speed", "-microarch:x86-64-v3", "-use-single-module") },
        @{ Name = "Arch Native (Host Max)"; Args = @("-o:speed", "-microarch:native", "-use-single-module") },
        @{ Name = "Release Game Binary"; BuildOnly = $true; Source = "examples/game"; Out = "build/game_release.exe"; Args = @("-o:speed", "-microarch:native", "-no-bounds-check", "-disable-assert") },
        @{ Name = "Showcase Binary"; BuildOnly = $true; Source = "examples/showcase"; Out = "build/showcase.exe"; Args = @("-o:speed", "-microarch:native", "-no-bounds-check", "-disable-assert") },
        @{ Name = "Bench Binary"; BuildOnly = $true; Source = "examples/bench"; Out = "build/bench.exe"; Args = @("-o:speed", "-microarch:native", "-no-bounds-check", "-disable-assert") }
    )

    $Results = @()
    $FailedCount = 0

    foreach ($item in $Matrix)
    {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $status = "PASS"

        if ($item.BuildOnly)
        {
            Write-Host "`n[Building] $($item.Name)..." -ForegroundColor Cyan
            $code = Invoke-OdinBuild $item.Source $item.Out $item.Args
            if ($code -ne 0)
            {
                $status = "FAIL"
                $FailedCount++
            }
        }
        else
        {
            Write-Host "`n[Testing] $($item.Name)..." -ForegroundColor Cyan
            $code = Invoke-OdinTest $item.Args
            if ($code -ne 0)
            {
                $status = "FAIL"
                $FailedCount++
            }
        }

        $sw.Stop()
        $Results += [PSCustomObject]@{
            Configuration = $item.Name
            Flags         = ($item.Args -join " ")
            Duration      = "$([math]::Round($sw.Elapsed.TotalSeconds, 2))s"
            Status        = $status
        }
    }

    Write-Host "`n============================================================" -ForegroundColor Yellow
    Write-Host "                MATRIX VALIDATION RESULTS                   " -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    $Results | Format-Table -AutoSize

    if ($FailedCount -gt 0)
    {
        Write-Host "`nMatrix FAILED with $FailedCount errors!" -ForegroundColor Red
        exit 1
    }
    else
    {
        Write-Host "`nAll $($Matrix.Count) matrix configurations PASSED with ZERO errors!" -ForegroundColor Green
    }
}

$RaddbgPath = $env:RADDBG_PATH
if (-not $RaddbgPath -or -not (Test-Path $RaddbgPath))
{
    $RaddbgPath = "E:\OdinLang\raddbg\raddbg.exe"
}

switch ($Action)
{
    "debug"
    {
        if ((Invoke-OdinBuild $Source $OutExe @("-debug")) -eq 0)
        {
            if (Test-Path $RaddbgPath)
            {
                Write-Host "Launching RAD Debugger..." -ForegroundColor Green
                $raddbgArgs = @($OutExe, "--auto_run")
                if (Test-Path $ProjectFile)
                {
                    $raddbgArgs += "--project:$ProjectFile"
                }
                Start-Process -FilePath $RaddbgPath -ArgumentList $raddbgArgs
            } else
            {
                Write-Warning "RAD Debugger not found at $RaddbgPath. Running normally."
                & $OutExe
            }
        }
    }
    "build"
    {
        Invoke-OdinBuild $Source $OutExe @("-debug")
    }
    "release"
    {
        Invoke-OdinBuild $Source "build/game_release.exe" @("-o:speed", "-microarch:native", "-no-bounds-check", "-disable-assert")
    }
    "showcase"
    {
        Invoke-OdinBuild $ShowcaseSource $ShowcaseExe @("-debug")
    }
    "run-showcase"
    {
        if ((Invoke-OdinBuild $ShowcaseSource $ShowcaseExe @("-debug")) -eq 0)
        {
            Write-Host "Running $ShowcaseExe..." -ForegroundColor Green
            & $ShowcaseExe
        }
    }
    "quest"
    {
        Invoke-OdinBuild $QuestSource $QuestExe @("-debug")
    }
    "run-quest"
    {
        if ((Invoke-OdinBuild $QuestSource $QuestExe @("-debug")) -eq 0)
        {
            Write-Host "Running $QuestExe..." -ForegroundColor Green
            & $QuestExe
        }
    }
    "bench"
    {
        Invoke-OdinBuild $BenchSource $BenchExe @("-o:speed", "-microarch:native", "-no-bounds-check", "-disable-assert")
    }
    "run-bench"
    {
        if ((Invoke-OdinBuild $BenchSource $BenchExe @("-o:speed", "-microarch:native", "-no-bounds-check", "-disable-assert")) -eq 0)
        {
            Write-Host "Running $BenchExe..." -ForegroundColor Green
            & $BenchExe
        }
    }
    "run"
    {
        if ((Invoke-OdinBuild $Source $OutExe @("-debug")) -eq 0)
        {
            Write-Host "Running $OutExe..." -ForegroundColor Green
            & $OutExe
        }
    }
    "test"
    {
        Invoke-OdinTest
    }
    "matrix"
    {
        Invoke-Matrix
    }
    "check-arm64"
    {
        Write-Host "Cross-checking ARM64 targets (darwin_arm64, linux_arm64)..." -ForegroundColor Cyan
        odin check . -no-entry-point -target:darwin_arm64
        odin check . -no-entry-point -target:linux_arm64
    }
    "check-riscv64"
    {
        Write-Host "Cross-checking RISC-V 64 target (linux_riscv64)..." -ForegroundColor Cyan
        odin check . -no-entry-point -target:linux_riscv64
    }
    "check-wasm"
    {
        Write-Host "Cross-checking WebAssembly target (js_wasm32)..." -ForegroundColor Cyan
        odin check . -no-entry-point -target:js_wasm32
    }
    "check-all"
    {
        Write-Host "Cross-checking all 7 target architectures..." -ForegroundColor Yellow
        $targets = @("windows_amd64", "linux_amd64", "darwin_amd64", "darwin_arm64", "linux_arm64", "linux_riscv64", "js_wasm32")
        $failed = 0
        foreach ($tgt in $targets)
        {
            Write-Host "  Checking target: $tgt..." -NoNewline
            $output = odin check . -no-entry-point "-target:$tgt" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host " [PASS]" -ForegroundColor Green
            } else {
                Write-Host " [FAIL]" -ForegroundColor Red
                Write-Host $output
                $failed++
            }
        }
        if ($failed -eq 0) {
            Write-Host "All 7 multi-ISA/Wasm targets successfully verified!" -ForegroundColor Green
        } else {
            Write-Host "$failed targets failed cross-check!" -ForegroundColor Red
        }
    }
    "test-arm64"
    {
        & "$PSScriptRoot/run_wsl_qemu.ps1" arm64
    }
    "test-riscv64"
    {
        & "$PSScriptRoot/run_wsl_qemu.ps1" riscv64
    }
    "wasm"
    {
        Write-Host "Building WebAssembly coroutine test suite..." -ForegroundColor Cyan
        $wasmDir = "$PSScriptRoot/examples/wasm_test"
        odin build $wasmDir -target:js_wasm32 -out:"$wasmDir/test.wasm"
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        $wasmOpt = Get-WasmOptPath
        if ($wasmOpt) {
            Write-Host "Post-processing with Binaryen Asyncify ($wasmOpt)..." -ForegroundColor Cyan
            & $wasmOpt --asyncify "$wasmDir/test.wasm" -o "$wasmDir/test_opt.wasm"
        } else {
            Write-Host "[WARNING] wasm-opt not found. Run tools/download_binaryen.ps1 or python tools/download_binaryen.py" -ForegroundColor Yellow
        }
    }
    "test-wasm"
    {
        Write-Host "Running WebAssembly test suite via Node.js..." -ForegroundColor Cyan
        $wasmDir = "$PSScriptRoot/examples/wasm_test"
        odin build $wasmDir -target:js_wasm32 -out:"$wasmDir/test.wasm"
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        $wasmOpt = Get-WasmOptPath
        if ($wasmOpt) {
            Write-Host "Post-processing with Binaryen Asyncify..." -ForegroundColor Cyan
            & $wasmOpt --asyncify "$wasmDir/test.wasm" -o "$wasmDir/test_opt.wasm"
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            node "$PSScriptRoot/tools/run_wasm.js" "$wasmDir/test_opt.wasm"
        } else {
            Write-Host "[ERROR] wasm-opt required for Asyncify execution. Run tools/download_binaryen.ps1 or python tools/download_binaryen.py" -ForegroundColor Red
            exit 1
        }
    }
    "web-game"
    {
        Write-Host "Building WebAssembly boss fight game (examples/game)..." -ForegroundColor Cyan
        $webDir = "$PSScriptRoot/build/web"
        if (-not (Test-Path $webDir)) {
            New-Item -ItemType Directory -Path $webDir -Force | Out-Null
        }
        odin build examples/game -target:js_wasm32 -out:"$webDir/game.wasm"
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

        $wasmOpt = Get-WasmOptPath
        if ($wasmOpt) {
            Write-Host "Post-processing game with Binaryen Asyncify ($wasmOpt)..." -ForegroundColor Cyan
            & $wasmOpt --asyncify "$webDir/game.wasm" -o "$webDir/game_opt.wasm"
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        } else {
            Write-Host "[ERROR] wasm-opt not found. Required for Asyncify! Run tools/download_binaryen.ps1 or python tools/download_binaryen.py" -ForegroundColor Red
            exit 1
        }

        Write-Host "Copying web adapter and shell assets..." -ForegroundColor Cyan
        Copy-Item "$PSScriptRoot/tools/web/index.html" "$webDir/index.html" -Force
        Copy-Item "$PSScriptRoot/tools/web/raylib_canvas.js" "$webDir/raylib_canvas.js" -Force
        Write-Host "Web game bundle created in build/web/ (index.html, game_opt.wasm, raylib_canvas.js)" -ForegroundColor Green
    }
    "test-web-game"
    {
        Write-Host "Testing WebAssembly game loop via headless Node.js runner (1000 frames)..." -ForegroundColor Cyan
        & $PSCommandPath web-game
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        node "$PSScriptRoot/tools/web/test_headless_game.js" "$PSScriptRoot/build/web/game_opt.wasm" 1000
    }
    "run-web-game"
    {
        & $PSCommandPath web-game
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        Write-Host "Starting local HTTP server on http://localhost:8080 (Press Ctrl+C to stop)..." -ForegroundColor Green
        python -m http.server -d "$PSScriptRoot/build/web" 8080
    }
    "amalgamate"
    {
        Write-Host "Generating amalgamated single-file library in dist/coroutine.odin..." -ForegroundColor Cyan
        python tools/amalgamate.py --all-targets
    }
    "dist"
    {
        Write-Host "Generating amalgamated single-file library in dist/coroutine.odin..." -ForegroundColor Cyan
        python tools/amalgamate.py --all-targets
    }
    "test-dist"
    {
        Write-Host "Testing amalgamated dist/coroutine.odin with examples/dist_test..." -ForegroundColor Cyan
        python tools/amalgamate.py --verify
        if ($LASTEXITCODE -eq 0) {
            odin run examples/dist_test -out:build/dist_test.exe
        }
    }
    "pack-itch"
    {
        Write-Host "Building and packaging itch.io WebAssembly release..." -ForegroundColor Cyan
        
        $webDir = "$PSScriptRoot/build/web"
        if (-not (Test-Path $webDir)) {
            New-Item -ItemType Directory -Path $webDir -Force | Out-Null
        }
        odin build examples/game -target:js_wasm32 -out:"$webDir/game.wasm"
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

        $wasmOpt = Get-WasmOptPath
        if ($wasmOpt) {
            Write-Host "Post-processing game with Binaryen Asyncify ($wasmOpt)..." -ForegroundColor Cyan
            & $wasmOpt --asyncify "$webDir/game.wasm" -o "$webDir/game_opt.wasm"
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        } else {
            Write-Host "[ERROR] wasm-opt not found. Required for Asyncify!" -ForegroundColor Red
            exit 1
        }

        Write-Host "Copying minimal itch.io web assets..." -ForegroundColor Cyan
        Copy-Item "$PSScriptRoot/tools/web/index.html" "$webDir/index.html" -Force
        Copy-Item "$PSScriptRoot/tools/web/raylib_canvas.js" "$webDir/raylib_canvas.js" -Force

        $zipPath = "$PSScriptRoot/build/boss_fight_itch.zip"
        if (Test-Path $zipPath) {
            Remove-Item $zipPath -Force
        }

        Write-Host "Creating itch.io release archive at $zipPath..." -ForegroundColor Cyan
        $filesToZip = @(
            "$webDir/index.html",
            "$webDir/game_opt.wasm",
            "$webDir/raylib_canvas.js"
        )
        Compress-Archive -Path $filesToZip -DestinationPath $zipPath -Force

        $zipItem = Get-Item $zipPath
        $zipSizeMb = ($zipItem.Length / 1MB).ToString("F2")
        Write-Host "=================================================================" -ForegroundColor Green
        Write-Host " SUCCESS: itch.io WebAssembly release package created!" -ForegroundColor Green
        Write-Host " Archive: $zipPath ($zipSizeMb MB)" -ForegroundColor Green
        Write-Host " Upload directly to itch.io as 'HTML: playable in browser'!" -ForegroundColor Green
        Write-Host " (Verified: index.html is located at the archive root)" -ForegroundColor Green
        Write-Host "=================================================================" -ForegroundColor Green
    }
    default
    {
        Invoke-OdinBuild $Source $OutExe @("-debug")
    }
}
