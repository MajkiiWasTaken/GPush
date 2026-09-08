$RawArguments = @($args)

# ============================================================
# ENCODING
# ============================================================

[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding           = [System.Text.UTF8Encoding]::new($false)


# ============================================================
# CONFIG
# ============================================================

$ScriptVersion = "4.0.1"

$ConfigDir  = Join-Path $env:LOCALAPPDATA "GPush"
$ConfigFile = Join-Path $ConfigDir "config.json"
$CacheDir   = $ConfigDir
$CacheFile  = Join-Path $CacheDir "repos.json"
$RecentFile = Join-Path $ConfigDir "recent.json"

# Built-in defaults are used to create config.json on first run and as a
# safe fallback when individual config values are missing or invalid.
$DefaultSearchRoots = @(
    '$HOME\Documents\Project',
    '$HOME\Documents'
)

$DefaultIgnoredDirectories = @(
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

$DefaultProtectedBranches = @(
    "main",
    "master",
    "release/*"
)

$DefaultLargeFileThresholdMB = 25
$DefaultRemote = "origin"

# Runtime values are populated from config.json below.
$SearchRoots = @()
$IgnoredDirectories = @()
$ProtectedBranches = @()
$LargeFileThresholdMB = $DefaultLargeFileThresholdMB
$PreferredRemote = $DefaultRemote
$RepositoryAliases = @{}
$FavoriteRepositories = @()

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

    $name = "Michal " +
        [char]0x0160 +   # Š
        "vr" +
        [char]0x010D +   # č
        "ek"

    Write-Host "Made by " -NoNewline -ForegroundColor DarkGray
    Write-Host $name -ForegroundColor Magenta
    Write-Host "GitHub  " -NoNewline -ForegroundColor DarkGray
    Write-Host "https://github.com/MajkiiWasTaken" -ForegroundColor Blue
}

function Write-OptionHelp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Option,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    # Keep every description in one fixed column, regardless of option length.
    Write-Host ("  {0,-26}" -f $Option) -NoNewline -ForegroundColor Cyan
    Write-Host $Description
}

function Write-ExampleHelp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $commandWidth = 52

    # Normal examples stay on one aligned line.
    if ($Command.Length -le $commandWidth) {
        Write-Host ("  {0,-52}" -f $Command) -NoNewline -ForegroundColor Green
        Write-Host $Description -ForegroundColor DarkGray
        return
    }

    # Safety fallback for future long examples: never let the command
    # run directly into the description column.
    Write-Host "  $Command" -ForegroundColor Green
    Write-Host ("  {0,-52}" -f "") -NoNewline
    Write-Host $Description -ForegroundColor DarkGray
}

function Write-ExampleGroup {
    param([string]$Title)

    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Magenta
}

function New-DefaultGPushConfig {
    return [PSCustomObject]@{
        searchRoots = @($DefaultSearchRoots)
        ignoredDirectories = @($DefaultIgnoredDirectories)
        protectedBranches = @($DefaultProtectedBranches)
        largeFileThresholdMB = $DefaultLargeFileThresholdMB
        defaultRemote = $DefaultRemote
        aliases = @{}
        favorites = @()
    }
}

function Expand-GPushPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())

    if ($expanded.StartsWith('$HOME', [System.StringComparison]::OrdinalIgnoreCase)) {
        $suffix = $expanded.Substring(5) -replace '^[\\/]+', ''

        if ([string]::IsNullOrWhiteSpace($suffix)) {
            return $HOME
        }

        return (Join-Path $HOME $suffix)
    }

    return $expanded
}

