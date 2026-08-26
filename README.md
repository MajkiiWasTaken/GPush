# GPush

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=for-the-badge&logo=powershell&logoColor=white)
![Git](https://img.shields.io/badge/Git-required-F05032?style=for-the-badge&logo=git&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-supported-0078D6?style=for-the-badge&logo=windows&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)

GPush is a small PowerShell helper for finding Git repositories, committing changes and pushing them without manually navigating between project folders.

It shows the current branch and changed files, runs `git add .`, creates the commit and pushes it. If the remote is ahead, GPush can automatically run `git pull --rebase` and retry the push.

<img width="780" height="898" alt="image" src="https://github.com/user-attachments/assets/b18aa10e-5be2-4550-b8ef-f569d1325252" />

---

### Install

Requirements: **Windows**, **PowerShell 5.1+** and **Git in PATH**.

Clone the repository and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The installer:

- detects or asks for directories containing your repositories,
- saves them to `%LOCALAPPDATA%\GPush\config.json`,
- adds the `gp` command to your PowerShell profile,
- updates an existing GPush profile entry safely.

Reload the profile after installation:

```powershell
. $PROFILE
```

You can also provide repository directories directly:

```powershell
.\install.ps1 -SearchRoot "D:\Projects","C:\Work"
```

Run the installer again whenever you want to change the configured repository directories.

---

### Usage

```powershell
gp MyProject "Fix packet parser"
gp MyProject
gp --status MyProject
gp --pull MyProject
gp --dry-run MyProject "Test commit"
gp --no-push MyProject "Local checkpoint"
gp --list
gp --refresh --list
gp --cached MyProject "Quick commit"
gp --help
```

If no commit message is supplied, GPush asks for it interactively.

### Options

| Option | Description |
|---|---|
| `-h`, `--help` | Show help |
| `-v`, `--version` | Show version |
| `--list` | List discovered repositories |
| `--status` | Show branch and working tree status only |
| `--pull` | Run `git pull --rebase` only |
| `--dry-run` | Preview actions without changing anything |
| `--no-push` | Commit locally without pushing |
| `--cached` | Use the saved repository cache |
| `--refresh` | Rescan repositories and refresh the cache |

---

### Safety

GPush does **not** resolve merge or rebase conflicts automatically. If a rebase fails, resolve the conflict manually and continue with:

```powershell
git add .
git rebase --continue
git push
```

To cancel the rebase:

```powershell
git rebase --abort
```

---

### Author

Michal Švrček

Distributed under the MIT License.
