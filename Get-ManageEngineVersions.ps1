<#
.SYNOPSIS
    Checks the installed version / build of ManageEngine products via their REST APIs
    and renders an HTML report.

.DESCRIPTION
    Supported products (configurable): ADAudit Plus, ADSelfService Plus, Key Manager Plus.

    For each product the script calls the configured API endpoints in order until one
    returns a parseable response, extracts the version and build number, compares them
    against the "latest" values defined in the config, and writes a self-contained
    HTML report.

    Authentication is token based (ManageEngine AUTHTOKEN). Tokens may be supplied
    per product via:
      1. the "token" field in the config file (not recommended for production), or
      2. an environment variable named by "tokenEnvVar" (recommended).

    Written for Windows PowerShell 5.1 (no PowerShell 7 syntax).

.PARAMETER ConfigPath
    Path to the JSON config file. Defaults to config.json next to this script.

.PARAMETER OutputPath
    Path of the HTML report to write. Overrides the value in the config file.

.PARAMETER Show
    Open the HTML report in the default browser when done.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Get-ManageEngineVersions.ps1 -Show

.EXAMPLE
    .\Get-ManageEngineVersions.ps1 -ConfigPath .\prod.json -OutputPath C:\Reports\me.html

.NOTES
    Tool version: 1.0.0
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$OutputPath,
    [switch]$Show
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# TLS / certificate handling
# ---------------------------------------------------------------------------
function Initialize-Tls {
    param([bool]$SkipCertificateCheck)

    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol
    } catch {
        Write-Verbose "Could not raise SecurityProtocol: $($_.Exception.Message)"
    }

    if (-not $SkipCertificateCheck) { return }

    if (-not ('DsmtCertPolicy' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class DsmtCertPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) {
        return true;
    }
}
'@
    }
    [Net.ServicePointManager]::CertificatePolicy = New-Object DsmtCertPolicy
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
function Get-ScriptDirectory {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Split-Path -Parent $MyInvocation.MyCommand.Definition)
}

function Import-MeConfig {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path (Get-ScriptDirectory) 'config.json'
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        # First run: create config.json from the shipped template rather than making
        # the user do it by hand, then stop so the placeholder values get edited.
        $sample = Join-Path (Get-ScriptDirectory) 'config.sample.json'
        if (-not (Test-Path -LiteralPath $sample)) {
            throw "Config file not found: $Path (and no config.sample.json next to the script to create it from)."
        }

        try {
            Copy-Item -LiteralPath $sample -Destination $Path -ErrorAction Stop
        }
        catch {
            throw "Config file not found: $Path, and creating it from config.sample.json failed: $($_.Exception.Message)"
        }

        Write-Host ''
        Write-Host "Created $Path from config.sample.json." -ForegroundColor Green
        Write-Host ''
        Write-Host 'Before running again, edit that file and:' -ForegroundColor Yellow
        Write-Host '  1. set "baseUrl" of each product to your real server (the defaults are placeholders),'
        Write-Host '     or delete the products you do not use;'
        Write-Host '  2. supply each token by setting the environment variable named in "tokenEnvVar",'
        Write-Host '     for example:  $env:ME_KMP_TOKEN = ''<token>''      (do NOT paste the token into'
        Write-Host '     "tokenEnvVar" itself - that field holds the variable NAME).'
        Write-Host ''
        Write-Host "Opening $Path ..." -ForegroundColor Green

        try { Start-Process -FilePath 'notepad.exe' -ArgumentList $Path -ErrorAction Stop }
        catch { Write-Host "Could not open an editor automatically - edit $Path yourself." }

        throw 'Config was just created and still holds placeholder values. Edit it, then run this script again.'
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $cfg = $raw | ConvertFrom-Json

    if (-not (Get-Member -InputObject $cfg -Name 'products' -MemberType NoteProperty)) {
        throw "Config file $Path has no 'products' array."
    }
    return $cfg
}

