# VersionTool - next steps and ideas

Status at v1.0.0: the script queries the three products, extracts version/build, compares
against reference values from the config, and writes an HTML report. It has **not been run
against real servers yet** - runtime verification is the first task below.

---

## 1. Verify against the real environment (do this first)

- [ ] Run with `-Verbose` against each product and confirm which endpoint actually answers:
      `powershell.exe -ExecutionPolicy Bypass -File .\Get-ManageEngineVersions.ps1 -Verbose`
- [ ] For any product where no endpoint returns a version, find the correct path in that
      product's API documentation and add it to the top of its `endpoints` list in `config.json`,
      then update `config.sample.json` so the default ships correct.
- [ ] Capture one raw JSON response per product (redact the token) into a `samples/` folder,
      so the parsing logic can be tested without hitting live servers.
- [ ] Confirm whether each product wants the token as a header or as a query parameter, and fix
      `authMode` accordingly.

## 2. Keep the reference versions current

Today `latestVersion` / `latestBuild` are typed into the config by hand, so the status column is
only as good as the last time someone updated them. Options, cheapest first:

- [ ] A short quarterly checklist entry: update the config from the ManageEngine release notes.
- [ ] Read the reference values from a shared file (network share / SharePoint) so several
      admins stay in sync without editing the script folder.
- [ ] Scrape the ManageEngine release-notes page per product and fill the reference values
      automatically. Note that this needs outbound internet from the machine running the script,
      and the pages change layout - keep the manual values as a fallback.

## 3. Reporting and delivery

- [ ] Email the HTML report (`Send-MailMessage` on 5.1, or `System.Net.Mail` for TLS control)
      after a scheduled run, so nobody has to open a file share to see the status.
- [ ] Exit code by worst status (0 = all up to date, 1 = update available, 2 = unreachable) so a
      monitoring system or a scheduled task can alert on it.
- [ ] Emit JSON / CSV alongside the HTML for ingestion into a dashboard or CMDB.
- [ ] Keep a history folder (`reports\yyyy-MM-dd.html`) and show "changed since last run" in the
      report, so version drift is visible over time.

## 4. Coverage

- [ ] Add the other ManageEngine products in use (ADManager Plus, PAM360, ServiceDesk Plus,
      Password Manager Pro) - each is just another entry in `products`, no code change needed.
- [ ] Support multiple instances of the same product (DR site, test environment) by allowing
      duplicate product names with distinct `baseUrl` values, and group them in the report.
- [ ] Also report the license expiry date and the build date when the API exposes them - the
      recursive JSON search makes this a matter of adding key names to the lookup lists.

## 5. Hardening

- [ ] Replace `skipCertificateCheck: true` with trusted certificates on the ManageEngine servers,
      then set it to `false`. Certificate validation is off by default today only because
      ManageEngine ships self-signed certificates.
- [ ] Store the API tokens in Windows Credential Manager or a DPAPI-encrypted file instead of
      environment variables, so they are not visible to other processes in the same session.
- [ ] Run the scheduled task under a dedicated low-privilege service account - the API tokens are
      read-only for this purpose, and the account needs no rights in AD.
- [ ] Add retry with backoff for transient network failures, so a single blip does not report a
      product as unreachable.

## 6. Code / project

- [ ] Add Pester tests for `ConvertTo-ComparableVersion`, `Get-VersionStatus` and `Find-JsonValue`
      using the captured sample responses - these are the parts most likely to break on a new
      product build.
- [ ] Consider packaging as a PowerShell module (`VersionTool.psm1`) once there is more than one
      script, so functions can be reused.
- [ ] Bump `VERSION` with every change: patch for a fix, minor for a new capability, and tag the
      commit so a packaged ZIP can be traced back to its source.