function Save-DefaultGPushConfig {
    if (-not (Test-Path $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }

    New-DefaultGPushConfig |
        ConvertTo-Json -Depth 5 |
        Set-Content -Path $ConfigFile -Encoding UTF8
}

function Initialize-GPushConfig {
    $script:GPushConfigCreated = $false
    $script:GPushConfigValid = $true
    $script:GPushConfigError = $null

    if (-not (Test-Path $ConfigFile)) {
        try {
            Save-DefaultGPushConfig
            $script:GPushConfigCreated = $true
        }
        catch {
            $script:GPushConfigValid = $false
            $script:GPushConfigError = $_.Exception.Message
        }
    }

    $config = New-DefaultGPushConfig

    if (Test-Path $ConfigFile) {
        try {
            $loaded = Get-Content -Path $ConfigFile -Raw -ErrorAction Stop |
                ConvertFrom-Json -ErrorAction Stop

            if ($null -ne $loaded.PSObject.Properties['searchRoots'] -and @($loaded.searchRoots).Count -gt 0) {
                $config.searchRoots = @($loaded.searchRoots)
            }

            if ($null -ne $loaded.PSObject.Properties['ignoredDirectories'] -and @($loaded.ignoredDirectories).Count -gt 0) {
                $config.ignoredDirectories = @($loaded.ignoredDirectories)
            }

            if ($null -ne $loaded.PSObject.Properties['protectedBranches'] -and @($loaded.protectedBranches).Count -gt 0) {
                $config.protectedBranches = @($loaded.protectedBranches)
            }

            if ($null -ne $loaded.PSObject.Properties['largeFileThresholdMB']) {
                $threshold = 0
                if ([int]::TryParse([string]$loaded.largeFileThresholdMB, [ref]$threshold) -and $threshold -gt 0) {
                    $config.largeFileThresholdMB = $threshold
                }
            }

            if ($null -ne $loaded.PSObject.Properties['defaultRemote'] -and
                -not [string]::IsNullOrWhiteSpace([string]$loaded.defaultRemote)) {
                $config.defaultRemote = [string]$loaded.defaultRemote
            }

            if ($null -ne $loaded.PSObject.Properties['aliases'] -and $null -ne $loaded.aliases) {
                $aliasMap = @{}
                foreach ($property in $loaded.aliases.PSObject.Properties) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$property.Name) -and
                        -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                        $aliasMap[[string]$property.Name] = [string]$property.Value
                    }
                }
                $config.aliases = $aliasMap
            }

            if ($null -ne $loaded.PSObject.Properties['favorites']) {
                $config.favorites = @(
                    $loaded.favorites |
                        ForEach-Object { [string]$_ } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                )
            }
        }
        catch {
            $script:GPushConfigValid = $false
            $script:GPushConfigError = $_.Exception.Message
            $config = New-DefaultGPushConfig
            Write-Warn "GPush config is invalid. Built-in defaults will be used for this run."
            Write-Dim "Config: $ConfigFile"
        }
    }

    $script:GPushConfig = $config
    $script:SearchRoots = @(
        $config.searchRoots |
            ForEach-Object { Expand-GPushPath -Path ([string]$_) } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $script:IgnoredDirectories = @($config.ignoredDirectories | ForEach-Object { [string]$_ })
    $script:ProtectedBranches = @($config.protectedBranches | ForEach-Object { [string]$_ })
    $script:LargeFileThresholdMB = [int]$config.largeFileThresholdMB
    $script:PreferredRemote = [string]$config.defaultRemote

    $script:RepositoryAliases = @{}
    if ($config.aliases -is [System.Collections.IDictionary]) {
        foreach ($key in $config.aliases.Keys) {
            $script:RepositoryAliases[[string]$key] = [string]$config.aliases[$key]
        }
    }
    elseif ($null -ne $config.aliases) {
        foreach ($property in $config.aliases.PSObject.Properties) {
            $script:RepositoryAliases[[string]$property.Name] = [string]$property.Value
        }
    }

    $script:FavoriteRepositories = @(
        $config.favorites |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}

function Save-GPushConfig {
    if (-not (Test-Path $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }

    $configToSave = [ordered]@{
        searchRoots = @($script:GPushConfig.searchRoots)
        ignoredDirectories = @($script:GPushConfig.ignoredDirectories)
        protectedBranches = @($script:GPushConfig.protectedBranches)
        largeFileThresholdMB = [int]$script:LargeFileThresholdMB
        defaultRemote = [string]$script:PreferredRemote
        aliases = $script:RepositoryAliases
        favorites = @($script:FavoriteRepositories)
    }

    $configToSave |
        ConvertTo-Json -Depth 8 |
        Set-Content -Path $ConfigFile -Encoding UTF8

    $script:GPushConfig.aliases = $script:RepositoryAliases
    $script:GPushConfig.favorites = @($script:FavoriteRepositories)
}

function Get-GPushRecentRepositories {
    if (-not (Test-Path $RecentFile)) {
        return @()
    }

    try {
        $items = Get-Content -Path $RecentFile -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop

        return @(
            @($items) |
                Where-Object {
                    $_.Name -and $_.Path -and (Test-Path ([string]$_.Path))
                } |
                Sort-Object LastUsed -Descending
        )
    }
    catch {
        return @()
    }
}

function Save-GPushRecentRepository {
    param(
        [Parameter(Mandatory = $true)]
        $Repository
    )

    if (-not (Test-Path $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }

    $current = @(Get-GPushRecentRepositories)
    $pathKey = ([System.IO.Path]::GetFullPath([string]$Repository.Path)).ToLowerInvariant()

    $remaining = @(
        $current |
            Where-Object {
                ([System.IO.Path]::GetFullPath([string]$_.Path)).ToLowerInvariant() -ne $pathKey
            }
    )

    $entry = [PSCustomObject]@{
        Name = [string]$Repository.Name
        Path = [string]$Repository.Path
        LastUsed = (Get-Date).ToString("o")
    }

    @($entry) + @($remaining) |
        Select-Object -First 15 |
        ConvertTo-Json -Depth 4 |
        Set-Content -Path $RecentFile -Encoding UTF8
}

function Resolve-GPushAlias {
    param([string]$Search)

    if ([string]::IsNullOrWhiteSpace($Search)) {
        return $Search
    }

    foreach ($key in $RepositoryAliases.Keys) {
        if ([string]::Equals([string]$key, $Search, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$RepositoryAliases[$key]
        }
    }

    return $Search
}

function Show-GPushConfig {
    Show-Banner
    Write-Section "Configuration"
    Write-KeyValue "Path" $ConfigFile ([ConsoleColor]::DarkGray)
    Write-KeyValue "Remote" $PreferredRemote
    Write-KeyValue "Large files" "$LargeFileThresholdMB MB"

    Write-Section "Search roots"
    foreach ($root in $SearchRoots) {
        Write-Host "  $root"
    }

    Write-Section "Protected branches"
    foreach ($branchPattern in $ProtectedBranches) {
        Write-Host "  $branchPattern"
    }

    Write-Section "Ignored directories"
    foreach ($directory in $IgnoredDirectories) {
        Write-Host "  $directory"
    }

    Write-Section "Aliases"
    if ($RepositoryAliases.Count -eq 0) {
        Write-Dim "  No repository aliases configured."
    }
    else {
        foreach ($key in @($RepositoryAliases.Keys | Sort-Object)) {
            Write-Host ("  {0,-18}" -f $key) -NoNewline -ForegroundColor White
            Write-Host $RepositoryAliases[$key] -ForegroundColor DarkGray
        }
    }

    Write-Section "Favorites"
    if ($FavoriteRepositories.Count -eq 0) {
        Write-Dim "  No favorite repositories configured."
    }
    else {
        foreach ($favorite in $FavoriteRepositories) {
            Write-Host "  $favorite"
        }
    }

    Write-Host ""
}

function Write-DoctorResult {
    param(
        [ValidateSet('OK', 'WARN', 'FAIL')]
        [string]$State,
        [string]$Name,
        [string]$Detail
    )

    $color = switch ($State) {
        'OK'   { [ConsoleColor]::Green }
        'WARN' { [ConsoleColor]::Yellow }
        'FAIL' { [ConsoleColor]::Red }
    }

    Write-Host ("  [{0,-4}] " -f $State) -NoNewline -ForegroundColor $color
    Write-Host ("{0,-18}" -f $Name) -NoNewline -ForegroundColor White
    Write-Host $Detail -ForegroundColor DarkGray
}

function Show-GPushDoctor {
    Show-Banner
    Write-Section "Doctor"

    $failures = 0
    $warnings = 0

    if ($GPushConfigValid) {
        $detail = if ($GPushConfigCreated) { "Created $ConfigFile" } else { $ConfigFile }
        Write-DoctorResult "OK" "Config" $detail
    }
    else {
        Write-DoctorResult "WARN" "Config" "Invalid/unavailable; defaults are active. $GPushConfigError"
        $warnings++
    }

    $existingRoots = @($SearchRoots | Where-Object { Test-Path $_ })
    if ($existingRoots.Count -eq $SearchRoots.Count -and $SearchRoots.Count -gt 0) {
        Write-DoctorResult "OK" "Search roots" "$($SearchRoots.Count) configured root(s) exist"
    }
    elseif ($existingRoots.Count -gt 0) {
        Write-DoctorResult "WARN" "Search roots" "$($existingRoots.Count)/$($SearchRoots.Count) configured root(s) exist"
        $warnings++
    }
    else {
        Write-DoctorResult "FAIL" "Search roots" "No configured search root exists"
        $failures++
    }

    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) {
        Write-DoctorResult "FAIL" "Git" "git was not found in PATH"
        $failures++
    }
    else {
        $gitVersion = (& git --version 2>$null) -join " "
        Write-DoctorResult "OK" "Git" $gitVersion

        $gitName = (& git config --global --get user.name 2>$null) -join ""
        if ([string]::IsNullOrWhiteSpace($gitName)) {
            Write-DoctorResult "WARN" "Git user.name" "Not configured globally"
            $warnings++
        }
        else {
            Write-DoctorResult "OK" "Git user.name" $gitName.Trim()
        }

        $gitEmail = (& git config --global --get user.email 2>$null) -join ""
        if ([string]::IsNullOrWhiteSpace($gitEmail)) {
            Write-DoctorResult "WARN" "Git user.email" "Not configured globally"
            $warnings++
        }
        else {
            Write-DoctorResult "OK" "Git user.email" $gitEmail.Trim()
        }
    }

    if (-not (Test-Path $ConfigDir)) {
        try {
            New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
        }
        catch {
            Write-DoctorResult "FAIL" "Data directory" "Cannot create $ConfigDir"
            $failures++
        }
    }

    if (Test-Path $ConfigDir) {
        Write-DoctorResult "OK" "Data directory" $ConfigDir
    }

    if (Test-Path $CacheFile) {
        try {
            $null = Get-Content -Path $CacheFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            Write-DoctorResult "OK" "Repo cache" $CacheFile
        }
        catch {
            Write-DoctorResult "WARN" "Repo cache" "Cache exists but is invalid; --refresh will rebuild it"
            $warnings++
        }
    }
    else {
        Write-DoctorResult "WARN" "Repo cache" "Not created yet; run gp --refresh"
        $warnings++
    }

    $sshCommand = Get-Command ssh -ErrorAction SilentlyContinue
    if ($null -eq $sshCommand) {
        Write-DoctorResult "WARN" "SSH" "ssh was not found in PATH"
        $warnings++
    }
    else {
        Write-DoctorResult "OK" "SSH" $sshCommand.Source

        $sshDir = Join-Path $HOME ".ssh"
        $keyCandidates = @("id_ed25519", "id_rsa", "id_ecdsa", "id_dsa") |
            ForEach-Object { Join-Path $sshDir $_ } |
            Where-Object { Test-Path $_ }

        if (@($keyCandidates).Count -gt 0) {
            Write-DoctorResult "OK" "SSH key" ((@($keyCandidates) | Select-Object -First 1))
        }
        else {
            Write-DoctorResult "WARN" "SSH key" "No standard private key found in $sshDir"
            $warnings++
        }
    }

    if ($null -ne $gitCommand) {
        $currentRepo = (& git rev-parse --show-toplevel 2>$null) -join ""
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($currentRepo)) {
            $repoRemoteNames = @((& git remote 2>$null) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($repoRemoteNames.Count -gt 0) {
                $doctorRemote = if ($PreferredRemote -and $repoRemoteNames -contains $PreferredRemote) {
                    $PreferredRemote
                }
                elseif ($repoRemoteNames -contains "origin") {
                    "origin"
                }
                else {
                    $repoRemoteNames[0].Trim()
                }

                $doctorUrl = (& git remote get-url $doctorRemote 2>$null) -join ""
                Write-DoctorResult "OK" "Current remote" "$doctorRemote  $($doctorUrl.Trim())"
            }
            else {
                Write-DoctorResult "WARN" "Current remote" "Current repository has no remote"
                $warnings++
            }
        }
    }

    Write-Separator
    if ($failures -gt 0) {
        Write-Err "Doctor found $failures failure(s) and $warnings warning(s)."
        Write-Host ""
        return 1
    }

    if ($warnings -gt 0) {
        Write-Warn "Doctor completed with $warnings warning(s)."
    }
    else {
        Write-Ok "Doctor completed. Everything looks good."
    }

    Write-Host ""
    return 0
}

function Show-Help {
    Show-Banner

    Write-Host ""
    Write-Host ""
    Write-Host '  ###  ####            o' -ForegroundColor White
    Write-Host ' #     #   #          / \' -ForegroundColor White
    Write-Host ' #  ## ####      o---o   o' -ForegroundColor White
    Write-Host ' #   # #          \   \ /' -ForegroundColor White
    Write-Host '  ###  #           o---o---o' -ForegroundColor White
    Write-Host '                            \ ' -ForegroundColor White
    Write-Host '                             o---o' -ForegroundColor White
    Write-Host ""

    Write-Host "A small Git helper for finding repositories, checking sync state,"
    Write-Host "committing local changes, and pushing the current branch safely."
    Write-Host ""

    Write-Host "USAGE" -ForegroundColor Yellow
    Write-Host "  gp " -NoNewline -ForegroundColor Green
    Write-Host "<project> [commit message]" -ForegroundColor White
    Write-Host "  gp " -NoNewline -ForegroundColor Green
    Write-Host "<command> <action> [arguments]" -ForegroundColor White
    Write-Host "  gp " -NoNewline -ForegroundColor Green
    Write-Host "[legacy options] <project> [arguments]" -ForegroundColor DarkGray
    Write-Host ""

    Write-Host "COMMANDS" -ForegroundColor Yellow
    Write-Host "  Command     Actions / usage" -ForegroundColor DarkGray
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ("  {0,-11}{1}" -f "repo", "status, diff, log, open, fetch, pull, sync") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "branch", "list, new, switch, delete, prune") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "tag", "list, create, push, delete, release") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "remote", "list, add, set-url, remove") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "stash", "push, list, pop") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "cache", "list, refresh, add") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "config", "show, path, doctor") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "alias", "list, set, remove") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "favorite", "list, add, remove") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "all", "status, fetch, sync") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "clone", "<url> [destination]") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "recent", "show recent repositories") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "help", "show help") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "version", "show version") -ForegroundColor White
    Write-Host ""

    Write-Host "OPTIONS" -ForegroundColor Yellow
    Write-Dim "  Classic flag syntax remains fully supported."
    Write-OptionHelp "-h, --help" "Show this help and exit."
    Write-OptionHelp "-v, --version" "Show the script version and exit."
    Write-OptionHelp "-l, --list" "List discovered Git repositories and exit."
    Write-OptionHelp "-r, --refresh" "Force a new repository scan and refresh the cache."
    Write-OptionHelp "--add" "Add a Git repository to the cache manually."
    Write-OptionHelp "--cached" "Use the repository cache only. Kept for compatibility."
    Write-OptionHelp "--config" "Show the effective GPush configuration and exit."
    Write-OptionHelp "--config-path" "Show the config.json path and exit."
    Write-OptionHelp "--doctor" "Check Git, config, cache, search roots, SSH, and repository setup."
    Write-OptionHelp "--all" "Show or safely operate on all discovered repositories."
    Write-OptionHelp "--aliases" "List configured repository aliases."
    Write-OptionHelp "--alias-set" "Create/update an alias: gp --alias-set <alias> <project>."
    Write-OptionHelp "--alias-remove" "Remove a configured repository alias."
    Write-OptionHelp "--favorite" "Add a repository to favorites."
    Write-OptionHelp "--unfavorite" "Remove a repository from favorites."
    Write-OptionHelp "--favorites" "List favorite repositories."
    Write-OptionHelp "--recent" "Show recently used repositories."
    Write-OptionHelp "--open" "Open a repository folder in File Explorer."
    Write-OptionHelp "--clone" "Clone: gp --clone <url> [destination]."
    Write-OptionHelp "-s, --status" "Show repository, branch, remote, sync, and local status only."
    Write-OptionHelp "--diff" "Show local changes and diff statistics only."
    Write-OptionHelp "--renormalize" "Renormalize tracked files using .gitattributes and show status."
    Write-OptionHelp "--fetch" "Fetch and prune the selected repository remote."
    Write-OptionHelp "--log" "Show a decorated Git graph for recent commits."
    Write-OptionHelp "--tags" "List repository tags, newest first."
    Write-OptionHelp "--tag" "Create an annotated tag at HEAD; optionally provide a message."
    Write-OptionHelp "--tag-push" "Push one existing local tag to the selected remote."
    Write-OptionHelp "--tag-delete" "Delete one local tag. Remote tags are never deleted automatically."
    Write-OptionHelp "--release" "Create and push a release tag after strict sync/safety checks."
    Write-OptionHelp "--branches" "Show local and remote branches."
    Write-OptionHelp "--remotes" "Show configured Git remotes."
    Write-OptionHelp "--remote-add" "Add a named Git remote."
    Write-OptionHelp "--remote-set-url" "Change the URL of an existing Git remote."
    Write-OptionHelp "--remote-remove" "Remove a named Git remote."
    Write-OptionHelp "--prune-branches" "Safely delete merged local branches whose upstream is gone."
    Write-OptionHelp "--pull" "Run 'git pull --rebase' only. Do not commit or push."
    Write-OptionHelp "--sync" "Safely synchronize the branch without creating a commit."
    Write-OptionHelp "--stash" "Stash tracked and untracked local changes."
    Write-OptionHelp "--stash-pop" "Apply and remove the newest stash entry."
    Write-OptionHelp "--stash-list" "Show stash entries."
    Write-OptionHelp "--autostash" "Temporarily stash dirty files for --pull or --sync, then restore them."
    Write-OptionHelp "--amend" "Amend the latest local commit; optionally replace its message."
    Write-OptionHelp "--undo" "Undo the latest unpushed commit and keep its changes staged."
    Write-OptionHelp "--branch-new" "Create and switch to a new local branch."
    Write-OptionHelp "--branch-switch" "Switch to an existing local branch."
    Write-OptionHelp "--branch-delete" "Safely delete a merged local branch."
    Write-OptionHelp "--allow-protected" "Skip confirmation when committing/pushing a protected branch."
    Write-OptionHelp "--allow-risky-files" "Skip sensitive/large-file confirmation before staging."
    Write-OptionHelp "--dry-run" "Preview add/commit/push actions without changing Git state."
    Write-OptionHelp "--no-push" "Add and commit changes, but do not fetch, pull, or push."
    Write-OptionHelp "--" "Stop option parsing. Useful if a commit message starts with '-'."
    Write-Host ""

    Write-Host "EXAMPLES" -ForegroundColor Yellow
    Write-Dim "  Command                                             Description"

    Write-ExampleGroup "V4 command syntax"
    Write-ExampleHelp 'gp repo status TestProject' "Show repository status."
    Write-ExampleHelp 'gp repo sync TestProject' "Synchronize one repository."
    Write-ExampleHelp 'gp branch new TestProject feature/api' "Create and switch to a branch."
    Write-ExampleHelp 'gp branch prune TestProject' "Safely remove stale merged branches."
    Write-ExampleHelp 'gp tag release TestProject v1.0.0 "Release 1.0.0"' "Create and push a safe release tag."
    Write-ExampleHelp 'gp remote add TestProject upstream <url>' "Add a Git remote."
    Write-ExampleHelp 'gp stash push TestProject' "Stash local changes."
    Write-ExampleHelp 'gp cache refresh' "Rebuild the repository cache."
    Write-ExampleHelp 'gp config doctor' "Run GPush diagnostics."
    Write-ExampleHelp 'gp alias set manager TestProject' "Create a repository alias."
    Write-ExampleHelp 'gp all fetch' "Refresh status for all repositories."
    Write-ExampleHelp 'gp clone <url>' "Clone and cache a repository."

    Write-ExampleGroup "Commit & push"
    Write-ExampleHelp 'gp TestProject "Fix communication handling"' "Commit all local changes and safely push them."
    Write-ExampleHelp 'gp TestProject Fix communication handling' "Same as above; quotes are optional for a normal message."
    Write-ExampleHelp 'gp --dry-run TestProject "Test commit"' "Preview the normal workflow without changing Git state."
    Write-ExampleHelp 'gp --no-push TestProject "Local checkpoint"' "Create a local commit without fetching or pushing."
    Write-ExampleHelp 'gp --amend TestProject' "Amend the latest local commit and keep its message."
    Write-ExampleHelp 'gp --amend TestProject "Better commit message"' "Amend the latest local commit and replace its message."
    Write-ExampleHelp 'gp --undo TestProject' "Undo the latest unpushed commit while keeping changes staged."

    Write-ExampleGroup "Status & inspection"
    Write-ExampleHelp 'gp --status TestProject' "Show branch, remote, sync state, and local changes."
    Write-ExampleHelp 'gp --status' "Show status for the repository in the current directory."
    Write-ExampleHelp 'gp --diff TestProject' "Show staged and unstaged diff statistics."
    Write-ExampleHelp 'gp --diff' "Show diff statistics for the repository in the current directory."
    Write-ExampleHelp 'gp --log TestProject' "Show a decorated Git graph for recent commits."
    Write-ExampleHelp 'gp --log' "Show the Git graph for the repository in the current directory."
    Write-ExampleHelp 'gp --tags TestProject' "List local tags, newest first."
    Write-ExampleHelp 'gp --branches TestProject' "Show local and remote branches."
    Write-ExampleHelp 'gp --remotes TestProject' "Show configured Git remotes."
    Write-ExampleHelp 'gp --remote-add TestProject upstream <url>' "Add a second remote."
    Write-ExampleHelp 'gp --remote-set-url TestProject origin <url>' "Change a remote URL."
    Write-ExampleHelp 'gp --remote-remove TestProject upstream' "Remove a remote."
    Write-ExampleHelp 'gp --fetch TestProject' "Fetch and prune the selected remote."

    Write-ExampleGroup "Synchronization"
    Write-ExampleHelp 'gp --pull TestProject' "Run a safe pull with rebase on a clean working tree."
    Write-ExampleHelp 'gp --pull --autostash TestProject' "Temporarily stash local changes, pull, then restore them."
    Write-ExampleHelp 'gp --sync TestProject' "Synchronize local and remote history without creating a commit."
    Write-ExampleHelp 'gp --sync --autostash TestProject' "Synchronize a dirty working tree using temporary autostash."

    Write-ExampleGroup "Stash"
    Write-ExampleHelp 'gp --stash TestProject' "Stash tracked and untracked local changes."
    Write-ExampleHelp 'gp --stash-list TestProject' "List available stash entries."
    Write-ExampleHelp 'gp --stash-pop TestProject' "Restore and remove the newest stash entry."

    Write-ExampleGroup "Tags & releases"
    Write-ExampleHelp 'gp --tag TestProject v1.0.0' "Create annotated tag v1.0.0 at HEAD."
    Write-ExampleHelp 'gp --tag TestProject v1.0.0 "First stable release"' "Create an annotated tag with a custom message."
    Write-ExampleHelp 'gp --tag-push TestProject v1.0.0' "Push one local tag to the selected remote."
    Write-ExampleHelp 'gp --tag-delete TestProject v1.0.0' "Delete only the local tag."
    Write-ExampleHelp 'gp --release TestProject v1.0.0 "Release 1.0.0"' "Create and push a tag only when the branch is clean and synced."

    Write-ExampleGroup "Branches"
    Write-ExampleHelp 'gp --branch-new TestProject feature/communication' "Create and switch to a new branch."
    Write-ExampleHelp 'gp --branch-switch TestProject main' "Switch to an existing local branch."
    Write-ExampleHelp 'gp --branch-delete TestProject feature/old' "Safely delete a merged local branch."
    Write-ExampleHelp 'gp --prune-branches TestProject' "Delete safe merged branches whose upstream was removed."
    Write-ExampleHelp 'gp --prune-branches' "Prune branches in the repository in the current directory."

    Write-ExampleGroup "Repository cache"
    Write-ExampleHelp 'gp --list' "List repositories currently known to GPush."
    Write-ExampleHelp 'gp --refresh' "Rescan configured search roots and rebuild the cache."
    Write-ExampleHelp 'gp --refresh --list' "Refresh the repository cache and print the result."
    Write-ExampleHelp 'gp --add .' "Add the current Git repository to the cache."
    Write-ExampleHelp 'gp --add "$HOME\Documents\Project\TestProject"' "Add a repository by explicit path."
    Write-ExampleHelp 'gp --renormalize TestProject' "Renormalize tracked files using .gitattributes."
    Write-ExampleHelp 'gp --config' "Show the effective GPush configuration."
    Write-ExampleHelp 'gp --config-path' "Print the config.json location."
    Write-ExampleHelp 'gp --doctor' "Run environment and Git setup diagnostics."

    Write-ExampleGroup "Multi-repository"
    Write-ExampleHelp 'gp --all' "Show a dashboard for all discovered repositories using cached remote refs."
    Write-ExampleHelp 'gp --all --status' "Explicitly show the multi-repository status dashboard."
    Write-ExampleHelp 'gp --all --fetch' "Fetch every repository, then show a fresh dashboard."
    Write-ExampleHelp 'gp --all --sync' "Safely fast-forward/push clean repositories where possible."
    Write-ExampleHelp 'gp --all --sync --allow-protected' "Also allow pushes to configured protected branches."

    Write-ExampleGroup "Aliases & navigation"
    Write-ExampleHelp 'gp --alias-set manager TestProject' "Create or update a short repository alias."
    Write-ExampleHelp 'gp manager "Fix communication"' "Use an alias anywhere a project name is accepted."
    Write-ExampleHelp 'gp --aliases' "List configured aliases."
    Write-ExampleHelp 'gp --alias-remove manager' "Remove an alias."
    Write-ExampleHelp 'gp --favorite TestProject' "Add a repository to favorites."
    Write-ExampleHelp 'gp --favorites' "List favorite repositories."
    Write-ExampleHelp 'gp --recent' "Show recently used repositories."
    Write-ExampleHelp 'gp --open TestProject' "Open the repository folder in File Explorer."
    Write-ExampleHelp 'gp --open' "Open the current repository folder."
    Write-ExampleHelp 'gp --clone <url>' "Clone into the first configured search root."
    Write-ExampleHelp 'gp --clone <url> <destination>' "Clone into an explicit destination."

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
    Write-Dim "  - Protected branches require confirmation before a direct commit/push."
    Write-Dim "  - Sensitive names and large files are checked before 'git add'."
    Write-Dim "  - Autostash restores local changes after pull/sync completes."
    Write-Dim "  - Undo/amend refuse to rewrite a commit already present on upstream."
    Write-Dim "  - Branch deletion uses 'git branch -d'; unmerged work is never force-deleted."
    Write-Dim "  - Release creation requires a clean tree and an exactly synchronized remote branch."
    Write-Dim "  - Remote tags are never deleted automatically."
    Write-Dim "  - Branch pruning only deletes merged branches with a gone upstream and always uses git branch -d."
    Write-Dim "  - Use --no-push when you intentionally want a local-only commit."
    Write-Dim "  - V4 subcommands are translated to the same proven safety logic as legacy options."
    Write-Host ""
}

