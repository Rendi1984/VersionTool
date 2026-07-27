<#
.SYNOPSIS
    Reports the installed version and build of every ManageEngine product found on one
    or more servers, and renders an HTML report.

.DESCRIPTION
    ManageEngine products write their identity to a plain key=value file in the
    installation folder:

        <install folder>\conf\product.conf
            product.name=ManageEngine KeyManager Plus
            product.version=7.1.2
            product.build_number=7120
            product.processor_architecture=64

    A product counts as installed when such a file is found. The script looks for it in
    three ways:

      1. Under the conventional ManageEngine installation roots (C:\ManageEngine,
         C:\Program Files\ManageEngine and so on), plus anything in "searchRoots".
      2. For the local machine, the InstallLocation of any uninstall-registry entry
         published by ManageEngine or ZOHO.
      3. For the local machine, the binary path of any installed service that runs from
         a ManageEngine folder.

    No product list to maintain, and a product installed later shows up on its own.

    Settings live in config.json next to the script. It is read as it is; the script never
    rewrites it. Without one, the local machine is inventoried.

    Nothing is queried over the internet, so no outbound firewall rule is needed. Reading a
    remote server goes over SMB (TCP 445) to its administrative share, for example
    \\KMP01\C$\Program Files\ManageEngine\...

    Written for Windows PowerShell 5.1 (no PowerShell 7 syntax).

.PARAMETER ConfigPath
    Path to config.json. Defaults to config.json next to this script.

.PARAMETER ComputerName
    Servers to inventory, overriding the "servers" list in config.json.

.PARAMETER Product
    Report only products whose name contains one of these strings, case-insensitively.

.PARAMETER OutputPath
    Path of the HTML report. Overrides "outputPath" from the config.

.PARAMETER Show
    Open the report in the default browser when done.

.EXAMPLE
    .\Get-ManageEngineVersions.ps1 -Show

    Inventory the servers listed in config.json and open the report.

.EXAMPLE
    .\Get-ManageEngineVersions.ps1 -ComputerName KMP01,ADAUDIT01 -Show

    Inventory two servers without touching the config.

.NOTES
    A service pack does not always rewrite product.conf: one live install reported build
    7120 there while the console showed 7130. The script reads every *.conf in the conf
    folder and reports the highest build number it finds, naming the file it came from -
    but if all of them are stale, the base install is what gets reported. Verify against
    the product console when the exact patch level matters.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string[]]$ComputerName,
    [string[]]$Product,
    [string]$OutputPath,
    [string]$Title,
    [switch]$Show
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Keep in step with the VERSION file. Printed at startup and in the report so the running
# copy identifies itself even if the file was renamed or copied elsewhere.
$script:ToolVersion = '3.0.0'

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
function Get-ScriptDirectory {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Split-Path -Parent $MyInvocation.MyCommand.Definition)
}

