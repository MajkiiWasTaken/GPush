param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$RawArguments = @($Arguments)

# ============================================================
# ENCODING
# ============================================================

[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding           = [System.Text.UTF8Encoding]::new($false)

# Keep non-ASCII author characters independent of source-file encoding.
$AuthorName = "Michal " + [char]0x0160 + "vr" + [char]0x010D + "ek"

# ============================================================
# CONFIGURATION
# ============================================================

$ScriptVersion = "3.2.0"

$CacheDir   = Join-Path $env:LOCALAPPDATA "GPush"
$CacheFile  = Join-Path $CacheDir "repos.json"
$ConfigFile = Join-Path $CacheDir "config.json"

# Search roots are normally created by install.ps1.
# This value is only a fallback when no configuration exists yet.
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
        Write-Host "Could not read configuration: $ConfigFile" -ForegroundColor Yellow
        Write-Host "Using the built-in fallback search root." -ForegroundColor Yellow
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

function Write-Dim {
    param([string]$Text)
    Write-Host $Text -ForegroundColor DarkGray
}

function Write-KeyValue {
    param(
        [string]$Key,
        [string]$Value,
        [ConsoleColor]$ValueColor = [ConsoleColor]::White
    )

    Write-Host ("  {0,-12}" -f $Key) -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor $ValueColor
}

function Write-Section {
    param([string]$Title)

    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
}

function Write-Separator {
    Write-Host ""
    Write-Host ("-" * 52) -ForegroundColor DarkGray
}

function Show-Banner {
    Write-Host ""
    Write-Host "GPush " -NoNewline -ForegroundColor Cyan
    Write-Host $ScriptVersion -ForegroundColor DarkGray
    Write-Host "Made by " -NoNewline -ForegroundColor DarkGray
    Write-Host $AuthorName -ForegroundColor Magenta
}

function Show-Help {
    Show-Banner
    Write-Host "A small Git helper for finding repositories, checking sync state,"
    Write-Host "committing local changes, and pushing the current branch safely."
    Write-Host ""

    Write-Host "USAGE" -ForegroundColor Yellow
    Write-Host "  gp " -NoNewline -ForegroundColor Green
    Write-Host "<project> [commit message]" -ForegroundColor White
    Write-Host "  gp " -NoNewline -ForegroundColor Green
    Write-Host "[options] <project> [commit message]" -ForegroundColor White
    Write-Host "  gp " -NoNewline -ForegroundColor Green
    Write-Host "--list" -ForegroundColor Cyan
    Write-Host "  gp " -NoNewline -ForegroundColor Green
    Write-Host "--help" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "OPTIONS" -ForegroundColor Yellow
    Write-Host "  -h, --help          " -NoNewline -ForegroundColor Cyan
    Write-Host "Show this help and exit."
    Write-Host "  -v, --version       " -NoNewline -ForegroundColor Cyan
    Write-Host "Show the script version and exit."
    Write-Host "  -l, --list          " -NoNewline -ForegroundColor Cyan
    Write-Host "List discovered Git repositories and exit."
    Write-Host "  -r, --refresh       " -NoNewline -ForegroundColor Cyan
    Write-Host "Force a new repository scan, refresh the cache, and exit when no project is supplied."
    Write-Host "      --add           " -NoNewline -ForegroundColor Cyan
    Write-Host "Add a Git repository to the cache manually."
    Write-Host "                      Examples: gp --add ." -ForegroundColor DarkGray
    Write-Host "                                gp --add C:\path\to\repository" -ForegroundColor DarkGray
    Write-Host "      --cached        " -NoNewline -ForegroundColor Cyan
    Write-Host "Use the repository cache only. Kept for compatibility."
    Write-Host "  -s, --status        " -NoNewline -ForegroundColor Cyan
    Write-Host "Show repository, branch, remote, sync, and local status only."
    Write-Host "      --diff          " -NoNewline -ForegroundColor Cyan
    Write-Host "Show local changes and diff statistics only."
    Write-Host "      --renormalize   " -NoNewline -ForegroundColor Cyan
    Write-Host "Renormalize tracked files using .gitattributes and show status."
    Write-Host "      --fetch         " -NoNewline -ForegroundColor Cyan
    Write-Host "Fetch and prune the selected repository remote."
    Write-Host "      --log           " -NoNewline -ForegroundColor Cyan
    Write-Host "Show the last 10 commits."
    Write-Host "      --branches      " -NoNewline -ForegroundColor Cyan
    Write-Host "Show local and remote branches."
    Write-Host "      --remotes       " -NoNewline -ForegroundColor Cyan
    Write-Host "Show configured Git remotes."
    Write-Host "      --pull          " -NoNewline -ForegroundColor Cyan
    Write-Host "Run 'git pull --rebase' only. Do not commit or push."
    Write-Host "      --dry-run       " -NoNewline -ForegroundColor Cyan
    Write-Host "Preview add/commit/push actions without changing Git state."
    Write-Host "      --no-push       " -NoNewline -ForegroundColor Cyan
    Write-Host "Add and commit changes, but do not fetch, pull, or push."
    Write-Host "      --              " -NoNewline -ForegroundColor Cyan
    Write-Host "Stop option parsing. Useful if a commit message starts with '-'."
    Write-Host ""

    Write-Host "EXAMPLES" -ForegroundColor Yellow
    $examples = @(
        'gp RSUManager "Fix GNSS handling"',
        'gp RSUManager Fix GNSS handling',
        'gp --status RSUManager',
        'gp --diff RSUManager',
        'gp --renormalize',
        'gp --renormalize RSUManager',
        'gp --fetch RSUManager',
        'gp --log RSUManager',
        'gp --branches RSUManager',
        'gp --remotes RSUManager',
        'gp --pull RSUManager',
        'gp --dry-run RSUManager "Test commit"',
        'gp --no-push RSUManager "Local checkpoint"',
        'gp --list',
        'gp --refresh',
        'gp --refresh --list',
        'gp --add .',
        'gp --add "C:\Users\SvrcekM\Documents\Project\RSUManager"'
    )

    foreach ($example in $examples) {
        Write-Host "  $example" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "DEFAULT WORKFLOW" -ForegroundColor Yellow
    Write-Dim "  1. Find the repository from the local cache."
    Write-Dim "  2. Run Git preflight checks."
    Write-Dim "  3. Fetch the remote and compare local/remote history."
    Write-Dim "  4. Show local changes."
    Write-Dim "  5. Add and commit local changes when needed."
    Write-Dim "  6. Rebase onto the upstream branch when the remote is ahead."
    Write-Dim "  7. Push the branch and create upstream automatically if needed."
    Write-Dim "  8. Show a final summary."
    Write-Host ""

    Write-Host "SAFETY" -ForegroundColor Yellow
    Write-Dim "  - Merge conflicts are never resolved automatically."
    Write-Dim "  - GPush refuses to continue through an active merge or rebase."
    Write-Dim "  - Unresolved conflicts must be fixed manually."
    Write-Dim "  - If the remote cannot be checked, normal push mode stops before committing."
    Write-Dim "  - Use --no-push when you intentionally want a local-only commit."
    Write-Host ""

    Write-Host "CONFIGURATION" -ForegroundColor Yellow
    Write-Dim "  Config: $ConfigFile"
    Write-Dim "  Cache:  $CacheFile"
    Write-Host ""
}

# ============================================================
# ARGUMENT PARSING
# ============================================================

$tokens = @($RawArguments)

$ShowHelp    = $false
$ShowVersion = $false
$ListRepos   = $false
$Refresh     = $false
$AddRepo     = $false
$CachedOnly  = $false
$StatusOnly   = $false
$DiffOnly     = $false
$Renormalize  = $false
$FetchOnly    = $false
$LogOnly      = $false
$BranchesOnly = $false
$RemotesOnly  = $false
$PullOnly     = $false
$DryRun      = $false
$NoPush      = $false

$positionals = @()
$parseOptions = $true

foreach ($token in $tokens) {
    if ($parseOptions -and $token -eq "--") {
        $parseOptions = $false
        continue
    }

    if ($parseOptions -and $token.StartsWith("-")) {
        $handledOption = $true

        switch ($token.ToLowerInvariant()) {
            "-h"        { $ShowHelp = $true }
            "--help"    { $ShowHelp = $true }
            "-?"        { $ShowHelp = $true }
            "-v"        { $ShowVersion = $true }
            "--version" { $ShowVersion = $true }
            "-l"        { $ListRepos = $true }
            "--list"    { $ListRepos = $true }
            "-r"        { $Refresh = $true }
            "--refresh" { $Refresh = $true }
            "--add"     { $AddRepo = $true }
            "--cached"  { $CachedOnly = $true }
            "-s"        { $StatusOnly = $true }
            "--status"  { $StatusOnly = $true }
            "--diff"        { $DiffOnly = $true }
            "--renormalize" { $Renormalize = $true }
            "--fetch"       { $FetchOnly = $true }
            "--log"         { $LogOnly = $true }
            "--branches"    { $BranchesOnly = $true }
            "--remotes"     { $RemotesOnly = $true }
            "--pull"        { $PullOnly = $true }
            "--dry-run" { $DryRun = $true }
            "--no-push" { $NoPush = $true }
            default      { $handledOption = $false }
        }

        if ($handledOption) {
            continue
        }

        Write-Err "Unknown option: $token"
        Write-Dim "Run 'gp --help' to see available options."
        exit 2
    }

    $positionals += $token
}

if ($ShowHelp) {
    Show-Help
    exit 0
}

if ($ShowVersion) {
    Write-Host "GPush $ScriptVersion"
    exit 0
}

$exclusiveModes = @(
    $StatusOnly,
    $DiffOnly,
    $Renormalize,
    $FetchOnly,
    $LogOnly,
    $BranchesOnly,
    $RemotesOnly,
    $PullOnly
) | Where-Object { $_ }
if ($exclusiveModes.Count -gt 1) {
    Write-Err "Only one operation mode can be used at a time."
    exit 2
}

if ($PullOnly -and $DryRun) {
    Write-Err "Options '--pull' and '--dry-run' cannot be used together."
    exit 2
}

if ($PullOnly -and $NoPush) {
    Write-Err "Options '--pull' and '--no-push' cannot be used together."
    exit 2
}

if ($Refresh -and $CachedOnly) {
    Write-Err "Options '--refresh' and '--cached' cannot be used together."
    exit 2
}

if ($AddRepo -and (
    $Refresh -or $ListRepos -or $StatusOnly -or $DiffOnly -or $Renormalize -or
    $FetchOnly -or $LogOnly -or $BranchesOnly -or $RemotesOnly -or
    $PullOnly -or $DryRun -or $NoPush -or $CachedOnly
)) {
    Write-Err "Option '--add' cannot be combined with other operation modes."
    exit 2
}

$Project = $null
$CommitMessageParts = @()

if ($positionals.Count -gt 0) {
    $Project = $positionals[0]
}

if ($positionals.Count -gt 1) {
    $CommitMessageParts = @($positionals[1..($positionals.Count - 1)])
}

# ============================================================
# GIT HELPERS
# ============================================================

function Test-GitCommand {
    $git = Get-Command git -ErrorAction SilentlyContinue
    return ($null -ne $git)
}

function Get-GitOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & git @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if (-not $AllowFailure -and $exitCode -ne 0) {
        return [PSCustomObject]@{
            Success  = $false
            ExitCode = $exitCode
            Lines    = @($output)
            Text     = (@($output) -join "`n")
        }
    }

    return [PSCustomObject]@{
        Success  = ($exitCode -eq 0)
        ExitCode = $exitCode
        Lines    = @($output)
        Text     = (@($output) -join "`n")
    }
}

function Get-GitPath {
    param([string]$Name)

    $result = Get-GitOutput -Arguments @("rev-parse", "--git-path", $Name) -AllowFailure
    if (-not $result.Success -or [string]::IsNullOrWhiteSpace($result.Text)) {
        return $null
    }

    $path = $result.Text.Trim()

    if ([System.IO.Path]::IsPathRooted($path)) {
        return $path
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $path))
}

