param(
    [Parameter(Position = 0)]
    [string]$Project,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$CommitMessageParts
)

# ============================================================
# CONFIG
# ============================================================

$SearchRoots = @(
    "C:\Users\SvrcekM\Documents\Project"
    # "D:\Projects"
    # "C:\Git"
)

$CacheDir  = Join-Path $env:LOCALAPPDATA "GitPush"
$CacheFile = Join-Path $CacheDir "repos.json"

$IgnoredDirectories = @(
    "node_modules",
    "bin",
    "obj",
    ".venv",
    "venv",
    "target",
    "packages",
    ".vs",
    ".idea"
)

# ============================================================
# HELPERS
# ============================================================

function Write-Info {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Red
}

function Find-GitRepositories {
    param(
        [string[]]$Roots
    )

    $result = @()

    foreach ($root in $Roots) {

        if (-not (Test-Path $root)) {
            Write-Warn "Search root does not exist: $root"
            continue
        }

        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push($root)

        while ($stack.Count -gt 0) {

            $current = $stack.Pop()

            try {
                $gitPath = Join-Path $current ".git"

                if (Test-Path $gitPath) {

                    $repoName = Split-Path $current -Leaf

                    $result += [PSCustomObject]@{
                        Name = $repoName
                        Path = $current
                    }

                    # Repo nalezeno -> dál dovnitř už nemusíme.
                    continue
                }

                $directories = Get-ChildItem `
                    -Path $current `
                    -Directory `
                    -Force `
                    -ErrorAction SilentlyContinue

                foreach ($dir in $directories) {

                    if ($IgnoredDirectories -contains $dir.Name) {
                        continue
                    }

                    $stack.Push($dir.FullName)
                }
            }
            catch {
                # Nedostupnou složku jednoduše přeskočíme.
            }
        }
    }

    return $result | Sort-Object Name, Path
}

