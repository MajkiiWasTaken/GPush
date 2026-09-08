# GPush

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=for-the-badge&logo=powershell&logoColor=white)
![Git](https://img.shields.io/badge/Git-required-F05032?style=for-the-badge&logo=git&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-supported-0078D6?style=for-the-badge&logo=windows&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)

GPush is a small PowerShell helper for finding Git repositories, committing changes and pushing them without manually navigating between project folders.

It shows the current branch and changed files, runs `git add .`, creates the commit and pushes it. If the remote is ahead, GPush can automatically run `git pull --rebase` and retry the push.

<img width="699" height="785" alt="image" src="https://github.com/user-attachments/assets/bb6dd591-b5d9-4b70-94be-b58d49f1b2c8" />

---

### Install

Requirements: **Windows**, **PowerShell 5.1+** and **Git in PATH**.

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The installer saves repository search directories to:

```text
%LOCALAPPDATA%\GPush\config.json
```

and adds the `gp` command to your PowerShell profile.

Reload the profile after installation:

```powershell
. $PROFILE
```

---

### Usage

```powershell
gp MyProject "Fix packet parser"
gp MyProject

gp --status MyProject
gp --diff MyProject
gp --pull MyProject

gp --dry-run MyProject "Test commit"
gp --no-push MyProject "Local checkpoint"

gp --list
gp --refresh
gp --refresh --list

gp --add .
gp --add C:\path\to\repository

gp --help
```

If no commit message is supplied, GPush asks for it interactively.

### Options

| Option | Description |
|---|---|
| `-h`, `--help` | Show help |
| `-v`, `--version` | Show version |
| `-l`, `--list` | List cached repositories |
| `-r`, `--refresh` | Rescan repositories and rebuild the cache |
| `--add` | Add a repository to the cache manually |
| `-s`, `--status` | Show repository, branch, remote and sync state |
| `--diff` | Show local diff statistics |
| `--pull` | Run a safe `git pull --rebase` |
| `--dry-run` | Preview actions without changing Git state |
| `--no-push` | Commit locally without fetching or pushing |
| `--cached` | Use the existing repository cache only |

---

### Safety

GPush performs preflight checks before changing the repository and does **not** resolve merge or rebase conflicts automatically.

If a rebase fails:

```powershell
git add .
git rebase --continue
```

or cancel it with:

```powershell
git rebase --abort
```

---

### Author

**Michal Švrček**

GPush **3.1.2** · Distributed under the MIT License.
