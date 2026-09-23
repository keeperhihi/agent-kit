$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('agent-kit windows ' + [IO.Path]::GetRandomFileName())
$TestRepo = Join-Path $TestRoot 'repo with spaces'
$TestProfile = Join-Path $TestRoot 'home with spaces'
$PreviousProfile = $env:USERPROFILE

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

try {
    foreach ($RelativePath in 'codex', 'claude', 'skills/example', 'vendor/skills/firecrawl') {
        New-Item -ItemType Directory -Path (Join-Path $TestRepo $RelativePath) -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $Repo 'install.ps1') -Destination $TestRepo
    $Installer = Join-Path $TestRepo 'install.ps1'
    $ConfigSource = Join-Path $TestRepo 'codex/config.toml.tmpl'
    [IO.File]::WriteAllText($ConfigSource, 'model = "repo"')
    [IO.File]::WriteAllText((Join-Path $TestRepo 'codex/AGENTS.md'), '# Shared instructions')
    # Git on Windows can check out a symlink as a file containing its target.
    [IO.File]::WriteAllText((Join-Path $TestRepo 'claude/CLAUDE.md'), '../codex/AGENTS.md')
    [IO.File]::WriteAllText((Join-Path $TestRepo 'skills/example/SKILL.md'), '# Example skill')
    [IO.File]::WriteAllText((Join-Path $TestRepo 'vendor/skills/firecrawl/SKILL.md'), '# Optional third-party skill')

    $env:USERPROFILE = $TestProfile
    $CodexDir = Join-Path $TestProfile '.codex'
    New-Item -ItemType Directory -Path (Join-Path $CodexDir 'skills/user-only') -Force | Out-Null
    $AuthPath = Join-Path $CodexDir 'auth.json'
    $Auth = '{"auth_mode":"apikey","OPENAI_API_KEY":"test-only-key"}'
    [IO.File]::WriteAllText($AuthPath, $Auth)
    [IO.File]::WriteAllText((Join-Path $CodexDir 'skills/user-only/SKILL.md'), 'keep')

    & $Installer *> $null
    $ConfigPath = Join-Path $CodexDir 'config.toml'
    Assert ([IO.File]::ReadAllText($ConfigPath) -eq 'model = "repo"') 'Fresh config was not installed'
    Assert ([IO.File]::ReadAllText((Join-Path $CodexDir 'AGENTS.md')) -eq '# Shared instructions') 'Canonical instructions were not copied'
    Assert (Test-Path -LiteralPath (Join-Path $CodexDir 'skills/example/SKILL.md')) 'Skill was not copied'
    $VendorPath = Join-Path $CodexDir 'skills/firecrawl/SKILL.md'
    Assert (-not (Test-Path -LiteralPath $VendorPath)) 'Third-party skill was installed by default'

    [IO.File]::WriteAllText($ConfigPath, 'model = "local"')
    [IO.File]::WriteAllText((Join-Path $CodexDir 'skills/example/old-only.txt'), 'old skill file')
    & $Installer *> $null
    Assert ([IO.File]::ReadAllText($ConfigPath) -eq 'model = "local"') 'Existing config was overwritten without -Force'
    Assert (-not (Test-Path -LiteralPath (Join-Path $CodexDir '.agent-kit-backups'))) 'Default install made an unnecessary backup'

    & $Installer -WithVendor *> $null
    Assert ([IO.File]::ReadAllText($VendorPath) -eq '# Optional third-party skill') '-WithVendor did not install the third-party skill'
    [IO.File]::WriteAllText($VendorPath, 'keep optional skill')

    & $Installer -Force *> $null
    Assert ([IO.File]::ReadAllText($ConfigPath) -eq 'model = "repo"') '-Force did not replace config'
    Assert (-not (Test-Path -LiteralPath (Join-Path $CodexDir 'skills/example/old-only.txt'))) 'Old skill files survived replacement'
    $Backups = @(Get-ChildItem -LiteralPath (Join-Path $CodexDir '.agent-kit-backups') -Directory)
    Assert ($Backups.Count -eq 1) 'Expected one backup run directory'
    Assert ([IO.File]::ReadAllText((Join-Path $Backups[0].FullName 'config.toml')) -eq 'model = "local"') 'Original config was not backed up'
    Assert (Test-Path -LiteralPath (Join-Path $Backups[0].FullName 'skills/example/old-only.txt')) 'Original skill was not backed up'
    Assert ([IO.File]::ReadAllText($AuthPath) -eq $Auth) 'Credentials changed'
    Assert ([IO.File]::ReadAllText((Join-Path $CodexDir 'skills/user-only/SKILL.md')) -eq 'keep') 'Unrelated skill changed'
    Assert ([IO.File]::ReadAllText($VendorPath) -eq 'keep optional skill') 'Default install changed an already installed third-party skill'
    Write-Host 'PASS: Windows copy install preserves credentials and backups; third-party skills require -WithVendor'
} finally {
    $env:USERPROFILE = $PreviousProfile
    Remove-Item -LiteralPath $TestRoot -Recurse -Force
}
