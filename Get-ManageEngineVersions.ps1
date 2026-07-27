<#
.SYNOPSIS
    Reports the installed version / build of ManageEngine products by reading
    conf\product.conf, and renders an HTML report.

.DESCRIPTION
    ManageEngine products write their identity to a plain key=value file in the
    installation folder:

        <install folder>\conf\product.conf
            product.name=ManageEngine KeyManager Plus
            product.version=7.1.2
            product.build_number=7120
            product.processor_architecture=64

    Reading it needs no API token, no API permission and no running web service,
    which makes it the reliable way to inventory installed versions.

    For each configured product the script locates that file, extracts the version,
    build number and architecture, compares them against the reference values in the
    config, and writes a self-contained HTML report. Results are also emitted as
    objects on the pipeline.

    Written for Windows PowerShell 5.1 (no PowerShell 7 syntax).

.PARAMETER ConfigPath
    Path to the JSON config file. Defaults to config.json next to this script.

.PARAMETER OutputPath
    Path of the HTML report to write. Overrides the value in the config file.

.PARAMETER Show
    Open the HTML report in the default browser when done.

.PARAMETER Product
    Check only the named product(s). Matches the "name" field, case-insensitively,
    and a partial name is enough.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Get-ManageEngineVersions.ps1 -Show

.EXAMPLE
    .\Get-ManageEngineVersions.ps1 -Product "Key Manager" -Verbose

.NOTES
    Products that are not installed can be switched off with "enabled": false in the
    config instead of being deleted.

    The installation folder is found from "installPath", or "confPath" to point at a
    product.conf directly; failing both, the conventional ManageEngine install roots
    and the uninstall registry are searched.

    Note that a service pack does not always rewrite product.conf. The script scans
    every *.conf in the conf folder and reports the highest build number it finds,
    naming the file it came from - but if all of them are stale, the base install is
    what gets reported.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$OutputPath,
    [switch]$Show,
    [string[]]$Product
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Keep in step with the VERSION file. Printed at startup and in the HTML report so the
# running copy identifies itself even if the file was renamed or copied elsewhere.
$script:ToolVersion = '2.0.0'

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
        Write-Host 'Before running again, edit that file and set "installPath" of each product' -ForegroundColor Yellow
        Write-Host 'to its installation folder, or delete the products you do not have.'
        Write-Host 'Products can also be switched off with "enabled": false.'
        Write-Host ''
        Write-Host "Opening $Path ..." -ForegroundColor Green

        try { Start-Process -FilePath 'notepad.exe' -ArgumentList $Path -ErrorAction Stop }
        catch { Write-Host "Could not open an editor automatically - edit $Path yourself." }

        throw 'Config was just created and still holds placeholder values. Edit it, then run this script again.'
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8

    # Get-Content -Raw yields one string, but returns $null for an empty file and an
    # array if -Raw is ever lost. Normalise, because ConvertFrom-Json on an array parses
    # each element as its own document and reports a confusing error on the first line.
    if ($null -eq $raw) {
        throw "Config file $Path is empty. Delete it and run the script again to recreate it from config.sample.json."
    }
    if ($raw -is [array]) { $raw = $raw -join "`r`n" }
    $raw = [string]$raw

    # Strip a UTF-8 BOM: Notepad writes one when saving as UTF-8, and ConvertFrom-Json
    # treats it as a stray character before the opening brace.
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
    $raw = $raw.Trim()

    if ($raw.Length -eq 0) {
        throw "Config file $Path contains no text. Delete it and run the script again to recreate it."
    }

    try {
        $cfg = ConvertFrom-Json -InputObject $raw
    }
    catch {
        # ConvertFrom-Json only names the offending token ("Invalid JSON primitive: https"),
        # never where it is. Find the line so the file can actually be fixed.
        $detail = $_.Exception.Message
        $hint   = ''

        $token = $null
        if ($detail -match 'Invalid JSON primitive:\s*(.+?)\.?\s*$') { $token = $Matches[1].Trim() }

        if ($token) {
            $lines = $raw -split "`r?`n"
            for ($i = 0; $i -lt $lines.Length; $i++) {
                if ($lines[$i] -match [regex]::Escape($token)) {
                    $hint = "`r`n  First line mentioning '$token' is line $($i + 1):`r`n    $($lines[$i].Trim())"
                    break
                }
            }
            $hint += "`r`n  A value like this must be inside double quotes, and every entry except the last needs a trailing comma."
        }

        throw "Config file $Path is not valid JSON: $detail$hint`r`n  Fix it, or delete it and run the script again to recreate it from config.sample.json."
    }

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

