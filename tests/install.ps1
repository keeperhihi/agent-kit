# Verifies install.ps1 in a temporary repository and Codex home without touching real config.
# Keep this file ASCII-only so Windows PowerShell 5.1 reads it correctly.
$ErrorActionPreference = 'Stop'
$Source = Split-Path -Parent $PSScriptRoot
$Root = Join-Path ([IO.Path]::GetTempPath()) ('agent-kit test ' + [IO.Path]::GetRandomFileName())
$PreviousCodexHome = $env:CODEX_HOME
$Checks = 0

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:Checks++
}
function Write-Text([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text)
}
function Read-Text([string]$Path) { [IO.File]::ReadAllText($Path) }
function Read-Key { (Read-Text $AuthPath | ConvertFrom-Json).OPENAI_API_KEY }
function Invoke-Installer { & $Installer @args *> $null }
function Test-Fails {
    try { & $Installer @args *> $null } catch { return $true }
    return $false
}

try {
    $Repo = Join-Path $Root 'repo with spaces'
    $Codex = Join-Path $Root 'codex home'
    New-Item -ItemType Directory -Path $Repo -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Source 'install.ps1') -Destination $Repo
    Write-Text (Join-Path $Repo 'instructions.md') '# Instructions'
    Write-Text (Join-Path $Repo 'codex/config.toml') 'model_provider = "cm"'
    Write-Text (Join-Path $Repo 'codex/nested/extra.toml') 'nested'
    Write-Text (Join-Path $Repo 'codex/.DS_Store') 'junk'
    foreach ($Name in 'alpha', 'beta') { Write-Text (Join-Path $Repo "skills/$Name/SKILL.md") "# $Name" }
    Write-Text (Join-Path $Repo 'vendor/skills/gamma/SKILL.md') '# gamma'
    $Installer = Join-Path $Repo 'install.ps1'
    $env:CODEX_HOME = "$Codex\"
    $AuthPath = Join-Path $Codex 'auth.json'
    $State = Join-Path $Codex '.agent-kit'

    # Fresh install: copies everything and writes an empty key; restore removes it all.
    Invoke-Installer
    Assert ((Read-Text (Join-Path $Codex 'AGENTS.md')) -eq '# Instructions') 'instructions installed'
    Assert ((Read-Text (Join-Path $Codex 'config.toml')) -eq 'model_provider = "cm"') 'config installed'
    Assert ((Read-Text (Join-Path $Codex 'nested/extra.toml')) -eq 'nested') 'nested file installed by relative path'
    Assert (-not (Test-Path -LiteralPath (Join-Path $Codex '.DS_Store'))) 'hidden files skipped'
    Assert ((Read-Text (Join-Path $Codex 'skills/beta/SKILL.md')) -eq '# beta') 'skills installed'
    Assert (-not (Test-Path -LiteralPath (Join-Path $Codex 'skills/gamma'))) 'vendor skills skipped by default'
    $Auth = Read-Text $AuthPath | ConvertFrom-Json
    Assert ($Auth.auth_mode -eq 'apikey' -and $Auth.OPENAI_API_KEY -eq '') 'empty key'
    Assert ([IO.File]::ReadAllBytes($AuthPath)[0] -eq 123) 'auth.json has no BOM'
    Invoke-Installer -Restore
    Assert (@(Get-ChildItem -LiteralPath $Codex -Recurse -File -Force).Count -eq 0) 'restore removes installed files'
    Assert (Test-Fails -Restore) 'restore without a record fails'

    # Existing config: originals are saved on first takeover only; restore puts them back.
    Write-Text (Join-Path $Codex 'config.toml') 'model = "local"'
    Write-Text $AuthPath '{"auth_mode":"chatgpt","tokens":{"access_token":"t"}}'
    $OriginalAuth = Read-Text $AuthPath
    Write-Text (Join-Path $Codex 'skills/alpha/SKILL.md') '# my alpha'
    Write-Text (Join-Path $Codex 'skills/alpha/notes.md') 'notes'
    Write-Text (Join-Path $Codex 'skills/mine/SKILL.md') '# mine'
    Write-Text (Join-Path $Codex 'sessions/keep.jsonl') 'data'
    $Key = 'test-"key"\path' + "`tline`nnext`r"
    $Output = & $Installer -CmKey $Key *>&1 | Out-String
    Assert (-not $Output.Contains('test-"key"')) 'key not printed'
    Assert ((Read-Key) -ceq $Key) 'key serialized'
    Assert ((Read-Text (Join-Path $Codex 'config.toml')) -eq 'model_provider = "cm"') 'config replaced'
    Assert (-not (Test-Path -LiteralPath (Join-Path $Codex 'skills/alpha/notes.md'))) 'same-name skill replaced as a whole'
    Assert ((Read-Text (Join-Path $Codex 'skills/mine/SKILL.md')) -eq '# mine') 'unrelated skill untouched'
    Assert ((Read-Text (Join-Path $Codex 'sessions/keep.jsonl')) -eq 'data') 'sessions untouched'

    # Reinstall keeps a CodexManager key and never overwrites saved originals.
    $KeyedAuth = Read-Text $AuthPath
    Write-Text (Join-Path $Codex 'config.toml') 'edited'
    Invoke-Installer
    Assert ((Read-Text $AuthPath) -ceq $KeyedAuth) 'reinstall keeps the key'
    Assert ((Read-Text (Join-Path $Codex 'config.toml')) -eq 'model_provider = "cm"') 'reinstall overwrites local edits'
    Assert ((Read-Text (Join-Path $State 'original/config.toml')) -eq 'model = "local"') 'original saved once'
    Invoke-Installer -CmKey 'replacement'
    Assert ((Read-Key) -ceq 'replacement') '-CmKey replaces an existing key'
    foreach ($StaleAuth in '{"auth_mode":"chatgpt","OPENAI_API_KEY":"old"}', '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-official"}') {
        Write-Text $AuthPath $StaleAuth
        Invoke-Installer
        Assert ((Read-Key) -eq '') "not kept: $StaleAuth"
    }

    # Skills removed from the repository get their originals back; vendor skills follow -WithVendor.
    Move-Item -LiteralPath (Join-Path $Repo 'skills/alpha') -Destination (Join-Path $Root 'alpha')
    Invoke-Installer -WithVendor
    Assert (Test-Path -LiteralPath (Join-Path $Codex 'skills/alpha/notes.md')) 'removed skill restored'
    Assert ((Read-Text (Join-Path $Codex 'skills/gamma/SKILL.md')) -eq '# gamma') 'vendor skill installed'
    Invoke-Installer
    Assert (-not (Test-Path -LiteralPath (Join-Path $Codex 'skills/gamma'))) 'vendor skill removed without -WithVendor'
    Move-Item -LiteralPath (Join-Path $Root 'alpha') -Destination (Join-Path $Repo 'skills/alpha')
    Invoke-Installer

    Assert (Test-Fails -Restore -CmKey 'unused') '-Restore rejects other options'
    Invoke-Installer -Restore
    Assert ((Read-Text (Join-Path $Codex 'config.toml')) -eq 'model = "local"') 'original config restored'
    Assert ((Read-Text $AuthPath) -eq $OriginalAuth) 'original login restored'
    Assert (Test-Path -LiteralPath (Join-Path $Codex 'skills/alpha/notes.md')) 'original skill restored'
    Assert (-not (Test-Path -LiteralPath (Join-Path $Codex 'AGENTS.md'))) 'paths that did not exist are removed'
    Assert ((Read-Text (Join-Path $Codex 'skills/mine/SKILL.md')) -eq '# mine') 'unrelated skill still there'
    Assert (-not (Test-Path -LiteralPath $State)) 'install record removed'

    # The documented native command works, and the install survives deleting the repository.
    $Copy = Join-Path $Root 'repo copy'
    Copy-Item -LiteralPath $Repo -Destination $Copy -Recurse
    $env:CODEX_HOME = Join-Path $Root 'custom codex'
    $PowerShell = (Get-Process -Id $PID).Path
    $Output = & $PowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Copy 'install.ps1') -CmKey test-cli-key 2>&1 | Out-String
    Assert ($LASTEXITCODE -eq 0) 'native command succeeded'
    Assert (-not $Output.Contains('test-cli-key')) 'native command did not print the key'
    Remove-Item -LiteralPath $Copy -Recurse -Force
    Assert ((Read-Text (Join-Path $env:CODEX_HOME 'skills/alpha/SKILL.md')) -eq '# alpha') 'install survives deleting the repository'
    Assert ((Read-Text (Join-Path $env:CODEX_HOME 'auth.json') | ConvertFrom-Json).OPENAI_API_KEY -eq 'test-cli-key') 'CODEX_HOME and -CmKey honored'

    Write-Host "PASS: $Checks checks for install, reinstall, auth.json, skill changes, vendor skills, restore, and native invocation"
} finally {
    $env:CODEX_HOME = $PreviousCodexHome
    if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
}
