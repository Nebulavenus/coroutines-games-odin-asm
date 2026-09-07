# Cross-Platform Binaryen Downloader & Installer for PowerShell (Windows, Linux, macOS)
$ErrorActionPreference = "Stop"

$version = "version_132"
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$targetDir = Join-Path $toolsDir "binaryen"
$binDir = Join-Path $targetDir "bin"

# 1. Determine Operating System
$os = "windows"
$exeExt = ".exe"
if ($PSVersionTable.PSVersion.Major -ge 6) {
    if ($IsMacOS) {
        $os = "macos"
        $exeExt = ""
    } elseif ($IsLinux) {
        $os = "linux"
        $exeExt = ""
    } elseif ($IsWindows) {
        $os = "windows"
        $exeExt = ".exe"
    }
} else {
    $os = "windows"
    $exeExt = ".exe"
}

# 2. Determine Architecture
$arch = "x86_64"
try {
    $osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    if ($osArch -match "Arm64") {
        $arch = if ($os -eq "linux") { "aarch64" } else { "arm64" }
    } elseif ($osArch -match "X64") {
        $arch = "x86_64"
    }
} catch {
    if ($env:PROCESSOR_ARCHITECTURE -match "ARM64") {
        $arch = if ($os -eq "linux") { "aarch64" } else { "arm64" }
    } else {
        $arch = "x86_64"
    }
}

$optExe = Join-Path $binDir "wasm-opt$exeExt"

if (Test-Path $optExe) {
    Write-Host "[OK] wasm-opt already present at $optExe" -ForegroundColor Green
    & $optExe --version
    exit 0
}

$archiveName = "binaryen-$version-$arch-$os.tar.gz"
$url = "https://github.com/WebAssembly/binaryen/releases/download/$version/$archiveName"

Write-Host "Target Platform: $os ($arch)" -ForegroundColor Cyan
Write-Host "Downloading Binaryen $version from $url..." -ForegroundColor Cyan

$tempTar = Join-Path ([System.IO.Path]::GetTempPath()) $archiveName
if ([Net.ServicePointManager]::SecurityProtocol -notmatch "Tls12") {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

Invoke-WebRequest -Uri $url -OutFile $tempTar

Write-Host "Extracting to $targetDir..." -ForegroundColor Cyan
if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
}

$tempExtract = Join-Path ([System.IO.Path]::GetTempPath()) "binaryen_extracted"
if (-not (Test-Path $tempExtract)) {
    New-Item -ItemType Directory -Force -Path $tempExtract | Out-Null
}
tar -xzf $tempTar -C $tempExtract

$extractedBin = Join-Path $tempExtract "binaryen-$version/bin"
if (-not (Test-Path $extractedBin)) {
    $found = Get-ChildItem -Path $tempExtract -Recurse -Filter "wasm-opt*" | Select-Object -First 1
    if ($found) {
        $extractedBin = $found.DirectoryName
    }
}

if (Test-Path $extractedBin) {
    if (-not (Test-Path $binDir)) {
        New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    }
    Copy-Item "$extractedBin/*" $binDir -Recurse -Force
}

Remove-Item $tempTar -Force -ErrorAction SilentlyContinue
Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

# Ensure executable permissions on Unix
if ($os -ne "windows") {
    chmod +x $optExe 2>$null
}

Write-Host "Binaryen installed successfully!" -ForegroundColor Green
& $optExe --version