function Test-GitRef {
    param([string]$Ref)

    & git show-ref --verify --quiet $Ref
    return ($LASTEXITCODE -eq 0)
}

function Get-CommitShortHash {
    param([string]$Ref = "HEAD")

    $result = Get-GitOutput -Arguments @("rev-parse", "--short=8", $Ref) -AllowFailure
    if ($result.Success) {
        return $result.Text.Trim()
    }

    return "-"
}

function Get-CommitSubject {
    param([string]$Ref = "HEAD")

    $result = Get-GitOutput -Arguments @("log", "-1", "--pretty=%s", $Ref) -AllowFailure
    if ($result.Success) {
        return $result.Text.Trim()
    }

    return "-"
}

# ============================================================
# GIT STATUS CODE TRANSLATION
# ============================================================

function Get-StatusInfo {
    param([string]$Code)

    switch -Regex ($Code) {
        '^\?\?$' { return @{ Label = "Added";     Color = "Green"  } }
        '^A.$'    { return @{ Label = "Added";     Color = "Green"  } }
        '^.A$'    { return @{ Label = "Added";     Color = "Green"  } }
        '^M.$'    { return @{ Label = "Modified";  Color = "Yellow" } }
        '^.M$'    { return @{ Label = "Modified";  Color = "Yellow" } }
        '^D.$'    { return @{ Label = "Deleted";   Color = "Red"    } }
        '^.D$'    { return @{ Label = "Deleted";   Color = "Red"    } }
        '^R.$'    { return @{ Label = "Renamed";   Color = "Cyan"   } }
        '^C.$'    { return @{ Label = "Copied";    Color = "Cyan"   } }
        '^U.$'    { return @{ Label = "Conflict";  Color = "Red"    } }
        '^.U$'    { return @{ Label = "Conflict";  Color = "Red"    } }
        '^AA$'    { return @{ Label = "Conflict";  Color = "Red"    } }
        '^DD$'    { return @{ Label = "Conflict";  Color = "Red"    } }
        default   { return @{ Label = $Code.Trim(); Color = "White" } }
    }
}

