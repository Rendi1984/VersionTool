# VersionTool - Project Rules for Claude

## What is this project
VersionTool reports the installed version/build of infrastructure systems and renders a
self-contained HTML report grouped by vendor, then by server.

- **ManageEngine** - reads `conf\product.conf` from each installation folder. No credentials,
  no API. Every product found is reported; there is no product list.
- **VMware** - vCenter via the vSphere REST API, falling back to PowerCLI (which also yields
  ESXi hosts). This one does need credentials and TCP 443, because a vCenter appliance has no
  file share to read.

Nothing is ever checked against a vendor's release page: the report says what is installed,
never whether it is current. No reference versions, no status column.

- `Get-VersionInventory.ps1` - the tool. Windows PowerShell 5.1 compatible; no PowerShell 7
  syntax (no `??`, no ternary, no `&&`/`||`, ASCII only).
- `config.json` - the only config, read as-is and never rewritten by the script. Ships in
  the ZIP and is committed; it holds no secrets, just a server list.
- `VERSION` - single source of truth for the release number. Patch for a fix, minor for a new
  capability.

The config carries `reportTitle`, `outputPath`, `servers` (empty = local machine),
`searchRoots`, `vcenters` (empty = VMware skipped), `credentialFolder`,
`skipCertificateCheck` and `timeoutSec`. Never commit a real customer hostname or credential;
`credentials/` and `*.cred.xml` are gitignored.

---

## Deliverable packaging (always)
Whenever files are produced for the user, all three of these are required - no exceptions:
1. **Package as ZIP**, named `VersionTool-v<version>.zip`, where `<version>` is read from `VERSION`.
   The ZIP holds **only what is needed to run the tool** - today that is
   `Get-VersionInventory.ps1` and `config.json`. No documentation, no project files.
   Put the files at the **root of the archive, with no wrapper folder** - extracting already
   creates a folder, so a prefix directory just nests one inside another.
   Inside the ZIP the script is named `Get-VersionInventory-v<version>.ps1`, so it is
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
- Before shipping a change to the script, run `python3 tools/check-script.py`. There is no
  PowerShell here, so it is the only automated guard: it catches script-scope variables read
  but never set (a dropped parameter - this shipped three times), foreach variables colliding
  with a parameter name (PowerShell names are case-insensitive), brace balance and non-ASCII.
- Under `Set-StrictMode`, `.Count` on a scalar throws "The property 'Count' cannot be found"
  (shipped in 3.1.0). A function returning a one-element array unrolls it to a scalar, so never
  call `.Count` on a raw function return - wrap the call in `@(...)`, or test truthiness with
  `if (-not $x)` instead. The checker does not catch this yet.
- Anything that would install software or store a credential must ask first, and declining
  must skip that check rather than fail the run.
- This tool was originally committed to the DSMT-V2 repository by mistake and moved here.
