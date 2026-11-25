# GPush

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=for-the-badge&logo=powershell&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-supported-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)
![Git](https://img.shields.io/badge/Git-required-F05032?style=for-the-badge&logo=git&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-supported-0078D6?style=for-the-badge&logo=windows&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-supported-FCC624?style=for-the-badge&logo=linux&logoColor=black)
![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)

```text
 ###  ####            o
#     #   #          / \
#  ## ####      o---o   o
#   # #          \   \ /
 ###  #           o---o---o
                           \
                            o---o
```

GPush is a small Git helper for quickly working with repositories without manually navigating between project folders. It can find repositories, show status, commit and push changes, synchronize branches, manage tags, remotes, aliases, favorites and more.

<img width="699" height="785" alt="image" src="https://github.com/user-attachments/assets/bb6dd591-b5d9-4b70-94be-b58d49f1b2c8" />

---

### Install

#### Windows

Requirements: **PowerShell 5.1+** and **Git in PATH**.

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\install.ps1
```

GPush stores its configuration in:

```text
%LOCALAPPDATA%\GPush\config.json
```

The installed PowerShell launcher is located at:

```text
%LOCALAPPDATA%\GPush\bin\gp.ps1
```

##### PowerShell security warning

On some Windows systems, PowerShell may display a security warning when `gp` is started:

```text
Run only scripts that you trust.
Do you want to run ...\GPush\bin\gp.ps1?
[D] Do not run  [R] Run once  [S] Suspend  [?] Help
```

If you installed GPush from a source you trust, unblock the installed launcher once:

```powershell
Unblock-File -Path "$env:LOCALAPPDATA\GPush\bin\gp.ps1"
```

Then verify the installation:

```powershell
gp --version
```

To unblock all PowerShell scripts installed inside the GPush directory:

```powershell
Get-ChildItem "$env:LOCALAPPDATA\GPush" -Recurse -Filter *.ps1 | Unblock-File
```

> **Note:** `%LOCALAPPDATA%` is `cmd.exe` syntax.  
> In PowerShell commands, use `$env:LOCALAPPDATA` instead.

For example:

```powershell
$env:LOCALAPPDATA
```

Do not run this in PowerShell:

```powershell
Unblock-File -Path %LOCALAPPDATA%\GPush\bin\gp.ps1
```

because PowerShell will treat `%LOCALAPPDATA%` as a literal part of the path instead of expanding the environment variable.

#### Linux

Requirements: **Bash** and **Git in PATH**.

```bash
chmod +x ./linux/install.sh
./linux/install.sh
```

The installer places `gp` in:

```text
~/.local/bin/gp
```

---

### Usage

Quick repository picker:

```text
gp
```

Shows up to 5 recent repositories and your favorites.

Classic shortcut:

```text
gp MyProject "Fix packet parser"
gp MyProject
```

Command syntax:

```text
gp repo status MyProject
gp repo sync MyProject
gp branch new MyProject feature/api
gp branch prune MyProject
gp tag release MyProject v1.0.0 "Release 1.0.0"
gp remote add MyProject upstream <url>
gp stash push MyProject
gp favorite add MyProject
gp fav list
gp all fetch
gp all
gp all push "Update projects"
gp clone <url>
```

Existing flag syntax remains supported:

```text
gp --status MyProject
gp --diff MyProject
gp --sync MyProject
gp --all --fetch
gp --help
```

If no commit message is supplied, GPush asks for it interactively.

---

### Main commands

| Command | Purpose |
|---|---|
| `repo` | Status, diff, log, fetch, pull and sync |
| `branch` | List, create, switch, delete and prune branches |
| `tag` | Tags and safe release workflow |
| `remote` | Manage Git remotes |
| `stash` | Push, list and pop stash entries |
| `cache` | Repository discovery and cache |
| `config` | Configuration and diagnostics |
| `alias` | Repository aliases |
| `favorite` / `fav` | Favorite repositories |
| `all` | Status, fetch, sync or commit/push cached repositories |
| `project` | Project info, build, test, run, open and shell |
| `clone` | Clone and cache a repository |
| `recent` | Show recently used repositories |
| `update` | Check, install or roll back GPush updates |

Run:

```text
gp --help
```

for the complete command and option list.

---

### Safety

GPush performs preflight checks before changing repositories and does not resolve merge or rebase conflicts automatically.

Protected branches, risky files, unpushed commit rewrites, release creation and stale branch cleanup include additional safety checks.

If a rebase fails, resolve it manually and continue with:

```text
git add .
git rebase --continue
```

or cancel it with:

```text
git rebase --abort
```

---

### Author

**Michal Švrček**

Distributed under the MIT License.

### Bulk repository synchronization

`gp all status` displays repository, branch, last commit, behind/ahead counts, and working tree state. Counts use locally cached remote refs; `gp all fetch` refreshes them first. A dash means no reliable comparison is available.

`gp all` (or `gp all sync`) fetches and synchronizes cached repositories without creating commits. `gp all push "Update projects"` additionally commits local changes after confirmation. Use `--allow-protected` to permit pushes to protected branches. Dirty repositories are skipped in sync mode; diverged histories and risky files in bulk commit mode require manual attention. No automatic force push or rebase is performed. Run `gp cache refresh` first if the cache is empty.

### Updating GPush

Use `gp update check` to check for releases, `gp update` (or `gp update install`) to install, and `gp update rollback` to restore a backup. On Windows, `gp --update` remains a compatible legacy alias.

## Visual Experience (4.5.0)

| Command | Description |
|---|---|
| `gp overview` | Interactive cached workspace dashboard (arrows, Enter, F, S, Q); static when redirected |
| `gp health` | Clean/synchronized ratio and cached status |
| `gp watch [seconds]` | Refresh cached status periodically; Ctrl+C to stop |
| `gp stats` | Current-branch commits, added/deleted lines and daily activity over 30 days |
| `gp changes [project]` | Working tree and Git diff statistics |
| `gp branch graph [project]` | Decorated commit graph (up to 40 commits) |
| `gp history` | Last 30 bulk operation records |
| `gp all status --json` | Cached state as JSON (Linux requires python3) |
| `gp all status --dirty` | Dirty repositories |
| `gp all status --ahead` | Repositories with local commits ahead |
| `gp all status --behind` | Repositories behind their upstream |
| `gp all dry-run` | Read-only, local-ref synchronization candidates; no fetch/commit/push |
| `gp --no-color overview` | Disable GPush output colors |

Visual previews do not contact remotes unless Fetch or Sync is explicitly selected. Sync preserves protected-branch checks. Stats include all authors on each repository's current branch; shared commits may be counted across repositories. ASCII bars are used for compatibility. Bulk progress advances per completed repository; updater progress advances per milestone. History records local paths and operation results, not commit contents.

### Windows update reliability (4.5.1)

The updater prefers `curl.exe`, falls back to `Invoke-WebRequest`, bypasses HTTP caches and retries failed downloads up to three times. A matching published SHA-256 is required before installation. Older clients affected by stale downloads may need a one-time manual upgrade using a verified release archive.