function Format-StatusLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line) -or $Line.Length -lt 3) {
        Write-Host "  $Line"
        return
    }

    $code = $Line.Substring(0, 2)
    $path = $Line.Substring(3)
    $info = Get-StatusInfo -Code $code

    Write-Host ("  [{0,-8}] " -f $info.Label) -NoNewline -ForegroundColor $info.Color
    Write-Host $path
}

function Show-Changes {
    param([string[]]$Status)

    Write-Section "Changes"

    if ($Status.Count -eq 0) {
        Write-Ok "  Clean working tree."
        return
    }

    foreach ($line in $Status) {
        Format-StatusLine -Line $line
    }

    Write-Dim ""
    Write-Dim ("  {0} changed item(s)" -f $Status.Count)
}

# ============================================================
# REPOSITORY DISCOVERY / CACHE
# ============================================================

function Find-GitRepositories {
    param([string[]]$Roots)

    $result = @()
    $seen = @{}

    foreach ($root in $Roots) {
        if (-not (Test-Path $root)) {
            Write-Warn "Search root does not exist: $root"
            continue
        }

        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push((Resolve-Path $root).Path)

        while ($stack.Count -gt 0) {
            $current = $stack.Pop()

            try {
                $gitPath = Join-Path $current ".git"

                if (Test-Path $gitPath) {
                    $normalizedPath = [System.IO.Path]::GetFullPath($current)
                    $key = $normalizedPath.ToLowerInvariant()

                    if (-not $seen.ContainsKey($key)) {
                        $seen[$key] = $true

                        $result += [PSCustomObject]@{
                            Name = Split-Path $normalizedPath -Leaf
                            Path = $normalizedPath
                        }
                    }

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
                # Skip directories that cannot be accessed.
            }
        }
    }

    return @($result | Sort-Object Name, Path)
}

function ConvertTo-RepositoryList {
    param($InputObject)

    $normalized = @()

    foreach ($entry in @($InputObject)) {
        if ($null -eq $entry) {
            continue
        }

        # Flatten accidentally nested arrays from older cache versions.
        if ($entry -is [System.Array]) {
            foreach ($nested in @($entry)) {
                if ($nested -and $nested.Name -and $nested.Path) {
                    $normalized += [PSCustomObject]@{
                        Name = [string]$nested.Name
                        Path = [string]$nested.Path
                    }
                }
            }
            continue
        }

        if ($entry.Name -and $entry.Path) {
            $normalized += [PSCustomObject]@{
                Name = [string]$entry.Name
                Path = [string]$entry.Path
            }
        }
    }

    return @(
        $normalized |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_.Name) -and
                -not [string]::IsNullOrWhiteSpace($_.Path)
            } |
            Sort-Object Path -Unique |
            Sort-Object Name, Path
    )
}

function Save-Cache {
    param($Repos)

    if (-not (Test-Path $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }

    $cleanRepos = @(ConvertTo-RepositoryList -InputObject $Repos)

    # The leading comma forces JSON to always contain an array, even for one repo.
    ConvertTo-Json -InputObject @($cleanRepos) -Depth 4 |
        Set-Content -Path $CacheFile -Encoding UTF8
}

function Load-Cache {
    if (-not (Test-Path $CacheFile)) {
        return @()
    }

    try {
        $raw = Get-Content -Path $CacheFile -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop

        $cached = @(ConvertTo-RepositoryList -InputObject $raw)

        return @(
            $cached | Where-Object {
                $_.Name -and
                $_.Path -and
                (Test-Path $_.Path) -and
                (Test-Path (Join-Path $_.Path ".git"))
            } | Sort-Object Name, Path
        )
    }
    catch {
        Write-Warn "Repository cache is invalid and will be ignored."
        return @()
    }
}

function Add-RepositoryToCache {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)

    try {
        $resolved = (Resolve-Path -Path $expanded -ErrorAction Stop).Path
    }
    catch {
        Write-Err "Path does not exist: $Path"
        return $false
    }

    if (-not (Test-Path (Join-Path $resolved ".git"))) {
        Write-Err "Not a Git repository: $resolved"
        return $false
    }

    $repoToAdd = [PSCustomObject]@{
        Name = Split-Path $resolved -Leaf
        Path = $resolved
    }

    $current = @(Load-Cache)
    $combined = @($current + $repoToAdd)
    $combined = @(ConvertTo-RepositoryList -InputObject $combined)

    Save-Cache -Repos $combined

    Write-Ok "Repository added to cache."
    Write-KeyValue "Name" $repoToAdd.Name
    Write-KeyValue "Path" $repoToAdd.Path ([ConsoleColor]::DarkGray)
    Write-Dim "Cache: $CacheFile"

    return $true
}

