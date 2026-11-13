# Install or update Claude Code and Codex to the latest version through their official
# installers, downloading the large release files in parallel ranges so that slow links do not
# run into installer time limits. Compatible with Windows PowerShell 5.1; keep this file ASCII.
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateRange(1, 65535)]
    [int]$Port,
    [Parameter(ValueFromRemainingArguments = $true)]
    [ValidateSet('claude', 'codex')]
    [string[]]$Clients = @('claude', 'codex')
)

$ErrorActionPreference = 'Stop'
# Checked here rather than as a mandatory parameter, which would prompt for it instead.
if (-not $Port) { throw 'Missing -Port PORT: every request goes through the proxy at http://127.0.0.1:PORT.' }

# Download $Uri to $OutFile in 4 MiB ranges over up to 16 connections. Finished ranges stay
# in the cache until $OutFile is assembled, so running again resumes the download.
# It also runs inside the Codex installer: read no caller variables and stay valid under the
# installer's Set-StrictMode -Version Latest.
function Save-Ranges([string]$Uri, [string]$OutFile) {
    function Test-Range($Range) {
        $File = Get-Item -LiteralPath $Range.Path -ErrorAction SilentlyContinue
        $File -and $File.Length -eq $Range.End - $Range.Start + 1
    }
    $ProgressPreference = 'Continue'
    $Name = $Uri.Substring($Uri.LastIndexOf('/') + 1)
    $Parts = Join-Path $env:LOCALAPPDATA ('agent-kit\downloads\' + ($Uri -replace '[^A-Za-z0-9._-]', '_'))
    for ($Attempt = 0; ; $Attempt++) {
        try {
            $Probe = [Net.HttpWebRequest]::Create($Uri)
            $Probe.AddRange([long]0, [long]0)
            $Response = $Probe.GetResponse()
            break
        } catch {
            if ($Attempt -ge 5) { throw }
            Start-Sleep -Seconds 1
        }
    }
    $Size = $Response.Headers['Content-Range']
    $Response.Close()
    if ($Size -notmatch '^bytes 0-0/(\d+)$') { throw "Could not download in ranges: $Uri" }
    $Total = [long]$Matches[1]
    New-Item -ItemType Directory -Force -Path $Parts | Out-Null
    $Ranges = @(for ($Start = [long]0; $Start -lt $Total; $Start += 4MB) {
        [pscustomobject]@{ Start = $Start; End = [Math]::Min($Start + 4MB, $Total) - 1; Path = Join-Path $Parts $Start }
    })
    $Missing = @($Ranges | Where-Object { -not (Test-Range $_) })
    $Cached = $Ranges.Count - $Missing.Count
    Write-Host "Downloading $Name ($([Math]::Ceiling($Total / 1MB)) MiB, $Cached/$($Ranges.Count) ranges cached)"

    # Each range retries on its own; 30 seconds without data counts as a failed attempt.
    $Fetch = {
        param([string]$Uri, [long]$Start, [long]$End, [string]$Path)
        for ($Attempt = 0; ; $Attempt++) {
            try {
                $Request = [Net.HttpWebRequest]::Create($Uri)
                $Request.AddRange($Start, $End)
                $Request.ReadWriteTimeout = 30000
                $Response = $Request.GetResponse()
                try {
                    $File = [IO.File]::Create("$Path.tmp")
                    try {
                        $Response.GetResponseStream().CopyTo($File)
                        $Length = $File.Length
                    } finally { $File.Close() }
                } finally { $Response.Close() }
                if ($Length -ne $End - $Start + 1) { throw "Range $Start-$End returned $Length bytes." }
                Move-Item -LiteralPath "$Path.tmp" -Destination $Path -Force -ErrorAction Stop
                return
            } catch {
                if ($Attempt -ge 5) { throw }
                Start-Sleep -Seconds 1
            }
        }
    }
    [Net.ServicePointManager]::DefaultConnectionLimit = 16
    $Pool = [RunspaceFactory]::CreateRunspacePool(1, 16)
    $Pool.Open()
    try {
        $Jobs = @(foreach ($Range in $Missing) {
            $Shell = [PowerShell]::Create().AddScript($Fetch).AddArgument($Uri).AddArgument($Range.Start).AddArgument($Range.End).AddArgument($Range.Path)
            $Shell.RunspacePool = $Pool
            [pscustomobject]@{ Shell = $Shell; Handle = $Shell.BeginInvoke() }
        })
        while (@($Jobs | Where-Object { -not $_.Handle.IsCompleted }).Count) {
            $Done = [long]0
            foreach ($File in Get-ChildItem -LiteralPath $Parts -File) { $Done += $File.Length }
            Write-Progress -Activity "Downloading $Name" -Status ('{0} / {1} MiB' -f [Math]::Floor($Done / 1MB), [Math]::Ceiling($Total / 1MB)) -PercentComplete ([Math]::Min(100, $Done * 100 / $Total))
            Start-Sleep -Milliseconds 500
        }
        Write-Progress -Activity "Downloading $Name" -Completed
        foreach ($Job in $Jobs) {
            try { $Job.Shell.EndInvoke($Job.Handle) | Out-Null } catch { Write-Warning "$_" }
            $Job.Shell.Dispose()
        }
    } finally {
        $Pool.Close()
    }

    foreach ($Range in $Ranges) {
        if (-not (Test-Range $Range)) { throw "Download incomplete; run again to resume: $Uri" }
    }
    $Output = [IO.File]::Create($OutFile)
    try {
        foreach ($Range in $Ranges) {
            $Part = [IO.File]::OpenRead($Range.Path)
            try { $Part.CopyTo($Output) } finally { $Part.Close() }
        }
    } finally { $Output.Close() }
    Remove-Item -LiteralPath $Parts -Recurse -Force
}

function Update-Claude {
    $Releases = 'https://downloads.claude.ai/claude-code-releases'
    $Version = "$(Invoke-RestMethod -Uri "$Releases/latest")".Trim()
    if ($Version -notmatch '^\d+\.\d+\.\d+') { throw 'Could not read the latest Claude Code version.' }
    $Launcher = Join-Path $HOME '.local\bin\claude.exe'
    if ((Test-Path -LiteralPath $Launcher) -and "$(& $Launcher --version)".Split(' ')[0] -eq $Version) {
        Write-Host "Claude Code $Version is up to date."
        return
    }
    # Choose the build the official installer would.
    $Platform = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win32-arm64' } else { 'win32-x64' }
    $Checksum = (Invoke-RestMethod -Uri "$Releases/$Version/manifest.json").platforms.$Platform.checksum
    if (-not $Checksum) { throw "Claude Code $Version has no build for $Platform." }
    Write-Host "Updating Claude Code to $Version"
    $Binary = Join-Path $Work "claude-$Version.exe"
    Save-Ranges "$Releases/$Version/$Platform/claude.exe" $Binary
    if ((Get-FileHash -LiteralPath $Binary -Algorithm SHA256).Hash -ne $Checksum) {
        throw "Claude Code $Version failed checksum verification."
    }
    # The install command copies a running binary of the requested version instead of downloading it.
    & $Binary install $Version
    if ($LASTEXITCODE -ne 0) { throw "Claude Code install failed (exit $LASTEXITCODE)." }
}

function Update-Codex {
    $Installer = Join-Path $Work 'codex-install.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://chatgpt.com/codex/install.ps1' -OutFile $Installer
    Write-Host 'Updating Codex'
    # The official installer downloads its package with Invoke-WebRequest -OutFile. While it runs,
    # package downloads go to Save-Ranges and every other request to the real cmdlet.
    function Invoke-WebRequest {
        param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing, [int]$TimeoutSec)
        if ($OutFile -and $Uri -match '\.(tar\.gz|tgz)$') { Save-Ranges $Uri $OutFile }
        else { Microsoft.PowerShell.Utility\Invoke-WebRequest @PSBoundParameters }
    }
    $Interactive = $env:CODEX_NON_INTERACTIVE
    $env:CODEX_NON_INTERACTIVE = '1'
    try { & $Installer -Release latest } finally { $env:CODEX_NON_INTERACTIVE = $Interactive }
}