# Load/create config before argument parsing so every command uses the same settings.
Initialize-GPushConfig

# ============================================================
# V4 COMMAND ROUTER
# ============================================================

function ConvertFrom-GPushSubcommand {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Arguments
    )

    $inputArgs = @($Arguments)

    if ($inputArgs.Count -eq 0) {
        return $inputArgs
    }

    # Existing flag-based syntax and the classic
    #   gp <project> <commit message>
    # workflow remain fully backward compatible.
    $first = [string]$inputArgs[0]
    if ($first.StartsWith("-")) {
        return $inputArgs
    }

    $command = $first.ToLowerInvariant()
    $rest = if ($inputArgs.Count -gt 1) {
        @($inputArgs[1..($inputArgs.Count - 1)])
    }
    else {
        @()
    }

    function Join-GPushArgs {
        param(
            [string[]]$Prefix,
            [object[]]$Tail
        )

        return @($Prefix) + @($Tail)
    }

    switch ($command) {
        "repo" {
            if ($rest.Count -eq 0) {
                return @("--status")
            }

            $action = ([string]$rest[0]).ToLowerInvariant()
            $tail = if ($rest.Count -gt 1) { @($rest[1..($rest.Count - 1)]) } else { @() }

            switch ($action) {
                "status" { return Join-GPushArgs @("--status") $tail }
                "diff"   { return Join-GPushArgs @("--diff") $tail }
                "log"    { return Join-GPushArgs @("--log") $tail }
                "open"   { return Join-GPushArgs @("--open") $tail }
                "fetch"  { return Join-GPushArgs @("--fetch") $tail }
                "pull"   { return Join-GPushArgs @("--pull") $tail }
                "sync"   { return Join-GPushArgs @("--sync") $tail }
                default {
                    Write-Err "Unknown repo command: $action"
                    Write-Dim "Use: gp repo status|diff|log|open|fetch|pull|sync [project]"
                    exit 2
                }
            }
        }

        "branch" {
            if ($rest.Count -eq 0) {
                return @("--branches")
            }

            $action = ([string]$rest[0]).ToLowerInvariant()
            $tail = if ($rest.Count -gt 1) { @($rest[1..($rest.Count - 1)]) } else { @() }

            switch ($action) {
                "list"   { return Join-GPushArgs @("--branches") $tail }
                "new"    { return Join-GPushArgs @("--branch-new") $tail }
                "switch" { return Join-GPushArgs @("--branch-switch") $tail }
                "delete" { return Join-GPushArgs @("--branch-delete") $tail }
                "prune"  { return Join-GPushArgs @("--prune-branches") $tail }
                default {
                    Write-Err "Unknown branch command: $action"
                    Write-Dim "Use: gp branch list|new|switch|delete|prune ..."
                    exit 2
                }
            }
        }

        "tag" {
            if ($rest.Count -eq 0) {
                return @("--tags")
            }

            $action = ([string]$rest[0]).ToLowerInvariant()
            $tail = if ($rest.Count -gt 1) { @($rest[1..($rest.Count - 1)]) } else { @() }

            switch ($action) {
                "list"    { return Join-GPushArgs @("--tags") $tail }
                "create"  { return Join-GPushArgs @("--tag") $tail }
                "push"    { return Join-GPushArgs @("--tag-push") $tail }
                "delete"  { return Join-GPushArgs @("--tag-delete") $tail }
                "release" { return Join-GPushArgs @("--release") $tail }
                default {
                    Write-Err "Unknown tag command: $action"
                    Write-Dim "Use: gp tag list|create|push|delete|release ..."
                    exit 2
                }
            }
        }

        "remote" {
            if ($rest.Count -eq 0) {
                return @("--remotes")
            }

            $action = ([string]$rest[0]).ToLowerInvariant()
            $tail = if ($rest.Count -gt 1) { @($rest[1..($rest.Count - 1)]) } else { @() }

            switch ($action) {
                "list"    { return Join-GPushArgs @("--remotes") $tail }
                "add"     { return Join-GPushArgs @("--remote-add") $tail }
                "set-url" { return Join-GPushArgs @("--remote-set-url") $tail }
                "remove"  { return Join-GPushArgs @("--remote-remove") $tail }
                default {
                    Write-Err "Unknown remote command: $action"
                    Write-Dim "Use: gp remote list|add|set-url|remove ..."
                    exit 2
                }
            }
        }

        "stash" {
            if ($rest.Count -eq 0) {
                return @("--stash-list")
            }

            $action = ([string]$rest[0]).ToLowerInvariant()
            $tail = if ($rest.Count -gt 1) { @($rest[1..($rest.Count - 1)]) } else { @() }

            switch ($action) {
                "push" { return Join-GPushArgs @("--stash") $tail }
                "list" { return Join-GPushArgs @("--stash-list") $tail }
                "pop"  { return Join-GPushArgs @("--stash-pop") $tail }
                default {
                    Write-Err "Unknown stash command: $action"
                    Write-Dim "Use: gp stash push|list|pop [project]"
                    exit 2
                }
            }
        }

        "cache" {
            if ($rest.Count -eq 0) {
                return @("--list")
            }

            $action = ([string]$rest[0]).ToLowerInvariant()
            $tail = if ($rest.Count -gt 1) { @($rest[1..($rest.Count - 1)]) } else { @() }

            switch ($action) {
                "list"    { return Join-GPushArgs @("--list") $tail }
                "refresh" { return Join-GPushArgs @("--refresh") $tail }
                "add"     { return Join-GPushArgs @("--add") $tail }
                default {
                    Write-Err "Unknown cache command: $action"
                    Write-Dim "Use: gp cache list|refresh|add ..."
                    exit 2
                }
            }
        }

        "config" {
            if ($rest.Count -eq 0) {
                return @("--config")
            }

            $action = ([string]$rest[0]).ToLowerInvariant()

            switch ($action) {
                "show"   { return @("--config") }
                "path"   { return @("--config-path") }
                "doctor" { return @("--doctor") }
                default {
                    Write-Err "Unknown config command: $action"
                    Write-Dim "Use: gp config show|path|doctor"
                    exit 2
                }
            }
        }

        "alias" {
            if ($rest.Count -eq 0) {
                return @("--aliases")
            }

            $action = ([string]$rest[0]).ToLowerInvariant()
            $tail = if ($rest.Count -gt 1) { @($rest[1..($rest.Count - 1)]) } else { @() }

            switch ($action) {
                "list"   { return @("--aliases") }
                "set"    { return Join-GPushArgs @("--alias-set") $tail }
                "remove" { return Join-GPushArgs @("--alias-remove") $tail }
                default {
                    Write-Err "Unknown alias command: $action"
                    Write-Dim "Use: gp alias list|set|remove ..."
                    exit 2
                }
            }
        }

        "favorite" {
            if ($rest.Count -eq 0) {
                return @("--favorites")
            }

            $action = ([string]$rest[0]).ToLowerInvariant()
            $tail = if ($rest.Count -gt 1) { @($rest[1..($rest.Count - 1)]) } else { @() }

            switch ($action) {
                "list"   { return @("--favorites") }
                "add"    { return Join-GPushArgs @("--favorite") $tail }
                "remove" { return Join-GPushArgs @("--unfavorite") $tail }
                default {
                    Write-Err "Unknown favorite command: $action"
                    Write-Dim "Use: gp favorite list|add|remove ..."
                    exit 2
                }
            }
        }

        "all" {
            if ($rest.Count -eq 0) {
                return @("--all")
            }

            $action = ([string]$rest[0]).ToLowerInvariant()
            $tail = if ($rest.Count -gt 1) { @($rest[1..($rest.Count - 1)]) } else { @() }

            switch ($action) {
                "status" { return Join-GPushArgs @("--all", "--status") $tail }
                "fetch"  { return Join-GPushArgs @("--all", "--fetch") $tail }
                "sync"   { return Join-GPushArgs @("--all", "--sync") $tail }
                default {
                    Write-Err "Unknown all command: $action"
                    Write-Dim "Use: gp all status|fetch|sync"
                    exit 2
                }
            }
        }

        "clone" {
            return Join-GPushArgs @("--clone") $rest
        }

        "recent" {
            if ($rest.Count -gt 0) {
                Write-Err "Command 'gp recent' does not accept arguments."
                exit 2
            }
            return @("--recent")
        }

        "help" {
            return @("--help")
        }

        "version" {
            return @("--version")
        }

        default {
            # Not a v4 command. Preserve the classic shortcut:
            #   gp Project "commit message"
            return $inputArgs
        }
    }
}

# ============================================================
# ARGUMENT PARSING
# ============================================================

$tokens = @(ConvertFrom-GPushSubcommand -Arguments $RawArguments)

$ShowHelp    = $false
$ShowVersion = $false
$ListRepos   = $false
$Refresh     = $false
$AddRepo     = $false
$CachedOnly  = $false
$ShowConfig  = $false
$ShowConfigPath = $false
$Doctor      = $false
$AllRepos    = $false
$AliasesOnly = $false
$AliasSet    = $false
$AliasRemove = $false
$FavoriteAdd = $false
$FavoriteRemove = $false
$FavoritesOnly = $false
$RecentOnly = $false
$OpenRepo = $false
$CloneRepo = $false
$RemoteAddOnly = $false
$RemoteSetUrlOnly = $false
$RemoteRemoveOnly = $false
$PruneBranchesOnly = $false
$StatusOnly   = $false
$DiffOnly     = $false
$Renormalize  = $false
$FetchOnly    = $false
$LogOnly      = $false
$TagsOnly     = $false
$TagCreateOnly = $false
$TagPushOnly   = $false
$TagDeleteOnly = $false
$ReleaseOnly   = $false
$BranchesOnly = $false
$RemotesOnly  = $false
$PullOnly     = $false
$SyncOnly     = $false
$StashOnly    = $false
$StashPopOnly = $false
$StashListOnly = $false
$AmendOnly    = $false
$UndoOnly     = $false
$BranchNewOnly = $false
$BranchSwitchOnly = $false
$BranchDeleteOnly = $false
$AutoStash    = $false
$AllowProtected = $false
$AllowRiskyFiles = $false
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
            "--config"  { $ShowConfig = $true }
            "--config-path" { $ShowConfigPath = $true }
            "--doctor"  { $Doctor = $true }
            "--all"     { $AllRepos = $true }
            "--aliases"       { $AliasesOnly = $true }
            "--alias-set"     { $AliasSet = $true }
            "--alias-remove"  { $AliasRemove = $true }
            "--favorite"      { $FavoriteAdd = $true }
            "--unfavorite"    { $FavoriteRemove = $true }
            "--favorites"     { $FavoritesOnly = $true }
            "--recent"        { $RecentOnly = $true }
            "--open"          { $OpenRepo = $true }
            "--clone"         { $CloneRepo = $true }
            "-s"        { $StatusOnly = $true }
            "--status"  { $StatusOnly = $true }
            "--diff"        { $DiffOnly = $true }
            "--renormalize" { $Renormalize = $true }
            "--fetch"       { $FetchOnly = $true }
            "--log"         { $LogOnly = $true }
            "--tags"        { $TagsOnly = $true }
            "--tag"         { $TagCreateOnly = $true }
            "--tag-push"    { $TagPushOnly = $true }
            "--tag-delete"  { $TagDeleteOnly = $true }
            "--release"     { $ReleaseOnly = $true }
            "--branches"    { $BranchesOnly = $true }
            "--remotes"     { $RemotesOnly = $true }
            "--remote-add"       { $RemoteAddOnly = $true }
            "--remote-set-url"   { $RemoteSetUrlOnly = $true }
            "--remote-remove"    { $RemoteRemoveOnly = $true }
            "--prune-branches"   { $PruneBranchesOnly = $true }
            "--pull"        { $PullOnly = $true }
            "--sync"        { $SyncOnly = $true }
            "--stash"       { $StashOnly = $true }
            "--stash-pop"   { $StashPopOnly = $true }
            "--stash-list"  { $StashListOnly = $true }
            "--amend"       { $AmendOnly = $true }
            "--undo"        { $UndoOnly = $true }
            "--branch-new"    { $BranchNewOnly = $true }
            "--branch-switch" { $BranchSwitchOnly = $true }
            "--branch-delete" { $BranchDeleteOnly = $true }
            "--autostash"   { $AutoStash = $true }
            "--allow-protected" { $AllowProtected = $true }
            "--allow-risky-files" { $AllowRiskyFiles = $true }
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

$metaModes = @($ShowConfig, $ShowConfigPath, $Doctor) | Where-Object { $_ }
if ($metaModes.Count -gt 1) {
    Write-Err "Only one of --config, --config-path, or --doctor can be used at a time."
    exit 2
}

$otherModeRequested = (
    $ListRepos -or $Refresh -or $AddRepo -or $AllRepos -or
    $AliasesOnly -or $AliasSet -or $AliasRemove -or $FavoriteAdd -or $FavoriteRemove -or
    $FavoritesOnly -or $RecentOnly -or $OpenRepo -or $CloneRepo -or
    $StatusOnly -or $DiffOnly -or $Renormalize -or
    $FetchOnly -or $LogOnly -or $TagsOnly -or $TagCreateOnly -or $TagPushOnly -or $TagDeleteOnly -or $ReleaseOnly -or
    $BranchesOnly -or $RemotesOnly -or $RemoteAddOnly -or $RemoteSetUrlOnly -or $RemoteRemoveOnly -or
    $PruneBranchesOnly -or $PullOnly -or $SyncOnly -or
    $StashOnly -or $StashPopOnly -or $StashListOnly -or $AmendOnly -or $UndoOnly -or
    $BranchNewOnly -or $BranchSwitchOnly -or $BranchDeleteOnly -or $AutoStash -or
    $AllowProtected -or $AllowRiskyFiles -or $DryRun -or $NoPush -or $CachedOnly
)

if ($metaModes.Count -gt 0 -and ($otherModeRequested -or $positionals.Count -gt 0)) {
    Write-Err "Options --config, --config-path, and --doctor must be used as standalone commands."
    exit 2
}

if ($ShowConfigPath) {
    Write-Host $ConfigFile
    exit 0
}

if ($ShowConfig) {
    Show-GPushConfig
    exit 0
}

if ($Doctor) {
    $doctorExitCode = Show-GPushDoctor
    exit $doctorExitCode
}