# ---------------------------------------------------------------------------
# Version comparison
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Locating and reading conf\product.conf
# ---------------------------------------------------------------------------
function Get-ProductConfPath {
    <#
        Resolves the product.conf for a product, in order of confidence:
          1. "confPath"    - explicit path to product.conf
          2. "installPath" - installation folder, conf\product.conf underneath it
          3. conventional ManageEngine install roots
          4. InstallLocation of a matching entry in the uninstall registry
        Returns the path, or $null when nothing matched.
    #>
    param($Product, [string]$Name)

    $explicit = [string](Get-ConfigValue -Object $Product -Name 'confPath' -Default '')
    if ($explicit) {
        if (Test-Path -LiteralPath $explicit) { return $explicit }
        Write-Verbose "[$Name] confPath does not exist: $explicit"
    }

    $installPath = [string](Get-ConfigValue -Object $Product -Name 'installPath' -Default '')
    if ($installPath) {
        $candidate = Join-Path $installPath 'conf\product.conf'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
        Write-Verbose "[$Name] no product.conf under installPath: $installPath"
    }

    # The installer does not use the display name verbatim - "Key Manager Plus"
    # installs into ...\ManageEngine\KeyManager - so compare on a normalised form
    # rather than guessing a fixed list of spellings.
    $roots = @(
        'C:\ManageEngine',
        'C:\Program Files\ManageEngine',
        'C:\Program Files (x86)\ManageEngine',
        'D:\ManageEngine',
        'D:\Program Files\ManageEngine',
        'E:\ManageEngine'
    )

    $normalise = {
        param([string]$Text)
        $t = ([string]$Text).ToLower()
        $t = $t -replace '[^a-z0-9]', ''
        $t = $t -replace 'plus$', ''
        return $t
    }
    $wanted = & $normalise $Name

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }

        try { $subDirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop }
        catch { continue }

        foreach ($dir in $subDirs) {
            $candidate = Join-Path $dir.FullName 'conf\product.conf'
            if (-not (Test-Path -LiteralPath $candidate)) { continue }

            $folderKey = & $normalise $dir.Name
            if ($folderKey -eq $wanted -or $folderKey -like "*$wanted*" -or $wanted -like "*$folderKey*") {
                return $candidate
            }
        }
    }

    # Last resort: ask Windows where the product was installed.
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($keyPath in $uninstallKeys) {
        try {
            $entries = Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue |
                       Where-Object { $_.DisplayName -and $_.DisplayName -like "*$Name*" -and $_.InstallLocation }
        }
        catch { continue }

        foreach ($entry in @($entries)) {
            $candidate = Join-Path $entry.InstallLocation 'conf\product.conf'
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }

    return $null
}

