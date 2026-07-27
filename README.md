# VersionTool - ManageEngine version inventory

Current version: see [`VERSION`](VERSION).

Scans one or more servers for installed ManageEngine products, reads the version and build
of each, and writes a self-contained HTML report grouped by server.

There is no product list to maintain: every ManageEngine product found under the
installation roots is reported, so one installed later shows up on its own.

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
# this machine
.\Get-ManageEngineVersions.ps1 -Show

# production, one server per system
.\Get-ManageEngineVersions.ps1 -ComputerName KMP01,ADAUDIT01,ADSSP01 -Show
```

Options:

- `-ComputerName <names>` - servers to scan, overriding the config
- `-ConfigPath <path>` - a different config file (default: `config.json` next to the script)
- `-OutputPath <path>` - where to write the HTML
- `-Product <name>` - report only products whose name contains this string
- `-Title <text>` - heading for the report
- `-Show` - open the report when finished
- `-Verbose` - log every root scanned and file read

Typical output:

```
VersionTool v3.0.0 - Get-ManageEngineVersions-v3.0.0.ps1
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
  "reportTitle": "ManageEngine Version Report",
  "outputPath": "ManageEngine-Versions.html",
  "servers": ["KMP01", "ADAUDIT01", "ADSSP01"],
  "searchRoots": []
}
```

| Field | Meaning |
|---|---|
| `reportTitle` | Heading of the report |
| `outputPath` | Where the HTML is written; relative paths are next to the script |
| `servers` | Servers to scan. Empty means the local machine |
| `searchRoots` | Extra folders to search, for installations outside the conventional locations, e.g. `["F:\\Apps\\ManageEngine"]` |

Backslashes in JSON must be doubled.

Roots searched by default: `C:\ManageEngine`, `C:\Program Files\ManageEngine`,
`C:\Program Files (x86)\ManageEngine`, `D:\ManageEngine`, `D:\Program Files\ManageEngine`,
`E:\ManageEngine`.

## The report

One block for ManageEngine, subdivided by server, with a row per product: name, version,
build, architecture and the file the values came from. Summary cards at the top count
products, servers scanned, and servers that returned nothing.

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

**`ConvertFrom-Json : Invalid JSON primitive`**

`config.json` is not valid JSON - usually an unescaped backslash, or a missing or extra comma
after an edit. The script names the offending line.

## Notes

- Written for Windows PowerShell 5.1; no PowerShell 7 syntax is used.
- The script only reads files - it never writes to a product installation.

## Next steps

See [ROADMAP.md](ROADMAP.md).
