# Test update.ps1's range downloader, Codex hook and proxy settings against a local release
# server. Runs the script's functions and body with a stand-in client: no real downloads or installs.
$ErrorActionPreference = 'Stop'
$Source = Split-Path -Parent $PSScriptRoot
$Root = Join-Path ([IO.Path]::GetTempPath()) ('agent-kit update test ' + [IO.Path]::GetRandomFileName())
$OldLocalAppData = $env:LOCALAPPDATA
$Core = $PSVersionTable.PSVersion.Major -ge 6
$OldProxies = @([Net.WebRequest]::DefaultWebProxy, $env:HTTPS_PROXY)
if ($Core) { $OldProxies += [Net.Http.HttpClient]::DefaultProxy }
$Server = $null
$Checks = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:Checks++
}
function Write-Random([string]$Path, [int]$Length) {
    $Bytes = New-Object byte[] $Length
    (New-Object Random).NextBytes($Bytes)
    [IO.File]::WriteAllBytes($Path, $Bytes)
}
function Get-Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
try {
    $Www = Join-Path $Root 'www'
    New-Item -ItemType Directory -Path (Join-Path $Www 'host') -Force | Out-Null
    $Python = 'python'
    foreach ($Candidate in '.venv/Scripts/python.exe', '.venv/bin/python') {
        if (Test-Path -LiteralPath (Join-Path $Source $Candidate)) { $Python = Join-Path $Source $Candidate }
    }
    $PortFile = Join-Path $Root 'port'
    $Server = Start-Process -FilePath $Python -PassThru -NoNewWindow -ArgumentList ('"{0}" "{1}" "{2}"' -f (Join-Path $PSScriptRoot 'range_server.py'), $Www, $PortFile)
    while (-not (Test-Path -LiteralPath $PortFile)) {
        if ($Server.HasExited) { throw 'The range server did not start.' }
        Start-Sleep -Milliseconds 100
    }
    $Base = 'http://127.0.0.1:' + (Get-Content -LiteralPath $PortFile)
    $Log = Join-Path $Www 'requests.log'
    function Get-RangeCount([string]$Path) {
        @(Get-Content -LiteralPath $Log | Where-Object { $_ -like "$Path bytes=*" -and $_ -notlike '* bytes=0-0' }).Count
    }

    $Errors = $null
    $Ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Source 'update.ps1'), [ref]$null, [ref]$Errors)
    Assert (-not $Errors) 'update.ps1 parses'
    foreach ($Function in $Ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        . ([scriptblock]::Create($Function.Extent.Text))
    }
    $env:LOCALAPPDATA = Join-Path $Root 'local'
    $Cache = Join-Path $env:LOCALAPPDATA 'agent-kit/downloads'

    $Blob = Join-Path $Www 'host/blob'
    Write-Random $Blob 10000000
    Set-Content -LiteralPath $Log -Value ''
    Save-Ranges "$Base/host/blob" (Join-Path $Root 'first')
    Assert ((Get-Hash (Join-Path $Root 'first')) -eq (Get-Hash $Blob)) 'assembles the download'
    Assert ((Get-RangeCount '/host/blob') -ge 2) 'downloads in ranges'
    Assert (@(Get-ChildItem -LiteralPath $Cache).Count -eq 0) 'removes finished ranges'

    Set-Content -LiteralPath (Join-Path $Www 'faults') -Value '/host/blob:4194304'
    $Message = ''
    $WarningPreference = 'SilentlyContinue'
    try { Save-Ranges "$Base/host/blob" (Join-Path $Root 'second') } catch { $Message = "$_" }
    $WarningPreference = 'Continue'
    Assert ($Message -like '*run again to resume*') 'asks to resume after a failed range'
    Remove-Item -LiteralPath (Join-Path $Www 'faults')
    Set-Content -LiteralPath $Log -Value ''
    Save-Ranges "$Base/host/blob" (Join-Path $Root 'second')
    Assert ((Get-Hash (Join-Path $Root 'second')) -eq (Get-Hash $Blob)) 'resumes the download'
    Assert ((Get-RangeCount '/host/blob') -eq 1) 'downloads only the missing range'

    # A fake Codex installer under strict mode that reads metadata and downloads its package
    # with a time limit that the slow package server would exceed.
    $Package = Join-Path $Www 'host/codex-package-test.tar.gz'
    Write-Random $Package 6000000
    Set-Content -LiteralPath (Join-Path $Www 'host/latest') -Value '1.2.3'
    Set-Content -LiteralPath (Join-Path $Www 'slow') -Value '/host/codex-package-test.tar.gz'
    $Installer = Join-Path $Root 'install.ps1'
    Set-Content -LiteralPath $Installer -Value @"
