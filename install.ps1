# Codex preferences only. Compatible with PowerShell 5.1.
[CmdletBinding()]
param([switch]$Restore)

$ErrorActionPreference = 'Stop'
$Python = Join-Path $PSScriptRoot '.venv/Scripts/python.exe'
if (-not (Test-Path -LiteralPath $Python)) {
    $Bootstrap = 'python'
    $BootstrapArguments = @()
    if (Get-Command py -ErrorAction SilentlyContinue) {
        $Bootstrap = 'py'
        $BootstrapArguments = @('-3')
    }
    & $Bootstrap @BootstrapArguments -c "import sys; sys.exit('Python 3.9 or newer is required.') if sys.version_info < (3, 9) else None"
    if ($LASTEXITCODE -ne 0) { throw 'Python 3.9 or newer is required.' }
    Write-Host 'Creating .venv in the repository'
    & $Bootstrap @BootstrapArguments -m venv (Join-Path $PSScriptRoot '.venv')
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the Python environment.' }
}

$Required = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'requirements.txt') | Where-Object { $_ -match '^tomlkit==' }) -replace '^tomlkit==', ''
& $Python -c "import importlib.util, importlib.metadata, sys; sys.exit(importlib.util.find_spec('tomlkit') is None or importlib.metadata.version('tomlkit') != sys.argv[1])" $Required
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Installing dependencies in .venv'
    & $Python -m pip install --disable-pip-version-check -r (Join-Path $PSScriptRoot 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Could not install dependencies.' }
}
$Arguments = @((Join-Path $PSScriptRoot 'preferences.py'), 'codex')
if ($Restore) { $Arguments += '--restore' }
& $Python @Arguments
if ($LASTEXITCODE -ne 0) { throw "Preferences failed (exit $LASTEXITCODE)." }
