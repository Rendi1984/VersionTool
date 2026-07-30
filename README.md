# VersionTool - infrastructure version inventory

Current version: see [`VERSION`](VERSION).

Collects the installed version and build of the systems in the environment and writes a
self-contained HTML report, grouped by vendor and then by server.

Supported today:

| Vendor | Covers | How |
|---|---|---|
| **ManageEngine** | Every product found - ADAudit Plus, ADSelfService Plus, Key Manager Plus, ADManager Plus, ... | Reads `conf\product.conf` on disk. No credentials |
| **VMware** | vCenter Server, and the ESXi hosts it manages | vSphere REST API, falling back to PowerCLI. Needs credentials |
| **Windows** | The OS version of a Windows server - what `winver` shows | Registry (remote registry for a remote server), falling back to WMI |
| **Active Directory** | Domain controller OS versions, replication health, FSMO roles | Registry/WMI, `repadmin /replsum`, .NET AD classes |

There is no ManageEngine product list to maintain: everything found under the installation
roots is reported, so a product installed later shows up on its own.

## How it knows a product is installed

A product counts as installed when `conf\product.conf` is found under its folder. The script
looks in three places, so an install outside the usual location is still picked up:

| # | Source | Covers |
|---|---|---|
| 1 | The conventional roots - `C:\ManageEngine`, `C:\Program Files\ManageEngine`, the x86 and D:/E: equivalents - plus anything in `searchRoots` | Local and remote |
| 2 | Uninstall registry: `InstallLocation` of any entry whose DisplayName or Publisher mentions ManageEngine or ZOHO | Local only |
| 3 | Installed services: the binary path of any service running from a ManageEngine folder | Local only |

Sources 2 and 3 need the registry and the service database, which are not available over a
plain file share. **For a remote server only source 1 applies**, so an install in an unusual
place on a remote machine has to be added to `searchRoots`.

Nothing is inferred from the product being *running* - a stopped service still reports its
version, because the answer comes from a file on disk.

## How the version is read

ManageEngine products write their identity to a plain key=value file in the installation
folder:

```
C:\Program Files\ManageEngine\KeyManager\conf\product.conf

  product.name=ManageEngine KeyManager Plus
  product.version=7.1.2
  product.build_number=7120
  product.processor_architecture=64
```

Reading it needs no API token, no API permission and no running web service.

**Nothing is queried over the internet.** The report states what is installed - it does not
check whether a newer release exists, so there is no outbound firewall rule to open and the
tool works in a fully disconnected environment.

## Firewall and permissions

| Scenario | What is needed |
|---|---|
| Local machine | Nothing. Read access to the installation folder - run elevated if `C:\Program Files` is restricted |
| Remote server | **SMB, TCP 445** from the machine running the script to the target, the administrative share (`C$`) enabled, and an account with local administrator rights on the target |
| Internet | **Nothing.** No outbound rule, no proxy, no DNS |

A remote read is an ordinary UNC file read:

```
\\KMP01\C$\Program Files\ManageEngine\KeyManager\conf\product.conf
```

If that path opens in Explorer, the script will work.

## Run

```powershell
# infrastructure health: DCs, replication, FSMO
.\Get-VersionInventory.ps1 -Infrastructure -Show

# system versions
.\Get-VersionInventory.ps1 -System VMware -IncludeEsxi -Show

# both
.\Get-VersionInventory.ps1 -Infrastructure -System ManageEngine,VMware -Show
```

Options:

**Infrastructure checks**

- `-Infrastructure` - domain controllers, AD replication (`repadmin /replsum`) and FSMO role
  holders; fills the Infrastructure Check tab

**System versions**

- `-System <name>` - `ManageEngine`, `VMware`, `Windows` or `All` (tab-completes). Targets come
  from `config.json` unless overridden below. More systems join this list as they are added
- `-IncludeEsxi` - with VMware, also list the ESXi hosts of each vCenter (needs PowerCLI)

**Target overrides** (optional - otherwise `config.json` is used)

- `-ComputerName <names>` - ManageEngine servers to scan
- `-VCenter <names>` - vCenter servers to query
- `-WindowsServer <names>` - Windows servers to read the OS version of
- `-Product <name>` - only ManageEngine products whose name contains this string

**General**

- `-Show` - open the report when finished
- `-OutputPath <path>` / `-ConfigPath <path>` / `-Title <text>`
- `-NonInteractive` - never prompt or install (scheduled tasks)
- `-InstallPowerCLI` - agree up front to installing PowerCLI if it is needed
- `-Verbose` - log every path searched and call attempted

Run with no parameters (and an empty config) and the script prints this list instead of
producing an empty report.

Typical output:

```
VersionTool v3.2.0 - Get-VersionInventory.ps1
Scanning KMP01 ...
  ManageEngine KeyManager Plus - version 7.1.2 (build 7120)
    \\KMP01\C$\Program Files\ManageEngine\KeyManager\conf\product.conf

Report written to: C:\Temp\VersionTool\ManageEngine-Versions.html
```

Results are also emitted as objects, so the script can be piped into `Export-Csv` or called
from a larger monitoring script.

## config.json

