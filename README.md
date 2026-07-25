# VersionTool - ManageEngine version checker

Current version: see [`VERSION`](VERSION).

Queries the REST API of ManageEngine products, extracts the installed version/build,
compares it to a reference version from the config, and writes a self-contained HTML report.

Products covered by the sample config:

- ADAudit Plus
- ADSelfService Plus
- Key Manager Plus

## Setup

1. Run the script once. It creates `config.json` from `config.sample.json`, opens it in
   Notepad and stops so you can fill it in:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\Get-ManageEngineVersions.ps1
   ```

   (Doing it by hand works too: `Copy-Item .\config.sample.json .\config.json`.)

   Per product there are only five fields to set:

   | Field | What it is |
   |---|---|
   | `name` | Display name shown in the report |
   | `baseUrl` | Scheme, host and web port of the product (e.g. `https://adaudit.corp.local:8081`) |
   | `tokenEnvVar` | Name of the environment variable holding that product's token |
   | `endpoints` | API paths to try, in order; the first one that returns a version wins |
   | `latestVersion` / `latestBuild` | The reference values the installed version is compared against |

   The token itself is never written in the config - `tokenEnvVar` only holds the *name*
   of the environment variable that carries it. See step 2.

   Report-wide fields at the top of the file: `reportTitle`, `outputPath` (where the HTML
   is written), `timeoutSec` (per API call) and `skipCertificateCheck`.

   <details>
   <summary>Optional fields (defaults are correct for all three products - only add these if a product rejects the token)</summary>

   - `authMode` - `header` (default) or `query`: send the token as an HTTP header or as a
     URL parameter
   - `authHeaderName` - name of the header, default `AUTHTOKEN` (used when `authMode` is `header`)
   - `authQueryName` - name of the URL parameter, default `AUTHTOKEN` (used when `authMode` is `query`)
   - `token` - the token inline instead of via environment variable. Works, but stores a
     secret on disk - prefer `tokenEnvVar`.
   </details>

2. Generate an API token in each product's console (Admin > API / Technician key) and
   expose it as an environment variable:

   ```powershell
   $env:ME_ADAUDIT_TOKEN = "..."
   $env:ME_ADSSP_TOKEN   = "..."
   $env:ME_KMP_TOKEN     = "..."
   ```

   The script reads each product's token from the variable named in its `tokenEnvVar`,
   and sends it as the `AUTHTOKEN` HTTP header. Note that variables set this way only
   live in the current PowerShell window; for a scheduled task set them at user or
   machine level, e.g.
   `[Environment]::SetEnvironmentVariable('ME_ADAUDIT_TOKEN','...','User')`.

## Run

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Get-ManageEngineVersions.ps1 -Show
```

Options:

- `-ConfigPath <path>` - use a different config file (default: `config.json` next to the script)
- `-OutputPath <path>` - where to write the HTML (default: value of `outputPath` in the config)
- `-Show` - open the report in the default browser when finished
- `-Verbose` - log every endpoint that is tried

The script also emits the results as objects on the pipeline, so it can be piped into
`Export-Csv` or used inside a larger monitoring script.

## Troubleshooting

**"Config was just created and still holds placeholder values"**

Expected on the very first run: the script created `config.json` for you from the template and
opened it in Notepad. Edit it (real `baseUrl` per product, or delete the products you do not
use), set your tokens, then run the script again.

**`The value of "tokenEnvVar" looks like the token itself`**

`tokenEnvVar` takes the **name** of an environment variable, not the token. Leave the name as
shipped and put the token in the variable:

```powershell
# config.json keeps:  "tokenEnvVar": "ME_KMP_TOKEN"
$env:ME_KMP_TOKEN = "A5FA6962-9108-4AFB-926B-1BE68A59A00D"
```

To keep the token in the file instead, add a `token` field to that product and leave
`tokenEnvVar` alone:

```json
"tokenEnvVar": "ME_KMP_TOKEN",
"token": "A5FA6962-9108-4AFB-926B-1BE68A59A00D",
```

That stores a secret on disk. `config.json` is gitignored, so it is never committed - but the
environment variable is still the safer option.

**`Environment variable 'X' is not set`**

The name in `tokenEnvVar` is right, but the variable is empty in this window. Variables set with
`$env:NAME = "..."` disappear when the window closes; for a scheduled task set them permanently:

```powershell
[Environment]::SetEnvironmentVariable('ME_KMP_TOKEN','<token>','User')
```

**A product reports as unreachable**

`config.sample.json` ships placeholder hosts (`adaudit.corp.local`, `adssp.corp.local`). Point
`baseUrl` at your real servers, or delete the products you do not use - otherwise every run
reports them as unreachable. Run with `-Verbose` to see each endpoint being tried.

## Notes

- Written for Windows PowerShell 5.1; no PowerShell 7 syntax is used.
- `skipCertificateCheck: true` in the config disables TLS certificate validation - useful
  for the self-signed certificates ManageEngine installs by default. Set it to `false`
  once the servers carry trusted certificates.
- ManageEngine's API paths differ between products and major versions. The `endpoints`
  list is therefore config-driven and tried in order: if none of the defaults return a
  version for your build, check the product's API documentation and add the correct path.
  The version/build value itself is located by searching the JSON response recursively for
  fields such as `product_version`, `version`, `build_number`, so a differently shaped
  response usually still parses.

## Next steps

See [ROADMAP.md](ROADMAP.md) for verification tasks, ideas and hardening steps.
