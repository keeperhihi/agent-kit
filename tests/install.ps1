# Test the public PowerShell entry point using a temporary Codex home.
$ErrorActionPreference = 'Stop'
$Source = Split-Path -Parent $PSScriptRoot
$Root = Join-Path ([IO.Path]::GetTempPath()) ('agent-kit test ' + [IO.Path]::GetRandomFileName())
$OldCodexHome = $env:CODEX_HOME
$OldPath = $env:PATH
$Checks = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:Checks++
}
function Write-Text([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
function Read-Text([string]$Path) { [IO.File]::ReadAllText($Path) }
try {
    $PythonDirectory = Join-Path $Source '.venv/Scripts'
    if (Test-Path -LiteralPath $PythonDirectory) { $env:PATH = $PythonDirectory + [IO.Path]::PathSeparator + $env:PATH }
    $Repo = Join-Path $Root 'repo with spaces'
    $Codex = Join-Path $Root 'codex home'
    New-Item -ItemType Directory -Path $Repo -Force | Out-Null
    foreach ($Name in 'install.ps1', 'preferences.py', 'requirements.txt') {
        Copy-Item -LiteralPath (Join-Path $Source $Name) -Destination $Repo
    }
    Copy-Item -LiteralPath (Join-Path $Source 'gateways') -Destination $Repo -Recurse
    Write-Text (Join-Path $Repo 'codex/config.toml') "approval_policy = `"never`"`n"
    $Config = Join-Path $Codex 'config.toml'
    $Auth = Join-Path $Codex 'auth.json'
    Write-Text $Config "model = `"magpie/test`"`napproval_policy = `"on-request`"`n"
    Write-Text $Auth '{"auth_mode":"chatgpt","tokens":{"access_token":"test"}}'
    $OriginalAuth = Read-Text $Auth
    $env:CODEX_HOME = $Codex
    $Installer = Join-Path $Repo 'install.ps1'
    & $Installer -Gateway magpie
    Assert ((Read-Text $Config).Contains('model = "magpie/test"')) 'model preserved'
    Assert ((Read-Text $Config).Contains('approval_policy = "never"')) 'preference applied'
    Assert ((Read-Text $Auth) -eq $OriginalAuth) 'login preserved'
    Assert (-not (Test-Path (Join-Path $Codex 'AGENTS.md'))) 'instructions not installed'
    Assert (-not (Test-Path (Join-Path $Codex 'skills'))) 'skills not installed'
    & $Installer -Gateway magpie
    Write-Text $Config ((Read-Text $Config).Replace('magpie/test', 'magpie/changed'))
    & $Installer -Restore -Gateway magpie
    Assert ((Read-Text $Config).Contains('model = "magpie/changed"')) 'changed model survives restore'
    Assert ((Read-Text $Config).Contains('approval_policy = "on-request"')) 'first preference restored'
    Assert ((Read-Text $Auth) -eq $OriginalAuth) 'restore preserves login'
    Assert (-not (Test-Path (Join-Path $Codex '.agent-kit/preferences.json'))) 'preference record removed'
    Write-Host "PASS: $Checks checks through install.ps1"
} finally {
    $env:CODEX_HOME = $OldCodexHome
    $env:PATH = $OldPath
    if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
}
