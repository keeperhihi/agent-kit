# Native Windows installer for Codex. Uses copies, not symbolic links.
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$WithVendor
)

$ErrorActionPreference = 'Stop'
$Repo = $PSScriptRoot
$CodexDir = Join-Path $env:USERPROFILE '.codex'
$BackupRoot = Join-Path $CodexDir ('.agent-kit-backups/{0}-{1}' -f (Get-Date -Format 'yyyyMMddHHmmss'), $PID)

function Install-Path([string]$Source, [string]$RelativePath) {
    $Destination = Join-Path $CodexDir $RelativePath
    if (Test-Path -LiteralPath $Destination) {
        if (-not $Force) {
            Write-Host "= $RelativePath already exists; kept (use -Force to back up and replace)"
            return
        }
        $Backup = Join-Path $BackupRoot $RelativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $Backup) -Force | Out-Null
        Move-Item -LiteralPath $Destination -Destination $Backup
        Write-Host "~ $RelativePath backed up to $Backup"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    Write-Host "+ $RelativePath"
}

Install-Path (Join-Path $Repo 'codex/config.toml.tmpl') 'config.toml'
Install-Path (Join-Path $Repo 'codex/AGENTS.md') 'AGENTS.md'
foreach ($Skill in Get-ChildItem -LiteralPath (Join-Path $Repo 'skills') -Directory) {
    Install-Path $Skill.FullName (Join-Path 'skills' $Skill.Name)
}
if ($WithVendor) {
    foreach ($Skill in Get-ChildItem -LiteralPath (Join-Path $Repo 'vendor/skills') -Directory) {
        Install-Path $Skill.FullName (Join-Path 'skills' $Skill.Name)
    }
}

Write-Host "Done. Set your CodexManager key in $CodexDir/auth.json, then restart Codex."
