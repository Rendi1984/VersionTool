# VersionTool - next steps and ideas

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
