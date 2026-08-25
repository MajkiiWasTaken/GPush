param(
    [Parameter(Position = 0)]
    [string]$Project,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$CommitMessageParts
)

# ============================================================
# CONFIGURATION
# Add directories where your Git repositories are located.
# ============================================================

$SearchRoots = @(
    "$HOME\Documents\Projects"
    # "$HOME\source\repos"
    # "D:\Projects"
    # "C:\Git"
)

$CacheDir  = Join-Path $env:LOCALAPPDATA "GPush"
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
# OUTPUT HELPERS
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

# ============================================================
# GIT STATUS CODE TRANSLATION
# Converts the raw two-letter codes from "git status --short"
# (e.g. "??", " M", "A ", "D ") into a readable label + color.
# ============================================================

function Get-StatusInfo {
    param([string]$Code)

    switch -Regex ($Code) {
        '^\?\?$' { return @{ Label = "Added";     Color = "Green"  } } # untracked / new file
        '^A.$'   { return @{ Label = "Added";     Color = "Green"  } } # staged new file
        '^.A$'   { return @{ Label = "Added";     Color = "Green"  } }
        '^M.$'   { return @{ Label = "Modified";  Color = "Yellow" } } # staged modification
        '^.M$'   { return @{ Label = "Modified";  Color = "Yellow" } } # unstaged modification
        '^D.$'   { return @{ Label = "Deleted";   Color = "Red"    } }
        '^.D$'   { return @{ Label = "Deleted";   Color = "Red"    } }
        '^R.$'   { return @{ Label = "Renamed";   Color = "Cyan"   } }
        '^C.$'   { return @{ Label = "Copied";    Color = "Cyan"   } }
        '^U.$'   { return @{ Label = "Conflict";  Color = "Red"    } }
        '^.U$'   { return @{ Label = "Conflict";  Color = "Red"    } }
        default  { return @{ Label = $Code.Trim(); Color = "White" } }
    }
}

function Format-StatusLine {
    param([string]$Line)

    # git status --short lines look like: "XY path"
    # XY is a fixed 2-char code, followed by a space, then the path.
    $code = $Line.Substring(0, 2)
    $path = $Line.Substring(3)

    $info = Get-StatusInfo -Code $code

    Write-Host ("  [{0,-8}] " -f $info.Label) `
        -NoNewline `
        -ForegroundColor $info.Color

    Write-Host $path
}

# ============================================================
# CHECK DEPENDENCIES
# ============================================================

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Err "Git was not found."
    Write-Host ""
    Write-Host "Install Git and make sure it is available in PATH."
    exit 1
}

# ============================================================
# REPOSITORY SCANNER
# ============================================================

function Find-GitRepositories {
    param(
        [string[]]$Roots
    )

    $result = @()

    foreach ($root in $Roots) {

        $expandedRoot = [Environment]::ExpandEnvironmentVariables($root)

        if (-not (Test-Path $expandedRoot)) {
            Write-Warn "Search root does not exist: $expandedRoot"
            continue
        }

        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push($expandedRoot)

        while ($stack.Count -gt 0) {

            $current = $stack.Pop()

            try {

                $gitPath = Join-Path $current ".git"

                # A .git entry may be either a directory or a file
                # (for example when using Git worktrees).
                if (Test-Path $gitPath) {

                    $repoName = Split-Path $current -Leaf

                    $result += [PSCustomObject]@{
                        Name = $repoName
                        Path = $current
                    }

                    # Repository found.
                    # Do not scan deeper inside it.
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
                # Skip inaccessible directories.
            }
        }
    }

    return @(
        $result |
            Sort-Object Path -Unique |
            Sort-Object Name, Path
    )
}

# ============================================================
# CACHE
# ============================================================

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

# ============================================================
# REPOSITORY SELECTION
# ============================================================

function Select-Repository {
    param(
        $Repos,
        [string]$Search
    )

    if ([string]::IsNullOrWhiteSpace($Search)) {
        $Search = Read-Host "Project"
    }

    # First try repositories whose names start with the query.
    $matches = @(
        $Repos | Where-Object {
            $_.Name -ilike "$Search*"
        }
    )

    # If nothing matches, search anywhere in the repository name.
    if ($matches.Count -eq 0) {
        $matches = @(
            $Repos | Where-Object {
                $_.Name -ilike "*$Search*"
            }
        )
    }

    # Finally search the full path.
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

    # Only one repository matched.
    if ($matches.Count -eq 1) {
        return $matches[0]
    }

    # Multiple repositories matched.
    Write-Host ""
    Write-Warn "Multiple repositories found:"
    Write-Host ""

    for ($i = 0; $i -lt $matches.Count; $i++) {

        Write-Host "[$($i + 1)] " `
            -NoNewline `
            -ForegroundColor DarkGray

        Write-Host $matches[$i].Name `
            -ForegroundColor White

        Write-Host "    $($matches[$i].Path)" `
            -ForegroundColor DarkGray
    }

    Write-Host ""

    while ($true) {

        $selection = Read-Host "Select repository"

        $number = 0

        if ([int]::TryParse($selection, [ref]$number)) {

            $index = $number - 1

            if (
                $index -ge 0 -and
                $index -lt $matches.Count
            ) {
                return $matches[$index]
            }
        }

        Write-Err "Invalid selection."
    }
}

# ============================================================
# SCAN REPOSITORIES
# ============================================================

Write-Host ""
Write-Info "Scanning Git repositories..."

$repos = @(Find-GitRepositories -Roots $SearchRoots)

if ($repos.Count -eq 0) {
    Write-Host ""
    Write-Err "No Git repositories found."
    Write-Host ""
    Write-Host "Check the SearchRoots configuration in gp.ps1."
    exit 1
}

Save-Cache -Repos $repos

Write-Ok "Found $($repos.Count) repositories."
Write-Host "Cache: $CacheFile" -ForegroundColor DarkGray

# ============================================================
# SELECT REPOSITORY
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

if ([string]::IsNullOrWhiteSpace($branch)) {
    $branch = "DETACHED HEAD"
}

Write-Host ""
Write-Host "Branch: " `
    -NoNewline `
    -ForegroundColor DarkGray

Write-Host $branch `
    -ForegroundColor Magenta

# ============================================================
# STATUS
# ============================================================

$status = @(git status --short)

if ($LASTEXITCODE -ne 0) {
    Write-Err "Could not read repository status."
    exit 1
}

Write-Host ""

if ($status.Count -eq 0) {
    Write-Warn "No local changes."
}
else {

    Write-Info "Changes:"

    foreach ($line in $status) {
        Format-StatusLine -Line $line
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

$pushOutput = @(git push 2>&1)
$pushExit = $LASTEXITCODE

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

# Detect a rejected push caused by the remote branch
# containing commits that are not available locally.
$remoteAhead = (
    $pushText -match "non-fast-forward" -or
    $pushText -match "fetch first" -or
    $pushText -match "\[rejected\]"
)

if (-not $remoteAhead) {

    Write-Host ""
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

    Write-Host "  git add ." `
        -ForegroundColor Cyan

    Write-Host "  git rebase --continue" `
        -ForegroundColor Cyan

    Write-Host ""
    Write-Host "When the rebase is finished:"
    Write-Host ""

    Write-Host "  git push" `
        -ForegroundColor Cyan

    Write-Host ""
    Write-Host "To cancel the rebase:"
    Write-Host ""

    Write-Host "  git rebase --abort" `
        -ForegroundColor Cyan

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