function Import-MeConfig {
    <#
        Reads config.json as it is. Returns $null when there is no config file, in which
        case the caller inventories the local machine.
    #>
    param([string]$Path)

    $explicitlyRequested = -not [string]::IsNullOrWhiteSpace($Path)
    if (-not $explicitlyRequested) {
        $Path = Join-Path (Get-ScriptDirectory) 'config.json'
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($explicitlyRequested) { throw "Config file not found: $Path" }
        Write-Verbose 'No config.json next to the script - scanning the local machine.'
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8

    # Get-Content -Raw yields one string, but returns $null for an empty file and an array
    # if -Raw is ever lost. Normalise, because ConvertFrom-Json on an array parses each
    # element as its own document and reports a confusing error on the first line.
    if ($null -eq $raw) { throw "Config file $Path is empty." }
    if ($raw -is [array]) { $raw = $raw -join "`r`n" }
    $raw = [string]$raw

    # Strip a UTF-8 BOM: Notepad writes one when saving as UTF-8, and ConvertFrom-Json
    # treats it as a stray character before the opening brace.
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
    $raw = $raw.Trim()

    if ($raw.Length -eq 0) { throw "Config file $Path contains no text." }

    try {
        return ConvertFrom-Json -InputObject $raw
    }
    catch {
        # ConvertFrom-Json only names the offending token ("Invalid JSON primitive: C"),
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
            $hint += "`r`n  Backslashes in a JSON path must be doubled: D:\\ManageEngine"
        }

        throw "Config file $Path is not valid JSON: $detail$hint"
    }
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
# Paths
# ---------------------------------------------------------------------------
function Get-SearchRoots {
    <#
        Conventional ManageEngine installation roots, plus any extras from the config.
        Local paths; the caller maps them onto a remote server.
    #>
    param([string[]]$Extra)

    $roots = @(
        'C:\ManageEngine',
        'C:\Program Files\ManageEngine',
        'C:\Program Files (x86)\ManageEngine',
        'D:\ManageEngine',
        'D:\Program Files\ManageEngine',
        'E:\ManageEngine'
    )
    if ($Extra) { $roots += $Extra }
    return $roots
}

function ConvertTo-RemotePath {
    <#
        Maps a local path onto a named server's administrative share:
            C:\Program Files\ManageEngine  +  KMP01
            -> \\KMP01\C$\Program Files\ManageEngine

        Returns the path unchanged for the local machine or an already-UNC path.
    #>
    param([string]$Path, [string]$Computer)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ([string]::IsNullOrWhiteSpace($Computer)) { return $Path }
    if ($Computer -eq $env:COMPUTERNAME -or $Computer -eq 'localhost' -or $Computer -eq '.') { return $Path }
    if ($Path.StartsWith('\\')) { return $Path }

    if ($Path -match '^([A-Za-z]):\\?(.*)$') {
        $drive = $Matches[1]
        $rest  = $Matches[2]
        return "\\$Computer\$drive`$\$rest"
    }
    return $Path
}

# ---------------------------------------------------------------------------
# Reading product.conf
# ---------------------------------------------------------------------------
function Read-ProductConf {
    <#
        Parses a product.conf (plain key=value lines, # for comments) and returns the
        fields of interest, or $null when the file cannot be read or holds nothing useful.
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

function Get-HighestBuildInFolder {
    <#
        A service pack does not always rewrite product.conf - an install can report build
        7120 there while the console shows 7130. Read every *.conf in the folder and return
        the one carrying the highest build number.

        Returns an object with Build, BuildNumber, Version and Path, or $null.
    #>
    param([string]$ConfFolder)

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

function Get-LocalInstallHints {
    <#
        Folders that Windows itself says hold a ManageEngine product, for installations
        outside the conventional roots. Two independent sources:

          1. The uninstall registry - InstallLocation of any entry whose DisplayName or
             Publisher mentions ManageEngine or ZOHO.
          2. Installed services - most products register one, and the service binary path
             points into the installation folder.

        Local machine only: both need remote registry / RPC to work across the network,
        which is a heavier dependency than the SMB file read this tool is built on.
    #>
    $hints = New-Object System.Collections.ArrayList

    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($keyPath in $uninstallKeys) {
        try {
            $entries = Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue
        }
        catch { continue }

        foreach ($entry in @($entries)) {
            $name      = [string](Get-ConfigValue -Object $entry -Name 'DisplayName')
            $publisher = [string](Get-ConfigValue -Object $entry -Name 'Publisher')
            $location  = [string](Get-ConfigValue -Object $entry -Name 'InstallLocation')

            if (-not $location) { continue }
            if ($name -notmatch '(?i)manage\s*engine|zoho' -and
                $publisher -notmatch '(?i)manage\s*engine|zoho') { continue }

            [void]$hints.Add($location.TrimEnd('\'))
        }
    }

    try {
        $services = Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
                    Where-Object { $_.PathName -match '(?i)manageengine' }
    }
    catch {
        Write-Verbose "Could not enumerate services: $($_.Exception.Message)"
        $services = @()
    }

    foreach ($service in @($services)) {
        # PathName looks like: "C:\Program Files\ManageEngine\KeyManager\bin\wrapper.exe" -s ...
        $path = [string]$service.PathName
        $match = [regex]::Match($path, '(?i)([A-Z]:\\[^"]*?ManageEngine\\[^\\"]+)')
        if ($match.Success) { [void]$hints.Add($match.Groups[1].Value.TrimEnd('\')) }
    }

    return ($hints | Sort-Object -Unique)
}

# ---------------------------------------------------------------------------
# Per-server scan
# ---------------------------------------------------------------------------
function Get-MeProductsOnServer {
    <#
        Every ManageEngine product found under the search roots on one server. Returns one
        record per product; a server with nothing readable yields a single record saying why.
    #>
    param([string]$Computer, [string[]]$ExtraRoots)

    $results   = New-Object System.Collections.ArrayList
    $rootsSeen = 0

    foreach ($localRoot in (Get-SearchRoots -Extra $ExtraRoots)) {
        $root = ConvertTo-RemotePath -Path $localRoot -Computer $Computer

        if (-not (Test-Path -LiteralPath $root)) {
            Write-Verbose "[$Computer] no such root: $root"
            continue
        }
        $rootsSeen++
        Write-Verbose "[$Computer] scanning $root"

        try { $subDirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop }
        catch {
            Write-Verbose "[$Computer] could not list ${root}: $($_.Exception.Message)"
            continue
        }

        foreach ($dir in $subDirs) {
            $confFolder = Join-Path $dir.FullName 'conf'
            $confPath   = Join-Path $confFolder 'product.conf'
            if (-not (Test-Path -LiteralPath $confPath)) { continue }

            $conf = Read-ProductConf -Path $confPath
            if (-not $conf -or (-not $conf.Build -and -not $conf.Version)) {
                Write-Verbose "[$Computer] $confPath holds no version or build number"
                continue
            }

            $displayName = $conf.ProductName
            if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $dir.Name }

            $record = [pscustomobject]@{
                Server       = $Computer
                Name         = $displayName
                FolderName   = $dir.Name
                Version      = $conf.Version
                Build        = $conf.Build
                Architecture = $conf.Architecture
                InstallPath  = $dir.FullName
                Source       = $confPath
                Found        = $true
                Error        = $null
                CheckedAt    = (Get-Date)
            }

            # Prefer a higher build recorded by a service pack elsewhere in conf\.
            $higher = Get-HighestBuildInFolder -ConfFolder $confFolder
            if ($higher) {
                $current = 0
                [void][int]::TryParse(([string]$conf.Build).Trim(), [ref]$current)
                if ($higher.BuildNumber -gt $current) {
                    Write-Verbose "[$Computer] $($higher.Path) reports build $($higher.Build), higher than product.conf ($($conf.Build))"
                    $record.Build = $higher.Build
                    if ($higher.Version) { $record.Version = $higher.Version }
                    $record.Source = $higher.Path
                }
            }

            [void]$results.Add($record)
        }
    }

    # Windows itself may know about an install outside the conventional roots.
    if ($Computer -eq $env:COMPUTERNAME -or $Computer -eq 'localhost' -or $Computer -eq '.') {
        $seen = @{}
        foreach ($r in $results) {
            if ($r.InstallPath) { $seen[([string]$r.InstallPath).ToLower().TrimEnd('\')] = $true }
        }

        foreach ($hint in (Get-LocalInstallHints)) {
            if ($seen.ContainsKey($hint.ToLower())) { continue }

            $confFolder = Join-Path $hint 'conf'
            $confPath   = Join-Path $confFolder 'product.conf'
            if (-not (Test-Path -LiteralPath $confPath)) { continue }

            $conf = Read-ProductConf -Path $confPath
            if (-not $conf -or (-not $conf.Build -and -not $conf.Version)) { continue }

            Write-Verbose "[$Computer] found via registry/services: $hint"
            $rootsSeen++

            $displayName = $conf.ProductName
            if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = Split-Path -Leaf $hint }

            $record = [pscustomobject]@{
                Server       = $Computer
                Name         = $displayName
                FolderName   = (Split-Path -Leaf $hint)
                Version      = $conf.Version
                Build        = $conf.Build
                Architecture = $conf.Architecture
                InstallPath  = $hint
                Source       = $confPath
                Found        = $true
                Error        = $null
                CheckedAt    = (Get-Date)
            }

            $higher = Get-HighestBuildInFolder -ConfFolder $confFolder
            if ($higher) {
                $current = 0
                [void][int]::TryParse(([string]$conf.Build).Trim(), [ref]$current)
                if ($higher.BuildNumber -gt $current) {
                    $record.Build = $higher.Build
                    if ($higher.Version) { $record.Version = $higher.Version }
                    $record.Source = $higher.Path
                }
            }

            [void]$results.Add($record)
            $seen[$hint.ToLower()] = $true
        }
    }

    if ($results.Count -eq 0) {
        if ($rootsSeen -eq 0) {
            $reason = 'No ManageEngine installation folder was reachable. For a remote server check that it is online, that the admin share (C$) is available and that SMB (TCP 445) is open; add a non-standard location to "searchRoots" in the config.'
        }
        else {
            $reason = 'ManageEngine folders were found but none contained conf\product.conf.'
        }

        [void]$results.Add([pscustomobject]@{
            Server       = $Computer
            Name         = 'No products found'
            FolderName   = $null
            Version      = $null
            Build        = $null
            Architecture = $null
            InstallPath  = $null
            Source       = $null
            Found        = $false
            Error        = $reason
            CheckedAt    = (Get-Date)
        })
    }

    return $results.ToArray()
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

    $installed = @($Results | Where-Object { $_.Found }).Count
    $servers   = @($Results | ForEach-Object { $_.Server } | Sort-Object -Unique).Count
    $failed    = @($Results | Where-Object { -not $_.Found }).Count

    # One block per server: in production each product tends to have its own machine.
    $groups = $Results | Group-Object -Property Server | Sort-Object Name

    $sections = New-Object System.Collections.ArrayList
    foreach ($group in $groups) {
        $rows = New-Object System.Collections.ArrayList

        foreach ($r in ($group.Group | Sort-Object Name)) {
            if (-not $r.Found) {
                $row = @"
      <tr class="missing">
        <td class="product">$(ConvertTo-HtmlText $r.Name)</td>
        <td class="version">-</td>
        <td class="build">-</td>
        <td>-</td>
        <td class="detail">$(ConvertTo-HtmlText $r.Error)</td>
      </tr>
"@
                [void]$rows.Add($row)
                continue
            }

            $version = $r.Version
            if ([string]::IsNullOrWhiteSpace($version)) { $version = '-' }
            $build = $r.Build
            if ([string]::IsNullOrWhiteSpace($build)) { $build = '-' }

            $architecture = $r.Architecture
            if ([string]::IsNullOrWhiteSpace($architecture)) { $architecture = '-' }
            else { $architecture = "$architecture-bit" }

            $row = @"
      <tr>
        <td class="product">$(ConvertTo-HtmlText $r.Name)<span class="sub">$(ConvertTo-HtmlText $r.InstallPath)</span></td>
        <td class="version">$(ConvertTo-HtmlText $version)</td>
        <td class="build">$(ConvertTo-HtmlText $build)</td>
        <td>$(ConvertTo-HtmlText $architecture)</td>
        <td class="detail">$(ConvertTo-HtmlText $r.Source)</td>
      </tr>
"@
            [void]$rows.Add($row)
        }

        $rowsHtml = ($rows -join "`r`n")
        $count = @($group.Group | Where-Object { $_.Found }).Count

        $section = @"
    <div class="server">
      <div class="server-head">
        <span class="server-name">$(ConvertTo-HtmlText $group.Name)</span>
        <span class="server-count">$count product(s)</span>
      </div>
      <div class="tablewrap">
        <table>
          <thead>
            <tr>
              <th>Product</th>
              <th>Version</th>
              <th>Build</th>
              <th>Arch</th>
              <th>Source</th>
            </tr>
          </thead>
          <tbody>
$rowsHtml
          </tbody>
        </table>
      </div>
    </div>
"@
        [void]$sections.Add($section)
    }

    $sectionsHtml = ($sections -join "`r`n")

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
    --panel2: #221f2c;
    --border: #2c2a37;
    --text: #e8e6f0;
    --muted: #9a95ad;
    --accent: #9184d9;
    --ok: #4ec9a0;
    --error: #e06c75;
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
  .wrap { max-width: 1080px; margin: 0 auto; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  .sub-line { color: var(--muted); font-size: 13px; margin-bottom: 24px; }
  .cards { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 28px; }
  .card {
    flex: 1 1 150px;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 14px 16px;
  }
  .card .n { font-size: 24px; font-weight: 600; }
  .card .l { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .06em; }
  .card.ok .n { color: var(--ok); }
  .card.error .n { color: var(--error); }

  /* Vendor block - everything ManageEngine lives inside this one region. */
  .vendor {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 20px;
    margin-bottom: 24px;
  }
  .vendor-head {
    display: flex;
    align-items: baseline;
    gap: 10px;
    padding-bottom: 14px;
    margin-bottom: 18px;
    border-bottom: 2px solid var(--accent);
  }
  .vendor-head .title { font-size: 17px; font-weight: 700; }
  .vendor-head .meta { color: var(--muted); font-size: 12px; }

  .server { margin-bottom: 20px; }
  .server:last-child { margin-bottom: 0; }
  .server-head { display: flex; align-items: baseline; gap: 10px; margin-bottom: 8px; }
  .server-name {
    font-weight: 600;
    font-size: 13px;
    letter-spacing: .04em;
    text-transform: uppercase;
    color: var(--accent);
  }
  .server-count { color: var(--muted); font-size: 12px; }

  .tablewrap {
    background: var(--panel2);
    border: 1px solid var(--border);
    border-radius: 10px;
    overflow-x: auto;
  }
  table { width: 100%; border-collapse: collapse; min-width: 700px; }
  th, td { padding: 11px 14px; text-align: left; border-bottom: 1px solid var(--border); vertical-align: top; }
  th {
    color: var(--muted);
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: .06em;
    font-weight: 600;
  }
  tr:last-child td { border-bottom: none; }
  td.product { font-weight: 600; }
  td.product .sub { display: block; font-weight: 400; color: var(--muted); font-size: 12px; margin-top: 3px; }
  td.version { font-weight: 700; font-size: 16px; color: var(--ok); }
  td.build { font-variant-numeric: tabular-nums; }
  td.detail { color: var(--muted); font-size: 12px; max-width: 380px; word-break: break-word; }
  tr.missing td.version, tr.missing td.build { color: var(--error); }
  footer { color: var(--muted); font-size: 12px; margin-top: 20px; line-height: 1.6; }
</style>
</head>
<body>
<div class="wrap">
  <h1>$(ConvertTo-HtmlText $Title)</h1>
  <div class="sub-line">Generated $generated on $(ConvertTo-HtmlText $env:COMPUTERNAME) by VersionTool v$(ConvertTo-HtmlText $script:ToolVersion)</div>

  <div class="cards">
    <div class="card ok"><div class="n">$installed</div><div class="l">Products installed</div></div>
    <div class="card"><div class="n">$servers</div><div class="l">Servers scanned</div></div>
    <div class="card error"><div class="n">$failed</div><div class="l">Servers with no result</div></div>
  </div>

  <div class="vendor">
    <div class="vendor-head">
      <span class="title">ManageEngine</span>
      <span class="meta">$installed product(s) across $servers server(s)</span>
    </div>
$sectionsHtml
  </div>

  <footer>
    Versions are read from conf\product.conf in each installation folder. Nothing is queried
    over the internet, so no outbound firewall rule is required; reading a remote server uses
    SMB (TCP 445) to its administrative share.
    A service pack does not always rewrite product.conf, so verify against the product console
    when the exact patch level matters.
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

# Distinct name: PowerShell variable names are case-insensitive, so $title and $Title
# would be the same variable and the parameter would be overwritten below.
$reportTitle = $Title
if ([string]::IsNullOrWhiteSpace($reportTitle)) {
    $reportTitle = [string](Get-ConfigValue -Object $config -Name 'reportTitle' -Default 'ManageEngine Version Report')
}

$outFile = $OutputPath
if ([string]::IsNullOrWhiteSpace($outFile)) {
    $outFile = [string](Get-ConfigValue -Object $config -Name 'outputPath' -Default 'ManageEngine-Versions.html')
}
if (-not [System.IO.Path]::IsPathRooted($outFile)) {
    $outFile = Join-Path (Get-ScriptDirectory) $outFile
}

$extraRoots = @(Get-ConfigValue -Object $config -Name 'searchRoots' -Default @())

# -ComputerName wins over the config; an empty list means this machine.
$targets = @($ComputerName)
if ($targets.Count -eq 0) {
    $targets = @(Get-ConfigValue -Object $config -Name 'servers' -Default @())
}
$targets = @($targets | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($targets.Count -eq 0) { $targets = @($env:COMPUTERNAME) }

$results = New-Object System.Collections.ArrayList

foreach ($target in $targets) {
    Write-Host "Scanning $target ..."

    $found = Get-MeProductsOnServer -Computer ([string]$target) -ExtraRoots $extraRoots

    foreach ($record in $found) {
        if ($record.Found -and $Product -and @($Product).Count -gt 0) {
            $matched = $false
            foreach ($wanted in $Product) {
                if ($record.Name -like ('*' + [string]$wanted + '*') -or
                    $record.FolderName -like ('*' + [string]$wanted + '*')) {
                    $matched = $true
                    break
                }
            }
            if (-not $matched) { continue }
        }

        [void]$results.Add($record)

        if ($record.Found) {
            Write-Host ("  {0} - version {1} (build {2})" -f $record.Name, $record.Version, $record.Build)
            Write-Host ("    {0}" -f $record.Source) -ForegroundColor DarkGray
        }
        else {
            Write-Warning ("{0}: {1}" -f $target, $record.Error)
        }
    }
}

$reportPath = New-MeHtmlReport -Results $results.ToArray() -Title $reportTitle -Path $outFile
Write-Host ""
Write-Host "Report written to: $reportPath"

if ($Show) {
    try { Start-Process -FilePath $reportPath }
    catch { Write-Warning "Could not open the report automatically: $($_.Exception.Message)" }
}

# Emit the results so the script can be piped into Export-Csv or a monitoring script.
$results.ToArray()
