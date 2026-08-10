#!/usr/bin/env pwsh
# Rebuild the engine and copy it + the rule bundles into both app targets.
# Both shells MUST carry the identical engine bundle — that is the architecture.
#
# Native PowerShell twin of tools/sync-engine.sh, for anyone who would rather
# not depend on Node to run the sync step itself (pnpm build still needs
# Node). Windows ships Windows PowerShell 5.1 as `powershell.exe` by default;
# this script only uses features available there, so it runs with either
# `powershell.exe` or `pwsh` (PowerShell 7+). If running the script is
# blocked by execution policy, use:
#
#   powershell -ExecutionPolicy Bypass -File tools\sync-engine.ps1
#
# Prefer `node tools/sync-engine.mjs` if you want one script that behaves
# identically on every OS — this file is the native alternative.

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$EngineDir = Join-Path $RepoRoot 'engine'
$AndroidRulesDir = Join-Path $RepoRoot 'android/app/src/main/assets/rules'
$IosRulesDir = Join-Path $RepoRoot 'ios/NoScroll/Resources/Rules'
$EngineOut = Join-Path $EngineDir 'dist/noscroll.js'
$RulesDir = Join-Path $RepoRoot 'rules'

Push-Location $EngineDir
try {
    pnpm build
    if ($LASTEXITCODE -ne 0) {
        throw "pnpm build failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

New-Item -ItemType Directory -Force -Path $AndroidRulesDir | Out-Null
New-Item -ItemType Directory -Force -Path $IosRulesDir | Out-Null

Copy-Item -Path $EngineOut -Destination (Join-Path $RepoRoot 'android/app/src/main/assets/noscroll.js') -Force
Copy-Item -Path $EngineOut -Destination (Join-Path $RepoRoot 'ios/NoScroll/Resources/noscroll.js') -Force

Copy-Item -Path (Join-Path $RulesDir '*.json') -Destination $AndroidRulesDir -Force
Copy-Item -Path (Join-Path $RulesDir '*.json') -Destination $IosRulesDir -Force

$bytes = (Get-Item $EngineOut).Length
Write-Host "engine + rules synced to both shells ($bytes bytes)"