if ($AllRepos) {
    if ($positionals.Count -gt 0) {
        Write-Err "Option '--all' does not accept a project name or commit message."
        exit 2
    }

    $invalidAllCombination = (
        $ListRepos -or $AddRepo -or $DiffOnly -or $Renormalize -or $LogOnly -or
        $TagsOnly -or $TagCreateOnly -or $TagPushOnly -or $TagDeleteOnly -or $ReleaseOnly -or
        $BranchesOnly -or $RemotesOnly -or $RemoteAddOnly -or $RemoteSetUrlOnly -or $RemoteRemoveOnly -or
        $PruneBranchesOnly -or $PullOnly -or $StashOnly -or
        $StashPopOnly -or $StashListOnly -or $AmendOnly -or $UndoOnly -or
        $BranchNewOnly -or $BranchSwitchOnly -or $BranchDeleteOnly -or
        $AliasesOnly -or $AliasSet -or $AliasRemove -or $FavoriteAdd -or $FavoriteRemove -or
        $FavoritesOnly -or $RecentOnly -or $OpenRepo -or $CloneRepo -or
        $AutoStash -or $AllowRiskyFiles -or $DryRun -or $NoPush
    )

    if ($invalidAllCombination) {
        Write-Err "Option '--all' can only be combined with --status, --fetch, --sync, --refresh, --cached, or --allow-protected."
        exit 2
    }

    if ($FetchOnly -and $SyncOnly) {
        Write-Err "Options '--all --fetch' and '--all --sync' are separate modes. Use only one."
        exit 2
    }
}

$exclusiveModes = @(
    $StatusOnly,
    $DiffOnly,
    $Renormalize,
    $FetchOnly,
    $LogOnly,
    $TagsOnly,
    $TagCreateOnly,
    $TagPushOnly,
    $TagDeleteOnly,
    $ReleaseOnly,
    $BranchesOnly,
    $RemotesOnly,
    $PullOnly,
    $SyncOnly,
    $StashOnly,
    $StashPopOnly,
    $StashListOnly,
    $AmendOnly,
    $UndoOnly,
    $BranchNewOnly,
    $BranchSwitchOnly,
    $BranchDeleteOnly,
    $AliasesOnly,
    $AliasSet,
    $AliasRemove,
    $FavoriteAdd,
    $FavoriteRemove,
    $FavoritesOnly,
    $RecentOnly,
    $OpenRepo,
    $CloneRepo,
    $RemoteAddOnly,
    $RemoteSetUrlOnly,
    $RemoteRemoveOnly,
    $PruneBranchesOnly
) | Where-Object { $_ }

