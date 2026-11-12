[CmdletBinding()]
param([string]$OutputDirectory = "bin-windows", [switch]$UpdateIndex, [switch]$InstallContextMenu)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows with GHC and Cabal installed (GHCup).' }
function Invoke-Checked([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE" }
}
Push-Location $PSScriptRoot
try {
    Get-Command ghc, cabal -ErrorAction Stop | Out-Null
    if ($UpdateIndex) { Invoke-Checked 'cabal' @('update') }
    # Zstandard is compiled into the program; no zstd DLL/pacman is needed.
    Invoke-Checked 'cabal' @('build','all','-fbundled-zstd')
    Invoke-Checked 'cabal' @('test','all','-fbundled-zstd','--test-show-details=direct','--test-options=+RTS -N2 -RTS')
    $binary = (& cabal list-bin exe:blackhole -fbundled-zstd | Select-Object -Last 1).Trim()
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw 'blackhole.exe was not produced.' }
    $out = [IO.Path]::GetFullPath($OutputDirectory)
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    $target = Join-Path $out 'blackhole.exe'
    Copy-Item -LiteralPath $binary -Destination $target -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'blackhole-progress.ps1') `
        -Destination (Join-Path $out 'blackhole-progress.ps1') -Force
    Invoke-Checked $target @('--version')
    if ($InstallContextMenu) {
        & "$PSScriptRoot\install-windows-context-menu.ps1" -BlackHolePath $target
        if ($LASTEXITCODE -ne 0) { throw 'Context menu installation failed.' }
    }
    Write-Host "Built and tested: $target"
    Write-Host "Example: & '$target' compress '.\project' -o '.\project.bh'"
} finally { Pop-Location }