function Read-ProductConf {
    <#
        Parses a product.conf (plain key=value lines, # for comments) and returns the
        fields of interest, or $null when the file cannot be read.
    #>
    param([string]$Path)

    try {
        $lines = Get-Content -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        Write-Verbose "Could not read ${Path}: $($_.Exception.Message)"
        return $null
    }

    $values = @{}
    foreach ($line in $lines) {
        $text = [string]$line
        if ($text -match '^\s*#') { continue }

        # Split on the first '=' only, so a value containing '=' survives intact.
        $split = $text.IndexOf('=')
        if ($split -lt 1) { continue }

        $key = $text.Substring(0, $split).Trim()
        $val = $text.Substring($split + 1).Trim()
        if ($key) { $values[$key.ToLower()] = $val }
    }

    if ($values.Count -eq 0) { return $null }

    $get = {
        param([string[]]$Names)
        foreach ($n in $Names) {
            if ($values.ContainsKey($n) -and -not [string]::IsNullOrWhiteSpace($values[$n])) {
                return $values[$n]
            }
        }
        return $null
    }

    return [pscustomobject]@{
        Build        = (& $get @('product.build_number', 'build_number', 'buildnumber'))
        Version      = (& $get @('product.version', 'version', 'product.release'))
        Architecture = (& $get @('product.processor_architecture', 'processor_architecture'))
        ProductName  = (& $get @('product.name', 'productname'))
        Path         = $Path
    }
}

function Find-HighestBuildConf {
    <#
        A service pack does not always rewrite product.conf - an install can report
        build 7120 there while the console shows 7130. Scan the conf folder for any
        other file carrying a build number and return the highest one found, so an
        applied patch is not missed.

        Returns a PSCustomObject with Build, BuildNumber, Version and Path, or $null.
    #>
    param([string]$ConfFolder)

    if (-not (Test-Path -LiteralPath $ConfFolder)) { return $null }

    try {
        $files = Get-ChildItem -LiteralPath $ConfFolder -Filter '*.conf' -File -ErrorAction Stop
    }
    catch { return $null }

    $best = $null

    foreach ($file in $files) {
        $parsed = Read-ProductConf -Path $file.FullName
        if (-not $parsed -or -not $parsed.Build) { continue }

        $buildNumber = 0
        if (-not [int]::TryParse(([string]$parsed.Build).Trim(), [ref]$buildNumber)) { continue }

        if ($null -eq $best -or $buildNumber -gt $best.BuildNumber) {
            $best = [pscustomobject]@{
                Build       = $parsed.Build
                BuildNumber = $buildNumber
                Version     = $parsed.Version
                Path        = $file.FullName
            }
        }
    }

    return $best
}

# ---------------------------------------------------------------------------
# Per-product check
# ---------------------------------------------------------------------------
function Test-MeProduct {
    param($Product, [string]$Name)

    $record = [pscustomobject]@{
        Name             = $Name
        Found            = $false
        InstalledVersion = $null
        InstalledBuild   = $null
        Architecture     = $null
        ProductName      = $null
        LatestVersion    = [string](Get-ConfigValue -Object $Product -Name 'latestVersion' -Default '')
        LatestBuild      = [string](Get-ConfigValue -Object $Product -Name 'latestBuild'   -Default '')
        Status           = 'Unknown'
        BuildStatus      = 'Unknown'
        Source           = $null
        Error            = $null
        CheckedAt        = (Get-Date)
    }

    $confPath = Get-ProductConfPath -Product $Product -Name $Name
    if (-not $confPath) {
        $record.Error = 'No product.conf found. Set "installPath" to the installation folder, or "confPath" to the file itself.'
        return $record
    }

    Write-Verbose "[$Name] reading $confPath"
    $conf = Read-ProductConf -Path $confPath

    if (-not $conf -or (-not $conf.Build -and -not $conf.Version)) {
        $record.Error = "Found $confPath but it holds no product.version or product.build_number."
        return $record
    }

    $record.Found            = $true
    $record.InstalledVersion = $conf.Version
    $record.InstalledBuild   = $conf.Build
    $record.Architecture     = $conf.Architecture
    $record.ProductName      = $conf.ProductName
    $record.Source           = $confPath

    # Prefer a higher build recorded by a service pack elsewhere in conf\.
    $higher = Find-HighestBuildConf -ConfFolder (Split-Path -Parent $confPath)
    if ($higher) {
        $current = 0
        [void][int]::TryParse(([string]$conf.Build).Trim(), [ref]$current)
        if ($higher.BuildNumber -gt $current) {
            Write-Verbose "[$Name] $($higher.Path) reports build $($higher.Build), higher than product.conf ($($conf.Build))"
            $record.InstalledBuild = $higher.Build
            if ($higher.Version) { $record.InstalledVersion = $higher.Version }
            $record.Source = $higher.Path
        }
    }

    $record.Status      = Get-VersionStatus -Installed $record.InstalledVersion -Latest $record.LatestVersion
    $record.BuildStatus = Get-VersionStatus -Installed $record.InstalledBuild   -Latest $record.LatestBuild

    # A newer build of the same version still means an update is pending.
    if ($record.Status -eq 'UpToDate' -and $record.BuildStatus -eq 'Outdated') {
        $record.Status = 'Outdated'
    }
    # No version in the file, but a build number that could be compared.
    if ($record.Status -eq 'Unknown' -and $record.BuildStatus -ne 'Unknown') {
        $record.Status = $record.BuildStatus
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
    $missing  = @($Results | Where-Object { -not $_.Found }).Count

    $rows = New-Object System.Collections.ArrayList
    foreach ($r in $Results) {
        $statusClass = 'unknown'
        if (-not $r.Found) {
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
        if (-not $r.Found) { $statusText = 'Not found' }

        $installed = $r.InstalledVersion
        if ([string]::IsNullOrWhiteSpace($installed)) { $installed = '-' }
        $installedBuild = $r.InstalledBuild
        if ([string]::IsNullOrWhiteSpace($installedBuild)) { $installedBuild = '-' }
        $latest = $r.LatestVersion
        if ([string]::IsNullOrWhiteSpace($latest)) { $latest = '-' }
        $latestBuild = $r.LatestBuild
        if ([string]::IsNullOrWhiteSpace($latestBuild)) { $latestBuild = '-' }
        $architecture = $r.Architecture
        if ([string]::IsNullOrWhiteSpace($architecture)) { $architecture = '-' }
        else { $architecture = "$architecture-bit" }

        $subtitle = $r.ProductName
        if ([string]::IsNullOrWhiteSpace($subtitle)) { $subtitle = '' }

        $detail = $r.Source
        if (-not $r.Found) { $detail = $r.Error }
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = '-' }

        $row = @"
      <tr>
        <td class="product">$(ConvertTo-HtmlText $r.Name)<span class="url">$(ConvertTo-HtmlText $subtitle)</span></td>
        <td class="version">$(ConvertTo-HtmlText $installed)</td>
        <td>$(ConvertTo-HtmlText $installedBuild)</td>
        <td>$(ConvertTo-HtmlText $architecture)</td>
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
  table { width: 100%; border-collapse: collapse; min-width: 820px; }
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
  td.version { font-weight: 700; font-size: 15px; }
  td.detail { color: var(--muted); font-size: 12px; max-width: 340px; word-break: break-word; }
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
  footer { color: var(--muted); font-size: 12px; margin-top: 20px; line-height: 1.6; }
</style>
</head>
<body>
<div class="wrap">
  <h1>$(ConvertTo-HtmlText $Title)</h1>
  <div class="sub">Generated $generated on $(ConvertTo-HtmlText $env:COMPUTERNAME) by VersionTool v$(ConvertTo-HtmlText $script:ToolVersion)</div>

  <div class="cards">
    <div class="card"><div class="n">$total</div><div class="l">Products checked</div></div>
    <div class="card ok"><div class="n">$ok</div><div class="l">Up to date</div></div>
    <div class="card warn"><div class="n">$outdated</div><div class="l">Update available</div></div>
    <div class="card error"><div class="n">$missing</div><div class="l">Not found</div></div>
  </div>

  <div class="tablewrap">
    <table>
      <thead>
        <tr>
          <th>Product</th>
          <th>Installed version</th>
          <th>Build</th>
          <th>Arch</th>
          <th>Reference version</th>
          <th>Reference build</th>
          <th>Status</th>
          <th>Source</th>
        </tr>
      </thead>
      <tbody>
$rowsHtml
      </tbody>
    </table>
  </div>

  <footer>
    Values are read from conf\product.conf in each installation folder.
    A service pack does not always rewrite that file, so verify against the product console
    when the exact patch level matters. Reference versions come from the config file.
  </footer>
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
Write-Host ("VersionTool v{0} - {1}" -f $script:ToolVersion, $MyInvocation.MyCommand.Name) -ForegroundColor Cyan

$config = Import-MeConfig -Path $ConfigPath

$title = [string](Get-ConfigValue -Object $config -Name 'reportTitle' -Default 'ManageEngine Version Report')

$outFile = $OutputPath
if ([string]::IsNullOrWhiteSpace($outFile)) {
    $outFile = [string](Get-ConfigValue -Object $config -Name 'outputPath' -Default 'ManageEngine-Versions.html')
}
if (-not [System.IO.Path]::IsPathRooted($outFile)) {
    $outFile = Join-Path (Get-ScriptDirectory) $outFile
}

# Narrow the product list first: not every product in the config is installed here,
# and checking one that is not just produces noise in the report.
#
# NOTE: the loop variable must not be called $product - PowerShell variable names are
# case-insensitive, so it would overwrite the -Product parameter on the first iteration.
$wantedNames = @($Product)

$selected = New-Object System.Collections.ArrayList
$skipped  = New-Object System.Collections.ArrayList

foreach ($productEntry in $config.products) {
    $productName = [string](Get-ConfigValue -Object $productEntry -Name 'name' -Default 'Unknown product')

    # "enabled": false marks a product as not installed here. Absent means enabled.
    $isEnabled = Get-ConfigValue -Object $productEntry -Name 'enabled' -Default $true
    if (-not [bool]$isEnabled) {
        [void]$skipped.Add("$productName (disabled in config)")
        continue
    }

    if ($wantedNames.Count -gt 0) {
        $matched = $false
        foreach ($wanted in $wantedNames) {
            if ($productName -like ('*' + [string]$wanted + '*')) { $matched = $true; break }
        }
        if (-not $matched) {
            [void]$skipped.Add("$productName (not selected by -Product)")
            continue
        }
    }

    [void]$selected.Add($productEntry)
}

if ($skipped.Count -gt 0) {
    Write-Host ("Skipping: {0}" -f ($skipped -join ', ')) -ForegroundColor DarkGray
}
if ($selected.Count -eq 0) {
    throw 'No products left to check. Every product is either disabled in the config or excluded by -Product.'
}

$results = New-Object System.Collections.ArrayList
foreach ($productEntry in $selected) {
    $productName = [string](Get-ConfigValue -Object $productEntry -Name 'name' -Default 'Unknown product')
    Write-Host "Checking $productName ..."

    $record = Test-MeProduct -Product $productEntry -Name $productName
    [void]$results.Add($record)

    if ($record.Found) {
        Write-Host ("  version {0} (build {1}) - {2}" -f `
            $record.InstalledVersion, $record.InstalledBuild, (Get-StatusLabel -Status $record.Status))
        if ($record.Architecture) { Write-Host ("  architecture: {0}-bit" -f $record.Architecture) }
        Write-Host ("  source: {0}" -f $record.Source) -ForegroundColor DarkGray
    } else {
        Write-Warning ("{0}: {1}" -f $productName, $record.Error)
    }
}

$reportPath = New-MeHtmlReport -Results $results.ToArray() -Title $title -Path $outFile
Write-Host ""
Write-Host "Report written to: $reportPath"

if ($Show) {
    try { Start-Process -FilePath $reportPath }
    catch { Write-Warning "Could not open the report automatically: $($_.Exception.Message)" }
}

# Emit the results so the script can be piped into Export-Csv or a monitoring script.
$results.ToArray()
