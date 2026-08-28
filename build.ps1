param (
    [Parameter(Mandatory=$false, Position=0)]
    [ValidateSet("build", "run", "test", "debug", "release", "matrix", "showcase", "run-showcase", "quest", "run-quest", "bench", "run-bench")]
    [string]$Action
)

$OutExe = "build/game.exe"
$ShowcaseExe = "build/showcase.exe"
$QuestExe = "build/quest_ai.exe"
$BenchExe = "build/bench.exe"
$Source = "src"
$ShowcaseSource = "examples/showcase"
$QuestSource = "examples/quest_ai"
$BenchSource = "examples/bench"
$ProjectFile = "game.raddbg"

function Invoke-OdinBuild
{
    param($Source, $Output, $ExtraArgs = @())

    Write-Host "Building $Output..." -ForegroundColor Cyan
    $buildArgs = @("build", $Source, "-out:$Output", "-linker:radlink", "-show-timings") + $ExtraArgs
    odin @buildArgs
    return $LASTEXITCODE
}

function Invoke-OdinTest
{
    param($ExtraArgs = @())

    Write-Host "Testing coroutine package ($($ExtraArgs -join ' '))..." -ForegroundColor Cyan
    $testArgs = @("test", "src/coroutine") + $ExtraArgs
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
        @{ Name = "Release Game Binary"; BuildOnly = $true; Source = "src"; Out = "build/game_release.exe"; Args = @("-o:speed", "-microarch:native", "-no-bounds-check", "-disable-assert") },
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
    default
    {
        Invoke-OdinBuild $Source $OutExe @("-debug")
    }
}
