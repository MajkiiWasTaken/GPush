
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ScriptVersion = "2.0.0"

# ============================================================
# CONFIGURATION
# Add directories where your Git repositories are located.
# ============================================================

$CacheDir   = Join-Path $env:LOCALAPPDATA "GPush"
$CacheFile  = Join-Path $CacheDir "repos.json"
$ConfigFile = Join-Path $CacheDir "config.json"

# Search roots are normally created by install.ps1.
# These values are only a fallback when no configuration exists yet.
$SearchRoots = @(
    "$HOME\Documents\Projects"
)

if (Test-Path $ConfigFile) {
    try {
        $config = Get-Content -Path $ConfigFile -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop

        if ($config.SearchRoots) {
            $SearchRoots = @($config.SearchRoots)
        }
    }
    catch {
        Write-Warn "Could not read configuration: $ConfigFile"
        Write-Warn "Using the built-in fallback search root."
    }
}

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

function Show-Help {
    Write-Host ""
    Write-Host "GP " -NoNewline -ForegroundColor Cyan
    Write-Host $ScriptVersion -NoNewline -ForegroundColor DarkGray
    Write-Host " - simple Git repository helper" -ForegroundColor White
    Write-Host ""

    Write-Host "USAGE" -ForegroundColor Yellow
    Write-Host "  gp " -NoNewline -ForegroundColor Green; Write-Host "<project> [commit message]"
    Write-Host "  gp " -NoNewline -ForegroundColor Green; Write-Host "[options] <project> [commit message]"
    Write-Host "  gp " -NoNewline -ForegroundColor Green; Write-Host "--status <project>" -ForegroundColor Cyan
    Write-Host "  gp " -NoNewline -ForegroundColor Green; Write-Host "--pull <project>" -ForegroundColor Cyan
    Write-Host "  gp " -NoNewline -ForegroundColor Green; Write-Host "--list" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "OPTIONS" -ForegroundColor Yellow
    $options = @(
        @("-h, --help",    "Show this help."),
        @("-v, --version", "Show GP version."),
        @("--list",         "List discovered Git repositories."),
        @("--status",       "Show branch and working tree status only."),
        @("--pull",         "Run 'git pull --rebase' only."),
        @("--dry-run",      "Show what would be done without changing anything."),
        @("--no-push",      "Add and commit changes, but do not push."),
        @("--cached",       "Use the repository cache instead of scanning."),
        @("--refresh",      "Force a repository scan and refresh the cache."),
        @("--",             "Stop parsing options.")
    )
    foreach ($option in $options) {
        Write-Host ("  {0,-18}" -f $option[0]) -NoNewline -ForegroundColor Cyan
        Write-Host $option[1]
    }
    Write-Host ""

    Write-Host "EXAMPLES" -ForegroundColor Yellow
    @(
        'gp FooBar "Fix packet parser"',
        'gp --status FooBar',
        'gp --dry-run FooBar "Test commit"',
        'gp --no-push FooBar "Local work"',
        'gp --pull FooBar',
        'gp --list',
        'gp --refresh --list',
        'gp --cached FooBar "Quick commit"'
    ) | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
    Write-Host ""

    Write-Host "NORMAL WORKFLOW" -ForegroundColor Yellow
    Write-Host "  1. " -NoNewline -ForegroundColor DarkGray; Write-Host "Find the repository."
    Write-Host "  2. " -NoNewline -ForegroundColor DarkGray; Write-Host "Show branch and local changes."
    Write-Host "  3. " -NoNewline -ForegroundColor DarkGray
    Write-Host "Run " -NoNewline; Write-Host "'git add .'" -ForegroundColor Cyan
    Write-Host "  4. " -NoNewline -ForegroundColor DarkGray; Write-Host "Create a commit when changes exist."
    Write-Host "  5. " -NoNewline -ForegroundColor DarkGray; Write-Host "Push to the remote."
    Write-Host "  6. " -NoNewline -ForegroundColor DarkGray
    Write-Host "If push is rejected because the remote is ahead, run"
    Write-Host "     'git pull --rebase'" -NoNewline -ForegroundColor Cyan
    Write-Host " and try the push again."
    Write-Host ""

    Write-Host "CACHE" -ForegroundColor Yellow
    Write-Host "  $CacheFile" -ForegroundColor DarkGray
    Write-Host ""
}

# ============================================================
# ARGUMENT PARSER
# ============================================================

$ShowHelp = $false
$ShowVersion = $false
$ListRepos = $false
$StatusOnly = $false
$PullOnly = $false
$DryRun = $false
$NoPush = $false
$UseCache = $false
$Refresh = $false
$StopOptionParsing = $false
$Positional = [System.Collections.Generic.List[string]]::new()

