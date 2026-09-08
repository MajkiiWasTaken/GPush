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
gp all fetch
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
| `favorite` | Favorite repositories |
| `all` | Status, fetch or sync all repositories |
| `clone` | Clone and cache a repository |
| `recent` | Show recently used repositories |

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
