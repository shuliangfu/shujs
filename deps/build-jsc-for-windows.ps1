# 在 Windows 上构建 JavaScriptCore（jsc-only），产出 include/ 与 lib/ 供 shu 链接。
# 用法：在 PowerShell 中于本脚本所在目录或仓库根执行；需已安装 VS、CMake、Ninja、Perl、Python、Ruby、gperf 等（见 deps/README.md）。
# 环境变量：WEBKIT_SRC 为 WebKit 源码根目录，默认 $env:GITHUB_WORKSPACE\WebKit 或 C:\WebKit；OUTPUT_DIR 为产出目录，默认当前目录下的 install-windows。

$ErrorActionPreference = "Stop"
$WebKitSrc = if ($env:WEBKIT_SRC) { $env:WEBKIT_SRC } else { if ($env:GITHUB_WORKSPACE) { Join-Path $env:GITHUB_WORKSPACE "WebKit" } else { "C:\WebKit" } }
$OutputDir = if ($env:OUTPUT_DIR) { $env:OUTPUT_DIR } else { Join-Path (Get-Location) "install-windows" }

if (-not (Test-Path $WebKitSrc)) { Write-Error "WebKit 源码目录不存在: $WebKitSrc"; exit 1 }
$buildJsc = Join-Path $WebKitSrc "Tools\Scripts\build-jsc"
if (-not (Test-Path $buildJsc)) { Write-Error "未找到 Tools\Scripts\build-jsc"; exit 1 }

Write-Host "WebKit 源码: $WebKitSrc"
Write-Host "产出目录:    $OutputDir"
Push-Location $WebKitSrc
try {
    & perl $buildJsc --jsc-only
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $buildDir = $null
    foreach ($cand in "WebKitBuild\JSCOnly\Release", "WebKitBuild\Release", "WebKitBuild\JSCOnly\Debug", "WebKitBuild\Debug") {
        if (Test-Path $cand) { $buildDir = $cand; break }
    }
    if (-not $buildDir) { Write-Error "未找到 WebKitBuild 下的构建产物"; exit 1 }
    $incOut = Join-Path $OutputDir "include"
    $libOut = Join-Path $OutputDir "lib"
    New-Item -ItemType Directory -Force -Path $incOut | Out-Null
    New-Item -ItemType Directory -Force -Path $libOut | Out-Null
    Copy-Item -Path (Join-Path $WebKitSrc "Source\JavaScriptCore\API\*.h") -Destination $incOut -Force
    Get-ChildItem -Path $buildDir -Recurse -File | Where-Object { $_.Name -match "^(lib)?[Jj]ava[Ss]cript[Cc]ore" -or $_.Extension -match "\.(lib|dll|a)$" } | ForEach-Object { Copy-Item $_.FullName -Destination $libOut -Force }
    $libCount = (Get-ChildItem $libOut -File).Count
    if ($libCount -eq 0) {
        Get-ChildItem -Path $buildDir -Recurse -File -Include "*.lib", "*.dll" | ForEach-Object { Copy-Item $_.FullName -Destination $libOut -Force }
    }
    Write-Host "install-windows 已写入 include/ 与 lib/。"
} finally {
    Pop-Location
}