function Get-Repositories {
    param(
        [bool]$ForceRefresh,
        [bool]$CacheOnly
    )

    $script:RepositorySource = "cache"

    if (-not $ForceRefresh) {
        $cachedRepos = @(Load-Cache)

        if ($cachedRepos.Count -gt 0) {
            Write-Info "Loading Git repositories from cache..."
            Write-Ok "Loaded $($cachedRepos.Count) repositories."
            Write-Dim "Cache: $CacheFile"
            return $cachedRepos
        }

        if ($CacheOnly) {
            Write-Err "No usable repository cache found."
            return @()
        }

        Write-Warn "No usable repository cache found. Running a full scan."
    }

    $script:RepositorySource = "scan"
    Write-Info "Scanning Git repositories..."
    $foundRepos = @(Find-GitRepositories -Roots $SearchRoots)

    if ($foundRepos.Count -gt 0) {
        Save-Cache -Repos $foundRepos
        Write-Ok "Found $($foundRepos.Count) repositories."
        Write-Dim "Cache: $CacheFile"
    }

    return $foundRepos
}

function Get-RepositoryMatches {
    param(
        $Repos,
        [string]$Search
    )

    if ([string]::IsNullOrWhiteSpace($Search)) {
        return @()
    }

    $matches = @($Repos | Where-Object { $_.Name -ieq $Search })
    if ($matches.Count -gt 0) {
        return $matches
    }

    $matches = @($Repos | Where-Object { $_.Name -ilike "$Search*" })
    if ($matches.Count -gt 0) {
        return $matches
    }

    $matches = @($Repos | Where-Object { $_.Name -ilike "*$Search*" })
    if ($matches.Count -gt 0) {
        return $matches
    }

    return @($Repos | Where-Object { $_.Path -ilike "*$Search*" })
}