function Save-Cache {
    param($Repos)

    if (-not (Test-Path $CacheDir)) {
        New-Item `
            -ItemType Directory `
            -Path $CacheDir `
            -Force | Out-Null
    }

    $Repos |
        ConvertTo-Json -Depth 4 |
        Set-Content `
            -Path $CacheFile `
            -Encoding UTF8
}

function Select-Repository {
    param(
        $Repos,
        [string]$Search
    )

    if ([string]::IsNullOrWhiteSpace($Search)) {
        $Search = Read-Host "Project"
    }

    # 1. Nejprve všechny názvy začínající hledaným textem
    $matches = @(
        $Repos | Where-Object {
            $_.Name -ilike "$Search*"
        }
    )

    # 2. Pokud nic, hledej kdekoliv v názvu
    if ($matches.Count -eq 0) {
        $matches = @(
            $Repos | Where-Object {
                $_.Name -ilike "*$Search*"
            }
        )
    }

    # 3. Pokud stále nic, zkus cestu
    if ($matches.Count -eq 0) {
        $matches = @(
            $Repos | Where-Object {
                $_.Path -ilike "*$Search*"
            }
        )
    }

    if ($matches.Count -eq 0) {
        Write-Host ""
        Write-Err "Repository '$Search' not found."
        return $null
    }

    # Jediný výsledek = rovnou použij
    if ($matches.Count -eq 1) {
        return $matches[0]
    }

    # Více výsledků = nabídnout výběr
    Write-Host ""
    Write-Warn "Multiple repositories found:"
    Write-Host ""

    for ($i = 0; $i -lt $matches.Count; $i++) {
        Write-Host "[$($i + 1)] " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($matches[$i].Name)" -ForegroundColor White
        Write-Host "    $($matches[$i].Path)" -ForegroundColor DarkGray
    }

    Write-Host ""

    while ($true) {
        $selection = Read-Host "Select repository"

        $number = 0

        if ([int]::TryParse($selection, [ref]$number)) {
            $index = $number - 1

            if ($index -ge 0 -and $index -lt $matches.Count) {
                return $matches[$index]
            }
        }

        Write-Err "Invalid selection."
    }
}

# ============================================================
# SCAN
# ============================================================

Write-Host ""
Write-Info "Scanning Git repositories..."

$repos = @(Find-GitRepositories -Roots $SearchRoots)

if ($repos.Count -eq 0) {
    Write-Err "No Git repositories found."
    exit 1
}

Save-Cache -Repos $repos

Write-Ok "Found $($repos.Count) repositories."
Write-Host "Cache: $CacheFile" -ForegroundColor DarkGray

# ============================================================
# SELECT PROJECT
# ============================================================

$repo = Select-Repository `
    -Repos $repos `
    -Search $Project

if ($null -eq $repo) {
    exit 1
}

Write-Host ""
Write-Info "Repository"
Write-Host "  $($repo.Name)" -ForegroundColor White
Write-Host "  $($repo.Path)" -ForegroundColor DarkGray

Set-Location $repo.Path

# ============================================================
# BRANCH
# ============================================================

$branch = git branch --show-current

if ($LASTEXITCODE -ne 0) {
    Write-Err "Could not determine Git branch."
    exit 1
}

Write-Host ""
Write-Host "Branch: " -NoNewline -ForegroundColor DarkGray
Write-Host $branch -ForegroundColor Magenta

# ============================================================
# STATUS
# ============================================================

$status = @(git status --short)

Write-Host ""

if ($status.Count -eq 0) {

    Write-Warn "No local changes."

}
else {

    Write-Info "Changes:"

    foreach ($line in $status) {
        Write-Host "  $line"
    }
}

# ============================================================
# COMMIT MESSAGE
# ============================================================

$commitMessage = ""

if ($CommitMessageParts) {
    $commitMessage = $CommitMessageParts -join " "
}

if (
    $status.Count -gt 0 -and
    [string]::IsNullOrWhiteSpace($commitMessage)
) {
    Write-Host ""
    $commitMessage = Read-Host "Commit message"
}

if (
    $status.Count -gt 0 -and
    [string]::IsNullOrWhiteSpace($commitMessage)
) {
    Write-Err "Commit message cannot be empty."
    exit 1
}

# ============================================================
# ADD + COMMIT
# ============================================================

if ($status.Count -gt 0) {

    Write-Host ""
    Write-Info "[ADD] git add ."

    git add .

    if ($LASTEXITCODE -ne 0) {
        Write-Err "[ADD] FAILED"
        exit 1
    }

    Write-Ok "[ADD] OK"

    Write-Host ""
    Write-Info "[COMMIT] $commitMessage"

    git commit -m "$commitMessage"

    if ($LASTEXITCODE -ne 0) {
        Write-Err "[COMMIT] FAILED"
        exit 1
    }

    Write-Ok "[COMMIT] OK"
}

# ============================================================
# PUSH
# ============================================================

Write-Host ""
Write-Info "[PUSH] git push"

$pushOutput = git push 2>&1
$pushExit   = $LASTEXITCODE

$pushOutput | ForEach-Object {
    Write-Host $_
}

if ($pushExit -eq 0) {

    Write-Host ""
    Write-Ok "[PUSH] OK"
    Write-Host ""
    Write-Ok "Done."
    exit 0
}

# ============================================================
# PUSH FAILED
# ============================================================

Write-Host ""
Write-Warn "[PUSH] Failed."

$pushText = $pushOutput -join "`n"

# Typický případ:
# ! [rejected] main -> main (fetch first)
# ! [rejected] main -> main (non-fast-forward)

$remoteAhead = (
    $pushText -match "non-fast-forward" -or
    $pushText -match "fetch first" -or
    $pushText -match "rejected"
)

if (-not $remoteAhead) {

    Write-Err ""
    Write-Err "Push failed for another reason."
    Write-Err "Automatic pull will NOT be attempted."
    exit 1
}

# ============================================================
# PULL --REBASE
# ============================================================

Write-Host ""
Write-Warn "Remote contains newer commits."
Write-Info "[PULL] git pull --rebase"

git pull --rebase

if ($LASTEXITCODE -ne 0) {

    Write-Host ""
    Write-Err "[PULL] REBASE FAILED"
    Write-Host ""
    Write-Warn "There is probably a merge conflict."
    Write-Host ""
    Write-Host "Resolve the conflicting files, then run:"
    Write-Host ""
    Write-Host "  git add ." -ForegroundColor Cyan
    Write-Host "  git rebase --continue" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "When the rebase is finished:"
    Write-Host ""
    Write-Host "  git push" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "To cancel the rebase:"
    Write-Host ""
    Write-Host "  git rebase --abort" -ForegroundColor Cyan

    exit 1
}

Write-Ok "[PULL] OK"

# ============================================================
# PUSH AGAIN
# ============================================================

Write-Host ""
Write-Info "[PUSH] Trying again..."

git push

if ($LASTEXITCODE -ne 0) {

    Write-Host ""
    Write-Err "[PUSH] FAILED AGAIN"
    exit 1
}

Write-Host ""
Write-Ok "[PUSH] OK"
Write-Host ""
Write-Ok "Done."