function Get-ConfigValue {
    param($Object, [string]$Name, $Default = $null)

    if ($null -eq $Object) { return $Default }
    if (-not (Get-Member -InputObject $Object -Name $Name -MemberType NoteProperty, Property)) {
        return $Default
    }
    $value = $Object.$Name
    if ($null -eq $value) { return $Default }
    if (($value -is [string]) -and [string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

function Test-LooksLikeToken {
    <#
        A tokenEnvVar is supposed to hold the NAME of an environment variable
        (ME_ADAUDIT_TOKEN), not the token itself. Environment variable names are
        short and use letters, digits and underscores; a ManageEngine AUTHTOKEN is
        long and usually contains dashes. Used only to produce a helpful error.
    #>
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value.Length -ge 24) { return $true }
    if ($Value -match '[^A-Za-z0-9_]') { return $true }
    return $false
}

function Resolve-ProductToken {
    <#
        Returns a PSCustomObject with:
          Token - the token string, or $null when it could not be resolved
          Error - why not, phrased so the fix is obvious
    #>
    param($Product)

    $result = [PSCustomObject]@{ Token = $null; Error = $null }

    $token = Get-ConfigValue -Object $Product -Name 'token'
    if ($token) {
        $result.Token = [string]$token
        return $result
    }

    $envVar = [string](Get-ConfigValue -Object $Product -Name 'tokenEnvVar')
    if ([string]::IsNullOrWhiteSpace($envVar)) {
        $result.Error = 'No token configured. Set "tokenEnvVar" to the name of an environment variable holding the token.'
        return $result
    }

    $fromEnv = [Environment]::GetEnvironmentVariable($envVar)
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        $result.Token = $fromEnv
        return $result
    }

    if (Test-LooksLikeToken -Value $envVar) {
        $result.Error = 'The value of "tokenEnvVar" looks like the token itself. That field takes the NAME of an environment variable (for example ME_ADAUDIT_TOKEN); put the token in that variable, or move it into the "token" field instead.'
    }
    else {
        $result.Error = "Environment variable '$envVar' is not set. Set it to the API token of this product, for example: `$env:$envVar = '<token>'"
    }
    return $result
}

# ---------------------------------------------------------------------------
# API calls
# ---------------------------------------------------------------------------
function Join-Url {
    param([string]$BaseUrl, [string]$Path)

    $b = $BaseUrl.TrimEnd('/')
    $p = $Path
    if (-not $p.StartsWith('/')) { $p = '/' + $p }
    return $b + $p
}

function Add-QueryParameter {
    param([string]$Url, [string]$Name, [string]$Value)

    $sep = '?'
    if ($Url.Contains('?')) { $sep = '&' }
    $encoded = [Uri]::EscapeDataString($Value)
    return "$Url$sep$Name=$encoded"
}

function Invoke-MeApi {
    <#
        Calls a single endpoint and returns a PSCustomObject:
        Success, Data, Url, StatusCode, Error
    #>
    param(
        [string]$Url,
        [string]$Token,
        [string]$AuthMode,
        [string]$AuthHeaderName,
        [string]$AuthQueryName,
        [int]$TimeoutSec
    )

    $requestUrl = $Url
    $headers = @{ 'Accept' = 'application/json' }

    if ($Token) {
        if ($AuthMode -eq 'query') {
            $qName = $AuthQueryName
            if ([string]::IsNullOrWhiteSpace($qName)) { $qName = 'AUTHTOKEN' }
            $requestUrl = Add-QueryParameter -Url $requestUrl -Name $qName -Value $Token
        } else {
            $hName = $AuthHeaderName
            if ([string]::IsNullOrWhiteSpace($hName)) { $hName = 'AUTHTOKEN' }
            $headers[$hName] = $Token
        }
    }

    $result = [pscustomobject]@{
        Success    = $false
        Data       = $null
        Url        = $requestUrl
        StatusCode = $null
        Error      = $null
    }

    try {
        $response = Invoke-WebRequest -Uri $requestUrl -Headers $headers -Method Get `
            -TimeoutSec $TimeoutSec -UseBasicParsing
        $result.StatusCode = [int]$response.StatusCode

        $content = $response.Content
        if ([string]::IsNullOrWhiteSpace($content)) {
            $result.Error = 'Empty response body'
            return $result
        }

        $parsed = $null
        try {
            $parsed = $content | ConvertFrom-Json
        } catch {
            $result.Error = 'Response is not valid JSON'
            $result.Data = $content
            return $result
        }

        $result.Data = $parsed
        $result.Success = $true
        return $result
    } catch {
        $ex = $_.Exception
        if ($ex.PSObject.Properties.Name -contains 'Response' -and $ex.Response) {
            try { $result.StatusCode = [int]$ex.Response.StatusCode } catch { }
        }
        $result.Error = $ex.Message
        return $result
    }
}

# ---------------------------------------------------------------------------
# Version extraction
# ---------------------------------------------------------------------------
$script:VersionKeys = @(
    'product_version', 'productversion', 'version', 'ppmversion',
    'server_version', 'appversion', 'product_release'
)
$script:BuildKeys = @(
    'build_number', 'buildnumber', 'build', 'buildno', 'build_no',
    'product_build', 'ppmbuild'
)

function Find-JsonValue {
    <#
        Recursively searches a parsed-JSON object graph for the first property whose
        (lower-cased, non-alphanumeric-stripped) name matches one of $Names.
    #>
    param(
        $Node,
        [string[]]$Names,
        [int]$Depth = 0
    )

    if ($null -eq $Node -or $Depth -gt 8) { return $null }

    if ($Node -is [string] -or $Node -is [valuetype]) { return $null }

    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($item in $Node) {
            $found = Find-JsonValue -Node $item -Names $Names -Depth ($Depth + 1)
            if ($null -ne $found) { return $found }
        }
        return $null
    }

    $props = @()
    try { $props = @($Node.PSObject.Properties) } catch { return $null }

    foreach ($prop in $props) {
        $normalized = ($prop.Name -replace '[^A-Za-z0-9]', '').ToLower()
        foreach ($name in $Names) {
            $target = ($name -replace '[^A-Za-z0-9]', '').ToLower()
            if ($normalized -eq $target) {
                $value = $prop.Value
                if ($null -ne $value -and -not ($value -is [System.Management.Automation.PSCustomObject])) {
                    $text = [string]$value
                    if (-not [string]::IsNullOrWhiteSpace($text)) { return $text.Trim() }
                }
            }
        }
    }

    foreach ($prop in $props) {
        $found = Find-JsonValue -Node $prop.Value -Names $Names -Depth ($Depth + 1)
        if ($null -ne $found) { return $found }
    }

    return $null
}

function ConvertTo-ComparableVersion {
    <#
        Turns "8.2.0", "6403", "Build 6200" into a [version] when possible.
        Returns $null when no numeric form can be derived.
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $match = [regex]::Match($Text, '\d+(\.\d+)*')
    if (-not $match.Success) { return $null }

    $numeric = $match.Value
    $parts = $numeric.Split('.')
    while ($parts.Count -lt 2) { $parts += '0' }
    if ($parts.Count -gt 4) { $parts = $parts[0..3] }

    try { return [version]($parts -join '.') } catch { return $null }
}

function Get-VersionStatus {
    <#
        Returns: UpToDate | Outdated | Ahead | NoReference | Unknown

        NoReference means the installed version was read successfully but the config
        carries no value to compare it against. That is a normal, honest outcome -
        better than inventing a reference version and reporting a false status.
    #>
    param([string]$Installed, [string]$Latest)

    if ([string]::IsNullOrWhiteSpace($Installed)) { return 'Unknown' }
    if ([string]::IsNullOrWhiteSpace($Latest))    { return 'NoReference' }

    $a = ConvertTo-ComparableVersion -Text $Installed
    $b = ConvertTo-ComparableVersion -Text $Latest
    if ($null -eq $a -or $null -eq $b) {
        if ($Installed.Trim() -eq $Latest.Trim()) { return 'UpToDate' }
        return 'Unknown'
    }

    if ($a -eq $b) { return 'UpToDate' }
    if ($a -lt $b) { return 'Outdated' }
    return 'Ahead'
}

# ---------------------------------------------------------------------------
# Per-product check
# ---------------------------------------------------------------------------
function Test-MeProduct {
    param($Product, [int]$TimeoutSec)

    $name    = [string](Get-ConfigValue -Object $Product -Name 'name'    -Default 'Unknown product')
    $baseUrl = [string](Get-ConfigValue -Object $Product -Name 'baseUrl' -Default '')

    $record = [pscustomobject]@{
        Name             = $name
        BaseUrl          = $baseUrl
        Reachable        = $false
        InstalledVersion = $null
        InstalledBuild   = $null
        LatestVersion    = [string](Get-ConfigValue -Object $Product -Name 'latestVersion' -Default '')
        LatestBuild      = [string](Get-ConfigValue -Object $Product -Name 'latestBuild'   -Default '')
        Status           = 'Unknown'
        BuildStatus      = 'Unknown'
        EndpointUsed     = $null
        StatusCode       = $null
        Error            = $null
        CheckedAt        = (Get-Date)
    }

    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $record.Error = 'No baseUrl configured'
        return $record
    }

    $auth = Resolve-ProductToken -Product $Product
    if (-not $auth.Token) {
        $record.Error = $auth.Error
        return $record
    }
    $token = $auth.Token

    $endpoints = @(Get-ConfigValue -Object $Product -Name 'endpoints' -Default @())
    if ($endpoints.Count -eq 0) {
        $record.Error = 'No endpoints configured'
        return $record
    }

    $authMode   = [string](Get-ConfigValue -Object $Product -Name 'authMode'        -Default 'header')
    $authHeader = [string](Get-ConfigValue -Object $Product -Name 'authHeaderName'  -Default 'AUTHTOKEN')
    $authQuery  = [string](Get-ConfigValue -Object $Product -Name 'authQueryName'   -Default 'AUTHTOKEN')

    $errors = New-Object System.Collections.ArrayList

    foreach ($endpoint in $endpoints) {
        $url = Join-Url -BaseUrl $baseUrl -Path ([string]$endpoint)
        Write-Verbose "[$name] GET $url"

        $call = Invoke-MeApi -Url $url -Token $token -AuthMode $authMode `
            -AuthHeaderName $authHeader -AuthQueryName $authQuery -TimeoutSec $TimeoutSec

        if ($null -ne $call.StatusCode) { $record.StatusCode = $call.StatusCode }

        if (-not $call.Success) {
            [void]$errors.Add("$endpoint : $($call.Error)")
            continue
        }

        $version = Find-JsonValue -Node $call.Data -Names $script:VersionKeys
        $build   = Find-JsonValue -Node $call.Data -Names $script:BuildKeys

        if ([string]::IsNullOrWhiteSpace($version) -and [string]::IsNullOrWhiteSpace($build)) {
            [void]$errors.Add("$endpoint : responded but contained no version/build field")
            continue
        }

        $record.Reachable        = $true
        $record.InstalledVersion = $version
        $record.InstalledBuild   = $build
        $record.EndpointUsed     = [string]$endpoint
        break
    }

    if (-not $record.Reachable) {
        $record.Error = ($errors -join ' | ')
        return $record
    }

    $record.Status      = Get-VersionStatus -Installed $record.InstalledVersion -Latest $record.LatestVersion
    $record.BuildStatus = Get-VersionStatus -Installed $record.InstalledBuild   -Latest $record.LatestBuild

    # A newer build of the same version still means an update is pending.
    if ($record.Status -eq 'UpToDate' -and $record.BuildStatus -eq 'Outdated') {
        $record.Status = 'Outdated'
    }

    return $record
}

# ---------------------------------------------------------------------------
# HTML report
# ---------------------------------------------------------------------------
function ConvertTo-HtmlText {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $out = $Text -replace '&', '&amp;'
    $out = $out -replace '<', '&lt;'
    $out = $out -replace '>', '&gt;'
    $out = $out -replace '"', '&quot;'
    return $out
}

function Get-StatusLabel {
    param([string]$Status)

    switch ($Status) {
        'UpToDate'    { return 'Up to date' }
        'Outdated'    { return 'Update available' }
        'Ahead'       { return 'Newer than reference' }
        'NoReference' { return 'Installed (no reference set)' }
        default       { return 'Unknown' }
    }
}

function New-MeHtmlReport {
    param(
        [object[]]$Results,
        [string]$Title,
        [string]$Path
    )

    $generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    $total    = @($Results).Count
    $ok       = @($Results | Where-Object { $_.Status -eq 'UpToDate' }).Count
    $outdated = @($Results | Where-Object { $_.Status -eq 'Outdated' }).Count
    $failed   = @($Results | Where-Object { -not $_.Reachable }).Count

    $rows = New-Object System.Collections.ArrayList
    foreach ($r in $Results) {
        $statusClass = 'unknown'
        if (-not $r.Reachable) {
            $statusClass = 'error'
        } else {
            switch ($r.Status) {
                'UpToDate'    { $statusClass = 'ok' }
                'Outdated'    { $statusClass = 'warn' }
                'Ahead'       { $statusClass = 'info' }
                'NoReference' { $statusClass = 'info' }
                default       { $statusClass = 'unknown' }
            }
        }

        $statusText = Get-StatusLabel -Status $r.Status
        if (-not $r.Reachable) { $statusText = 'Unreachable' }

        $installed = $r.InstalledVersion
        if ([string]::IsNullOrWhiteSpace($installed)) { $installed = '-' }
        $installedBuild = $r.InstalledBuild
        if ([string]::IsNullOrWhiteSpace($installedBuild)) { $installedBuild = '-' }
        $latest = $r.LatestVersion
        if ([string]::IsNullOrWhiteSpace($latest)) { $latest = '-' }
        $latestBuild = $r.LatestBuild
        if ([string]::IsNullOrWhiteSpace($latestBuild)) { $latestBuild = '-' }

        $detail = $r.EndpointUsed
        if (-not $r.Reachable) { $detail = $r.Error }
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = '-' }

        $row = @"
      <tr>
        <td class="product">$(ConvertTo-HtmlText $r.Name)<span class="url">$(ConvertTo-HtmlText $r.BaseUrl)</span></td>
        <td>$(ConvertTo-HtmlText $installed)</td>
        <td>$(ConvertTo-HtmlText $installedBuild)</td>
        <td>$(ConvertTo-HtmlText $latest)</td>
        <td>$(ConvertTo-HtmlText $latestBuild)</td>
        <td><span class="badge $statusClass">$(ConvertTo-HtmlText $statusText)</span></td>
        <td class="detail">$(ConvertTo-HtmlText $detail)</td>
      </tr>
"@
        [void]$rows.Add($row)
    }

    $rowsHtml = ($rows -join "`r`n")

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(ConvertTo-HtmlText $Title)</title>
<style>
  :root {
    --bg: #14131a;
    --panel: #1c1b24;
    --border: #2c2a37;
    --text: #e8e6f0;
    --muted: #9a95ad;
    --accent: #9184d9;
    --ok: #4ec9a0;
    --warn: #e0a34a;
    --error: #e06c75;
    --info: #6aa8e0;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    padding: 32px 24px;
    background: var(--bg);
    color: var(--text);
    font-family: "Segoe UI", Inter, Arial, sans-serif;
    font-size: 14px;
  }
  .wrap { max-width: 1100px; margin: 0 auto; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  .sub { color: var(--muted); font-size: 13px; margin-bottom: 24px; }
  .cards { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 24px; }
  .card {
    flex: 1 1 160px;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 14px 16px;
  }
  .card .n { font-size: 24px; font-weight: 600; }
  .card .l { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .06em; }
  .card.ok .n { color: var(--ok); }
  .card.warn .n { color: var(--warn); }
  .card.error .n { color: var(--error); }
  .tablewrap {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 10px;
    overflow-x: auto;
  }
  table { width: 100%; border-collapse: collapse; min-width: 860px; }
  th, td { padding: 12px 14px; text-align: left; border-bottom: 1px solid var(--border); vertical-align: top; }
  th {
    color: var(--muted);
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: .06em;
    font-weight: 600;
  }
  tr:last-child td { border-bottom: none; }
  td.product { font-weight: 600; }
  td.product .url { display: block; font-weight: 400; color: var(--muted); font-size: 12px; margin-top: 3px; }
  td.detail { color: var(--muted); font-size: 12px; max-width: 320px; word-break: break-word; }
  .badge {
    display: inline-block;
    padding: 3px 10px;
    border-radius: 999px;
    font-size: 12px;
    font-weight: 600;
    border: 1px solid transparent;
    white-space: nowrap;
  }
  .badge.ok { color: var(--ok); border-color: var(--ok); }
  .badge.warn { color: var(--warn); border-color: var(--warn); }
  .badge.error { color: var(--error); border-color: var(--error); }
  .badge.info { color: var(--info); border-color: var(--info); }
  .badge.unknown { color: var(--muted); border-color: var(--muted); }
  footer { color: var(--muted); font-size: 12px; margin-top: 20px; }
</style>
</head>
<body>
<div class="wrap">
  <h1>$(ConvertTo-HtmlText $Title)</h1>
  <div class="sub">Generated $generated on $(ConvertTo-HtmlText $env:COMPUTERNAME)</div>

  <div class="cards">
    <div class="card"><div class="n">$total</div><div class="l">Products checked</div></div>
    <div class="card ok"><div class="n">$ok</div><div class="l">Up to date</div></div>
    <div class="card warn"><div class="n">$outdated</div><div class="l">Update available</div></div>
    <div class="card error"><div class="n">$failed</div><div class="l">Unreachable</div></div>
  </div>

  <div class="tablewrap">
    <table>
      <thead>
        <tr>
          <th>Product</th>
          <th>Installed version</th>
          <th>Installed build</th>
          <th>Reference version</th>
          <th>Reference build</th>
          <th>Status</th>
          <th>Endpoint / error</th>
        </tr>
      </thead>
      <tbody>
$rowsHtml
      </tbody>
    </table>
  </div>

  <footer>Reference versions come from the config file - keep them current to make the status column meaningful.</footer>
</div>
</body>
</html>
"@

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
    return $Path
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$config = Import-MeConfig -Path $ConfigPath

$skipCert = [bool](Get-ConfigValue -Object $config -Name 'skipCertificateCheck' -Default $false)
Initialize-Tls -SkipCertificateCheck $skipCert

$timeout = [int](Get-ConfigValue -Object $config -Name 'timeoutSec' -Default 30)
$title   = [string](Get-ConfigValue -Object $config -Name 'reportTitle' -Default 'ManageEngine Version Report')

$outFile = $OutputPath
if ([string]::IsNullOrWhiteSpace($outFile)) {
    $outFile = [string](Get-ConfigValue -Object $config -Name 'outputPath' -Default 'ManageEngine-Versions.html')
}
if (-not [System.IO.Path]::IsPathRooted($outFile)) {
    $outFile = Join-Path (Get-ScriptDirectory) $outFile
}

$results = New-Object System.Collections.ArrayList
foreach ($product in $config.products) {
    $productName = [string](Get-ConfigValue -Object $product -Name 'name' -Default 'Unknown product')
    Write-Host "Checking $productName ..."
    $record = Test-MeProduct -Product $product -TimeoutSec $timeout
    [void]$results.Add($record)

    if ($record.Reachable) {
        Write-Host ("  version {0} (build {1}) - {2}" -f `
            $record.InstalledVersion, $record.InstalledBuild, (Get-StatusLabel -Status $record.Status))
    } else {
        # Name the product: Write-Warning prefixes "WARNING:" and PowerShell may wrap the
        # line, which visually detaches it from the "Checking <name> ..." line above.
        Write-Warning ("{0} failed: {1}" -f $productName, $record.Error)
    }
}

$reportPath = New-MeHtmlReport -Results $results.ToArray() -Title $title -Path $outFile
Write-Host ""
Write-Host "Report written to: $reportPath"

if ($Show) {
    Start-Process $reportPath
}

$results.ToArray() | Select-Object Name, InstalledVersion, InstalledBuild, LatestVersion, Status, EndpointUsed
