# VersionTool - Project Rules for Claude

## What is this project
VersionTool checks the installed version/build of ManageEngine products (ADAudit Plus,
ADSelfService Plus, Key Manager Plus) through their REST APIs and renders a self-contained
HTML report.

- `Get-ManageEngineVersions.ps1` - the tool. Windows PowerShell 5.1 compatible; no PowerShell 7
  syntax (no `??`, no ternary, no `&&`/`||`, ASCII only).
- `config.sample.json` - template config. Real config lives in `config.json`, which is
  gitignored because it can hold API tokens.
- `VERSION` - single source of truth for the release number. Patch for a fix, minor for a new
  capability.

Tokens are supplied per product via environment variables named in `tokenEnvVar`
(`ME_ADAUDIT_TOKEN`, `ME_ADSSP_TOKEN`, `ME_KMP_TOKEN`). Never commit a real token.

---

## Deliverable packaging (always)
Whenever files are produced for the user, all three of these are required - no exceptions:
1. **Package as ZIP**, named `VersionTool-v<version>.zip`, where `<version>` is read from `VERSION`.
   The ZIP holds **only what is needed to run the tool** - today that is
   `Get-ManageEngineVersions.ps1` and `config.sample.json`. No documentation, no project files.
   Never include `config.json`: it can hold real tokens.
   Put the files at the **root of the archive, with no wrapper folder** - extracting already
   creates a folder, so a prefix directory just nests one inside another.
2. **Provide a download link** - send the ZIP with `SendUserFile`, and also link the files on the
   pushed branch in GitHub.
3. **Write run instructions** - the exact command to launch the tool, its parameters/switches, and
   any prerequisite setup (config to copy, environment variables/tokens to set). These live in the
   **`.md` files in git** (`README.md` is the reference), and are repeated in the chat reply.
   They do not ship inside the ZIP.
4. **Open a pull request** for the branch and include its link in the reply. Do this for every
   change pushed - no need to ask first. If a PR is already open for the branch, push to it
   rather than opening a second one.

---

## Notes
- API paths differ between ManageEngine products and major versions, so `endpoints` is
  config-driven and each path is tried in order until one returns a version. The version/build
  value is located by searching the JSON response recursively (`product_version`, `version`,
  `build_number`, ...), so a differently shaped response usually still parses.
- Before shipping a change to the script, verify ASCII-only content and brace/paren balance.
- This tool was originally committed to the DSMT-V2 repository by mistake and moved here.
