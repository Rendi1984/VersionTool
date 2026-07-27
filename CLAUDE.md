# VersionTool - Project Rules for Claude

## What is this project
VersionTool reports the installed version/build of ManageEngine products (ADAudit Plus,
ADSelfService Plus, Key Manager Plus) by reading conf\product.conf from each installation
folder, and renders a self-contained HTML report. There is no API/token path any more - it
was removed in 2.0.0 because reading the file needs no token, no API permission and no
running web service.

- `Get-ManageEngineVersions.ps1` - the tool. Windows PowerShell 5.1 compatible; no PowerShell 7
  syntax (no `??`, no ternary, no `&&`/`||`, ASCII only).
- `config.sample.json` - template config. Real config lives in `config.json`, which is
  gitignored.
- `VERSION` - single source of truth for the release number. Patch for a fix, minor for a new
  capability.

Per product the config carries `name`, `installPath`, `enabled` and the optional
`latestVersion`/`latestBuild` reference values. Never commit a real token or customer
hostname.

---

## Deliverable packaging (always)
Whenever files are produced for the user, all three of these are required - no exceptions:
1. **Package as ZIP**, named `VersionTool-v<version>.zip`, where `<version>` is read from `VERSION`.
   The ZIP holds **only what is needed to run the tool** - today that is
   `Get-ManageEngineVersions.ps1` and `config.sample.json`. No documentation, no project files.
   Never include `config.json`: it can hold real tokens.
   Put the files at the **root of the archive, with no wrapper folder** - extracting already
   creates a folder, so a prefix directory just nests one inside another.
   Inside the ZIP the script is named `Get-ManageEngineVersions-v<version>.ps1`, so it is
   obvious which build is being run. The repository keeps the unversioned name.
   `$script:ToolVersion` inside the script must match `VERSION` - bump both together.
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
- The installer does not use the display name verbatim: Key Manager Plus installs into
  `...\ManageEngine\KeyManager`. Folder discovery normalises names (lowercase, no separators,
  no trailing "plus") rather than guessing spellings.
- A service pack does not always rewrite `product.conf`; a live install reported build 7120
  there while the console showed 7130. The script scans every `*.conf` in the `conf` folder and
  reports the highest build, naming its source. Keep that caveat in the README - do not present
  the number as authoritative.
- Before shipping a change to the script, verify ASCII-only content and brace/paren balance.
- This tool was originally committed to the DSMT-V2 repository by mistake and moved here.
