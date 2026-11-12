[CmdletBinding()]
param(
    [string]$BlackHolePath = (Join-Path $PSScriptRoot 'bin-windows\blackhole.exe'),
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

function Set-BlackHoleVerb([string]$ClassName, [string]$Label, [string]$Executable, [string]$ProgressScript) {
    $verb = "Registry::HKEY_CURRENT_USER\Software\Classes\$ClassName\shell\BlackHoleCompress"
    $command = "$verb\command"
    New-Item -Force -Path $verb | Out-Null
    Set-ItemProperty -Path $verb -Name '(default)' -Value $Label
    New-Item -Force -Path $command | Out-Null
    Set-ItemProperty -Path $command -Name '(default)' `
        -Value ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -BlackHolePath "{1}" -Source "%1"' -f $ProgressScript, $Executable)
}

$classes = @('*', 'Directory')
if ($Uninstall) {
    foreach ($class in $classes) {
        $verb = "Registry::HKEY_CURRENT_USER\Software\Classes\$class\shell\BlackHoleCompress"
        Remove-Item -LiteralPath $verb -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'BlackHole a ete retire du menu contextuel.'
    exit 0
}

$resolved = (Resolve-Path -LiteralPath $BlackHolePath -ErrorAction Stop).Path
if ([IO.Path]::GetExtension($resolved) -ne '.exe') {
    throw "Le programme doit etre un executable Windows : $resolved"
}

$progressScript = Join-Path (Split-Path -Parent $resolved) 'blackhole-progress.ps1'
if (-not (Test-Path -LiteralPath $progressScript -PathType Leaf)) {
    throw "Le lanceur graphique est introuvable : $progressScript"
}

foreach ($class in $classes) {
    Set-BlackHoleVerb $class 'Compresser avec BlackHole' $resolved $progressScript
}
Write-Host "Menu contextuel installe pour $resolved"
Write-Host 'Clic droit sur un fichier ou dossier, puis Compresser avec BlackHole.'