# Send every request through the proxy, even when a system proxy or proxy variable says
# otherwise. The variables also reach claude.exe; NO_PROXY could exempt hosts from the proxy,
# so it is cleared, and as Windows ignores the case of variable names, so is no_proxy. These
# settings belong to the whole PowerShell process, which may be an open session, so they are
# restored afterwards.
$ProxyUri = "http://127.0.0.1:$Port"
$WebProxy = New-Object Net.WebProxy $ProxyUri
$ProxyVariables = @{ HTTP_PROXY = $ProxyUri; HTTPS_PROXY = $ProxyUri; ALL_PROXY = $ProxyUri; NO_PROXY = $null }
$Saved = @{ WebRequest = [Net.WebRequest]::DefaultWebProxy }
# PowerShell 7 web cmdlets use HttpClient instead of WebRequest. Save both before changing
# the variables, which the first read of either default can pick up.
if ($PSVersionTable.PSVersion.Major -ge 6) { $Saved.HttpClient = [Net.Http.HttpClient]::DefaultProxy }
foreach ($Name in $ProxyVariables.Keys) {
    $Saved[$Name] = [Environment]::GetEnvironmentVariable($Name)
    [Environment]::SetEnvironmentVariable($Name, $ProxyVariables[$Name])
}
[Net.WebRequest]::DefaultWebProxy = $WebProxy
if ($Saved.Contains('HttpClient')) { [Net.Http.HttpClient]::DefaultProxy = $WebProxy }
$Work = Join-Path ([IO.Path]::GetTempPath()) ('agent-kit-update-' + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $Work | Out-Null
try {
    foreach ($Client in $Clients) {
        if ($Client -eq 'claude') { Update-Claude } else { Update-Codex }
    }
} finally {
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($Name in $ProxyVariables.Keys) { [Environment]::SetEnvironmentVariable($Name, $Saved[$Name]) }
    [Net.WebRequest]::DefaultWebProxy = $Saved.WebRequest
    if ($Saved.Contains('HttpClient')) { [Net.Http.HttpClient]::DefaultProxy = $Saved.HttpClient }
}
