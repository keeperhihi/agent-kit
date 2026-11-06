$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('agent-kit windows ' + [IO.Path]::GetRandomFileName())
$TestRepo = Join-Path $TestRoot 'repo with spaces'
$TestProfile = Join-Path $TestRoot 'home with spaces'
$PreviousProfile = $env:USERPROFILE
$PreviousCodexHome = $env:CODEX_HOME

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

try {
    foreach ($RelativePath in 'codex', 'skills/example', 'vendor/skills/firecrawl') {
        New-Item -ItemType Directory -Path (Join-Path $TestRepo $RelativePath) -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $Repo 'install.ps1') -Destination $TestRepo
    $Installer = Join-Path $TestRepo 'install.ps1'
    $Config = [IO.File]::ReadAllText((Join-Path $Repo 'codex/config.toml.tmpl'))
    [IO.File]::WriteAllText((Join-Path $TestRepo 'codex/config.toml.tmpl'), $Config)
    [IO.File]::WriteAllText((Join-Path $TestRepo 'codex/AGENTS.md'), '# Shared instructions')
    [IO.File]::WriteAllText((Join-Path $TestRepo 'skills/example/SKILL.md'), '# Example skill')
    [IO.File]::WriteAllText((Join-Path $TestRepo 'vendor/skills/firecrawl/SKILL.md'), '# Optional skill')

    $env:USERPROFILE = $TestProfile
    $env:CODEX_HOME = $null
    $CodexDir = Join-Path $TestProfile '.codex'
    $ConfigPath = Join-Path $CodexDir 'config.toml'
    $AuthPath = Join-Path $CodexDir 'auth.json'
    & $Installer *> $null
    Assert ([IO.File]::ReadAllText($ConfigPath) -eq $Config) 'Fresh config was not installed'
    Assert ([IO.File]::ReadAllText((Join-Path $CodexDir 'AGENTS.md')) -eq '# Shared instructions') 'Instructions were not copied'
    $Auth = Get-Content -LiteralPath $AuthPath -Raw | ConvertFrom-Json
    Assert ($Auth.auth_mode -eq 'apikey' -and $Auth.OPENAI_API_KEY -eq '') 'Fresh install must create an empty API key'
    Assert (-not (Test-Path -LiteralPath (Join-Path $CodexDir '.agent-kit-backups'))) 'Fresh install needs no backup'
    Assert (-not (Test-Path -LiteralPath (Join-Path $CodexDir 'skills/firecrawl'))) 'Vendor skill installed by default'

    foreach ($RelativePath in 'skills/user-only', 'sessions') {
        New-Item -ItemType Directory -Path (Join-Path $CodexDir $RelativePath) -Force | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $CodexDir 'skills/user-only/SKILL.md'), 'keep')
    [IO.File]::WriteAllText((Join-Path $CodexDir 'sessions/keep.jsonl'), 'session data')
    [IO.File]::WriteAllText((Join-Path $CodexDir 'state.sqlite'), 'database data')
    [IO.File]::WriteAllText($ConfigPath, 'model = "local"')
    [IO.File]::WriteAllText($AuthPath, '{"auth_mode":"chatgpt","tokens":{"access_token":"old-test-token"}}')
    $OldAuth = [IO.File]::ReadAllText($AuthPath)
    [IO.File]::WriteAllText((Join-Path $CodexDir 'skills/example/old-only.txt'), 'old skill file')
    $Key = 'test-"key"\path' + "`tline`nnext`r"
    $Output = & $Installer -CmKey $Key *>&1 | Out-String
    Assert (-not $Output.Contains('test-"key"')) 'Installer printed the key'
    Assert ([IO.File]::ReadAllText($ConfigPath) -eq $Config) 'Existing config was not replaced'
    $Auth = Get-Content -LiteralPath $AuthPath -Raw | ConvertFrom-Json
    Assert ($Auth.auth_mode -eq 'apikey' -and $Auth.OPENAI_API_KEY -ceq $Key) 'Key was not serialized correctly'
    $AuthBytes = [IO.File]::ReadAllBytes($AuthPath)
    Assert ($AuthBytes[0] -eq 123) 'auth.json must be UTF-8 without a BOM'
    Assert (-not (Test-Path -LiteralPath (Join-Path $CodexDir 'skills/example/old-only.txt'))) 'Old skill files survived replacement'
    $Backups = @(Get-ChildItem -LiteralPath (Join-Path $CodexDir '.agent-kit-backups') -Directory)
    Assert ($Backups.Count -eq 1) 'Expected one backup directory per run'
    Assert ([IO.File]::ReadAllText((Join-Path $Backups[0].FullName 'config.toml')) -eq 'model = "local"') 'Original config was not backed up'
    Assert ([IO.File]::ReadAllText((Join-Path $Backups[0].FullName 'auth.json')) -eq $OldAuth) 'Original credentials were not backed up'
    Assert (Test-Path -LiteralPath (Join-Path $Backups[0].FullName 'skills/example/old-only.txt')) 'Original skill was not backed up'
    Assert ([IO.File]::ReadAllText((Join-Path $CodexDir 'sessions/keep.jsonl')) -eq 'session data') 'Sessions changed'
    Assert ([IO.File]::ReadAllText((Join-Path $CodexDir 'state.sqlite')) -eq 'database data') 'Database changed'
    Assert ([IO.File]::ReadAllText((Join-Path $CodexDir 'skills/user-only/SKILL.md')) -eq 'keep') 'Unrelated skill changed'

    # Repeated runs in the same PowerShell process need separate backup directories.
    & $Installer *> $null
    $Backups = @(Get-ChildItem -LiteralPath (Join-Path $CodexDir '.agent-kit-backups') -Directory)
    Assert ($Backups.Count -eq 2) 'Repeated install reused a backup directory'
    Assert ((Get-Content -LiteralPath $AuthPath -Raw | ConvertFrom-Json).OPENAI_API_KEY -eq '') 'Omitting the key did not clear the credential'
    $SavedKey = @($Backups | Where-Object {
        (Get-Content -LiteralPath (Join-Path $_.FullName 'auth.json') -Raw | ConvertFrom-Json).OPENAI_API_KEY -ceq $Key
    })
    Assert ($SavedKey.Count -eq 1) 'Reinstall did not back up the previous key'

    # Exercise the documented native command syntax, including --cm-key.
    $env:CODEX_HOME = Join-Path $TestRoot 'custom codex'
    $PowerShell = (Get-Process -Id $PID).Path
    $Output = & $PowerShell -NoProfile -ExecutionPolicy Bypass -File $Installer --cm-key test-cli-key 2>&1 | Out-String
    Assert ($LASTEXITCODE -eq 0) '--cm-key command failed'
    Assert (-not $Output.Contains('test-cli-key')) 'Native command printed the key'
    $CustomAuthPath = Join-Path $env:CODEX_HOME 'auth.json'
    Assert ((Get-Content -LiteralPath $CustomAuthPath -Raw | ConvertFrom-Json).OPENAI_API_KEY -eq 'test-cli-key') 'CODEX_HOME or --cm-key was ignored'
    Assert ((Get-Content -LiteralPath $AuthPath -Raw | ConvertFrom-Json).OPENAI_API_KEY -eq '') 'Custom install modified the default directory'

    & $Installer -WithVendor *> $null
    $VendorPath = Join-Path $env:CODEX_HOME 'skills/firecrawl/SKILL.md'
    Assert ([IO.File]::ReadAllText($VendorPath) -eq '# Optional skill') '-WithVendor did not install the skill'
    [IO.File]::WriteAllText($VendorPath, 'keep optional skill')
    & $Installer *> $null
    Assert ([IO.File]::ReadAllText($VendorPath) -eq 'keep optional skill') 'Default install changed an unselected vendor skill'
    Write-Host 'PASS: PowerShell replacement, auth, backups, custom paths, and vendor selection'
} finally {
    $env:USERPROFILE = $PreviousProfile
    $env:CODEX_HOME = $PreviousCodexHome
    Remove-Item -LiteralPath $TestRoot -Recurse -Force
}
