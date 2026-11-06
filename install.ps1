# Windows installer: Codex only. Copies this repository into the Codex config directory,
# so the repository can be deleted afterwards. .agent-kit\ in that directory records the
# managed paths, their originals from before the first takeover, and whether vendor skills
# are wanted; -Restore puts the originals back.
# Behaves like install.sh. Keep this file ASCII-only so Windows PowerShell 5.1 reads it correctly.
[CmdletBinding()]
param(
    [string]$CmKey = '',
    [switch]$WithVendor,
    [switch]$WithoutVendor,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
$Repo = $PSScriptRoot
$CodexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME.TrimEnd('\', '/') } else { Join-Path $env:USERPROFILE '.codex' }
$State = Join-Path $CodexDir '.agent-kit'
$ManagedList = Join-Path $State 'managed'
$Original = Join-Path $State 'original'
$VendorChoice = Join-Path $State 'with-vendor'
$CmKeyGiven = $PSBoundParameters.ContainsKey('CmKey')

function Test-Entry([string]$Path) {
    [bool](Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
}

function Remove-Entry([string]$Path) {
    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $Item) { return }
    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        # Delete the link itself; Windows PowerShell 5.1 would recurse into its target.
        if ($Item.PSIsContainer) { [IO.Directory]::Delete($Item.FullName) } else { [IO.File]::Delete($Item.FullName) }
    } else {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

# Copy next to the destination first, then swap it in.
function Copy-Entry([string]$Source, [string]$Destination) {
    $Parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $Parent -Force | Out-Null
    $Pending = Join-Path $Parent ('.agent-kit.' + [IO.Path]::GetRandomFileName())
    try {
        Copy-Item -LiteralPath $Source -Destination $Pending -Recurse
        Remove-Entry $Destination
        Move-Item -LiteralPath $Pending -Destination $Destination
    } finally {
        Remove-Entry $Pending
    }
}

# Put the original back; remove the path if it did not exist before.
function Restore-Entry([string]$Relative) {
    if (-not $Relative -or [IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.?([\\/]|$)') {
        throw "Unsafe path in the managed list: $Relative"
    }
    $Target = Join-Path $CodexDir $Relative
    $Saved = Join-Path $Original $Relative
    Remove-Entry $Target
    if (Test-Entry $Saved) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Target) -Force | Out-Null
        Move-Item -LiteralPath $Saved -Destination $Target
    }
}

function Get-Managed {
    if (Test-Path -LiteralPath $ManagedList) { @(Get-Content -LiteralPath $ManagedList | Where-Object { $_ }) } else { @() }
}

# CodexManager keys never start with sk-; that prefix marks an official OpenAI key.
function Test-CmKey([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $Auth = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        $Key = $Auth.OPENAI_API_KEY
        return $Auth.auth_mode -ceq 'apikey' -and $Key -is [string] -and $Key -ne '' -and $Key -cnotlike 'sk-*'
    } catch {
        return $false
    }
}

if ($WithVendor -and $WithoutVendor) { throw '-WithVendor and -WithoutVendor cannot be combined' }
if ($Restore) {
    if ($CmKeyGiven -or $WithVendor -or $WithoutVendor) { throw '-Restore cannot be combined with other options' }
    if (-not (Test-Path -LiteralPath $State)) { throw "No install record in $CodexDir" }
    foreach ($Relative in Get-Managed) { Restore-Entry $Relative }
    Remove-Entry $State
    Write-Host "Restored $CodexDir"
    return
}

Write-Host "-> $CodexDir"
New-Item -ItemType Directory -Path $Original -Force | Out-Null
# Remember whether this machine wants vendor skills; with neither switch the last choice stands.
if ($WithVendor) { [IO.File]::WriteAllText($VendorChoice, '') }
if ($WithoutVendor) { Remove-Entry $VendorChoice }
$Vendor = Test-Path -LiteralPath $VendorChoice

# Managed path (relative to the Codex config directory) -> source in this repository.
$Targets = [ordered]@{ 'AGENTS.md' = (Join-Path $Repo 'instructions.md'); 'auth.json' = $null }
$Mirror = (Get-Item -LiteralPath (Join-Path $Repo 'codex')).FullName
foreach ($File in Get-ChildItem -LiteralPath $Mirror -Recurse -File) {
    $Relative = $File.FullName.Substring($Mirror.Length + 1).Replace('\', '/')
    if ($Relative -notmatch '(^|/)\.') { $Targets[$Relative] = $File.FullName }
}
$SkillRoots = @(Join-Path $Repo 'skills')
if ($Vendor) { $SkillRoots += Join-Path $Repo 'vendor/skills' }
foreach ($Root in $SkillRoots) {
    foreach ($Skill in Get-ChildItem -LiteralPath $Root -Directory) {
        $Relative = "skills/$($Skill.Name)"
        if (-not $Targets.Contains($Relative)) { $Targets[$Relative] = $Skill.FullName }
    }
}

$Managed = Get-Managed

# First takeover of a path: save the original, then register it. Saved originals are never overwritten.
foreach ($Relative in $Targets.Keys) {
    if ($Managed -contains $Relative) { continue }
    $Target = Join-Path $CodexDir $Relative
    $Saved = Join-Path $Original $Relative
    if ((Test-Entry $Target) -and -not (Test-Entry $Saved)) {
        Copy-Entry $Target $Saved
        Write-Host "  ~ $Relative (original saved in .agent-kit)"
    }
    Add-Content -LiteralPath $ManagedList -Value $Relative
}

# Paths no longer in the repository: put the originals back.
foreach ($Relative in $Managed) {
    if (-not $Targets.Contains($Relative)) {
        Restore-Entry $Relative
        Write-Host "  - $Relative"
    }
}

$EmptyKey = $false
foreach ($Relative in $Targets.Keys) {
    $Target = Join-Path $CodexDir $Relative
    if ($Relative -ne 'auth.json') {
        Copy-Entry $Targets[$Relative] $Target
        continue
    }
    if (-not $CmKeyGiven -and (Test-CmKey $Target)) {
        Write-Host '  = auth.json: existing key kept'
        continue
    }
    Remove-Entry $Target
    $Auth = [ordered]@{ auth_mode = 'apikey'; OPENAI_API_KEY = $CmKey } | ConvertTo-Json
    [IO.File]::WriteAllText($Target, $Auth + "`n", (New-Object Text.UTF8Encoding($false)))
    $EmptyKey = -not $CmKey
}

[IO.File]::WriteAllLines($ManagedList, [string[]]@($Targets.Keys))
Write-Host "  Installed $($Targets.Count) items$(if ($Vendor) { ', including vendor skills' })"
if ($EmptyKey) { Write-Host "Set OPENAI_API_KEY in $CodexDir\auth.json to your CodexManager gateway key." }
Write-Host 'Done. Start the CodexManager gateway, then restart Codex and open a new session. Undo with -Restore.'