if (-not $AllRepos -and $exclusiveModes.Count -gt 1) {
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

if ($SyncOnly -and $NoPush) {
    Write-Err "Options '--sync' and '--no-push' cannot be used together."
    exit 2
}

if ($SyncOnly -and $DryRun) {
    Write-Err "Options '--sync' and '--dry-run' cannot be used together."
    exit 2
}

if (($TagCreateOnly -or $TagPushOnly -or $TagDeleteOnly -or $ReleaseOnly) -and $DryRun) {
    Write-Err "Option '--dry-run' is not supported with tag or release operations."
    exit 2
}

if (($AmendOnly -or $UndoOnly -or $BranchNewOnly -or $BranchSwitchOnly -or $BranchDeleteOnly) -and $DryRun) {
    Write-Err "Option '--dry-run' is not supported with amend, undo, or branch operations."
    exit 2
}

if (($TagCreateOnly -or $TagPushOnly -or $TagDeleteOnly -or $ReleaseOnly) -and $NoPush) {
    Write-Err "Option '--no-push' cannot be combined with tag or release operations."
    exit 2
}

if (($AmendOnly -or $UndoOnly -or $BranchNewOnly -or $BranchSwitchOnly -or $BranchDeleteOnly) -and $NoPush) {
    Write-Err "Option '--no-push' cannot be combined with amend, undo, or branch operations."
    exit 2
}

if ($AutoStash -and -not ($PullOnly -or $SyncOnly)) {
    Write-Err "Option '--autostash' can only be used with '--pull' or '--sync'."
    exit 2
}

if ($Refresh -and $CachedOnly) {
    Write-Err "Options '--refresh' and '--cached' cannot be used together."
    exit 2
}

if ($AddRepo -and (
    $Refresh -or $ListRepos -or $AllRepos -or
    $AliasesOnly -or $AliasSet -or $AliasRemove -or $FavoriteAdd -or $FavoriteRemove -or
    $FavoritesOnly -or $RecentOnly -or $OpenRepo -or $CloneRepo -or
    $StatusOnly -or $DiffOnly -or $Renormalize -or
    $FetchOnly -or $LogOnly -or $TagsOnly -or $TagCreateOnly -or $TagPushOnly -or $TagDeleteOnly -or $ReleaseOnly -or
    $BranchesOnly -or $RemotesOnly -or $RemoteAddOnly -or $RemoteSetUrlOnly -or $RemoteRemoveOnly -or
    $PruneBranchesOnly -or
    $PullOnly -or $SyncOnly -or $StashOnly -or $StashPopOnly -or $StashListOnly -or
    $AmendOnly -or $UndoOnly -or $BranchNewOnly -or $BranchSwitchOnly -or $BranchDeleteOnly -or
    $AutoStash -or $AllowProtected -or $AllowRiskyFiles -or $DryRun -or $NoPush -or $CachedOnly -or
    $ShowConfig -or $ShowConfigPath -or $Doctor
)) {
    Write-Err "Option '--add' cannot be combined with other operation modes."
    exit 2
}

$Project = $null
$CommitMessageParts = @()
$OperationArgument = $null
$OperationArgument2 = $null

if ($AliasSet) {
    if ($positionals.Count -ne 2) {
        Write-Err "Alias creation requires exactly an alias and a project."
        Write-Dim "Example: gp --alias-set manager TestProject"
        exit 2
    }

    $OperationArgument = [string]$positionals[0]
    $Project = [string]$positionals[1]
}
elseif ($AliasRemove) {
    if ($positionals.Count -ne 1) {
        Write-Err "Alias removal requires exactly one alias."
        Write-Dim "Example: gp --alias-remove manager"
        exit 2
    }

    $OperationArgument = [string]$positionals[0]
}
elseif ($AliasesOnly -or $FavoritesOnly -or $RecentOnly) {
    if ($positionals.Count -gt 0) {
        Write-Err "This command does not accept a project name."
        exit 2
    }
}
elseif ($FavoriteAdd -or $FavoriteRemove) {
    if ($positionals.Count -ne 1) {
        Write-Err "This command requires exactly one project."
        exit 2
    }

    $Project = [string]$positionals[0]
}
elseif ($TagCreateOnly -or $ReleaseOnly) {
    if ($positionals.Count -lt 2) {
        Write-Err "This operation requires a project and a tag name."
        Write-Dim "Example: gp --release TestProject v1.0.0 \"Release 1.0.0\""
        exit 2
    }

    $Project = [string]$positionals[0]
    $OperationArgument = [string]$positionals[1]

    if ($positionals.Count -gt 2) {
        $CommitMessageParts = @($positionals[2..($positionals.Count - 1)])
    }
}
elseif ($TagPushOnly -or $TagDeleteOnly) {
    if ($positionals.Count -ne 2) {
        Write-Err "This operation requires exactly a project and a tag name."
        Write-Dim "Example: gp --tag-push TestProject v1.0.0"
        exit 2
    }

    $Project = [string]$positionals[0]
    $OperationArgument = [string]$positionals[1]
}
elseif ($CloneRepo) {
    if ($positionals.Count -lt 1 -or $positionals.Count -gt 2) {
        Write-Err "Clone requires a repository URL and optionally a destination path."
        Write-Dim "Example: gp --clone git@github.com:user/project.git"
        Write-Dim "Example: gp --clone https://github.com/user/project.git `"$HOME\Documents\Project\project`""
        exit 2
    }

    $OperationArgument = [string]$positionals[0]
    if ($positionals.Count -eq 2) {
        $OperationArgument2 = [string]$positionals[1]
    }
}
elseif ($RemoteAddOnly -or $RemoteSetUrlOnly) {
    if ($positionals.Count -ne 3) {
        Write-Err "This remote operation requires a project, remote name, and URL."
        Write-Dim "Example: gp --remote-add TestProject upstream https://github.com/user/project.git"
        exit 2
    }

    $Project = [string]$positionals[0]
    $OperationArgument = [string]$positionals[1]
    $OperationArgument2 = [string]$positionals[2]
}
elseif ($RemoteRemoveOnly) {
    if ($positionals.Count -ne 2) {
        Write-Err "Remote removal requires a project and remote name."
        Write-Dim "Example: gp --remote-remove TestProject upstream"
        exit 2
    }

    $Project = [string]$positionals[0]
    $OperationArgument = [string]$positionals[1]
}
elseif ($PruneBranchesOnly) {
    if ($positionals.Count -gt 1) {
        Write-Err "Option '--prune-branches' accepts at most one project."
        exit 2
    }

    if ($positionals.Count -eq 1) {
        $Project = [string]$positionals[0]
    }
}
elseif ($OpenRepo) {
    if ($positionals.Count -gt 1) {
        Write-Err "Option '--open' accepts at most one project."
        exit 2
    }

    if ($positionals.Count -eq 1) {
        $Project = [string]$positionals[0]
    }
}
else {
    if ($positionals.Count -gt 0) {
        $Project = $positionals[0]
    }

    if ($positionals.Count -gt 1) {
        $CommitMessageParts = @($positionals[1..($positionals.Count - 1)])
    }
}

if ($BranchNewOnly -or $BranchSwitchOnly -or $BranchDeleteOnly) {
    if ($CommitMessageParts.Count -ne 1) {
        Write-Err "This branch operation requires exactly one branch name after the project."
        Write-Dim "Example: gp --branch-new TestProject feature/communication"
        exit 2
    }

    $OperationArgument = [string]$CommitMessageParts[0]
    $CommitMessageParts = @()
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

function Test-ProtectedBranch {
    param([string]$Branch)

    foreach ($pattern in $ProtectedBranches) {
        if ($Branch -like $pattern) {
            return $true
        }
    }

    return $false
}

function Confirm-GPushAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    $answer = Read-Host "$Prompt [y/N]"
    return ($answer -match '^(?i:y|yes)$')
}

function Confirm-GPushActionDefaultYes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    $answer = Read-Host "$Prompt [Y/n]"
    return (
        [string]::IsNullOrWhiteSpace($answer) -or
        $answer -match '^(?i:y|yes)$'
    )
}

function Get-ChangedPaths {
    $paths = @()

    $unstaged = Get-GitOutput -Arguments @("diff", "--name-only", "--diff-filter=ACMRTUXB") -AllowFailure
    if ($unstaged.Success) {
        $paths += @($unstaged.Lines)
    }

    $staged = Get-GitOutput -Arguments @("diff", "--cached", "--name-only", "--diff-filter=ACMRTUXB") -AllowFailure
    if ($staged.Success) {
        $paths += @($staged.Lines)
    }

    $untracked = Get-GitOutput -Arguments @("ls-files", "--others", "--exclude-standard") -AllowFailure
    if ($untracked.Success) {
        $paths += @($untracked.Lines)
    }

    return @(
        $paths |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}

function Test-SensitivePath {
    param([string]$Path)

    $normalized = $Path.Replace('\', '/').ToLowerInvariant()
    $name = [System.IO.Path]::GetFileName($normalized)

    if ($name -in @('.env.example', '.env.sample', '.env.template')) {
        return $false
    }

    if ($name -eq '.env' -or $name -like '.env.*') { return $true }
    if ($name -like '*.pem' -or $name -like '*.key') { return $true }
    if ($name -like '*.pfx' -or $name -like '*.p12') { return $true }
    if ($name -in @('id_rsa', 'id_ed25519', 'id_ecdsa', 'id_dsa')) { return $true }
    if ($name -like 'secrets*.json' -or $name -like 'secrets*.yml' -or $name -like 'secrets*.yaml') { return $true }
    if ($name -like 'credentials*.json' -or $name -like 'credentials*.yml' -or $name -like 'credentials*.yaml') { return $true }
    if ($name -like 'service-account*.json') { return $true }

    return $false
}

function Get-RiskyFiles {
    $sensitive = @()
    $large = @()
    $thresholdBytes = [int64]$LargeFileThresholdMB * 1MB

    foreach ($path in @(Get-ChangedPaths)) {
        if (Test-SensitivePath -Path $path) {
            $sensitive += $path
        }

        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $item = Get-Item -LiteralPath $path -ErrorAction Stop
                if ($item.Length -ge $thresholdBytes) {
                    $large += [PSCustomObject]@{
                        Path = $path
                        SizeMB = [Math]::Round($item.Length / 1MB, 1)
                    }
                }
            }
            catch {
                # Ignore files that disappear between status and inspection.
            }
        }
    }

    return [PSCustomObject]@{
        Sensitive = @($sensitive | Sort-Object -Unique)
        Large = @($large | Sort-Object Path -Unique)
    }
}

function Confirm-RiskyFiles {
    param([switch]$PreviewOnly)

    $risk = Get-RiskyFiles
    $hasRisk = ($risk.Sensitive.Count -gt 0 -or $risk.Large.Count -gt 0)

    if (-not $hasRisk) {
        return $true
    }

    Write-Section "File safety check"

    if ($risk.Sensitive.Count -gt 0) {
        Write-Warn "Potentially sensitive file names detected:"
        foreach ($path in $risk.Sensitive) {
            Write-Host "  $path" -ForegroundColor Yellow
        }
    }

    if ($risk.Large.Count -gt 0) {
        if ($risk.Sensitive.Count -gt 0) { Write-Host "" }
        Write-Warn "Large files detected (threshold: $LargeFileThresholdMB MB):"
        foreach ($item in $risk.Large) {
            Write-Host ("  {0} ({1} MB)" -f $item.Path, $item.SizeMB) -ForegroundColor Yellow
        }
    }

    if ($PreviewOnly) {
        Write-Dim "  Dry run: GPush would require confirmation before staging these files."
        return $true
    }

    Write-Host ""
    Write-Warn "Review these files before committing. Secrets and large binaries are easy to publish accidentally."
    return (Confirm-GPushAction -Prompt "Stage these files anyway?")
}

function New-GPushAutoStash {
    param([string]$Reason)

    Write-Section "Autostash"
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $message = "GPush autostash ($Reason) $stamp"
    Write-Info "[STASH] git stash push --include-untracked"

    $result = Get-GitOutput -Arguments @("stash", "push", "--include-untracked", "-m", $message) -AllowFailure
    foreach ($line in $result.Lines) {
        Write-Host $line
    }

    if (-not $result.Success) {
        Write-Err "[STASH] FAILED"
        return $false
    }

    Write-Ok "[STASH] OK"
    return $true
}

function Restore-GPushAutoStash {
    Write-Section "Restore autostash"
    Write-Info "[STASH POP] git stash pop"
    $result = Get-GitOutput -Arguments @("stash", "pop") -AllowFailure

    foreach ($line in $result.Lines) {
        Write-Host $line
    }

    if (-not $result.Success) {
        Write-Err "[STASH POP] FAILED"
        Write-Warn "Your changes are still available in Git's stash or working tree. Resolve any conflicts manually."
        return $false
    }

    Write-Ok "[STASH POP] OK"
    return $true
}

function Write-SyncAutoStashRecoveryHint {
    if ($syncAutoStashCreated) {
        Write-Host ""
        Write-Warn "GPush kept your autostashed local changes safe because sync did not finish."
        Write-Dim "Finish or abort the Git operation first, then restore them with: git stash pop"
    }
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

function Get-GPushCache {
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

    $current = @(Get-GPushCache)
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
        $cachedRepos = @(Get-GPushCache)

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

    $Search = Resolve-GPushAlias -Search $Search

    $repoMatches = @($Repos | Where-Object { $_.Name -ieq $Search })
    if ($repoMatches.Count -gt 0) {
        return $repoMatches
    }

    $repoMatches = @($Repos | Where-Object { $_.Name -ilike "$Search*" })
    if ($repoMatches.Count -gt 0) {
        return $repoMatches
    }

    $repoMatches = @($Repos | Where-Object { $_.Name -ilike "*$Search*" })
    if ($repoMatches.Count -gt 0) {
        return $repoMatches
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
    $repoMatches = @(Get-RepositoryMatches -Repos $Repos -Search $Search)

    if ($repoMatches.Count -eq 0) {
        if (-not $QuietNotFound) {
            Write-Host ""
            Write-Err "Repository '$Search' not found."
        }
        return $null
    }

    if ($repoMatches.Count -eq 1) {
        return $repoMatches[0]
    }

    Write-Host ""
    Write-Warn "Multiple repositories found:"
    Write-Host ""

    for ($i = 0; $i -lt $repoMatches.Count; $i++) {
        Write-Host "[$($i + 1)] " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($repoMatches[$i].Name)" -ForegroundColor White
        Write-Dim "    $($repoMatches[$i].Path)"
    }

    Write-Host ""

    while ($true) {
        $selection = Read-Host "Select repository"
        $number = 0

        if ([int]::TryParse($selection, [ref]$number)) {
            $index = $number - 1

            if ($index -ge 0 -and $index -lt $repoMatches.Count) {
                return $repoMatches[$index]
            }
        }

        Write-Err "Invalid selection."
    }
}


# ============================================================
# MULTI-REPOSITORY DASHBOARD / OPERATIONS
# ============================================================

function Get-GPushRemoteForCurrentRepository {
    $namesResult = Get-GitOutput -Arguments @("remote") -AllowFailure
    $names = @(
        $namesResult.Lines |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() }
    )

    if ($names.Count -eq 0) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($PreferredRemote) -and $names -contains $PreferredRemote) {
        return $PreferredRemote
    }

    if ($names -contains "origin") {
        return "origin"
    }

    return $names[0]
}

function Get-GPushRepositorySnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Repository,
        [switch]$Fetch
    )

    $snapshot = [ordered]@{
        Repository = [string]$Repository.Name
        Path = [string]$Repository.Path
        Branch = "-"
        Worktree = "-"
        DirtyCount = 0
        Remote = "-"
        Upstream = "-"
        CompareRef = $null
        Ahead = 0
        Behind = 0
        Sync = "Unknown"
        FetchOk = $true
        Valid = $true
        Detached = $false
        RemoteBranchExists = $false
    }

    Push-Location $Repository.Path
    try {
        $inside = Get-GitOutput -Arguments @("rev-parse", "--is-inside-work-tree") -AllowFailure
        if (-not $inside.Success -or $inside.Text.Trim() -ne "true") {
            $snapshot.Valid = $false
            $snapshot.Sync = "Invalid repository"
            return [PSCustomObject]$snapshot
        }

        $branchResult = Get-GitOutput -Arguments @("symbolic-ref", "--quiet", "--short", "HEAD") -AllowFailure
        if (-not $branchResult.Success -or [string]::IsNullOrWhiteSpace($branchResult.Text)) {
            $snapshot.Detached = $true
            $snapshot.Branch = "(detached)"
        }
        else {
            $snapshot.Branch = $branchResult.Text.Trim()
        }

        $statusResult = Get-GitOutput -Arguments @("status", "--short") -AllowFailure
        if ($statusResult.Success) {
            $changed = @($statusResult.Lines | Where-Object { $_ -ne $null })
            $snapshot.DirtyCount = $changed.Count
            $snapshot.Worktree = if ($changed.Count -eq 0) { "clean" } else { "dirty ($($changed.Count))" }
        }
        else {
            $snapshot.Worktree = "unknown"
        }

        $remote = Get-GPushRemoteForCurrentRepository
        if ($remote) {
            $snapshot.Remote = $remote
        }

        if ($Fetch -and $remote) {
            $fetchResult = Get-GitOutput -Arguments @("fetch", "--prune", $remote) -AllowFailure
            if (-not $fetchResult.Success) {
                $snapshot.FetchOk = $false
                $snapshot.Sync = "Fetch failed"
                return [PSCustomObject]$snapshot
            }
        }

        if ($snapshot.Detached) {
            $snapshot.Sync = "Detached HEAD"
            return [PSCustomObject]$snapshot
        }

        if (-not $remote) {
            $snapshot.Sync = "No remote"
            return [PSCustomObject]$snapshot
        }

        $upstreamResult = Get-GitOutput -Arguments @(
            "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"
        ) -AllowFailure

        if ($upstreamResult.Success -and -not [string]::IsNullOrWhiteSpace($upstreamResult.Text)) {
            $snapshot.Upstream = $upstreamResult.Text.Trim()
            $snapshot.CompareRef = $snapshot.Upstream
        }
        else {
            $remoteRef = "refs/remotes/$remote/$($snapshot.Branch)"
            if (Test-GitRef -Ref $remoteRef) {
                $snapshot.RemoteBranchExists = $true
                $snapshot.Upstream = "$remote/$($snapshot.Branch) (not tracking)"
                $snapshot.CompareRef = "$remote/$($snapshot.Branch)"
            }
        }

        if ($null -ne $snapshot.CompareRef) {
            $countResult = Get-GitOutput -Arguments @(
                "rev-list", "--left-right", "--count", "HEAD...$($snapshot.CompareRef)"
            ) -AllowFailure

            if ($countResult.Success) {
                $parts = $countResult.Text.Trim() -split '\s+'
                if ($parts.Count -ge 2) {
                    $snapshot.Ahead = [int]$parts[0]
                    $snapshot.Behind = [int]$parts[1]
                }
            }

            if ($snapshot.Ahead -eq 0 -and $snapshot.Behind -eq 0) {
                $snapshot.Sync = "Up to date"
            }
            elseif ($snapshot.Ahead -gt 0 -and $snapshot.Behind -eq 0) {
                $snapshot.Sync = "$($snapshot.Ahead) ahead"
            }
            elseif ($snapshot.Ahead -eq 0 -and $snapshot.Behind -gt 0) {
                $snapshot.Sync = "$($snapshot.Behind) behind"
            }
            else {
                $snapshot.Sync = "$($snapshot.Ahead) ahead / $($snapshot.Behind) behind"
            }
        }
        else {
            $snapshot.Sync = "New remote branch"
        }

        return [PSCustomObject]$snapshot
    }
    finally {
        Pop-Location
    }
}

function Limit-GPushTableText {
    param(
        [string]$Text,
        [int]$Width
    )

    if ($null -eq $Text) {
        return ""
    }

    if ($Text.Length -le $Width) {
        return $Text
    }

    if ($Width -le 3) {
        return $Text.Substring(0, $Width)
    }

    return $Text.Substring(0, $Width - 3) + "..."
}

function Write-GPushAllRow {
    param(
        [Parameter(Mandatory = $true)]
        $Snapshot,
        [string]$Result = ""
    )

    $repoText = Limit-GPushTableText -Text ([string]$Snapshot.Repository) -Width 24
    $branchText = Limit-GPushTableText -Text ([string]$Snapshot.Branch) -Width 24
    $worktreeText = Limit-GPushTableText -Text ([string]$Snapshot.Worktree) -Width 12
    $syncText = Limit-GPushTableText -Text ([string]$Snapshot.Sync) -Width 23
    $resultText = Limit-GPushTableText -Text $Result -Width 22

    $worktreeColor = if ($Snapshot.DirtyCount -gt 0) {
        [ConsoleColor]::Yellow
    }
    elseif ($Snapshot.Worktree -eq "clean") {
        [ConsoleColor]::Green
    }
    else {
        [ConsoleColor]::DarkGray
    }

    $syncColor = if (-not $Snapshot.Valid -or -not $Snapshot.FetchOk -or $Snapshot.Detached) {
        [ConsoleColor]::Red
    }
    elseif ($Snapshot.Sync -eq "Up to date") {
        [ConsoleColor]::Green
    }
    elseif ($Snapshot.Ahead -gt 0 -and $Snapshot.Behind -gt 0) {
        [ConsoleColor]::Red
    }
    elseif ($Snapshot.Sync -eq "No remote") {
        [ConsoleColor]::DarkGray
    }
    else {
        [ConsoleColor]::Yellow
    }

    $resultColor = if ($Result -match '^OK|^SYNCED|^PUSHED|^CREATED') {
        [ConsoleColor]::Green
    }
    elseif ($Result -match '^FAIL|^ERROR') {
        [ConsoleColor]::Red
    }
    elseif ($Result -match '^SKIP|^MANUAL|^PROTECTED') {
        [ConsoleColor]::Yellow
    }
    else {
        [ConsoleColor]::DarkGray
    }

    Write-Host ("  {0,-24} {1,-24} " -f $repoText, $branchText) -NoNewline -ForegroundColor White
    Write-Host ("{0,-12} " -f $worktreeText) -NoNewline -ForegroundColor $worktreeColor
    Write-Host ("{0,-23} " -f $syncText) -NoNewline -ForegroundColor $syncColor
    Write-Host $resultText -ForegroundColor $resultColor
}

function Invoke-GPushAllSync {
    param(
        [Parameter(Mandatory = $true)]
        $Repository,
        [switch]$AllowProtectedBranches
    )

    $state = Get-GPushRepositorySnapshot -Repository $Repository -Fetch

    if (-not $state.Valid) {
        return [PSCustomObject]@{ Snapshot = $state; Result = "FAIL invalid repo" }
    }

    if (-not $state.FetchOk) {
        return [PSCustomObject]@{ Snapshot = $state; Result = "FAIL fetch" }
    }

    if ($state.Detached) {
        return [PSCustomObject]@{ Snapshot = $state; Result = "SKIP detached" }
    }

    if ($state.Remote -eq "-") {
        return [PSCustomObject]@{ Snapshot = $state; Result = "SKIP no remote" }
    }

    if ($state.DirtyCount -gt 0) {
        return [PSCustomObject]@{ Snapshot = $state; Result = "SKIP dirty" }
    }

    if ($state.Ahead -gt 0 -and $state.Behind -gt 0) {
        return [PSCustomObject]@{ Snapshot = $state; Result = "MANUAL diverged" }
    }

    $requiresPush = (
        $state.Ahead -gt 0 -or
        $state.Sync -eq "New remote branch"
    )

    if ($requiresPush -and
        (Test-ProtectedBranch -Branch $state.Branch) -and
        -not $AllowProtectedBranches) {
        return [PSCustomObject]@{ Snapshot = $state; Result = "PROTECTED skip" }
    }

    Push-Location $Repository.Path
    try {
        if ($state.Behind -gt 0 -and $state.Ahead -eq 0) {
            $ffResult = Get-GitOutput -Arguments @("merge", "--ff-only", $state.CompareRef) -AllowFailure
            if (-not $ffResult.Success) {
                $failed = Get-GPushRepositorySnapshot -Repository $Repository
                return [PSCustomObject]@{ Snapshot = $failed; Result = "FAIL fast-forward" }
            }

            $updated = Get-GPushRepositorySnapshot -Repository $Repository
            return [PSCustomObject]@{ Snapshot = $updated; Result = "SYNCED ff-only" }
        }

        if ($state.Sync -eq "New remote branch") {
            $pushResult = Get-GitOutput -Arguments @(
                "push", "-u", $state.Remote, $state.Branch
            ) -AllowFailure

            if (-not $pushResult.Success) {
                $failed = Get-GPushRepositorySnapshot -Repository $Repository
                return [PSCustomObject]@{ Snapshot = $failed; Result = "FAIL push" }
            }

            $updated = Get-GPushRepositorySnapshot -Repository $Repository
            return [PSCustomObject]@{ Snapshot = $updated; Result = "CREATED upstream" }
        }

        if ($state.Ahead -gt 0 -and $state.Behind -eq 0) {
            $hasTracking = ($state.Upstream -ne "-" -and $state.Upstream -notmatch '\(not tracking\)$')
            $pushArgs = if ($hasTracking) {
                @("push")
            }
            else {
                @("push", "-u", $state.Remote, $state.Branch)
            }

            $pushResult = Get-GitOutput -Arguments $pushArgs -AllowFailure
            if (-not $pushResult.Success) {
                $failed = Get-GPushRepositorySnapshot -Repository $Repository
                return [PSCustomObject]@{ Snapshot = $failed; Result = "FAIL push" }
            }

            $updated = Get-GPushRepositorySnapshot -Repository $Repository
            return [PSCustomObject]@{ Snapshot = $updated; Result = "PUSHED" }
        }

        return [PSCustomObject]@{ Snapshot = $state; Result = "OK no change" }
    }
    finally {
        Pop-Location
    }
}

function Show-GPushAllRepositories {
    param(
        [Parameter(Mandatory = $true)]
        $Repositories,
        [ValidateSet("status", "fetch", "sync")]
        [string]$Mode = "status",
        [switch]$AllowProtectedBranches
    )

    Write-Section "All repositories"

    if ($Mode -eq "status") {
        Write-Dim "  Dashboard uses local/cached remote refs. Use 'gp --all --fetch' for fresh remote state."
    }
    elseif ($Mode -eq "fetch") {
        Write-Dim "  Fetching every repository before displaying status."
    }
    else {
        Write-Warn "  Safe bulk sync: dirty/diverged repositories are skipped; no automatic rebase is performed."
    }

    Write-Host ""
    Write-Host ("  {0,-24} {1,-24} {2,-12} {3,-23} {4}" -f "Repository", "Branch", "Worktree", "Sync", "Result") -ForegroundColor DarkGray
    Write-Host ("  {0}" -f ("-" * 112)) -ForegroundColor DarkGray

    $total = 0
    $clean = 0
    $dirty = 0
    $issues = 0
    $changed = 0

    foreach ($repository in @($Repositories | Sort-Object Name, Path)) {
        $total++

        if ($Mode -eq "sync") {
            $syncResult = Invoke-GPushAllSync -Repository $repository -AllowProtectedBranches:$AllowProtectedBranches
            $state = $syncResult.Snapshot
            $result = $syncResult.Result

            if ($result -match '^SYNCED|^PUSHED|^CREATED') {
                $changed++
            }

            if ($result -match '^FAIL|^SKIP|^MANUAL|^PROTECTED') {
                $issues++
            }
        }
        else {
            $state = Get-GPushRepositorySnapshot -Repository $repository -Fetch:($Mode -eq "fetch")
            $result = if ($Mode -eq "fetch") {
                if ($state.FetchOk) { "OK fetched" } else { "FAIL fetch" }
            }
            else {
                ""
            }

            if (-not $state.Valid -or -not $state.FetchOk -or $state.Detached -or
                $state.Sync -eq "No remote" -or
                ($state.Ahead -gt 0 -and $state.Behind -gt 0)) {
                $issues++
            }
        }

        if ($state.DirtyCount -gt 0) {
            $dirty++
        }
        elseif ($state.Worktree -eq "clean") {
            $clean++
        }

        Write-GPushAllRow -Snapshot $state -Result $result
    }

    Write-Separator
    Write-KeyValue "Repositories" ([string]$total)
    Write-KeyValue "Clean" ([string]$clean) ([ConsoleColor]::Green)
    Write-KeyValue "Dirty" ([string]$dirty) $(if ($dirty -gt 0) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green })

    if ($Mode -eq "sync") {
        Write-KeyValue "Changed" ([string]$changed) $(if ($changed -gt 0) { [ConsoleColor]::Green } else { [ConsoleColor]::DarkGray })
    }

    Write-KeyValue "Attention" ([string]$issues) $(if ($issues -gt 0) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green })
    Write-Host ""
}


# ============================================================
# ALIASES / FAVORITES / RECENT
# ============================================================

if ($AliasesOnly) {
    Show-Banner
    Write-Section "Repository aliases"

    if ($RepositoryAliases.Count -eq 0) {
        Write-Dim "  No aliases configured."
    }
    else {
        foreach ($key in @($RepositoryAliases.Keys | Sort-Object)) {
            Write-Host ("  {0,-18}" -f $key) -NoNewline -ForegroundColor Green
            Write-Host $RepositoryAliases[$key] -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    exit 0
}

if ($AliasRemove) {
    Show-Banner
    Write-Section "Remove alias"

    $matchedKey = $null
    foreach ($key in $RepositoryAliases.Keys) {
        if ([string]::Equals([string]$key, $OperationArgument, [System.StringComparison]::OrdinalIgnoreCase)) {
            $matchedKey = [string]$key
            break
        }
    }

    if ($null -eq $matchedKey) {
        Write-Warn "Alias '$OperationArgument' does not exist."
        Write-Host ""
        exit 0
    }

    $RepositoryAliases.Remove($matchedKey)
    Save-GPushConfig
    Write-Ok "Alias '$matchedKey' removed."
    Write-Host ""
    exit 0
}

if ($FavoritesOnly) {
    Show-Banner
    Write-Section "Favorite repositories"

    if ($FavoriteRepositories.Count -eq 0) {
        Write-Dim "  No favorite repositories."
    }
    else {
        foreach ($favorite in $FavoriteRepositories) {
            Write-Host "  $favorite" -ForegroundColor Green
        }
    }

    Write-Host ""
    exit 0
}

if ($RecentOnly) {
    Show-Banner
    Write-Section "Recent repositories"

    $recent = @(Get-GPushRecentRepositories)
    if ($recent.Count -eq 0) {
        Write-Dim "  No recent repositories yet."
    }
    else {
        foreach ($item in $recent) {
            Write-Host ("  {0,-28}" -f $item.Name) -NoNewline -ForegroundColor White
            Write-Host $item.Path -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    exit 0
}


# ============================================================
# CLONE
# ============================================================

function Get-GPushCloneRepositoryName {
    param([string]$Url)

    $value = $Url.Trim().TrimEnd('/', '\')
    $lastPart = $value -replace '^.*[/:]', ''
    $lastPart = $lastPart -replace '\.git$', ''

    if ([string]::IsNullOrWhiteSpace($lastPart)) {
        return "repository"
    }

    return $lastPart
}

if ($CloneRepo) {
    Show-Banner

    if (-not (Test-GitCommand)) {
        Write-Err "Git was not found in PATH."
        exit 1
    }

    $cloneUrl = $OperationArgument.Trim()
    if ([string]::IsNullOrWhiteSpace($cloneUrl)) {
        Write-Err "Clone URL cannot be empty."
        exit 2
    }

    if (-not [string]::IsNullOrWhiteSpace($OperationArgument2)) {
        $cloneDestination = Expand-GPushPath -Path $OperationArgument2

        if (-not [System.IO.Path]::IsPathRooted($cloneDestination)) {
            $cloneDestination = Join-Path (Get-Location).Path $cloneDestination
        }
    }
    else {
        $cloneRoot = @($SearchRoots | Where-Object { Test-Path $_ } | Select-Object -First 1)

        if ($cloneRoot.Count -eq 0) {
            Write-Err "No configured search root exists."
            Write-Warn "Create one or specify an explicit destination path."
            exit 1
        }

        $repoFolderName = Get-GPushCloneRepositoryName -Url $cloneUrl
        $cloneDestination = Join-Path $cloneRoot[0] $repoFolderName
    }

    $cloneDestination = [System.IO.Path]::GetFullPath($cloneDestination)

    if (Test-Path $cloneDestination) {
        Write-Err "Clone destination already exists: $cloneDestination"
        exit 1
    }

    $cloneParent = Split-Path $cloneDestination -Parent
    if (-not (Test-Path $cloneParent)) {
        try {
            New-Item -ItemType Directory -Path $cloneParent -Force | Out-Null
        }
        catch {
            Write-Err "Could not create clone destination parent: $cloneParent"
            exit 1
        }
    }

    Write-Section "Clone"
    Write-KeyValue "URL" $cloneUrl ([ConsoleColor]::DarkGray)
    Write-KeyValue "Destination" $cloneDestination
    Write-Host ""
    Write-Info "[CLONE] git clone $cloneUrl `"$cloneDestination`""

    $cloneResult = Get-GitOutput -Arguments @("clone", $cloneUrl, $cloneDestination) -AllowFailure
    foreach ($line in $cloneResult.Lines) {
        Write-Host $line
    }

    if (-not $cloneResult.Success) {
        Write-Err "[CLONE] FAILED"
        exit 1
    }

    if (-not (Test-Path (Join-Path $cloneDestination ".git"))) {
        Write-Err "Clone completed but the destination is not a normal Git working tree."
        exit 1
    }

    $clonedRepo = [PSCustomObject]@{
        Name = Split-Path $cloneDestination -Leaf
        Path = $cloneDestination
    }

    Add-RepositoryToCache -Path $cloneDestination | Out-Null
    Save-GPushRecentRepository -Repository $clonedRepo

    Write-Ok "[CLONE] OK"
    Write-KeyValue "Repository" $clonedRepo.Name
    Write-KeyValue "Path" $clonedRepo.Path ([ConsoleColor]::DarkGray)
    Write-Host ""
    exit 0
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
    $StatusOnly -or
    $DiffOnly -or
    $Renormalize -or
    $FetchOnly -or
    $LogOnly -or
    $TagsOnly -or
    $BranchesOnly -or
    $RemotesOnly -or
    $PullOnly -or
    $SyncOnly -or
    $StashOnly -or
    $StashPopOnly -or
    $StashListOnly -or
    $OpenRepo -or
    $PruneBranchesOnly
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

if ($AllRepos) {
    $allMode = if ($SyncOnly) {
        "sync"
    }
    elseif ($FetchOnly) {
        "fetch"
    }
    else {
        "status"
    }

    Show-GPushAllRepositories `
        -Repositories $repos `
        -Mode $allMode `
        -AllowProtectedBranches:$AllowProtected

    exit 0
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

if ($AliasSet) {
    $aliasName = $OperationArgument.Trim()

    if ($aliasName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        Write-Err "Alias may only contain letters, numbers, '.', '_' and '-'."
        exit 2
    }

    $reservedOptions = @(
        "help", "version", "list", "refresh", "add", "cached", "config", "doctor",
        "all", "status", "diff", "fetch", "log", "branches", "remotes", "pull",
        "sync", "stash", "amend", "undo", "open", "recent", "favorites", "aliases"
    )

    if ($reservedOptions -contains $aliasName.ToLowerInvariant()) {
        Write-Err "Alias '$aliasName' conflicts with a GPush command name."
        exit 2
    }

    $RepositoryAliases[$aliasName] = [string]$repo.Path
    Save-GPushConfig

    Write-Section "Alias"
    Write-KeyValue "Alias" $aliasName ([ConsoleColor]::Green)
    Write-KeyValue "Repository" $repo.Name
    Write-KeyValue "Path" $repo.Path ([ConsoleColor]::DarkGray)
    Write-Host ""
    exit 0
}

if ($FavoriteAdd) {
    if ($FavoriteRepositories -notcontains $repo.Path) {
        $script:FavoriteRepositories = @(
            @($FavoriteRepositories + [string]$repo.Path) |
                Sort-Object -Unique
        )
        Save-GPushConfig
        Write-Ok "Repository '$($repo.Name)' added to favorites."
    }
    else {
        Write-Dim "Repository '$($repo.Name)' is already a favorite."
    }

    Write-Host ""
    exit 0
}

if ($FavoriteRemove) {
    $beforeCount = $FavoriteRepositories.Count
    $script:FavoriteRepositories = @(
        $FavoriteRepositories |
            Where-Object {
                -not [string]::Equals([string]$_, [string]$repo.Path, [System.StringComparison]::OrdinalIgnoreCase)
            }
    )

    if ($FavoriteRepositories.Count -lt $beforeCount) {
        Save-GPushConfig
        Write-Ok "Repository '$($repo.Name)' removed from favorites."
    }
    else {
        Write-Dim "Repository '$($repo.Name)' was not in favorites."
    }

    Write-Host ""
    exit 0
}

if ($OpenRepo) {
    Save-GPushRecentRepository -Repository $repo

    Write-Section "Open repository"
    Write-KeyValue "Repository" $repo.Name
    Write-KeyValue "Path" $repo.Path ([ConsoleColor]::DarkGray)

    try {
        Start-Process explorer.exe -ArgumentList @($repo.Path) -ErrorAction Stop
        Write-Ok "Opened in File Explorer."
        Write-Host ""
        exit 0
    }
    catch {
        Write-Err "Could not open File Explorer."
        Write-Dim $_.Exception.Message
        Write-Host ""
        exit 1
    }
}

Save-GPushRecentRepository -Repository $repo


# ============================================================
# REMOTE MANAGEMENT
# ============================================================

if ($RemoteAddOnly) {
    Write-Section "Add remote"

    $remoteName = $OperationArgument.Trim()
    $remoteUrlToAdd = $OperationArgument2.Trim()

    if ($remoteName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        Write-Err "Invalid remote name: $remoteName"
        exit 2
    }

    $existing = @((& git remote) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($existing -contains $remoteName) {
        Write-Err "Remote '$remoteName' already exists."
        Write-Dim "Use --remote-set-url to change its URL."
        exit 1
    }

    Write-Info "[REMOTE] git remote add $remoteName $remoteUrlToAdd"
    $result = Get-GitOutput -Arguments @("remote", "add", $remoteName, $remoteUrlToAdd) -AllowFailure

    if (-not $result.Success) {
        Write-Err "[REMOTE] FAILED"
        foreach ($line in $result.Lines) { Write-Dim "  $line" }
        exit 1
    }

    Write-Ok "[REMOTE] OK"
    Write-KeyValue "Remote" $remoteName
    Write-KeyValue "URL" $remoteUrlToAdd ([ConsoleColor]::DarkGray)
    Write-Host ""
    exit 0
}

if ($RemoteSetUrlOnly) {
    Write-Section "Set remote URL"

    $remoteName = $OperationArgument.Trim()
    $newRemoteUrl = $OperationArgument2.Trim()

    $existing = @((& git remote) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($existing -notcontains $remoteName) {
        Write-Err "Remote '$remoteName' does not exist."
        exit 1
    }

    $oldUrlResult = Get-GitOutput -Arguments @("remote", "get-url", $remoteName) -AllowFailure
    $oldUrl = if ($oldUrlResult.Success) { $oldUrlResult.Text.Trim() } else { "-" }

    Write-KeyValue "Remote" $remoteName
    Write-KeyValue "Old URL" $oldUrl ([ConsoleColor]::DarkGray)
    Write-KeyValue "New URL" $newRemoteUrl
    Write-Host ""

    if (-not (Confirm-GPushAction -Prompt "Change the URL of remote '$remoteName'?")) {
        Write-Warn "Remote URL change cancelled."
        exit 0
    }

    $result = Get-GitOutput -Arguments @("remote", "set-url", $remoteName, $newRemoteUrl) -AllowFailure
    if (-not $result.Success) {
        Write-Err "[REMOTE] FAILED"
        foreach ($line in $result.Lines) { Write-Dim "  $line" }
        exit 1
    }

    Write-Ok "[REMOTE] OK"
    Write-Host ""
    exit 0
}

if ($RemoteRemoveOnly) {
    Write-Section "Remove remote"

    $remoteName = $OperationArgument.Trim()
    $existing = @((& git remote) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($existing -notcontains $remoteName) {
        Write-Warn "Remote '$remoteName' does not exist."
        Write-Host ""
        exit 0
    }

    $urlResult = Get-GitOutput -Arguments @("remote", "get-url", $remoteName) -AllowFailure
    $remoteUrlToRemove = if ($urlResult.Success) { $urlResult.Text.Trim() } else { "-" }

    Write-KeyValue "Remote" $remoteName
    Write-KeyValue "URL" $remoteUrlToRemove ([ConsoleColor]::DarkGray)
    Write-Host ""

    if (-not (Confirm-GPushAction -Prompt "Remove remote '$remoteName'?")) {
        Write-Warn "Remote removal cancelled."
        exit 0
    }

    $result = Get-GitOutput -Arguments @("remote", "remove", $remoteName) -AllowFailure
    if (-not $result.Success) {
        Write-Err "[REMOTE] FAILED"
        foreach ($line in $result.Lines) { Write-Dim "  $line" }
        exit 1
    }

    Write-Ok "[REMOTE] OK"
    Write-Host ""
    exit 0
}

# ============================================================
# UTILITY MODES
# ============================================================

if ($Renormalize) {
    Write-Section "Renormalize"

    # If tracked files were moved/deleted without updating the index,
    # git add --renormalize can fail with "unable to stat".
    $missingResult = Get-GitOutput -Arguments @("ls-files", "--deleted") -AllowFailure
    $missingTracked = @(
        $missingResult.Lines |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($missingTracked.Count -gt 0) {
        Write-Warn "Tracked files are missing from the working tree:"

        foreach ($path in $missingTracked) {
            Write-Host "  $path" -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Dim "The Git index is out of sync with file moves/deletions."
        Write-Dim "Stage those changes first, then run renormalize again:"
        Write-Host ""
        Write-Host "  git add -A" -ForegroundColor Green
        Write-Host "  gp --renormalize" -ForegroundColor Green
        Write-Host ""
        Write-Warn "GPush did not stage anything automatically."
        exit 1
    }

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
    $status = @(
        $statusResult.Lines |
            Where-Object { $_ -ne $null }
    )

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

    $remote = if ($PreferredRemote -and $remotes -contains $PreferredRemote) { $PreferredRemote } elseif ($remotes -contains "origin") { "origin" } else { $remotes[0].Trim() }

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
    Write-Section "Git graph"
    & git log -20 --graph --decorate --oneline --all
    Write-Host ""
    exit $LASTEXITCODE
}

if ($TagsOnly) {
    Write-Section "Tags"

    $tagResult = Get-GitOutput -Arguments @(
        "tag", "--sort=-creatordate", "--format=%(refname:short)|%(creatordate:short)|%(subject)"
    ) -AllowFailure

    if (-not $tagResult.Success) {
        Write-Err "Could not read repository tags."
        exit 1
    }

    $tagLines = @($tagResult.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($tagLines.Count -eq 0) {
        Write-Dim "  No tags."
    }
    else {
        Write-Host ("  {0,-22} {1,-12} {2}" -f "Tag", "Date", "Message") -ForegroundColor DarkGray
        foreach ($line in $tagLines) {
            $parts = [string]$line -split '\|', 3
            $tagName = if ($parts.Count -gt 0) { $parts[0] } else { "-" }
            $tagDate = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { "-" }
            $tagSubject = if ($parts.Count -gt 2 -and $parts[2]) { $parts[2] } else { "-" }
            Write-Host ("  {0,-22} {1,-12} " -f $tagName, $tagDate) -NoNewline -ForegroundColor White
            Write-Host $tagSubject -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    exit 0
}

if ($TagCreateOnly -or $TagPushOnly -or $TagDeleteOnly -or $ReleaseOnly) {
    $tagName = [string]$OperationArgument

    if ([string]::IsNullOrWhiteSpace($tagName)) {
        Write-Err "Tag name cannot be empty."
        exit 2
    }

    $validTag = Get-GitOutput -Arguments @("check-ref-format", "refs/tags/$tagName") -AllowFailure
    if (-not $validTag.Success) {
        Write-Err "Invalid Git tag name: $tagName"
        exit 2
    }

    $localTagExists = Test-GitRef -Ref "refs/tags/$tagName"

    $tagRemotes = @((& git remote) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $tagRemote = if ($PreferredRemote -and $tagRemotes -contains $PreferredRemote) {
        $PreferredRemote
    }
    elseif ($tagRemotes -contains "origin") {
        "origin"
    }
    elseif ($tagRemotes.Count -gt 0) {
        $tagRemotes[0].Trim()
    }
    else {
        $null
    }

    if ($TagCreateOnly) {
        Write-Section "Create tag"

        if ($localTagExists) {
            Write-Err "Tag '$tagName' already exists locally."
            exit 1
        }

        $tagMessage = ($CommitMessageParts -join " ").Trim()
        if ([string]::IsNullOrWhiteSpace($tagMessage)) {
            $tagMessage = "Release $tagName"
        }

        Write-KeyValue "Tag" $tagName ([ConsoleColor]::Magenta)
        Write-KeyValue "Commit" (Get-CommitShortHash) ([ConsoleColor]::DarkGray)
        Write-KeyValue "Message" $tagMessage
        Write-Host ""
        Write-Info "[TAG] git tag -a $tagName -m <message>"

        $result = Get-GitOutput -Arguments @("tag", "-a", $tagName, "-m", $tagMessage) -AllowFailure
        if (-not $result.Success) {
            Write-Err "[TAG] FAILED"
            foreach ($line in $result.Lines) { Write-Dim "  $line" }
            exit 1
        }

        Write-Ok "[TAG] OK"
        Write-Warn "Tag is local only. Push it with: gp --tag-push $($repo.Name) $tagName"
        Write-Host ""
        exit 0
    }

    if ($TagDeleteOnly) {
        Write-Section "Delete local tag"

        if (-not $localTagExists) {
            Write-Warn "Local tag '$tagName' does not exist."
            Write-Host ""
            exit 0
        }

        $remoteHasTag = $false
        if ($tagRemote) {
            $remoteCheck = Get-GitOutput -Arguments @("ls-remote", "--tags", $tagRemote, "refs/tags/$tagName") -AllowFailure
            $remoteHasTag = ($remoteCheck.Success -and -not [string]::IsNullOrWhiteSpace($remoteCheck.Text))
        }

        if ($remoteHasTag) {
            Write-Warn "Tag '$tagName' also exists on remote '$tagRemote'."
            Write-Dim "GPush will delete only the local tag. The remote tag will remain unchanged."
        }

        if (-not (Confirm-GPushAction -Prompt "Delete local tag '$tagName'?")) {
            Write-Warn "Tag deletion cancelled."
            exit 0
        }

        $deleteResult = Get-GitOutput -Arguments @("tag", "-d", $tagName) -AllowFailure
        foreach ($line in $deleteResult.Lines) { Write-Host $line }
        if (-not $deleteResult.Success) {
            Write-Err "[TAG DELETE] FAILED"
            exit 1
        }

        Write-Ok "[TAG DELETE] OK"
        Write-Host ""
        exit 0
    }

    if ($TagPushOnly) {
        Write-Section "Push tag"

        if (-not $localTagExists) {
            Write-Err "Local tag '$tagName' does not exist."
            exit 1
        }

        if (-not $tagRemote) {
            Write-Err "No Git remote is configured."
            exit 1
        }

        $remoteCheck = Get-GitOutput -Arguments @("ls-remote", "--tags", $tagRemote, "refs/tags/$tagName") -AllowFailure
        if ($remoteCheck.Success -and -not [string]::IsNullOrWhiteSpace($remoteCheck.Text)) {
            Write-Ok "Tag '$tagName' already exists on '$tagRemote'."
            Write-Host ""
            exit 0
        }

        Write-Info "[TAG PUSH] git push $tagRemote refs/tags/$tagName"
        $pushTag = Get-GitOutput -Arguments @("push", $tagRemote, "refs/tags/$tagName") -AllowFailure
        foreach ($line in $pushTag.Lines) { Write-Host $line }
        if (-not $pushTag.Success) {
            Write-Err "[TAG PUSH] FAILED"
            exit 1
        }

        Write-Ok "[TAG PUSH] OK"
        Write-Host ""
        exit 0
    }

    if ($ReleaseOnly) {
        Write-Section "Release"

        if (-not $tagRemote) {
            Write-Err "No Git remote is configured."
            exit 1
        }

        $releaseStatus = Get-GitOutput -Arguments @("status", "--short") -AllowFailure
        $releaseChanges = @($releaseStatus.Lines | Where-Object { $_ -ne $null })
        if (-not $releaseStatus.Success -or $releaseChanges.Count -gt 0) {
            Write-Err "Release requires a clean working tree."
            Write-Dim "Commit or stash local changes first."
            exit 1
        }

        $releaseBranchResult = Get-GitOutput -Arguments @("symbolic-ref", "--quiet", "--short", "HEAD") -AllowFailure
        if (-not $releaseBranchResult.Success -or [string]::IsNullOrWhiteSpace($releaseBranchResult.Text)) {
            Write-Err "Release cannot be created from detached HEAD."
            exit 1
        }
        $releaseBranch = $releaseBranchResult.Text.Trim()

        Write-Info "[FETCH] git fetch --prune $tagRemote"
        $releaseFetch = Get-GitOutput -Arguments @("fetch", "--prune", $tagRemote) -AllowFailure
        if (-not $releaseFetch.Success) {
            Write-Err "[FETCH] FAILED"
            foreach ($line in $releaseFetch.Lines) { Write-Dim "  $line" }
            exit 1
        }
        Write-Ok "[FETCH] OK"

        $releaseUpstreamResult = Get-GitOutput -Arguments @(
            "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"
        ) -AllowFailure

        $releaseCompareRef = $null
        if ($releaseUpstreamResult.Success -and -not [string]::IsNullOrWhiteSpace($releaseUpstreamResult.Text)) {
            $releaseCompareRef = $releaseUpstreamResult.Text.Trim()
        }
        elseif (Test-GitRef -Ref "refs/remotes/$tagRemote/$releaseBranch") {
            $releaseCompareRef = "$tagRemote/$releaseBranch"
        }

        if (-not $releaseCompareRef) {
            Write-Err "Release branch '$releaseBranch' has no remote branch to verify."
            Write-Dim "Push the branch and configure upstream before creating a release."
            exit 1
        }

        $releaseCounts = Get-GitOutput -Arguments @(
            "rev-list", "--left-right", "--count", "HEAD...$releaseCompareRef"
        ) -AllowFailure
        if (-not $releaseCounts.Success) {
            Write-Err "Could not compare HEAD with '$releaseCompareRef'."
            exit 1
        }

        $releaseParts = $releaseCounts.Text.Trim() -split '\s+'
        [int]$releaseAhead = $releaseParts[0]
        [int]$releaseBehind = $releaseParts[1]
        if ($releaseAhead -ne 0 -or $releaseBehind -ne 0) {
            Write-Err "Release requires HEAD and '$releaseCompareRef' to be exactly synchronized."
            Write-KeyValue "Ahead" ([string]$releaseAhead) $(if ($releaseAhead -eq 0) { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow })
            Write-KeyValue "Behind" ([string]$releaseBehind) $(if ($releaseBehind -eq 0) { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow })
            Write-Dim "Run gp --sync first, then retry the release."
            exit 1
        }

        if ($localTagExists) {
            Write-Err "Tag '$tagName' already exists locally."
            exit 1
        }

        $remoteTagCheck = Get-GitOutput -Arguments @("ls-remote", "--tags", $tagRemote, "refs/tags/$tagName") -AllowFailure
        if ($remoteTagCheck.Success -and -not [string]::IsNullOrWhiteSpace($remoteTagCheck.Text)) {
            Write-Err "Tag '$tagName' already exists on remote '$tagRemote'."
            exit 1
        }

        $releaseMessage = ($CommitMessageParts -join " ").Trim()
        if ([string]::IsNullOrWhiteSpace($releaseMessage)) {
            $releaseMessage = "Release $tagName"
        }

        Write-KeyValue "Repository" $repo.Name
        Write-KeyValue "Branch" $releaseBranch ([ConsoleColor]::Magenta)
        Write-KeyValue "Tag" $tagName ([ConsoleColor]::Magenta)
        Write-KeyValue "Commit" (Get-CommitShortHash) ([ConsoleColor]::DarkGray)
        Write-KeyValue "Remote" $tagRemote
        Write-KeyValue "Message" $releaseMessage
        Write-Host ""

        if (-not (Confirm-GPushAction -Prompt "Create and push release tag '$tagName'?")) {
            Write-Warn "Release cancelled."
            exit 0
        }

        Write-Info "[TAG] Creating annotated release tag"
        $createReleaseTag = Get-GitOutput -Arguments @("tag", "-a", $tagName, "-m", $releaseMessage) -AllowFailure
        if (-not $createReleaseTag.Success) {
            Write-Err "[TAG] FAILED"
            foreach ($line in $createReleaseTag.Lines) { Write-Dim "  $line" }
            exit 1
        }
        Write-Ok "[TAG] OK"

        Write-Info "[TAG PUSH] git push $tagRemote refs/tags/$tagName"
        $releasePush = Get-GitOutput -Arguments @("push", $tagRemote, "refs/tags/$tagName") -AllowFailure
        foreach ($line in $releasePush.Lines) { Write-Host $line }

        if (-not $releasePush.Success) {
            Write-Err "[TAG PUSH] FAILED"
            Write-Warn "Release tag push failed. Rolling back the local tag created by this command."
            Get-GitOutput -Arguments @("tag", "-d", $tagName) -AllowFailure | Out-Null
            exit 1
        }

        Write-Ok "[RELEASE] OK"
        Write-KeyValue "Tag" $tagName ([ConsoleColor]::Green)
        Write-KeyValue "Commit" (Get-CommitShortHash) ([ConsoleColor]::DarkGray)
        Write-Host ""
        exit 0
    }
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

    $remoteList = @((& git remote) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($remoteList.Count -eq 0) {
        Write-Dim "  No remotes configured."
        Write-Host ""
        exit 0
    }

    foreach ($remoteName in $remoteList) {
        $fetchUrl = Get-GitOutput -Arguments @("remote", "get-url", $remoteName) -AllowFailure
        $pushUrl = Get-GitOutput -Arguments @("remote", "get-url", "--push", $remoteName) -AllowFailure

        Write-Host ("  {0,-16}" -f $remoteName) -NoNewline -ForegroundColor White
        Write-Host $(if ($fetchUrl.Success) { $fetchUrl.Text.Trim() } else { "-" }) -ForegroundColor DarkGray

        if ($pushUrl.Success -and $fetchUrl.Success -and $pushUrl.Text.Trim() -ne $fetchUrl.Text.Trim()) {
            Write-Dim ("  {0,-16}{1}" -f "push", $pushUrl.Text.Trim())
        }
    }

    Write-Host ""
    exit 0
}

if ($PruneBranchesOnly) {
    Write-Section "Prune local branches"

    $statusCheck = Get-GitOutput -Arguments @("status", "--short") -AllowFailure
    if (-not $statusCheck.Success) {
        Write-Err "Could not read repository status."
        exit 1
    }

    if (@($statusCheck.Lines | Where-Object { $_ -ne $null }).Count -gt 0) {
        Write-Err "Branch pruning requires a clean working tree."
        Write-Warn "Commit or stash local changes first."
        exit 1
    }

    $currentResult = Get-GitOutput -Arguments @("branch", "--show-current") -AllowFailure
    $currentBranch = $currentResult.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($currentBranch)) {
        Write-Err "Cannot prune branches while HEAD is detached."
        exit 1
    }

    $remoteNames = @((& git remote) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($remoteNames.Count -gt 0) {
        $pruneRemote = if ($PreferredRemote -and $remoteNames -contains $PreferredRemote) {
            $PreferredRemote
        }
        elseif ($remoteNames -contains "origin") {
            "origin"
        }
        else {
            $remoteNames[0].Trim()
        }

        Write-Info "[FETCH] git fetch --prune $pruneRemote"
        $fetchPrune = Get-GitOutput -Arguments @("fetch", "--prune", $pruneRemote) -AllowFailure
        if (-not $fetchPrune.Success) {
            Write-Err "[FETCH] FAILED"
            foreach ($line in $fetchPrune.Lines) { Write-Dim "  $line" }
            exit 1
        }
        Write-Ok "[FETCH] OK"
    }
    else {
        Write-Warn "No remote configured; only already-known gone upstreams can be inspected."
    }

    $refsResult = Get-GitOutput -Arguments @(
        "for-each-ref",
        "--format=%(refname:short)|%(upstream:track)",
        "refs/heads"
    ) -AllowFailure

    if (-not $refsResult.Success) {
        Write-Err "Could not inspect local branches."
        exit 1
    }

    $candidates = @()
    $skippedProtected = @()
    $skippedUnmerged = @()

    foreach ($line in $refsResult.Lines) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line -notmatch '\|') {
            continue
        }

        $parts = $line -split '\|', 2
        $candidateBranch = $parts[0].Trim()
        $trackState = $parts[1].Trim()

        if ($trackState -notmatch '\[gone\]') {
            continue
        }

        if ($candidateBranch -eq $currentBranch) {
            continue
        }

        if ((Test-ProtectedBranch -Branch $candidateBranch) -and -not $AllowProtected) {
            $skippedProtected += $candidateBranch
            continue
        }

        $mergedCheck = Get-GitOutput -Arguments @(
            "merge-base", "--is-ancestor", $candidateBranch, "HEAD"
        ) -AllowFailure

        if (-not $mergedCheck.Success) {
            $skippedUnmerged += $candidateBranch
            continue
        }

        $candidates += $candidateBranch
    }

    $candidates = @($candidates | Sort-Object -Unique)

    if ($candidates.Count -eq 0) {
        Write-Ok "No safe stale local branches found."

        if ($skippedProtected.Count -gt 0) {
            Write-Warn "Protected stale branches skipped: $($skippedProtected -join ', ')"
        }

        if ($skippedUnmerged.Count -gt 0) {
            Write-Warn "Unmerged stale branches skipped: $($skippedUnmerged -join ', ')"
        }

        Write-Host ""
        exit 0
    }

    Write-Host ""
    Write-Host "  Safe deletion candidates:" -ForegroundColor White
    foreach ($candidate in $candidates) {
        Write-Host "    $candidate" -ForegroundColor Yellow
    }

    if ($skippedProtected.Count -gt 0) {
        Write-Host ""
        Write-Dim "  Protected skipped: $($skippedProtected -join ', ')"
    }

    if ($skippedUnmerged.Count -gt 0) {
        Write-Dim "  Unmerged skipped: $($skippedUnmerged -join ', ')"
    }

    Write-Host ""
    if (-not (Confirm-GPushAction -Prompt "Delete these $($candidates.Count) merged local branch(es)?")) {
        Write-Warn "Branch pruning cancelled."
        exit 0
    }

    $deleted = 0
    $failed = 0

    foreach ($candidate in $candidates) {
        Write-Info "[DELETE] git branch -d $candidate"
        $deleteResult = Get-GitOutput -Arguments @("branch", "-d", $candidate) -AllowFailure
        foreach ($line in $deleteResult.Lines) { Write-Host $line }

        if ($deleteResult.Success) {
            $deleted++
        }
        else {
            $failed++
            Write-Warn "Could not safely delete '$candidate'."
        }
    }

    Write-Separator
    Write-KeyValue "Deleted" ([string]$deleted) ([ConsoleColor]::Green)
    Write-KeyValue "Failed" ([string]$failed) $(if ($failed -gt 0) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green })
    Write-Host ""
    exit $(if ($failed -gt 0) { 1 } else { 0 })
}

if ($BranchNewOnly) {
    Write-Section "Create branch"

    if ([string]::IsNullOrWhiteSpace($OperationArgument)) {
        Write-Err "Branch name cannot be empty."
        exit 2
    }

    $exists = Get-GitOutput -Arguments @("show-ref", "--verify", "--quiet", "refs/heads/$OperationArgument") -AllowFailure
    if ($exists.Success) {
        Write-Err "Local branch '$OperationArgument' already exists."
        exit 1
    }

    Write-Info "[BRANCH] git switch -c $OperationArgument"
    $result = Get-GitOutput -Arguments @("switch", "-c", $OperationArgument) -AllowFailure
    foreach ($line in $result.Lines) { Write-Host $line }

    if (-not $result.Success) {
        Write-Err "[BRANCH] FAILED"
        exit 1
    }

    Write-Ok "[BRANCH] OK"
    Write-KeyValue "Branch" $OperationArgument ([ConsoleColor]::Magenta)
    Write-Host ""
    exit 0
}

if ($BranchSwitchOnly) {
    Write-Section "Switch branch"

    if ([string]::IsNullOrWhiteSpace($OperationArgument)) {
        Write-Err "Branch name cannot be empty."
        exit 2
    }

    Write-Info "[BRANCH] git switch $OperationArgument"
    $result = Get-GitOutput -Arguments @("switch", $OperationArgument) -AllowFailure
    foreach ($line in $result.Lines) { Write-Host $line }

    if (-not $result.Success) {
        Write-Err "[BRANCH] FAILED"
        Write-Warn "GPush did not discard or stash any local changes."
        exit 1
    }

    Write-Ok "[BRANCH] OK"
    Write-KeyValue "Branch" $OperationArgument ([ConsoleColor]::Magenta)
    Write-Host ""
    exit 0
}

if ($BranchDeleteOnly) {
    Write-Section "Delete branch"

    if ([string]::IsNullOrWhiteSpace($OperationArgument)) {
        Write-Err "Branch name cannot be empty."
        exit 2
    }

    if ((Test-ProtectedBranch -Branch $OperationArgument) -and -not $AllowProtected) {
        Write-Err "Branch '$OperationArgument' matches the protected branch list."
        Write-Warn "Use --allow-protected only when you intentionally want to delete it."
        exit 1
    }

    $currentResult = Get-GitOutput -Arguments @("branch", "--show-current") -AllowFailure
    $currentBranch = $currentResult.Text.Trim()
    if ($currentBranch -eq $OperationArgument) {
        Write-Err "Cannot delete the currently checked-out branch '$OperationArgument'."
        exit 1
    }

    # -d deliberately refuses to delete a branch that Git considers unmerged.
    Write-Info "[BRANCH] git branch -d $OperationArgument"
    $result = Get-GitOutput -Arguments @("branch", "-d", $OperationArgument) -AllowFailure
    foreach ($line in $result.Lines) { Write-Host $line }

    if (-not $result.Success) {
        Write-Err "[BRANCH] FAILED"
        Write-Warn "GPush only performs safe branch deletion; unmerged branches are never force-deleted."
        exit 1
    }

    Write-Ok "[BRANCH] OK"
    Write-Host ""
    exit 0
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
if ($PreferredRemote -and $remotes -contains $PreferredRemote) {
    $remote = $PreferredRemote
}
elseif ($remotes -contains "origin") {
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

if (-not $remote -and -not $NoPush -and -not $DryRun -and -not $DiffOnly -and -not $StatusOnly -and -not $PullOnly -and -not $StashOnly -and -not $StashPopOnly -and -not $StashListOnly) {
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
# STASH MODES
# ============================================================

if ($StashListOnly) {
    Write-Section "Stash"
    $result = Get-GitOutput -Arguments @("stash", "list") -AllowFailure
    if (-not $result.Success) {
        Write-Err "Could not read stash list."
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace($result.Text)) {
        Write-Dim "  No stash entries."
    }
    else {
        foreach ($line in $result.Lines) { Write-Host $line }
    }

    Write-Host ""
    exit 0
}

if ($StashOnly) {
    if ($status.Count -eq 0) {
        Write-Ok "Working tree is already clean; nothing to stash."
        Write-Host ""
        exit 0
    }

    Write-Section "Stash"
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $result = Get-GitOutput -Arguments @("stash", "push", "--include-untracked", "-m", "GPush stash $stamp") -AllowFailure
    foreach ($line in $result.Lines) { Write-Host $line }

    if (-not $result.Success) {
        Write-Err "[STASH] FAILED"
        exit 1
    }

    Write-Ok "[STASH] OK"
    Write-Host ""
    exit 0
}

if ($StashPopOnly) {
    Write-Section "Stash pop"
    $result = Get-GitOutput -Arguments @("stash", "pop") -AllowFailure
    foreach ($line in $result.Lines) { Write-Host $line }

    if (-not $result.Success) {
        Write-Err "[STASH POP] FAILED"
        Write-Warn "Resolve any stash conflicts manually. Git preserves the stash when pop cannot complete cleanly."
        exit 1
    }

    Write-Ok "[STASH POP] OK"
    Write-Host ""
    exit 0
}

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

if ($UndoOnly) {
    Write-Section "Undo last commit"

    if ((Test-ProtectedBranch -Branch $branch) -and -not $AllowProtected) {
        Write-Warn "Branch '$branch' matches the protected branch list."
        if (-not (Confirm-GPushAction -Prompt "Rewrite the latest LOCAL commit on '$branch'?")) {
            Write-Warn "Undo cancelled."
            exit 0
        }
    }

    $headParent = Get-GitOutput -Arguments @("rev-parse", "HEAD^") -AllowFailure
    if (-not $headParent.Success) {
        Write-Err "The current branch has no parent commit to reset to."
        exit 1
    }

    # Never rewrite a commit that is already reachable from the configured upstream.
    if ($compareRef) {
        $pushedCheck = Get-GitOutput -Arguments @("merge-base", "--is-ancestor", "HEAD", $compareRef) -AllowFailure
        if ($pushedCheck.Success) {
            Write-Err "The latest commit is already present on '$compareRef'."
            Write-Warn "GPush will not undo a commit that appears to have been pushed."
            exit 1
        }
    }
    elseif ($remote -and $remoteBranchExists) {
        Write-Err "Remote state could not be compared safely."
        Write-Warn "GPush will not undo the commit without proving that it is local-only."
        exit 1
    }

    $undoHash = Get-CommitShortHash
    $undoSubject = Get-CommitSubject
    Write-KeyValue "Commit" $undoHash ([ConsoleColor]::DarkGray)
    Write-KeyValue "Message" $undoSubject
    Write-Host ""
    $answer = Read-Host "Undo this LOCAL commit and keep its changes staged? [y/N]"
    if ($answer -notmatch '^(?i:y|yes)$') {
        Write-Warn "Undo cancelled."
        exit 0
    }

    $result = Get-GitOutput -Arguments @("reset", "--soft", "HEAD~1") -AllowFailure
    if (-not $result.Success) {
        Write-Err "[UNDO] FAILED"
        foreach ($line in $result.Lines) { Write-Dim "  $line" }
        exit 1
    }

    Write-Ok "[UNDO] OK"
    Write-Dim "Changes from $undoHash remain staged."
    Write-Host ""
    exit 0
}

if ($AmendOnly) {
    Write-Section "Amend commit"

    if ((Test-ProtectedBranch -Branch $branch) -and -not $AllowProtected) {
        Write-Warn "Branch '$branch' matches the protected branch list."
        if (-not (Confirm-GPushAction -Prompt "Amend the latest LOCAL commit on '$branch'?")) {
            Write-Warn "Amend cancelled."
            exit 0
        }
    }

    # Amending rewrites HEAD. Refuse when HEAD is already reachable from upstream.
    if ($compareRef) {
        $pushedCheck = Get-GitOutput -Arguments @("merge-base", "--is-ancestor", "HEAD", $compareRef) -AllowFailure
        if ($pushedCheck.Success) {
            Write-Err "The latest commit is already present on '$compareRef'."
            Write-Warn "GPush will not amend a commit that appears to have been pushed."
            exit 1
        }
    }

    if ($status.Count -gt 0 -and -not $AllowRiskyFiles) {
        if (-not (Confirm-RiskyFiles)) {
            exit 1
        }
    }

    if ($status.Count -gt 0) {
        Write-Info "[ADD] git add ."
        $addResult = Get-GitOutput -Arguments @("add", ".") -AllowFailure
        if (-not $addResult.Success) {
            Write-Err "[ADD] FAILED"
            foreach ($line in $addResult.Lines) { Write-Dim "  $line" }
            exit 1
        }
        Write-Ok "[ADD] OK"
    }

    $amendMessage = ($CommitMessageParts -join " ").Trim()
    if ([string]::IsNullOrWhiteSpace($amendMessage)) {
        $amendArgs = @("commit", "--amend", "--no-edit")
        Write-Info "[AMEND] Keeping existing commit message"
    }
    else {
        $amendArgs = @("commit", "--amend", "-m", $amendMessage)
        Write-Info "[AMEND] $amendMessage"
    }

    $result = Get-GitOutput -Arguments $amendArgs -AllowFailure
    foreach ($line in $result.Lines) { Write-Host $line }
    if (-not $result.Success) {
        Write-Err "[AMEND] FAILED"
        exit 1
    }

    Write-Ok "[AMEND] OK ($(Get-CommitShortHash))"
    Write-Host ""
    exit 0
}

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

    $pullAutoStashCreated = $false

    if ($status.Count -gt 0) {
        if (-not $AutoStash) {
            Write-Err "Pull-only mode requires a clean working tree."
            Write-Warn "Commit/stash the local changes first, or add --autostash."
            exit 1
        }

        if (-not (New-GPushAutoStash -Reason "pull")) {
            exit 1
        }

        $pullAutoStashCreated = $true
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

        if ($pullAutoStashCreated) {
            Write-Warn "Autostashed changes were not restored because the pull did not finish cleanly."
            Write-Dim "After resolving/aborting the rebase, restore them with: git stash pop"
        }

        exit 1
    }

    Write-Host ""
    Write-Ok "[PULL] OK"

    if ($pullAutoStashCreated) {
        if (-not (Restore-GPushAutoStash)) {
            exit 1
        }
    }

    Write-Separator
    Write-Ok "Complete."
    Write-Host ""
    exit 0
}

# ============================================================
# SYNC PREPARATION
# ============================================================

$syncAutoStashCreated = $false

if ($SyncOnly -and $status.Count -gt 0) {
    if (-not $AutoStash) {
        Write-Err "Sync mode requires a clean working tree."
        Write-Warn "Commit/stash the local changes first, or add --autostash."
        exit 1
    }

    if (-not (New-GPushAutoStash -Reason "sync")) {
        exit 1
    }

    $syncAutoStashCreated = $true
}

# ============================================================
# PROTECTED BRANCH GUARD
# ============================================================

$protectedActionNeeded = $false

if ($SyncOnly) {
    $protectedActionNeeded = ($ahead -gt 0 -or ($remote -and -not $remoteBranchExists))
}
else {
    $protectedActionNeeded = ($status.Count -gt 0 -or $ahead -gt 0 -or ($remote -and -not $remoteBranchExists))
}

if ($protectedActionNeeded -and (Test-ProtectedBranch -Branch $branch) -and -not $AllowProtected -and -not $DryRun) {
    Write-Section "Protected branch"
    Write-Warn "Branch '$branch' matches the protected branch list."
    Write-Dim "Protected patterns: $($ProtectedBranches -join ', ')"

    if (-not (Confirm-GPushActionDefaultYes -Prompt "Continue with a direct commit/push on '$branch'?")) {
        Write-Warn "Operation cancelled."

        if ($syncAutoStashCreated) {
            if (-not (Restore-GPushAutoStash)) {
                exit 1
            }
        }

        exit 1
    }
}

# ============================================================
# COMMIT MESSAGE
# ============================================================

$commitMessage = ""

if ($CommitMessageParts.Count -gt 0) {
    $commitMessage = $CommitMessageParts -join " "
}

if (-not $SyncOnly -and $status.Count -gt 0 -and [string]::IsNullOrWhiteSpace($commitMessage) -and -not $DryRun) {
    Write-Host ""
    $commitMessage = Read-Host "Commit message"
}

if (-not $SyncOnly -and $status.Count -gt 0 -and [string]::IsNullOrWhiteSpace($commitMessage) -and -not $DryRun) {
    Write-Err "Commit message cannot be empty."
    exit 1
}

# ============================================================
# DRY RUN
# ============================================================

if ($DryRun) {
    Write-Section "Dry run"
    Write-Warn "No Git state will be changed."

    if ($status.Count -gt 0 -and -not $AllowRiskyFiles) {
        Confirm-RiskyFiles -PreviewOnly | Out-Null
    }

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

if ($status.Count -gt 0 -and -not $SyncOnly) {
    if (-not $AllowRiskyFiles) {
        if (-not (Confirm-RiskyFiles)) {
            Write-Warn "Commit cancelled before staging."
            exit 1
        }
    }

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
        Write-SyncAutoStashRecoveryHint
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
            Write-SyncAutoStashRecoveryHint
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
                Write-SyncAutoStashRecoveryHint
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
            Write-SyncAutoStashRecoveryHint
            exit 1
        }

        $pushResult = $retryPush
    }
    else {
        Write-Err "Push failed for a reason that GPush will not try to repair automatically."
        Write-SyncAutoStashRecoveryHint
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

if ($syncAutoStashCreated) {
    if (-not (Restore-GPushAutoStash)) {
        exit 1
    }
}

$finalStatusResult = Get-GitOutput -Arguments @("status", "--short") -AllowFailure
$finalStatus = @($finalStatusResult.Lines | Where-Object { $_ -ne $null })

# ============================================================
# SUMMARY
# ============================================================

Write-Separator
Write-Ok $(if ($SyncOnly) { "GPush sync completed" } else { "GPush completed" })
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
