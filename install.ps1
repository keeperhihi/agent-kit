# Native Windows installer for Codex. Uses copies, not symbolic links.
[CmdletBinding()]
param(
    [Alias('cm-key', '-cm-key')]
    [string]$CmKey = '',
    [switch]$WithVendor
)

$ErrorActionPreference = 'Stop'
$Repo = $PSScriptRoot
$CodexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$BackupRoot = Join-Path $CodexDir ('.agent-kit-backups/{0}-{1}' -f (Get-Date -Format 'yyyyMMddHHmmssfffffff'), $PID)

function Backup-Path([string]$RelativePath) {
    $Destination = Join-Path $CodexDir $RelativePath
    if (Test-Path -LiteralPath $Destination) {
        $Backup = Join-Path $BackupRoot $RelativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $Backup) -Force | Out-Null
        Move-Item -LiteralPath $Destination -Destination $Backup
        Write-Host "~ $RelativePath backed up to $Backup"
    }
}

function Install-Path([string]$Source, [string]$RelativePath) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "Missing source: $Source" }
    $Destination = Join-Path $CodexDir $RelativePath
    Backup-Path $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    Write-Host "+ $RelativePath"
}

Install-Path (Join-Path $Repo 'codex/config.toml.tmpl') 'config.toml'
Backup-Path 'auth.json'
$Auth = [ordered]@{ auth_mode = 'apikey'; OPENAI_API_KEY = $CmKey } | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $CodexDir 'auth.json'), $Auth + "`n", (New-Object Text.UTF8Encoding($false)))
Write-Host '+ auth.json'
Install-Path (Join-Path $Repo 'codex/AGENTS.md') 'AGENTS.md'
foreach ($Skill in Get-ChildItem -LiteralPath (Join-Path $Repo 'skills') -Directory) {
    Install-Path $Skill.FullName (Join-Path 'skills' $Skill.Name)
}
if ($WithVendor) {
    foreach ($Skill in Get-ChildItem -LiteralPath (Join-Path $Repo 'vendor/skills') -Directory) {
        Install-Path $Skill.FullName (Join-Path 'skills' $Skill.Name)
    }
}

if (-not $CmKey) {
    Write-Host "Set OPENAI_API_KEY in $CodexDir/auth.json to your CodexManager gateway key."
}
Write-Host 'Done. Start the CodexManager gateway, then restart Codex and open a new session.'
