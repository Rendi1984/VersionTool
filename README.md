# VersionTool - ManageEngine version checker

Current version: see [`VERSION`](VERSION).

Reads the installed version/build of ManageEngine products, compares it to a reference
version from the config, and writes a self-contained HTML report.

Two sources are used, in order:

1. **`conf\product.conf`** in the product installation folder, where ManageEngine writes
   `product.build_number` and `product.processor_architecture`. This needs no token, no API
   permission and no running web service, so it is tried first and is the most reliable route.
2. **The REST API**, when no `product.conf` is found - for example when checking a remote
   server. This is where `baseUrl`, `endpoints` and the token come in.

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
   | `installPath` | Installation folder, e.g. `C:\ManageEngine\Key Manager Plus`. `conf\product.conf` under it is read first |
   | `baseUrl` | Scheme, host and web port of the product - only needed when there is no local install to read |
   | `tokenEnvVar` | Name of the environment variable holding that product's token |
   | `endpoints` | API paths to try, in order; the first one that returns a version wins |
   | `latestVersion` / `latestBuild` | Reference values to compare against - **optional**, see below |

   `latestVersion` / `latestBuild` ship empty. Leave them empty and the report simply states
   the installed version ("Installed (no reference set)"); fill them in from the product's
   release-notes page and the report gains an up-to-date / update-available status. They are
   *not* the installed version - the script reads that from the API. Nothing here is
   auto-updated, so a stale reference produces a wrong status; that is why empty is the
   default rather than a guessed number.

   The token itself is never written in the config - `tokenEnvVar` only holds the *name*
   of the environment variable that carries it. See step 2.

   Report-wide fields at the top of the file: `reportTitle`, `outputPath` (where the HTML
   is written), `timeoutSec` (per API call) and `skipCertificateCheck`.

   <details>
   <summary>Optional fields (defaults are correct for all three products - only add these if a product rejects the token)</summary>

   - `authMode` - `header` (default), `query` or `path`: send the token as an HTTP header,
     as a URL parameter, or as a trailing path segment. Key Manager Plus documents the
     last form: `https://host:6565/api/pki/restapi/<api_name>/AUTHTOKEN=<token>`
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

Inside the distributed ZIP the script carries its version in the filename
(`Get-ManageEngineVersions-v1.4.0.ps1`) so it is clear which build is being run; in this
repository it keeps the plain name. Either way it prints its version on startup:

```
VersionTool v1.4.0 - Get-ManageEngineVersions-v1.4.0.ps1
```

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Get-ManageEngineVersions.ps1 -Show
```

Options:

- `-ConfigPath <path>` - use a different config file (default: `config.json` next to the script)
- `-OutputPath <path>` - where to write the HTML (default: value of `outputPath` in the config)
- `-Show` - open the report in the default browser when finished
- `-Verbose` - log every endpoint that is tried
- `-Product <name>` - check only the named product(s); a partial name is enough, e.g.
  `-Product "Key Manager"`. Accepts several: `-Product "Key Manager","ADAudit"`
- `-SkipLocal` - ignore `conf\product.conf` and go to the REST API instead. Use when checking
  a remote server, or to verify that the configured API path actually works

## Checking only the products you have installed

The config ships with three products, but you probably do not run all of them. Two ways to
narrow it down, neither of which requires deleting anything:

- **Permanently** - add `"enabled": false` to a product in `config.json`:

  ```json
  { "name": "ADAudit Plus", "enabled": false, ... }
  ```

  Skipped products are listed at the start of the run. Products without an `enabled` field
  are checked as usual.

- **For one run** - `-Product "Key Manager"`.

Deleting the product's entry works too; `enabled` just keeps the settings around for later.

The script also emits the results as objects on the pipeline, so it can be piped into
`Export-Csv` or used inside a larger monitoring script.

## Troubleshooting

**"Config was just created and still holds placeholder values"**

Expected on the very first run: the script created `config.json` for you from the template and
opened it in Notepad. Edit it (real `baseUrl` per product, or delete the products you do not
use), set your tokens, then run the script again.

**Warning: `"tokenEnvVar" holds what looks like the token itself`**

Not fatal - the script uses the value as the token and carries on. `tokenEnvVar` is meant to
hold the **name** of an environment variable, so pasting the token there is a mismatch worth
cleaning up. To silence the warning, either rename that field to `token`, or leave the name as
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

**`ConvertFrom-Json : Invalid JSON primitive: https`**

`config.json` is not valid JSON - usually a URL that lost its surrounding quotes, or a missing
or extra comma after an edit in Notepad. The script names the offending line; fix it, or delete
`config.json` and run the script again to get a fresh copy.

A correct product entry looks exactly like this - every value in double quotes, a comma after
every entry except the last one in its block:

```json
{
  "name": "Key Manager Plus",
  "enabled": true,
  "baseUrl": "https://kmp.lab.local:6565",
  "tokenEnvVar": "ME_KMP_TOKEN",
  "endpoints": [
    "/api/json/aboutproduct"
  ],
  "latestVersion": "",
  "latestBuild": ""
}
```

**Testing the API by hand**

To check whether the product answers at all, independently of this script, call it directly.
Windows PowerShell 5.1 has no `-SkipCertificateCheck`, so the certificate callback is set first
(ManageEngine ships self-signed certificates):

```powershell
[Net.ServicePointManager]::ServerCertificateValidationCallback={$true}
Invoke-RestMethod -Uri "https://localhost:6565/api/json/aboutproduct" -Headers @{AUTHTOKEN="<token>"} | ConvertTo-Json -Depth 6
```

Since the working path is exactly what is unknown, this tries every candidate, as a header and
as a query parameter, and prints whichever answers:

```powershell
$token = "<token>"
$base  = "https://localhost:6565"

[Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol

foreach ($p in @("/api/json/aboutproduct","/restapi/json/v1/serverinfo","/api/pam/v1/serverinfo")) {
    foreach ($mode in @('header','query')) {
        $target = $base + $p; $headers = @{}
        if ($mode -eq 'header') { $headers = @{ AUTHTOKEN = $token } } else { $target += "?AUTHTOKEN=$token" }
        try {
            $r = Invoke-RestMethod -Uri $target -Headers $headers -TimeoutSec 15 -ErrorAction Stop
            Write-Host "OK   $mode $p" -ForegroundColor Green
            $r | ConvertTo-Json -Depth 6
        } catch {
            $code = ''
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            Write-Host "FAIL $mode $p  $code" -ForegroundColor DarkGray
        }
    }
}
```

Reading the result:

| What you see | What it means |
|---|---|
| `OK` plus JSON containing a version | That path works - put it first in `endpoints` |
| `401` / `403` on every path | Token or licence problem, not the path. REST API access may be restricted on a Free licence |
| `404` on every path | Wrong paths for this build - check the product's API documentation |
| Connection refused / timeout | Wrong host or port, or a firewall in between |
| `query` works but `header` does not | Set `"authMode": "query"` for that product |

**A product reports as unreachable**

`config.sample.json` ships placeholder hosts (`adaudit.corp.local`, `adssp.corp.local`). Point
`baseUrl` at your real servers, or delete the products you do not use - otherwise every run
reports them as unreachable. Run with `-Verbose` to see each endpoint being tried.

## Product API notes

**Key Manager Plus.** Per the [RESTful API documentation](https://www.manageengine.com/key-manager/help/restapi.html)
the base path is `/api/pki/restapi/<api_name>` on port **6565**, and the token is passed as a
trailing path segment (`authMode: "path"`), for example:

```
https://kmp.lab.local:6565/api/pki/restapi/getAllSSLCertificates/AUTHTOKEN=<token>
```

The documented calls cover certificate and key operations; **no version/about API is
documented**. The About dialog in the web console may therefore be served by an internal UI
call rather than the public REST API. If none of the configured endpoints return a version,
capture the real request:

1. Open the product console, press **F12**, select the **Network** tab.
2. Open **Help > About** (or Settings, where the About dialog appears).
3. Find the request that fires as the dialog opens, right-click it and choose
   **Copy > Copy as cURL**, or note its URL.
4. Add that path to `endpoints` for the product.

If the captured request authenticates with a session cookie rather than `AUTHTOKEN`, it cannot
be reached with a token alone - in that case the version has to come from somewhere else
(installed-product registry keys, or the ManageEngine console itself).

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
