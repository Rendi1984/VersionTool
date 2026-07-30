# VersionTool - next steps and ideas

## TODO (requested): more vendors to add version checks for

Each needs a different collection method - none of these exposes a `product.conf` on an
admin share, so this is a new provider per system (like VMware was), not a config entry.

- [ ] **FortiGate** - no file to read; it is an appliance. Options: the REST API
      (`GET /api/v2/monitor/system/status` returns firmware version/build, needs an API key
      or session token over HTTPS 443), or SSH `get system status`, or SNMP
      (`fnSysVersion`). REST is the cleanest. Needs credentials + TCP 443, self-signed cert.
- [ ] **NetApp ONTAP** - REST API `GET /api/cluster` returns `version.full` (ONTAP 9.6+),
      or ONTAPI/ZAPI `system-get-version` on older releases, or SSH `version`. Needs
      credentials + HTTPS 443.
- [ ] **VMware Horizon** - the Connection Server is Windows, so its build might be readable
      like ManageEngine (registry / install folder) for the local/remote server; the
      pod/environment version is also available via the Horizon REST API
      (`/rest/monitor/...`) with credentials. Decide per-component (Connection Server vs
      Agent vs Composer).
- [ ] **Commvault** - CommServe is Windows/SQL. The version is in the registry
      (`HKLM\SOFTWARE\CommVault Systems\Galaxy\...` / `sGalaxyBaseInstallSize`-adjacent keys)
      and in the CommServe SQL DB; there is also a REST API (`GET /SearchSvc/CVWebService.svc`
      login then version). Registry read (like the Windows OS check) is probably the least
      intrusive for the CommServe box.

Shared design point: these are credentialed network checks (like VMware/vCenter), so they
belong in the Versions tab under their own vendor region, reuse the DPAPI-encrypted
credential store, and must ask before installing any module and skip on decline. Firewall:
each is HTTPS 443 to the appliance/server, still nothing outbound to the internet.

---


Status at v2.0.0: the script reads conf\product.conf from each configured installation,
extracts version / build / architecture, compares against reference values from the config,
and writes an HTML report. The API/token path was removed in 2.0.0.

Verified against a live Key Manager Plus install (7.1.2 / build 7120, 64-bit) - which also
surfaced the caveat in section 1.

---

## 1. Trust the number (do this first)

- [ ] product.conf lagged a service pack on the live install: the file said build 7120 while
      the console said 7130. Find where the applied patch level is actually recorded
      (UpdateManager folder, a service-pack conf, the database) and read that instead.
- [ ] Capture a product.conf from ADAudit Plus and ADSelfService Plus to confirm the key names
      match, and add any aliases needed.
- [ ] Decide what to do when files disagree: report the highest, or report both and flag it.

## 2. Reach

- [ ] Read product.conf from remote servers over an administrative share
      (\\server\C$\Program Files\ManageEngine\...), so one run covers the estate.
- [ ] Or a small collector that runs per server via a scheduled task and writes to a shared
      folder, with the report built from those files.

## 3. Keep the reference versions current

Today `latestVersion` / `latestBuild` are typed in by hand, so the status column is only as
good as the last update.

- [ ] A quarterly checklist entry: update the config from the ManageEngine release notes.
- [ ] Read the reference values from a shared file so several admins stay in sync.
- [ ] Scrape the release-notes pages. Note they return 403 to automated fetches, so this needs
      a real browser agent or a manual step.

## 4. Reporting and delivery

- [ ] Email the HTML report after a scheduled run.
- [ ] Exit code by worst status (0 = all up to date, 1 = update available, 2 = not found) so a
      monitoring system can alert on it.
- [ ] Emit JSON / CSV alongside the HTML for a dashboard or CMDB.
- [ ] Keep a history folder (`reports\yyyy-MM-dd.html`) and show "changed since last run".

## 5. Coverage

- [ ] Add the other ManageEngine products in use (ADManager Plus, PAM360, ServiceDesk Plus,
      Password Manager Pro) - each is just another entry with a name and install path.
- [ ] Support several instances of the same product (DR site, test) and group them in the report.
- [ ] Report the licence type and expiry. product.conf does not carry them, so find the file
      that does - the console shows Trial / Free / Professional.

## 6. Code / project

- [ ] Pester tests for `ConvertTo-ComparableVersion`, `Get-VersionStatus` and `Read-ProductConf`
      using captured sample files. Every bug so far was a runtime error that no amount of
      static checking would have caught - this is the highest-value item on the list.
- [ ] Run PSScriptAnalyzer in CI.
- [ ] Tag each release so a packaged ZIP can be traced back to its source.