foreach ($arg in @($Arguments)) {
    if ($StopOptionParsing) {
        $Positional.Add($arg)
        continue
    }

    switch ($arg) {
        "--"        { $StopOptionParsing = $true }
        "-h"        { $ShowHelp = $true }
        "--help"    { $ShowHelp = $true }
        "-v"        { $ShowVersion = $true }
        "--version" { $ShowVersion = $true }
        "--list"    { $ListRepos = $true }
        "--status"  { $StatusOnly = $true }
        "--pull"    { $PullOnly = $true }
        "--dry-run" { $DryRun = $true }
        "--no-push" { $NoPush = $true }
        "--cached"  { $UseCache = $true }
        "--refresh" { $Refresh = $true }
        default {
            if ($arg.StartsWith("-")) {
                Write-Err "Unknown option: $arg"
                Write-Host "Run 'gp --help' for usage."
                exit 2
            }
            $Positional.Add($arg)
        }
    }
}

if ($ShowHelp) { Show-Help; exit 0 }
if ($ShowVersion) { Write-Host "GP $ScriptVersion"; exit 0 }
if ($StatusOnly -and $PullOnly) {
    Write-Err "'--status' and '--pull' cannot be used together."
    exit 2
}
if ($Refresh) { $UseCache = $false }

$Project = $null
$CommitMessageParts = @()
if ($Positional.Count -gt 0) { $Project = $Positional[0] }
if ($Positional.Count -gt 1) { $CommitMessageParts = @($Positional | Select-Object -Skip 1) }

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

function Load-Cache {
    if (-not (Test-Path $CacheFile)) { return @() }

    try {
        $data = Get-Content -Path $CacheFile -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop

        return @(
            @($data) |
                Where-Object {
                    $_.Name -and $_.Path -and
                    (Test-Path $_.Path) -and
                    (Test-Path (Join-Path $_.Path ".git"))
                } |
                Sort-Object Name, Path
        )
    }
    catch {
        Write-Warn "Repository cache could not be read."
        return @()
    }
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
# LOAD / SCAN REPOSITORIES
# ============================================================

$repos = @()

if ($UseCache) {
    Write-Host ""
    Write-Info "Loading Git repositories from cache..."
    $repos = @(Load-Cache)

    if ($repos.Count -eq 0) {
        Write-Warn "Cache is empty or unavailable. Scanning instead..."
        $UseCache = $false
    }
}

if (-not $UseCache) {
    Write-Host ""
    Write-Info "Scanning Git repositories..."
    $repos = @(Find-GitRepositories -Roots $SearchRoots)

    if ($repos.Count -gt 0) {
        Save-Cache -Repos $repos
    }
}

if ($repos.Count -eq 0) {
    Write-Host ""
    Write-Err "No Git repositories found."
    Write-Host ""
    Write-Host "Run install.ps1 again or edit: $ConfigFile"
    exit 1
}

if ($UseCache) {
    Write-Ok "Loaded $($repos.Count) repositories from cache."
}
else {
    Write-Ok "Found $($repos.Count) repositories."
    Write-Host "Cache: $CacheFile" -ForegroundColor DarkGray
}

if ($ListRepos) {
    Write-Host ""
    foreach ($item in $repos) {
        Write-Host ("  {0,-30}" -f $item.Name) -NoNewline -ForegroundColor White
        Write-Host $item.Path -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Info "Total: $($repos.Count)"
    exit 0
}

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

if ($StatusOnly) {
    exit 0
}

if ($PullOnly) {
    Write-Host ""

    if ($DryRun) {
        Write-Warn "[DRY RUN] git pull --rebase"
        exit 0
    }

    Write-Info "[PULL] git pull --rebase"
    git pull --rebase

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Err "[PULL] REBASE FAILED"
        exit 1
    }

    Write-Host ""
    Write-Ok "[PULL] OK"
    exit 0
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
    if ($DryRun) {
        $commitMessage = "<commit message>"
    }
    else {
        Write-Host ""
        $commitMessage = Read-Host "Commit message"
    }
}

if (
    $status.Count -gt 0 -and
    [string]::IsNullOrWhiteSpace($commitMessage)
) {
    Write-Err "Commit message cannot be empty."
    exit 1

}

if ($DryRun) {
    Write-Host ""
    Write-Warn "DRY RUN - no changes will be made."

    if ($status.Count -gt 0) {
        Write-Host ""
        Write-Info "[DRY RUN] git add ."
        Write-Info "[DRY RUN] git commit -m `"$commitMessage`""
    }

    if ($NoPush) {
        Write-Host ""
        Write-Info "[DRY RUN] Push skipped (--no-push)."
    }
    else {
        Write-Host ""
        Write-Info "[DRY RUN] git push"
        Write-Info "[DRY RUN] If rejected because remote is ahead: git pull --rebase, then git push"
    }

    exit 0
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
# OPTIONAL LOCAL-ONLY MODE
# ============================================================

if ($NoPush) {
    Write-Host ""

    if ($status.Count -gt 0) {
        Write-Ok "Commit created locally. Push skipped (--no-push)."
    }
    else {
        Write-Warn "Nothing to commit. Push skipped (--no-push)."
    }

    exit 0
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