Read as it is; the script never rewrites it. It is optional - without it the local machine
is scanned.

```json
{
  "reportTitle": "Infrastructure Version Report",
  "outputPath": "Version-Report.html",
  "servers": ["KMP01", "ADAUDIT01", "ADSSP01"],
  "searchRoots": [],
  "vcenters": ["vcenter01.lab.local"],
  "includeEsxi": false,
  "windowsServers": [],
  "domainControllers": true,
  "replicationSummary": false,
  "fsmoRoles": false,
  "credentialFolder": "",
  "skipCertificateCheck": true,
  "timeoutSec": 30
}
```

| Field | Meaning |
|---|---|
| `reportTitle` | Heading of the report |
| `outputPath` | Where the HTML is written; relative paths are next to the script |
| `servers` | Servers to scan. **Empty (`[]`) means the machine the script runs on** - the normal setup when the tool sits on one of the product servers |
| `searchRoots` | Extra folders to search, for installations outside the conventional locations, e.g. `["F:\\Apps\\ManageEngine"]` |
| `vcenters` | vCenter hostnames to query. Empty means VMware is skipped entirely |
| `includeEsxi` | Also list the ESXi hosts of each vCenter (needs PowerCLI). Default `false` |
| `windowsServers` | Windows servers to report the OS version of. Empty means the Windows check is skipped |
| `domainControllers` | `true` auto-discovers every DC in the domain and reports its OS version |
| `replicationSummary` | `true` runs `repadmin /replsum` and shows it under Infrastructure Check |
| `fsmoRoles` | `true` shows the FSMO role holders under Infrastructure Check |
| `credentialFolder` | Where encrypted vCenter credentials are stored. Empty means `credentials\` next to the script |
| `skipCertificateCheck` | Accept vCenter's self-signed certificate. Default `true` |
| `timeoutSec` | Per REST call. Default 30 |

Backslashes in JSON must be doubled.

Roots searched by default: `C:\ManageEngine`, `C:\Program Files\ManageEngine`,
`C:\Program Files (x86)\ManageEngine`, `D:\ManageEngine`, `D:\Program Files\ManageEngine`,
`E:\ManageEngine`.

## The report

The report opens on the **Infrastructure Check** tab; a **Versions** tab appears next to it
only when a version check was requested.

- **Infrastructure Check** (always present, shown first) - general health checks that are not a
  version, each in its own block, in this order:
  - **Domain Controllers** - each DC with its OS version and build.
  - **AD replication** - `repadmin /replsum`, with a healthy / failures-detected badge.
  - **FSMO role holders** - the five roles and which DC holds each.
  All three run together with `-Infrastructure`, or via the matching config flags
  (`domainControllers`, `replicationSummary`, `fsmoRoles`) for a scheduled run.
- **Versions** (only when a version check is requested) - one region per vendor (ManageEngine,
  VMware, Windows), subdivided by server, a row per item: name, version, build, IP address and
  source. Summary cards count items found, vendors, servers queried and anything with no result.

A bare run therefore produces only the Infrastructure Check tab; asking for `servers`,
`vcenters` or `windowsServers` adds the Versions tab.

`-Infrastructure -System All` runs everything. The AD checks discover their own targets; the
version checks run for whatever the config lists - they do not invent servers.

Nothing in the report claims to know whether a newer release exists: there is no reference
version and no status column, because the tool never contacts the vendors.

## Infrastructure Check: AD replication

**FSMO role holders** are read via the .NET ActiveDirectory classes (no RSAT), showing which DC
holds each of Schema Master, Domain Naming Master, PDC Emulator, RID Master and Infrastructure
Master.

**AD replication** runs `repadmin /replsum`, which summarises replication health across all DCs.
`repadmin` ships with the AD DS role / RSAT AD DS tools. If it is not on the machine running the
script, a domain controller is located and `repadmin` is run there over PowerShell remoting
(WinRM) instead - the block notes which host answered. A non-zero fails count flips the badge to
"failures detected".

## Caveat: product.conf can lag behind a service pack

On a live Key Manager Plus install, `product.conf` reported build **7120** while the console's
About dialog showed **7130** - the service pack had not rewritten the file.

The script reads every `*.conf` in the `conf` folder and reports the highest build number it
finds, naming the file in the Source column. If all of them are stale, the base install is
what gets reported. Verify against the product console when the exact patch level matters,
for example before applying a security update.

## Troubleshooting

**"No ManageEngine installation folder was reachable"**

For a remote server, test the path by hand:

```powershell
Test-Path \\KMP01\C$\Program Files\ManageEngine
```

If that fails it is SMB, the admin share or permissions - not the script. For a local run,
the install may be outside the default roots; add it to `searchRoots`, or find it with:

```powershell
Get-ChildItem C:\ -Filter product.conf -Recurse -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName
```

**"ManageEngine folders were found but none contained conf\product.conf"**

The folder layout differs from the expected `<product>\conf\product.conf`. Send the actual
path and the parser can be adjusted.

**A server I configured shows "No ManageEngine installation folder was reachable"**

If that server is the machine running the script but named by its FQDN (e.g. `kmp.cc.co.il`
while the short name is `KMP`), the script now recognises it as local and reads the disk
directly. For a genuinely remote server, confirm `\\SERVER\C$\Program Files\ManageEngine`
opens in Explorer - if it does not, it is SMB, the admin share or permissions.

**Where does the HTML report go?**

Next to the script, unless `-OutputPath` says otherwise. If you launched PowerShell from a UNC
path (Explorer > File > Open Windows PowerShell while browsing `\\kmp\c$\temp`), the script
directory *is* that UNC path, so the report lands there - it is not sent to any scanned server.
Pass `-OutputPath C:\Reports\versions.html` to pin it down. One report always covers every
server scanned in that run.

**`ConvertFrom-Json : Invalid JSON primitive`**

`config.json` is not valid JSON - usually an unescaped backslash, or a missing or extra comma
after an edit. The script names the offending line.

## Notes

- Written for Windows PowerShell 5.1; no PowerShell 7 syntax is used.
- The script only reads files - it never writes to a product installation.

## VMware / vCenter

A vCenter appliance has no `C$` to read - it runs Photon Linux - so unlike ManageEngine this
needs a network call and credentials.

```powershell
.\Get-VersionInventory.ps1 -VCenter vcenter01.lab.local -Show
```

or in `config.json`:

```json
"vcenters": ["vcenter01.lab.local"]
```

### How the version is obtained

1. **vSphere REST API** (tried first) - `POST /api/session` for a token, then
   `GET /api/appliance/system/version`. vCenter 6.7 serves the same thing under `/rest/...`,
   which is tried as well. Nothing to install; HTTPS on TCP 443 is enough.
2. **PowerCLI** (only if REST returns nothing) - `Connect-VIServer`, which additionally yields
   every **ESXi host** with its own version and build.

If PowerCLI is not installed, the script asks before installing anything:

```
The REST API did not answer, and VMware PowerCLI is not installed on this machine.
It can be installed for the current user from the PowerShell Gallery (a few hundred MB,
and it needs internet access to the Gallery).
Install VMware PowerCLI now? [y/N]
```

Answering no **skips the VMware check** and the rest of the report is produced as usual.
`-InstallPowerCLI` answers yes up front; `-NonInteractive` never prompts and never installs,
which is what a scheduled task wants.

### Credentials

Resolved in this order:

1. `VCENTER_USER` and `VCENTER_PASSWORD` environment variables.
2. A **DPAPI-encrypted file** under `credentials\` next to the script. Windows ties the
   encryption to the account and machine that wrote it, so nobody else can read it - not even
   another administrator on the same box.
3. An **interactive prompt**, which offers to save the result as (2) for next time.

The recommended setup is to run it interactively once and answer yes to saving, then let the
scheduled task run unattended as the same account. Read-only vCenter permissions are enough.

The `credentials\` folder and `*.cred.xml` are gitignored.

### Firewall for VMware

| From | To | Port |
|---|---|---|
| The machine running the script | vCenter | **TCP 443** |
| The machine running the script | PowerShell Gallery | TCP 443, **only** if you choose to install PowerCLI |

Still nothing checks the vendors' release pages, so a disconnected environment works as long
as vCenter itself is reachable.

`skipCertificateCheck` in the config defaults to `true`, because vCenter ships a self-signed
certificate. Set it to `false` once vCenter carries a trusted certificate.

### ESXi hosts

By default the report shows the vCenter appliance alone. To also list every ESXi host it
manages, with each host's version and build, add `-IncludeEsxi` (or `"includeEsxi": true` in
the config):

```powershell
.\Get-VersionInventory.ps1 -VCenter vcenter01.lab.local -IncludeEsxi -Show
```

ESXi versions are **not** exposed by the vCenter REST API, so this route uses PowerCLI - the
same install-on-consent flow applies. If PowerCLI is unavailable and you decline installing it,
the vCenter is still reported and a warning notes that the hosts were skipped.

## Windows OS version (Domain Controllers and other servers)

To report the operating-system version of a Windows server - the same "Windows Server 2022,
Version 21H2 (OS Build 20348.xxxx)" that `winver` shows:

```powershell
# every domain controller, discovered automatically
.\Get-VersionInventory.ps1 -Infrastructure -Show

# or specific servers by name
.\Get-VersionInventory.ps1 -WindowsServer DC01,DC02 -Show
```

`-Infrastructure` (or `"domainControllers": true` for a scheduled run) enumerates the DCs of the current domain
via .NET, so nothing has to be listed by hand and a new DC is picked up on its own. It needs no
RSAT or ActiveDirectory module. The two can be combined; a DC covered both ways is checked once.

The version is read from `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion`
(`ProductName`, `DisplayVersion`, `CurrentBuildNumber` + `UBR`). For a remote server this uses:

1. **Remote registry** - needs the *Remote Registry* service running on the target and admin
   rights. On many servers that service is set to Manual/Disabled by default.
2. **WMI** (`Win32_OperatingSystem`) as a fallback - needs WMI/WinRM reachable.

If neither works, the row shows the server with an error explaining what to enable. The local
machine is always readable with no extra service.

## Next steps

See [ROADMAP.md](ROADMAP.md).
