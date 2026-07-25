# VersionTool - ManageEngine version checker

Current version: see [`VERSION`](VERSION).

Queries the REST API of ManageEngine products, extracts the installed version/build,
compares it to a reference version from the config, and writes a self-contained HTML report.

Products covered by the sample config:

- ADAudit Plus
- ADSelfService Plus
- Key Manager Plus

## Setup

1. Copy the sample config and edit it:

   ```powershell
   Copy-Item .\config.sample.json .\config.json
   notepad .\config.json
   ```

   Per product set:
   - `baseUrl` - scheme, host and web port of the product (e.g. `https://adaudit.corp.local:8081`)
   - `endpoints` - API paths to try, in order; the first one that returns a version wins
   - `latestVersion` / `latestBuild` - the reference values you compare against
   - `authMode` - `header` (default) or `query`, depending on how the product accepts the token
   - `tokenEnvVar` - name of the environment variable holding that product's AUTHTOKEN

2. Generate an API token in each product's console (Admin > API / Technician key) and
   expose it as an environment variable:

   ```powershell
   $env:ME_ADAUDIT_TOKEN = "..."
   $env:ME_ADSSP_TOKEN   = "..."
   $env:ME_KMP_TOKEN     = "..."
   ```

   Tokens can also be placed in the `token` field of the config, but that stores a
   secret on disk - prefer the environment variable.

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
