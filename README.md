# VersionTool - ManageEngine version checker

Current version: see [`VERSION`](VERSION).

Reports the installed version and build of ManageEngine products by reading
`conf\product.conf` from each installation folder, compares them against reference values
in the config, and writes a self-contained HTML report.

ManageEngine products write their identity to a plain key=value file:

```
C:\Program Files\ManageEngine\KeyManager\conf\product.conf

  product.name=ManageEngine KeyManager Plus
  product.version=7.1.2
  product.build_number=7120
  product.processor_architecture=64
```

Reading it needs no API token, no API permission and no running web service, which makes it
the reliable way to inventory installed versions.

Products covered by the sample config:

- ADAudit Plus
- ADSelfService Plus
- Key Manager Plus

Any other ManageEngine product works too - add an entry with its name and install path.

## Setup

1. Run the script once. It creates `config.json` from `config.sample.json`, opens it in
   Notepad and stops so you can fill it in:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\Get-ManageEngineVersions.ps1
   ```

   (Doing it by hand works too: `Copy-Item .\config.sample.json .\config.json`.)

2. Per product there are four fields:

   | Field | What it is |
   |---|---|
   | `name` | Display name shown in the report |
   | `installPath` | Installation folder, e.g. `C:\Program Files\ManageEngine\KeyManager` |
   | `enabled` | `false` skips the product without deleting its entry |
   | `latestVersion` / `latestBuild` | Reference values to compare against - **optional**, see below |

   Plus two report-wide fields at the top of the file: `reportTitle` and `outputPath`.

   `installPath` can be left out: the script then searches the conventional ManageEngine
   install roots and the uninstall registry. Setting it is faster and unambiguous. To point
   at a `product.conf` in a non-standard place, use `confPath` instead.

   Note that the installer does not use the display name verbatim - Key Manager Plus installs
   into `...\ManageEngine\KeyManager`.

   `latestVersion` / `latestBuild` ship empty. Leave them empty and the report simply states
   the installed version ("Installed (no reference set)"); fill them in from the product's
   release-notes page and the report gains an up-to-date / update-available status. They are
   *not* the installed version - the script reads that from `product.conf`. Nothing here is
   auto-updated, so a stale reference produces a wrong status; that is why empty is the
   default rather than a guessed number.

## Run

Inside the distributed ZIP the script carries its version in the filename
(`Get-ManageEngineVersions-v2.0.0.ps1`) so it is clear which build is being run; in this
repository it keeps the plain name. Either way it prints its version on startup:

```
VersionTool v2.0.0 - Get-ManageEngineVersions-v2.0.0.ps1
```

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Get-ManageEngineVersions.ps1 -Show
```

Options:

- `-ConfigPath <path>` - use a different config file (default: `config.json` next to the script)
- `-OutputPath <path>` - where to write the HTML (default: value of `outputPath` in the config)
- `-Show` - open the report in the default browser when finished
- `-Verbose` - log every path that is searched and every file that is read
- `-Product <name>` - check only the named product(s); a partial name is enough, e.g.
  `-Product "Key Manager"`. Accepts several: `-Product "Key Manager","ADAudit"`

Typical output:

```
VersionTool v2.0.0 - Get-ManageEngineVersions-v2.0.0.ps1
Skipping: ADAudit Plus (disabled in config)
Checking Key Manager Plus ...
  version 7.1.2 (build 7120) - Installed (no reference set)
  architecture: 64-bit
  source: C:\Program Files\ManageEngine\KeyManager\conf\product.conf

Report written to: C:\Temp\VersionTool\ManageEngine-Versions.html
```

The results are also emitted as objects on the pipeline, so the script can be piped into
`Export-Csv` or called from a larger monitoring script.

## Checking only the products you have installed

The config ships with three products, but you probably do not run all of them:

- **Permanently** - `"enabled": false` on a product in `config.json`. Skipped products are
  listed at the start of the run.
- **For one run** - `-Product "Key Manager"`.

Deleting the entry works too; `enabled` just keeps the settings around for later.

## Caveat: product.conf can lag behind a service pack

On a real Key Manager Plus install, `product.conf` reported build **7120** while the console's
About dialog showed **7130** - the service pack had not rewritten the file. Take this into
account before trusting the number:

- The script scans the whole `conf` folder, not just `product.conf`, and uses the **highest**
  build number it finds, naming the file it came from in the report's Source column.
- If every file in `conf` is stale, the reported build is the base install rather than the
  patched one. Verify against the product console when the exact patch level matters, for
  example before applying a security update.

## Troubleshooting

**"Config was just created and still holds placeholder values"**

Expected on the very first run: the script created `config.json` from the template and opened
it in Notepad. Set `installPath` per product, or disable the products you do not have, then run
the script again.

**"No product.conf found"**

The product is not installed on this machine, or it lives somewhere the search does not cover.
Find the file and set the folder above `conf` as `installPath`:

```powershell
Get-ChildItem C:\ -Filter product.conf -Recurse -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName
```

**"Found ... but it holds no product.version or product.build_number"**

The file exists but uses different key names. Open it and send the contents - the parser looks
for `product.version`, `product.build_number` and `product.processor_architecture`, with a few
aliases.

**`ConvertFrom-Json : Invalid JSON primitive`**

`config.json` is not valid JSON - usually a path that lost its surrounding quotes, or a missing
or extra comma after an edit in Notepad. The script names the offending line; fix it, or delete
`config.json` and run the script again to get a fresh copy.

Backslashes in JSON must be doubled:

```json
"installPath": "C:\\Program Files\\ManageEngine\\KeyManager"
```

## Notes

- Written for Windows PowerShell 5.1; no PowerShell 7 syntax is used.
- The script only reads files - it never writes to a product installation.
- Reading `product.conf` under `C:\Program Files` may require an elevated PowerShell session,
  depending on the folder's permissions.

## Next steps

See [ROADMAP.md](ROADMAP.md) for remaining ideas and hardening steps.