function Select-Repository {
    param(
        $Repos,
        [string]$Search,
        [switch]$QuietNotFound
    )

    if ([string]::IsNullOrWhiteSpace($Search)) {
        $Search = Read-Host "Project"
    }

    $script:LastRepositorySearch = $Search
    $matches = @(Get-RepositoryMatches -Repos $Repos -Search $Search)

    if ($matches.Count -eq 0) {
        if (-not $QuietNotFound) {
            Write-Host ""
            Write-Err "Repository '$Search' not found."
        }
        return $null
    }

    if ($matches.Count -eq 1) {
        return $matches[0]
    }

    Write-Host ""
    Write-Warn "Multiple repositories found:"
    Write-Host ""

    for ($i = 0; $i -lt $matches.Count; $i++) {
        Write-Host "[$($i + 1)] " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($matches[$i].Name)" -ForegroundColor White
        Write-Dim "    $($matches[$i].Path)"
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
# MANUAL CACHE ADD
# ============================================================

if ($AddRepo) {
    Show-Banner

    if (-not (Test-GitCommand)) {
        Write-Err "Git was not found in PATH."
        exit 1
    }

    $pathToAdd = if ($positionals.Count -gt 0) {
        $positionals -join " "
    }
    else {
        "."
    }

    Write-Section "Add repository"
    if (Add-RepositoryToCache -Path $pathToAdd) {
        Write-Host ""
        exit 0
    }

    exit 1
}

# ============================================================
# CURRENT REPOSITORY FOR UTILITY MODES
# ============================================================

$UtilityMode = (
    $Renormalize -or
    $FetchOnly -or
    $LogOnly -or
    $BranchesOnly -or
    $RemotesOnly
)

$DirectRepositoryPath = $null

if ($UtilityMode -and [string]::IsNullOrWhiteSpace($Project)) {
    $currentRepo = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($currentRepo)) {
        $DirectRepositoryPath = $currentRepo.Trim()
    }
}

# ============================================================
# LOAD REPOSITORIES
# ============================================================

Show-Banner

if (-not (Test-GitCommand)) {
    Write-Err "Git was not found in PATH."
    exit 1
}

$repos = @()

if (-not $DirectRepositoryPath) {
    $repos = @(Get-Repositories -ForceRefresh $Refresh -CacheOnly $CachedOnly)

    if ($repos.Count -eq 0) {
        Write-Err "No Git repositories found."
        exit 1
    }
}

# A standalone refresh only rebuilds the repository cache.
# It must not continue into interactive repository selection.
if ($Refresh -and -not $ListRepos -and [string]::IsNullOrWhiteSpace($Project)) {
    Write-Section "Cache refreshed"
    Write-KeyValue "Repositories" ([string]$repos.Count) ([ConsoleColor]::Green)
    Write-KeyValue "Cache" $CacheFile ([ConsoleColor]::DarkGray)
    Write-Host ""
    exit 0
}

if ($ListRepos) {
    Write-Section "Repositories"

    $displayRepos = @(ConvertTo-RepositoryList -InputObject $repos)

    foreach ($item in $displayRepos) {
        Write-Host ("  {0,-28}" -f $item.Name) -NoNewline -ForegroundColor White
        Write-Host $item.Path -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Dim ("Total: {0} repositories" -f $displayRepos.Count)
    Write-Host ""
    exit 0
}

# ============================================================
# SELECT PROJECT
# ============================================================

if ($DirectRepositoryPath) {
    $repo = [PSCustomObject]@{
        Name = Split-Path $DirectRepositoryPath -Leaf
        Path = $DirectRepositoryPath
    }
}
else {
    $repo = Select-Repository -Repos $repos -Search $Project -QuietNotFound
}

if ($null -eq $repo -and -not $DirectRepositoryPath -and $script:RepositorySource -eq "cache" -and -not $CachedOnly) {
    Write-Host ""
    Write-Warn "Repository was not found in cache. Refreshing repository index..."
    $repos = @(Get-Repositories -ForceRefresh $true -CacheOnly $false)

    if ($repos.Count -gt 0) {
        $retrySearch = if ($script:LastRepositorySearch) { $script:LastRepositorySearch } else { $Project }
        $repo = Select-Repository -Repos $repos -Search $retrySearch
    }
}
elseif ($null -eq $repo) {
    Write-Host ""
    Write-Err "Repository '$Project' not found."
}

if ($null -eq $repo) {
    exit 1
}

Write-Section "Repository"
Write-KeyValue "Name" $repo.Name
Write-KeyValue "Path" $repo.Path ([ConsoleColor]::DarkGray)

Set-Location $repo.Path

# ============================================================
# UTILITY MODES
# ============================================================

if ($Renormalize) {
    Write-Section "Renormalize"
    Write-Info "[ADD] git add --renormalize ."

    $result = Get-GitOutput -Arguments @("add", "--renormalize", ".") -AllowFailure
    if (-not $result.Success) {
        Write-Err "[RENORMALIZE] FAILED"
        foreach ($line in $result.Lines) {
            Write-Dim "  $line"
        }
        exit 1
    }

    Write-Ok "[RENORMALIZE] OK"

    $statusResult = Get-GitOutput -Arguments @("status", "--short") -AllowFailure
    $status = @($statusResult.Lines | Where-Object { $_ -ne $null })
    Show-Changes -Status $status

    Write-Separator
    Write-Ok "Renormalize complete."
    Write-Host ""
    exit 0
}

if ($FetchOnly) {
    Write-Section "Fetch"

    $remotes = @((& git remote) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($remotes.Count -eq 0) {
        Write-Err "No Git remote is configured."
        exit 1
    }

    $remote = if ($remotes -contains "origin") { "origin" } else { $remotes[0].Trim() }

    Write-Info "[FETCH] git fetch --prune $remote"
    $result = Get-GitOutput -Arguments @("fetch", "--prune", $remote) -AllowFailure

    foreach ($line in $result.Lines) {
        Write-Host $line
    }

    if (-not $result.Success) {
        Write-Err "[FETCH] FAILED"
        exit 1
    }

    Write-Ok "[FETCH] OK"
    Write-Host ""
    exit 0
}

if ($LogOnly) {
    Write-Section "Recent commits"
    & git log -10 --oneline --decorate --date=short
    Write-Host ""
    exit $LASTEXITCODE
}

if ($BranchesOnly) {
    Write-Section "Local branches"
    & git branch -vv

    Write-Section "Remote branches"
    & git branch -r

    Write-Host ""
    exit 0
}

if ($RemotesOnly) {
    Write-Section "Remotes"
    & git remote -v
    Write-Host ""
    exit $LASTEXITCODE
}

# ============================================================
# PREFLIGHT
# ============================================================

Write-Section "Preflight"

$inside = Get-GitOutput -Arguments @("rev-parse", "--is-inside-work-tree") -AllowFailure
if (-not $inside.Success -or $inside.Text.Trim() -ne "true") {
    Write-Err "  x Not a valid Git working tree."
    exit 1
}
Write-Ok "  + Git working tree"

$branchResult = Get-GitOutput -Arguments @("symbolic-ref", "--quiet", "--short", "HEAD") -AllowFailure
if (-not $branchResult.Success -or [string]::IsNullOrWhiteSpace($branchResult.Text)) {
    $head = Get-CommitShortHash
    Write-Err "  x Detached HEAD at $head"
    Write-Warn "Checkout a branch before using GPush."
    exit 1
}

$branch = $branchResult.Text.Trim()
Write-Ok "  + Branch: $branch"

$mergeHead = Get-GitPath "MERGE_HEAD"
if ($mergeHead -and (Test-Path $mergeHead)) {
    Write-Err "  x A merge is currently in progress."
    Write-Warn "Finish it with 'git commit' or cancel it with 'git merge --abort'."
    exit 1
}

$rebaseMerge = Get-GitPath "rebase-merge"
$rebaseApply = Get-GitPath "rebase-apply"
if (($rebaseMerge -and (Test-Path $rebaseMerge)) -or ($rebaseApply -and (Test-Path $rebaseApply))) {
    Write-Err "  x A rebase is currently in progress."
    Write-Warn "Finish it with 'git rebase --continue' or cancel it with 'git rebase --abort'."
    exit 1
}

$cherryPickHead = Get-GitPath "CHERRY_PICK_HEAD"
if ($cherryPickHead -and (Test-Path $cherryPickHead)) {
    Write-Err "  x A cherry-pick is currently in progress."
    Write-Warn "Finish it with 'git cherry-pick --continue' or cancel it with 'git cherry-pick --abort'."
    exit 1
}

$revertHead = Get-GitPath "REVERT_HEAD"
if ($revertHead -and (Test-Path $revertHead)) {
    Write-Err "  x A revert is currently in progress."
    Write-Warn "Finish it with 'git revert --continue' or cancel it with 'git revert --abort'."
    exit 1
}

Write-Ok "  + No merge/rebase/cherry-pick/revert in progress"

$conflictsResult = Get-GitOutput -Arguments @("diff", "--name-only", "--diff-filter=U") -AllowFailure
$conflicts = @($conflictsResult.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

if ($conflicts.Count -gt 0) {
    Write-Err "  x Unresolved conflicts detected:"
    foreach ($conflict in $conflicts) {
        Write-Host "      $conflict" -ForegroundColor Red
    }
    Write-Warn "Resolve the conflicts before using GPush."
    exit 1
}

Write-Ok "  + No unresolved conflicts"

# ============================================================
# REMOTE / UPSTREAM DISCOVERY
# ============================================================

$remotesResult = Get-GitOutput -Arguments @("remote") -AllowFailure
$remotes = @($remotesResult.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

$remote = $null
if ($remotes -contains "origin") {
    $remote = "origin"
}
elseif ($remotes.Count -gt 0) {
    $remote = $remotes[0].Trim()
}

$remoteUrl = "-"
if ($remote) {
    $remoteUrlResult = Get-GitOutput -Arguments @("remote", "get-url", $remote) -AllowFailure
    if ($remoteUrlResult.Success -and -not [string]::IsNullOrWhiteSpace($remoteUrlResult.Text)) {
        $remoteUrl = $remoteUrlResult.Text.Trim()
    }
}

$upstreamResult = Get-GitOutput -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}") -AllowFailure
$upstream = $null
if ($upstreamResult.Success -and -not [string]::IsNullOrWhiteSpace($upstreamResult.Text)) {
    $upstream = $upstreamResult.Text.Trim()
}

$trackingRemoteResult = Get-GitOutput -Arguments @("config", "--get", "branch.$branch.remote") -AllowFailure
if ($trackingRemoteResult.Success -and -not [string]::IsNullOrWhiteSpace($trackingRemoteResult.Text)) {
    $trackingRemote = $trackingRemoteResult.Text.Trim()

    if ($trackingRemote -ne "." -and ($remotes -contains $trackingRemote)) {
        $remote = $trackingRemote

        $remoteUrlResult = Get-GitOutput -Arguments @("remote", "get-url", $remote) -AllowFailure
        if ($remoteUrlResult.Success -and -not [string]::IsNullOrWhiteSpace($remoteUrlResult.Text)) {
            $remoteUrl = $remoteUrlResult.Text.Trim()
        }
    }
}

$remoteBranchRef = $null
$remoteBranchExists = $false

if ($remote) {
    $remoteBranchRef = "$remote/$branch"
    $remoteBranchExists = Test-GitRef -Ref "refs/remotes/$remote/$branch"
}

if (-not $remote -and -not $NoPush -and -not $DryRun -and -not $DiffOnly -and -not $StatusOnly -and -not $PullOnly) {
    Write-Err "  x No Git remote is configured."
    Write-Warn "Add a remote or use --no-push for a local-only commit."
    exit 1
}

if ($remote) {
    Write-Ok "  + Remote: $remote"
}
else {
    Write-Warn "  ! No remote configured"
}

if ($upstream) {
    Write-Ok "  + Upstream: $upstream"
}
elseif ($remote) {
    Write-Warn "  ! No upstream configured; first successful push will create it."
}

# ============================================================
# LOCAL STATUS
# ============================================================

$statusResult = Get-GitOutput -Arguments @("status", "--short") -AllowFailure
if (-not $statusResult.Success) {
    Write-Err "Could not read Git status."
    exit 1
}

$status = @($statusResult.Lines | Where-Object { $_ -ne $null })

# ============================================================
# FETCH + SYNC STATE
# ============================================================

$fetchAttempted = $false
$fetchSucceeded = $false
$syncChecked = $false
$ahead = 0
$behind = 0
$compareRef = $null
$syncLabel = "Not checked"
$syncColor = [ConsoleColor]::DarkGray

$shouldFetch = (
    $remote -and
    -not $NoPush -and
    -not $DryRun -and
    -not $DiffOnly -and
    -not $PullOnly
)

if ($shouldFetch) {
    Write-Section "Remote check"
    Write-Info "[FETCH] git fetch --prune $remote"

    $fetchAttempted = $true
    $fetchResult = Get-GitOutput -Arguments @("fetch", "--prune", $remote) -AllowFailure

    if (-not $fetchResult.Success) {
        Write-Err "[FETCH] FAILED"
        foreach ($line in $fetchResult.Lines) {
            Write-Dim "  $line"
        }

        if ($StatusOnly) {
            Write-Warn "Remote could not be refreshed. Status will use cached remote refs when available."
        }
        else {
            Write-Host ""
            Write-Err "Remote state could not be verified."
            Write-Warn "GPush will stop before creating a commit. Use --no-push for a local-only commit."
            exit 1
        }
    }
    else {
        $fetchSucceeded = $true
        Write-Ok "[FETCH] OK"

        if (-not $upstream -and $remote) {
            $remoteBranchExists = Test-GitRef -Ref "refs/remotes/$remote/$branch"
        }
    }
}

if ($upstream) {
    $compareRef = $upstream
}
elseif ($remote -and $remoteBranchExists) {
    $compareRef = $remoteBranchRef
}

if ($compareRef) {
    $countResult = Get-GitOutput -Arguments @("rev-list", "--left-right", "--count", "HEAD...$compareRef") -AllowFailure

    if ($countResult.Success) {
        $parts = $countResult.Text.Trim() -split '\s+'

        if ($parts.Count -ge 2) {
            [int]$ahead = $parts[0]
            [int]$behind = $parts[1]
            $syncChecked = $true
        }
    }
}
elseif ($remote -and -not $remoteBranchExists) {
    $syncChecked = $true
    $ahead = 0
    $behind = 0
    $syncLabel = "New remote branch"
    $syncColor = [ConsoleColor]::Yellow
}

if ($syncChecked -and $syncLabel -ne "New remote branch") {
    if ($ahead -eq 0 -and $behind -eq 0) {
        $syncLabel = "Up to date"
        $syncColor = [ConsoleColor]::Green
    }
    elseif ($ahead -gt 0 -and $behind -eq 0) {
        $syncLabel = "$ahead commit(s) ahead"
        $syncColor = [ConsoleColor]::Yellow
    }
    elseif ($ahead -eq 0 -and $behind -gt 0) {
        $syncLabel = "$behind commit(s) behind"
        $syncColor = [ConsoleColor]::Yellow
    }
    else {
        $syncLabel = "$ahead ahead / $behind behind"
        $syncColor = [ConsoleColor]::Red
    }
}

if ($fetchAttempted -and -not $fetchSucceeded) {
    if ($syncChecked) {
        $syncLabel = "$syncLabel (cached refs)"
        $syncColor = [ConsoleColor]::Yellow
    }
    else {
        $syncLabel = "Remote unavailable"
        $syncColor = [ConsoleColor]::Yellow
    }
}

# ============================================================
# GIT OVERVIEW
# ============================================================

Write-Section "Git"
Write-KeyValue "Branch" $branch ([ConsoleColor]::Magenta)
Write-KeyValue "Remote" $(if ($remote) { $remote } else { "-" })
Write-KeyValue "Upstream" $(if ($upstream) { $upstream } elseif ($remoteBranchExists) { "$remoteBranchRef (not tracking)" } else { "-" })
Write-KeyValue "URL" $remoteUrl ([ConsoleColor]::DarkGray)
Write-KeyValue "Sync" $syncLabel $syncColor
Write-KeyValue "HEAD" (Get-CommitShortHash) ([ConsoleColor]::DarkGray)

Show-Changes -Status $status

# ============================================================
# STATUS-ONLY MODE
# ============================================================

if ($StatusOnly) {
    Write-Separator
    Write-Ok "Status check complete."
    Write-Host ""
    exit 0
}

# ============================================================
# DIFF-ONLY MODE
# ============================================================

if ($DiffOnly) {
    Write-Section "Diff summary"

    $unstaged = Get-GitOutput -Arguments @("diff", "--stat") -AllowFailure
    $staged = Get-GitOutput -Arguments @("diff", "--cached", "--stat") -AllowFailure

    $hasOutput = $false

    if (-not [string]::IsNullOrWhiteSpace($unstaged.Text)) {
        Write-Host "  Unstaged" -ForegroundColor Yellow
        foreach ($line in $unstaged.Lines) {
            Write-Host "    $line"
        }
        $hasOutput = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($staged.Text)) {
        if ($hasOutput) {
            Write-Host ""
        }
        Write-Host "  Staged" -ForegroundColor Green
        foreach ($line in $staged.Lines) {
            Write-Host "    $line"
        }
        $hasOutput = $true
    }

    if (-not $hasOutput -and $status.Count -gt 0) {
        Write-Dim "  Only untracked files are present; Git has no diff statistics for them yet."
    }
    elseif (-not $hasOutput) {
        Write-Ok "  No diff."
    }

    Write-Separator
    Write-Ok "Diff check complete."
    Write-Host ""
    exit 0
}

# ============================================================
# PULL-ONLY MODE
# ============================================================

if ($PullOnly) {
    if (-not $remote) {
        Write-Err "No remote is configured."
        exit 1
    }

    if ($status.Count -gt 0) {
        Write-Err "Pull-only mode requires a clean working tree."
        Write-Warn "Commit/stash the local changes first, or run normal GPush with a commit message."
        exit 1
    }

    Write-Section "Pull"

    if ($upstream) {
        $pullArgs = @("pull", "--rebase")
        $pullDescription = "git pull --rebase"
    }
    else {
        $pullArgs = @("pull", "--rebase", $remote, $branch)
        $pullDescription = "git pull --rebase $remote $branch"
    }

    Write-Info "[PULL] $pullDescription"
    $pullResult = Get-GitOutput -Arguments $pullArgs -AllowFailure
    foreach ($line in $pullResult.Lines) {
        Write-Host $line
    }

    if (-not $pullResult.Success) {
        Write-Host ""
        Write-Err "[PULL] FAILED"
        Write-Warn "Resolve any conflict manually. GPush will not modify the conflict."
        exit 1
    }

    Write-Host ""
    Write-Ok "[PULL] OK"
    Write-Separator
    Write-Ok "Complete."
    Write-Host ""
    exit 0
}

# ============================================================
# COMMIT MESSAGE
# ============================================================

$commitMessage = ""

if ($CommitMessageParts.Count -gt 0) {
    $commitMessage = $CommitMessageParts -join " "
}

if ($status.Count -gt 0 -and [string]::IsNullOrWhiteSpace($commitMessage) -and -not $DryRun) {
    Write-Host ""
    $commitMessage = Read-Host "Commit message"
}

if ($status.Count -gt 0 -and [string]::IsNullOrWhiteSpace($commitMessage) -and -not $DryRun) {
    Write-Err "Commit message cannot be empty."
    exit 1
}

# ============================================================
# DRY RUN
# ============================================================

if ($DryRun) {
    Write-Section "Dry run"
    Write-Warn "No Git state will be changed."

    if ($status.Count -gt 0) {
        Write-Dim "  Would run: git add ."

        if ([string]::IsNullOrWhiteSpace($commitMessage)) {
            Write-Dim "  Would ask for a commit message."
        }
        else {
            Write-Dim "  Would commit: $commitMessage"
        }
    }
    else {
        Write-Dim "  No local commit would be created."
    }

    if ($NoPush) {
        Write-Dim "  Push is disabled by --no-push."
    }
    elseif ($remote) {
        if ($upstream) {
            Write-Dim "  Would verify/sync against: $upstream"
            Write-Dim "  Would run: git push"
        }
        else {
            Write-Dim "  Would verify remote branch state."
            Write-Dim "  Would run: git push -u $remote $branch"
        }
    }
    else {
        Write-Dim "  Push would not be possible because no remote is configured."
    }

    Write-Separator
    Write-Ok "Dry run complete."
    Write-Host ""
    exit 0
}

# ============================================================
# ADD + COMMIT
# ============================================================

$commitCreated = $false
$createdCommitHash = "-"
$createdCommitMessage = "-"

if ($status.Count -gt 0) {
    Write-Section "Commit"
    Write-Info "[ADD] git add ."

    $addResult = Get-GitOutput -Arguments @("add", ".") -AllowFailure
    if (-not $addResult.Success) {
        Write-Err "[ADD] FAILED"
        foreach ($line in $addResult.Lines) {
            Write-Dim "  $line"
        }
        exit 1
    }

    Write-Ok "[ADD] OK"
    Write-Host ""
    Write-Info "[COMMIT] $commitMessage"

    $commitResult = Get-GitOutput -Arguments @("commit", "-m", $commitMessage) -AllowFailure
    foreach ($line in $commitResult.Lines) {
        Write-Host $line
    }

    if (-not $commitResult.Success) {
        Write-Err "[COMMIT] FAILED"
        exit 1
    }

    $commitCreated = $true
    $createdCommitHash = Get-CommitShortHash
    $createdCommitMessage = $commitMessage
    Write-Ok "[COMMIT] OK ($createdCommitHash)"
}

if ($NoPush) {
    Write-Separator
    Write-Ok "GPush completed locally."
    Write-KeyValue "Repository" $repo.Name
    Write-KeyValue "Branch" $branch ([ConsoleColor]::Magenta)
    Write-KeyValue "Commit" $(if ($commitCreated) { $createdCommitHash } else { "No new commit" })
    Write-Dim ""
    Write-Warn "  Push skipped because --no-push was specified."
    Write-Host ""
    exit 0
}

# ============================================================
# SYNC BEFORE PUSH
# ============================================================

# A fetch was already completed before the commit. Recalculate local/remote
# counts now because HEAD may have changed after creating the commit.
if ($compareRef) {
    $countResult = Get-GitOutput -Arguments @("rev-list", "--left-right", "--count", "HEAD...$compareRef") -AllowFailure

    if ($countResult.Success) {
        $parts = $countResult.Text.Trim() -split '\s+'
        if ($parts.Count -ge 2) {
            [int]$ahead = $parts[0]
            [int]$behind = $parts[1]
        }
    }
}

if ($behind -gt 0) {
    Write-Section "Sync"
    Write-Warn "Remote contains $behind newer commit(s)."

    if ($ahead -gt 0) {
        Write-Dim "Local branch also contains $ahead commit(s) not present on the remote."
    }

    $rebaseTarget = $compareRef
    Write-Info "[REBASE] git rebase $rebaseTarget"

    $rebaseResult = Get-GitOutput -Arguments @("rebase", $rebaseTarget) -AllowFailure
    foreach ($line in $rebaseResult.Lines) {
        Write-Host $line
    }

    if (-not $rebaseResult.Success) {
        Write-Host ""
        Write-Err "[REBASE] FAILED"
        Write-Warn "There is probably a conflict. GPush will not resolve it automatically."
        Write-Host ""
        Write-Host "Resolve the conflicting files, then run:"
        Write-Host "  git add ." -ForegroundColor Cyan
        Write-Host "  git rebase --continue" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "To cancel the rebase:"
        Write-Host "  git rebase --abort" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "After the rebase is finished, run GPush again."
        exit 1
    }

    Write-Ok "[REBASE] OK"

    if ($commitCreated) {
        $createdCommitHash = Get-CommitShortHash
    }
}

# ============================================================
# PUSH
# ============================================================

Write-Section "Push"

$pushArgs = @("push")
$pushDescription = "git push"

if (-not $upstream) {
    $pushArgs = @("push", "-u", $remote, $branch)
    $pushDescription = "git push -u $remote $branch"
}

Write-Info "[PUSH] $pushDescription"
$pushResult = Get-GitOutput -Arguments $pushArgs -AllowFailure

foreach ($line in $pushResult.Lines) {
    Write-Host $line
}

if (-not $pushResult.Success) {
    Write-Host ""
    Write-Err "[PUSH] FAILED"

    $pushText = $pushResult.Text
    $remoteAhead = (
        $pushText -match "non-fast-forward" -or
        $pushText -match "fetch first" -or
        $pushText -match "remote contains work"
    )

    if ($remoteAhead) {
        Write-Warn "The remote changed after the pre-push fetch."
        Write-Warn "GPush will refresh it once and attempt a safe rebase."

        Write-Host ""
        Write-Info "[FETCH] git fetch --prune $remote"
        $retryFetch = Get-GitOutput -Arguments @("fetch", "--prune", $remote) -AllowFailure

        if (-not $retryFetch.Success) {
            Write-Err "[FETCH] FAILED"
            exit 1
        }

        Write-Ok "[FETCH] OK"

        if ($upstream) {
            $retryTarget = $upstream
        }
        elseif (Test-GitRef -Ref "refs/remotes/$remote/$branch") {
            $retryTarget = "$remote/$branch"
        }
        else {
            $retryTarget = $null
        }

        if ($retryTarget) {
            Write-Info "[REBASE] git rebase $retryTarget"
            $retryRebase = Get-GitOutput -Arguments @("rebase", $retryTarget) -AllowFailure

            foreach ($line in $retryRebase.Lines) {
                Write-Host $line
            }

            if (-not $retryRebase.Success) {
                Write-Host ""
                Write-Err "[REBASE] FAILED"
                Write-Warn "Resolve the conflict manually, then continue or abort the rebase."
                Write-Host "  git add ." -ForegroundColor Cyan
                Write-Host "  git rebase --continue" -ForegroundColor Cyan
                Write-Host "  git rebase --abort" -ForegroundColor Cyan
                exit 1
            }

            Write-Ok "[REBASE] OK"

            if ($commitCreated) {
                $createdCommitHash = Get-CommitShortHash
            }
        }

        Write-Host ""
        Write-Info "[PUSH] Trying again..."
        $retryPush = Get-GitOutput -Arguments $pushArgs -AllowFailure

        foreach ($line in $retryPush.Lines) {
            Write-Host $line
        }

        if (-not $retryPush.Success) {
            Write-Err "[PUSH] FAILED AGAIN"
            exit 1
        }

        $pushResult = $retryPush
    }
    else {
        Write-Err "Push failed for a reason that GPush will not try to repair automatically."
        exit 1
    }
}

Write-Ok "[PUSH] OK"

# ============================================================
# FINAL SYNC CHECK
# ============================================================

$finalUpstreamResult = Get-GitOutput -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}") -AllowFailure
$finalUpstream = $null
if ($finalUpstreamResult.Success -and -not [string]::IsNullOrWhiteSpace($finalUpstreamResult.Text)) {
    $finalUpstream = $finalUpstreamResult.Text.Trim()
}

$finalAhead = 0
$finalBehind = 0
$finalSync = "Unknown"
$finalSyncColor = [ConsoleColor]::DarkGray

if ($finalUpstream) {
    $finalCount = Get-GitOutput -Arguments @("rev-list", "--left-right", "--count", "HEAD...$finalUpstream") -AllowFailure

    if ($finalCount.Success) {
        $parts = $finalCount.Text.Trim() -split '\s+'
        if ($parts.Count -ge 2) {
            [int]$finalAhead = $parts[0]
            [int]$finalBehind = $parts[1]

            if ($finalAhead -eq 0 -and $finalBehind -eq 0) {
                $finalSync = "Up to date"
                $finalSyncColor = [ConsoleColor]::Green
            }
            else {
                $finalSync = "$finalAhead ahead / $finalBehind behind"
                $finalSyncColor = [ConsoleColor]::Yellow
            }
        }
    }
}

$finalStatusResult = Get-GitOutput -Arguments @("status", "--short") -AllowFailure
$finalStatus = @($finalStatusResult.Lines | Where-Object { $_ -ne $null })

# ============================================================
# SUMMARY
# ============================================================

Write-Separator
Write-Ok "GPush completed"
Write-Host ""
Write-KeyValue "Repository" $repo.Name
Write-KeyValue "Branch" $branch ([ConsoleColor]::Magenta)
Write-KeyValue "Upstream" $(if ($finalUpstream) { $finalUpstream } else { "-" })
Write-KeyValue "Commit" $(if ($commitCreated) { $createdCommitHash } else { Get-CommitShortHash }) ([ConsoleColor]::DarkGray)

if ($commitCreated) {
    Write-KeyValue "Message" $createdCommitMessage
}
else {
    Write-KeyValue "Message" (Get-CommitSubject) ([ConsoleColor]::DarkGray)
}

Write-KeyValue "Sync" $finalSync $finalSyncColor

if ($finalStatus.Count -eq 0) {
    Write-KeyValue "Working tree" "Clean" ([ConsoleColor]::Green)
}
else {
    Write-KeyValue "Working tree" "$($finalStatus.Count) local change(s) remain" ([ConsoleColor]::Yellow)
}

Write-Host ""