[CmdletBinding()]
param([string]`$Release)
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
if ((Invoke-WebRequest -UseBasicParsing -Uri '$Base/host/latest' -TimeoutSec 30).StatusCode -ne 200) { throw 'metadata failed' }
Invoke-WebRequest -UseBasicParsing -Uri '$Base/host/codex-package-test.tar.gz' -OutFile '$Root/package.tar.gz' -TimeoutSec 1
"@
    Set-Content -LiteralPath $Log -Value ''
    & $Installer -Release latest
    Assert ((Get-Hash (Join-Path $Root 'package.tar.gz')) -eq (Get-Hash $Package)) 'downloads the Codex package despite its time limit'
    Assert ((Get-RangeCount '/host/codex-package-test.tar.gz') -ge 2) 'downloads the Codex package in ranges'

    $Script = Join-Path $Source 'update.ps1'
    $Parameter = ''
    try { & $Script -Proxy 65536 } catch { $Parameter = $_.Exception.ParameterName }
    Assert ($Parameter -eq 'Proxy') 'rejects -Proxy 65536'
    $Parameter = ''
    try { & $Script nope } catch { $Parameter = $_.Exception.ParameterName }
    Assert ($Parameter -eq 'Clients') 'binds other arguments to the clients'

    # Run the script body with a stand-in for Claude Code that records the proxy variable for
    # child processes and makes requests through both WebRequest and the web cmdlets.
    $Main = [scriptblock]::Create((@($Ast.EndBlock.Statements | Where-Object {
        $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.Extent.Text }) -join "`n"))
    function Update-Claude {
        $script:ChildProxy = $env:HTTPS_PROXY
        Save-Ranges "$Target/host/blob" (Join-Path $Root 'claude')
        $null = Invoke-RestMethod -Uri "$Target/host/latest"
    }
    function Get-Requests { @(Get-Content -LiteralPath $Log | Where-Object { $_ }) }
    $Clients = @('claude')

    # The host does not resolve, so requests only succeed through -Proxy: the release server.
    $Before = [Net.WebRequest]::DefaultWebProxy
    $Proxy = [int](Get-Content -LiteralPath $PortFile)
    $Target = 'http://agent-kit.invalid'
    Set-Content -LiteralPath $Log -Value ''
    & $Main
    Assert ((Get-Hash (Join-Path $Root 'claude')) -eq (Get-Hash $Blob)) 'downloads through -Proxy'
    Assert (-not (Get-Requests | Where-Object { $_ -notlike '* via proxy' })) 'sends every request through -Proxy'
    Assert ($ChildProxy -eq "http://127.0.0.1:$Proxy") 'hands -Proxy to child processes'
    Assert ([Net.WebRequest]::DefaultWebProxy -eq $Before) 'restores the default proxy'

    # Without -Proxy, requests go directly even when the system proxy and variable are unreachable.
    $Unreachable = New-Object Net.WebProxy 'http://127.0.0.1:9'
    [Net.WebRequest]::DefaultWebProxy = $Unreachable
    if ($Core) { [Net.Http.HttpClient]::DefaultProxy = $Unreachable }
    $env:HTTPS_PROXY = 'http://127.0.0.1:9'
    $Proxy = 0
    $Target = $Base
    Set-Content -LiteralPath $Log -Value ''
    & $Main
    Assert ((Get-Requests).Count -ge 3 -and -not (Get-Requests | Where-Object { $_ -like '* via proxy' })) 'connects directly without -Proxy'
    Assert (-not $ChildProxy) 'clears the proxy variable for child processes'
    Assert ([Net.WebRequest]::DefaultWebProxy -eq $Unreachable -and $env:HTTPS_PROXY -eq 'http://127.0.0.1:9') 'restores the system proxy and variable'
    if ($Core) { Assert ([Net.Http.HttpClient]::DefaultProxy -eq $Unreachable) 'restores the HttpClient proxy' }
    Write-Host "PASS: $Checks checks through update.ps1"
} finally {
    if ($Server) { Stop-Process -Id $Server.Id -Force -ErrorAction SilentlyContinue }
    $env:LOCALAPPDATA = $OldLocalAppData
    [Net.WebRequest]::DefaultWebProxy = $OldProxies[0]
    $env:HTTPS_PROXY = $OldProxies[1]
    if ($Core) { [Net.Http.HttpClient]::DefaultProxy = $OldProxies[2] }
    if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
}
