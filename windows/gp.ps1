$RawArguments = @($args)
if ($RawArguments.Count -gt 0 -and $RawArguments[0] -eq "--no-color") {
    $RawArguments = @($RawArguments | Select-Object -Skip 1)
    $script:GPushNoColor = $true
}
if ($script:GPushNoColor -or $env:NO_COLOR) {
    function Write-Host {
        param([Parameter(Position=0,ValueFromRemainingArguments=$true)] $Object, [switch]$NoNewline, $ForegroundColor, $BackgroundColor, $Separator)
        if ($null -ne $Separator) { Microsoft.PowerShell.Utility\Write-Host $Object -NoNewline:$NoNewline -Separator $Separator }
        else { Microsoft.PowerShell.Utility\Write-Host $Object -NoNewline:$NoNewline }
    }
}

# ============================================================
# ENCODING
# ============================================================

[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding           = [System.Text.UTF8Encoding]::new($false)


# ============================================================
# CONFIG
# ============================================================

$ScriptVersion = "4.7.5"
$CompletionSchemaVersion = "14"

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

function Confirm-GPushAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    $answer = Read-Host "$Prompt [y/N]" -ErrorAction Stop
    return ($answer -match '^(?i:y|yes)$')
}

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

    # Keep key/value output aligned with at least one visible space
    # after longer labels such as "Working tree".
    Write-Host ("  {0,-18}" -f $Key) -NoNewline -ForegroundColor DarkGray
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

function Show-GPushVisualBar {
    param([int]$Done, [int]$Total)
    $width = 20
    $filled = [int][Math]::Floor($width * $Done / [Math]::Max(1,$Total))
    Write-Host ('[' + ('#' * $filled) + ('-' * ($width-$filled)) + "] $Done/$Total") -ForegroundColor Cyan
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

    if ($null -eq $script:GPushConfig) {
        $script:GPushConfig = New-DefaultGPushConfig
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

    if ($null -eq $script:GPushConfig.PSObject.Properties['aliases']) {
        $script:GPushConfig | Add-Member -NotePropertyName aliases -NotePropertyValue $script:RepositoryAliases
    }
    else {
        $script:GPushConfig.aliases = $script:RepositoryAliases
    }

    if ($null -eq $script:GPushConfig.PSObject.Properties['favorites']) {
        $script:GPushConfig | Add-Member -NotePropertyName favorites -NotePropertyValue @($script:FavoriteRepositories)
    }
    else {
        $script:GPushConfig.favorites = @($script:FavoriteRepositories)
    }
}


function Resolve-GPushConfigKey {
    param([string]$Key)

    if ([string]::IsNullOrWhiteSpace($Key)) {
        return $null
    }

    switch ($Key.Trim().ToLowerInvariant()) {
        { $_ -in @("search-root", "search-roots") } {
            return "search-root"
        }
        { $_ -in @("protected-branch", "protected-branches") } {
            return "protected-branch"
        }
        { $_ -in @("ignored-directory", "ignored-directories", "ignore-directory", "ignore") } {
            return "ignored-directory"
        }
        { $_ -in @("default-remote", "remote") } {
            return "default-remote"
        }
        { $_ -in @("large-file-threshold", "large-file-mb", "large-file") } {
            return "large-file-threshold"
        }
        default {
            return $null
        }
    }
}

function Write-GPushConfigEditUsage {
    Write-Dim "Use:"
    Write-Dim "  gp add <key> <value>"
    Write-Dim "  gp remove <search-root|protected-branch|ignored-directory> <value>"
    Write-Dim "  gp set <default-remote|large-file-threshold> <value>"
    Write-Dim "  gp reset <key>"
    Write-Dim "  Keys: search-root, protected-branch, ignored-directory, default-remote, large-file-threshold"
    Write-Dim "  Full form: gp config add|remove|set|reset ..."
}

function Test-GPushConfigPathEqual {
    param(
        [string]$Left,
        [string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }

    $leftExpanded = Expand-GPushPath -Path $Left
    $rightExpanded = Expand-GPushPath -Path $Right

    try {
        $leftFull = [System.IO.Path]::GetFullPath($leftExpanded).TrimEnd('\', '/')
        $rightFull = [System.IO.Path]::GetFullPath($rightExpanded).TrimEnd('\', '/')
        return [string]::Equals($leftFull, $rightFull, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return [string]::Equals($Left.Trim(), $Right.Trim(), [System.StringComparison]::OrdinalIgnoreCase)
    }
}

function Invoke-GPushConfigEdit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [string]$Value
    )

    $actionName = $Action.Trim().ToLowerInvariant()
    $configKey = Resolve-GPushConfigKey -Key $Key

    if ($null -eq $configKey) {
        Write-Err "Unknown configuration key: $Key"
        Write-GPushConfigEditUsage
        return 2
    }

    $listKeys = @("search-root", "protected-branch", "ignored-directory")
    $scalarKeys = @("default-remote", "large-file-threshold")

    if ($actionName -eq "add") {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            Write-Err "Configuration 'add' requires a value."
            Write-Dim "Example: gp add $configKey <value>"
            return 2
        }

        # `add` is intentionally convenient: for list settings it appends,
        # while scalar settings behave like `set`.
        if ($configKey -in $scalarKeys) {
            $actionName = "set"
        }
    }
    elseif ($actionName -eq "remove") {
        if ($configKey -notin $listKeys) {
            Write-Err "Configuration key '$configKey' cannot remove an individual value."
            Write-Dim "Use: gp reset $configKey"
            return 2
        }

        if ([string]::IsNullOrWhiteSpace($Value)) {
            Write-Err "Configuration 'remove' requires a value."
            Write-Dim "Example: gp remove $configKey <value>"
            return 2
        }
    }
    elseif ($actionName -eq "set") {
        if ($configKey -notin $scalarKeys) {
            Write-Err "Configuration key '$configKey' does not support 'set'."
            Write-Dim "Use 'gp config add/remove $configKey <value>' for list settings."
            return 2
        }

        if ([string]::IsNullOrWhiteSpace($Value)) {
            Write-Err "Configuration 'set' requires a value."
            Write-Dim "Example: gp config set $configKey <value>"
            return 2
        }
    }
    elseif ($actionName -eq "reset") {
        if (-not [string]::IsNullOrWhiteSpace($Value)) {
            Write-Err "Configuration 'reset' accepts only a key."
            Write-Dim "Example: gp config reset $configKey"
            return 2
        }
    }
    else {
        Write-Err "Unknown config action: $Action"
        Write-GPushConfigEditUsage
        return 2
    }

    switch ($configKey) {
        "search-root" {
            $items = @($script:GPushConfig.searchRoots | ForEach-Object { [string]$_ })

            if ($actionName -eq "add") {
                $exists = @($items | Where-Object { Test-GPushConfigPathEqual -Left $_ -Right $Value }).Count -gt 0
                if ($exists) {
                    Write-Warn "Search root is already configured: $Value"
                    return 0
                }

                $script:GPushConfig.searchRoots = @($items) + @($Value.Trim())
            }
            elseif ($actionName -eq "remove") {
                $remaining = @($items | Where-Object { -not (Test-GPushConfigPathEqual -Left $_ -Right $Value) })
                if ($remaining.Count -eq $items.Count) {
                    Write-Err "Search root was not found: $Value"
                    return 1
                }

                if ($remaining.Count -eq 0) {
                    Write-Err "Cannot remove the last search root."
                    Write-Dim "Add another search root first."
                    return 2
                }

                $script:GPushConfig.searchRoots = $remaining
            }
            else {
                $script:GPushConfig.searchRoots = @($DefaultSearchRoots)
            }
        }

        "protected-branch" {
            $items = @($script:GPushConfig.protectedBranches | ForEach-Object { [string]$_ })

            if ($actionName -eq "add") {
                if ($items -icontains $Value.Trim()) {
                    Write-Warn "Protected branch is already configured: $Value"
                    return 0
                }
                $script:GPushConfig.protectedBranches = @($items) + @($Value.Trim())
            }
            elseif ($actionName -eq "remove") {
                if ($items -inotcontains $Value.Trim()) {
                    Write-Err "Protected branch was not found: $Value"
                    return 1
                }
                $script:GPushConfig.protectedBranches = @(
                    $items | Where-Object { -not [string]::Equals($_, $Value.Trim(), [System.StringComparison]::OrdinalIgnoreCase) }
                )
            }
            else {
                $script:GPushConfig.protectedBranches = @($DefaultProtectedBranches)
            }
        }

        "ignored-directory" {
            $items = @($script:GPushConfig.ignoredDirectories | ForEach-Object { [string]$_ })

            if ($actionName -eq "add") {
                if ($items -icontains $Value.Trim()) {
                    Write-Warn "Ignored directory is already configured: $Value"
                    return 0
                }
                $script:GPushConfig.ignoredDirectories = @($items) + @($Value.Trim())
            }
            elseif ($actionName -eq "remove") {
                if ($items -inotcontains $Value.Trim()) {
                    Write-Err "Ignored directory was not found: $Value"
                    return 1
                }
                $script:GPushConfig.ignoredDirectories = @(
                    $items | Where-Object { -not [string]::Equals($_, $Value.Trim(), [System.StringComparison]::OrdinalIgnoreCase) }
                )
            }
            else {
                $script:GPushConfig.ignoredDirectories = @($DefaultIgnoredDirectories)
            }
        }

        "default-remote" {
            if ($actionName -eq "set") {
                $remoteName = $Value.Trim()
                if ($remoteName -notmatch '^[^\s]+$') {
                    Write-Err "Remote name cannot contain whitespace."
                    return 2
                }

                $script:PreferredRemote = $remoteName
                $script:GPushConfig.defaultRemote = $remoteName
            }
            else {
                $script:PreferredRemote = $DefaultRemote
                $script:GPushConfig.defaultRemote = $DefaultRemote
            }
        }

        "large-file-threshold" {
            if ($actionName -eq "set") {
                $threshold = 0
                if (-not [int]::TryParse($Value.Trim(), [ref]$threshold) -or $threshold -le 0) {
                    Write-Err "Large-file threshold must be a positive integer in MB."
                    Write-Dim "Example: gp config set large-file-threshold 50"
                    return 2
                }

                $script:LargeFileThresholdMB = $threshold
                $script:GPushConfig.largeFileThresholdMB = $threshold
            }
            else {
                $script:LargeFileThresholdMB = $DefaultLargeFileThresholdMB
                $script:GPushConfig.largeFileThresholdMB = $DefaultLargeFileThresholdMB
            }
        }
    }

    Save-GPushConfig
    Initialize-GPushConfig

    Show-Banner
    Write-Section "Configuration updated"
    Write-KeyValue "Action" $actionName
    Write-KeyValue "Key" $configKey
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        Write-KeyValue "Value" $Value
    }
    Write-KeyValue "Config" $ConfigFile ([ConsoleColor]::DarkGray)
    Write-Host ""

    return 0
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

    try {
        @($entry) + @($remaining) |
            Select-Object -First 15 |
            ConvertTo-Json -Depth 4 |
            Set-Content -Path $RecentFile -Encoding UTF8 -ErrorAction Stop
    }
    catch [System.UnauthorizedAccessException] {
        # Corporate security may intentionally block PowerShell file writes.
        # Recent history is optional, so continue without failing the command.
        return
    }
    catch {
        # Recent history must never break the primary Git/project command.
        return
    }
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
    Write-Host '  ###  ####            o' -ForegroundColor White
    Write-Host ' #     #   #          / \' -ForegroundColor White
    Write-Host ' #  ## ####      o---o   o' -ForegroundColor White
    Write-Host ' #   # #          \   \ /' -ForegroundColor White
    Write-Host '  ###  #           o---o---o' -ForegroundColor White
    Write-Host '                            \ ' -ForegroundColor White
    Write-Host '                             o---o' -ForegroundColor White
    Write-Host ""

    Write-Host "A small Git helper for finding repositories, inspecting their state,"
    Write-Host "and handling common Git workflows safely."
    Write-Dim "Run gp without arguments to open the interactive main menu."
    Write-Host ""

    Write-Host "USAGE" -ForegroundColor Yellow
    Write-Host "  gp " -NoNewline -ForegroundColor Green
    Write-Host "<project> [commit message]" -ForegroundColor White
    Write-Host "  gp " -NoNewline -ForegroundColor Green
    Write-Host "<command> <action> [arguments]" -ForegroundColor White
    Write-Host "  gp " -NoNewline -ForegroundColor Green
    Write-Host "[options] <project> [arguments]" -ForegroundColor DarkGray
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
    Write-Host ("  {0,-11}{1}" -f "config", "show, path, doctor, add, remove, set, reset") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "add/set", "short config editing commands") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "alias", "list, set, remove") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "favorite", "list, add, remove  (alias: fav)") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "all", "status, fetch, sync, push (default: sync)") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "project", "info, build, test, run, open, shell") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "clone", "<url> [destination]") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "recent", "show recent repositories") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "update", "check, install, rollback") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "completion", "install, status, mode, uninstall  (PowerShell Tab)") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "help", "show help") -ForegroundColor White
    Write-Host ("  {0,-11}{1}" -f "version", "show version") -ForegroundColor White
    Write-Host ""

    Write-Host "OPTIONS" -ForegroundColor Yellow
    Write-Dim "  Command syntax above is preferred; flags remain available for compatibility."

    Write-ExampleGroup "General"
    Write-OptionHelp "-h, --help" "Show this help and exit."
    Write-OptionHelp "-v, --version" "Show the GPush version and exit."
    Write-OptionHelp "--" "Stop option parsing; useful when text starts with '-'."

    Write-ExampleGroup "Repository discovery & navigation"
    Write-OptionHelp "-l, --list" "List known Git repositories."
    Write-OptionHelp "-r, --refresh" "Rescan search roots and rebuild the repository cache."
    Write-OptionHelp "--add" "Add a Git repository to the cache manually."
    Write-OptionHelp "--cached" "Use the repository cache only."
    Write-OptionHelp "--no-color" "Disable output colors (place before command)."
    Write-OptionHelp "--recent" "Show recently used repositories."
    Write-OptionHelp "--open" "Open a repository folder in File Explorer."
    Write-OptionHelp "--clone" "Clone a repository and add it to the cache."

    Write-ExampleGroup "Repository inspection & sync"
    Write-OptionHelp "-s, --status" "Show branch, remote, sync, and working-tree state."
    Write-OptionHelp "--diff" "Show local changes and diff statistics."
    Write-OptionHelp "--log" "Show the recent decorated Git graph."
    Write-OptionHelp "--fetch" "Fetch and prune the selected remote."
    Write-OptionHelp "--pull" "Pull with rebase without creating a commit."
    Write-OptionHelp "--sync" "Synchronize local and remote history without creating a commit."
    Write-OptionHelp "--renormalize" "Renormalize tracked files using .gitattributes."
    Write-OptionHelp "--autostash" "Temporarily stash dirty files for --pull or --sync."

    Write-ExampleGroup "Commit workflow & safety"
    Write-OptionHelp "--dry-run" "Preview add/commit/push actions without changing Git state."
    Write-OptionHelp "--no-push" "Commit locally without fetching, pulling, or pushing."
    Write-OptionHelp "--amend" "Amend the latest local commit."
    Write-OptionHelp "--undo" "Undo the latest unpushed commit and keep changes staged."
    Write-OptionHelp "--allow-protected" "Skip protected-branch confirmation."
    Write-OptionHelp "--allow-risky-files" "Skip sensitive/large-file confirmation before staging."

    Write-ExampleGroup "Branches"
    Write-OptionHelp "--branches" "Show local and remote branches."
    Write-OptionHelp "--branch-new" "Create and switch to a new local branch."
    Write-OptionHelp "--branch-switch" "Switch to an existing local branch."
    Write-OptionHelp "--branch-delete" "Safely delete a merged local branch."
    Write-OptionHelp "--prune-branches" "Delete merged local branches whose upstream is gone."

    Write-ExampleGroup "Tags & releases"
    Write-OptionHelp "--tags" "List repository tags, newest first."
    Write-OptionHelp "--tag" "Create an annotated tag at HEAD."
    Write-OptionHelp "--tag-push" "Push one existing local tag."
    Write-OptionHelp "--tag-delete" "Delete one local tag."
    Write-OptionHelp "--release" "Create and push a release tag after safety checks."

    Write-ExampleGroup "Remotes & stash"
    Write-OptionHelp "--remotes" "Show configured Git remotes."
    Write-OptionHelp "--remote-add" "Add a named Git remote."
    Write-OptionHelp "--remote-set-url" "Change an existing remote URL."
    Write-OptionHelp "--remote-remove" "Remove a named Git remote."
    Write-OptionHelp "--stash" "Stash tracked and untracked local changes."
    Write-OptionHelp "--stash-list" "Show stash entries."
    Write-OptionHelp "--stash-pop" "Apply and remove the newest stash entry."

    Write-ExampleGroup "Aliases, favorites & multi-repository"
    Write-OptionHelp "--aliases" "List repository aliases."
    Write-OptionHelp "--alias-set" "Create or update a repository alias."
    Write-OptionHelp "--alias-remove" "Remove a repository alias."
    Write-OptionHelp "--favorite" "Add a repository to favorites."
    Write-OptionHelp "--unfavorite" "Remove a repository from favorites."
    Write-OptionHelp "--favorites" "List favorite repositories."
    Write-OptionHelp "--all" "Show or safely operate on all discovered repositories."

    Write-ExampleGroup "Configuration & tools"
    Write-OptionHelp "--config" "Show the effective GPush configuration."
    Write-OptionHelp "--config-path" "Show the config.json path."
    Write-OptionHelp "--doctor" "Check Git, config, cache, search roots, SSH, and repository setup."
    Write-Dim "  Config editor: gp config add|remove|set|reset <key> [value]"
    Write-Dim "  Keys: search-root, protected-branch, ignored-directory, default-remote, large-file-threshold"
    Write-OptionHelp "--project" "Run project info/build/test/run/open/shell tools."
    Write-OptionHelp "--update" "Check, install, or roll back a GPush release."
    Write-Host ""

    Write-Host "QUICK EXAMPLES" -ForegroundColor Yellow
    Write-Dim "  Command                                             Description"
    Write-ExampleHelp 'gp' "Pick from favorite/recent repositories or search by name."
    Write-ExampleHelp 'gp TestProject "Fix communication handling"' "Commit and safely push local changes."
    Write-ExampleHelp 'gp repo status TestProject' "Inspect one repository."
    Write-ExampleHelp 'gp all' "Synchronize cached repositories."
    Write-ExampleHelp 'gp all push "Update projects"' "Commit and synchronize cached repositories."
    Write-ExampleHelp 'gp repo sync TestProject' "Synchronize without creating a commit."
    Write-ExampleHelp 'gp menu' 'Open the workspace command menu.'
    Write-ExampleHelp 'gp detail Project' 'Inspect and manage a repository.'
    Write-ExampleHelp 'gp commit Project' 'Select files and commit.'
    Write-ExampleHelp 'gp diff Project' 'Show working tree diff.'
    Write-ExampleHelp 'gp branches Project' 'Manage local branches.'
    Write-ExampleHelp 'gp github Project' 'GitHub information via gh.'
    Write-ExampleHelp 'gp settings' 'Edit workspace configuration.'
    Write-ExampleHelp 'gp activity' 'Show recorded activity.'
    Write-ExampleHelp 'gp overview' "Workspace health and repository summary."
    Write-ExampleHelp 'gp stats' "30-day commit activity and daily heatmap."
    Write-ExampleHelp 'gp changes <project>' "Working tree and line statistics."
    Write-ExampleHelp 'gp branch graph <project>' "Decorated commit graph."
    Write-ExampleHelp 'gp all dry-run' "Read-only synchronization preview."
    Write-ExampleHelp 'gp all status --json' "Machine-readable cached status."
    Write-ExampleHelp 'gp all status' "Show last commit, behind/ahead and working tree for cached repositories."
    Write-ExampleHelp 'gp branch new TestProject feature/api' "Create and switch to a branch."
    Write-ExampleHelp 'gp stash push TestProject' "Stash local changes."
    Write-ExampleHelp 'gp cache refresh' "Rebuild the repository cache."
    Write-ExampleHelp 'gp favorite add TestProject' "Pin a repository to Favorites."
    Write-ExampleHelp 'gp fav remove TestProject' "Remove a repository from Favorites."
    Write-ExampleHelp 'gp config doctor' "Run diagnostics."
    Write-ExampleHelp 'gp completion mode memory|write|auto|off' "Choose completion persistence mode (memory auto-activates by default)."
    Write-ExampleHelp 'gp add protected-branch develop' "Add a protected branch."
    Write-ExampleHelp 'gp set default-remote origin' "Change the preferred remote."
    Write-ExampleHelp 'gp --dry-run TestProject "Test commit"' "Preview the normal commit workflow."
    Write-Host ""

    Write-Dim "Run 'gp <command> <action>' for normal use; legacy flags behave the same."
    Write-Host ""
}

# ============================================================
# GP SELF UPDATE / PROJECT TOOLS
# ============================================================

$GPushReleaseApi = "https://api.github.com/repos/MajkiiWasTaken/GPush/releases/latest"
$GPushBackupDir = Join-Path $ConfigDir "backups"

function ConvertTo-GPushVersion {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $clean = $Value.Trim()
    if ($clean.StartsWith("v", [System.StringComparison]::OrdinalIgnoreCase)) {
        $clean = $clean.Substring(1)
    }

    # [version] cannot parse prerelease suffixes. Stable updater intentionally
    # compares only the numeric part of a release tag.
    $clean = ($clean -split '-', 2)[0]

    try {
        return [version]$clean
    }
    catch {
        return $null
    }
}

function Get-GPushLatestRelease {
    $tempFile = $null
    $ProgressPreference = 'Continue'
    try {
        Write-Progress -Id 44 -Activity 'GPush update' -Status 'Checking GitHub release'
        $tempFile = [System.IO.Path]::GetTempFileName()
        Receive-GPushUpdateFile -Uri $GPushReleaseApi -Destination $tempFile
        return (Get-Content -LiteralPath $tempFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        if ($_.Exception -is [OperationCanceledException]) { Write-Warn 'Operation cancelled by user.' }
        else { Write-Err 'Could not check GitHub Releases.'; Write-Dim $_.Exception.Message }
        return $null
    } finally {
        Write-Progress -Id 44 -Activity 'GPush update' -Completed
        if ($tempFile -and (Test-Path -LiteralPath $tempFile)) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
    }
}

function Get-GPushWindowsReleaseAsset {
    param(
        [Parameter(Mandatory = $true)]
        $Release
    )

    $assets = @($Release.assets)

    if ($assets.Count -eq 0) {
        return $null
    }

    $preferred = @(
        $assets |
            Where-Object {
                $_.name -match '(?i)windows' -and
                $_.name -match '(?i)\.zip$' -and
                $_.name -notmatch '(?i)\.sha256\.zip$'
            } |
            Sort-Object name
    )

    if ($preferred.Count -gt 0) {
        return $preferred[0]
    }

    return $null
}

function Get-GPushChecksumAsset {
    param(
        [Parameter(Mandatory = $true)]
        $Release,
        [Parameter(Mandatory = $true)]
        [string]$PackageName
    )

    $assets = @($Release.assets)
    $exactNames = @(
        "$PackageName.sha256",
        "$PackageName.sha256.txt",
        "SHA256SUMS",
        "sha256sums.txt"
    )

    foreach ($name in $exactNames) {
        $match = @($assets | Where-Object { $_.name -ieq $name })
        if ($match.Count -gt 0) {
            return $match[0]
        }
    }

    return $null
}

# Windows command-line quoting for ProcessStartInfo on both .NET Framework and .NET.
function ConvertTo-GPushNativeArgument {
    param([AllowEmptyString()][string]$Value)
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Start-GPushNativeCapture {
    param([string]$Executable, [string[]]$ArgumentVector, [switch]$GitOperation)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = (@(foreach ($arg in $ArgumentVector) { ConvertTo-GPushNativeArgument $arg }) -join ' ')
    $info.WorkingDirectory = (Get-Location).ProviderPath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    if ($GitOperation) { $info.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0' }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Could not start native process.' }
        $process.StandardInput.Close()
        return [PSCustomObject]@{ Process=$process; OutputTask=$process.StandardOutput.ReadToEndAsync(); ErrorTask=$process.StandardError.ReadToEndAsync() }
    } catch { $process.Dispose(); throw }
}

function Stop-GPushNativeCapture {
    param($Capture)
    if ($null -eq $Capture) { return }
    $process = $Capture.Process
    try {
        if (-not $process.HasExited) {
            # Kill only this operation's process tree, not the GPush host.
            if ($env:OS -eq 'Windows_NT') {
                $taskkill = Join-Path $env:SystemRoot 'System32/taskkill.exe'
                if (Test-Path -LiteralPath $taskkill) { try { & $taskkill /PID $process.Id /T /F 2>$null | Out-Null } catch { } }
            }
            if (-not $process.HasExited) { $process.Kill() }
            $null = $process.WaitForExit(2000)
        }
    } catch { }
    finally { $process.Dispose() }
}

function Test-GPushOperationCancelled {
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return $false }
    while ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.KeyChar -eq [char]3 -or ($key.Key -eq 'C' -and ($key.Modifiers -band [ConsoleModifiers]::Control))) { return $true }
    }
    return $false
}

function Write-GPushTransferProgress {
    param([string]$Destination,[long]$ExpectedBytes,[Diagnostics.Stopwatch]$Timer)
    $bytes = 0L
    if (Test-Path -LiteralPath $Destination) { try { $bytes = (Get-Item -LiteralPath $Destination -ErrorAction Stop).Length } catch { } }
    $rate = $bytes / [Math]::Max(0.1,$Timer.Elapsed.TotalSeconds) / 1024
    $status = '{0:N1} KiB  |  {1:N1} KiB/s' -f ($bytes/1024),$rate
    $percent = -1
    if ($ExpectedBytes -gt 0) { $percent = [int][Math]::Min(100,[Math]::Floor(100.0*$bytes/$ExpectedBytes)); $status = '{0:N1} / {1:N1} KiB  |  {2:N1} KiB/s' -f ($bytes/1024),($ExpectedBytes/1024),$rate }
    Write-Progress -Id 45 -ParentId 44 -Activity 'Downloading update package' -Status $status -PercentComplete $percent -CurrentOperation 'Ctrl+C: cancel download'
}

function Invoke-GPushNativeCapture {
    param([string]$Executable,[string[]]$ArgumentVector,[switch]$GitOperation,[string]$ProgressFile,[long]$ExpectedBytes=0)
    $capture = $null
    $interactive = -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
    $previous = $false
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $ProgressPreference = 'Continue'
    try {
        if ($interactive) { $previous = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true }
        $capture = Start-GPushNativeCapture -Executable $Executable -ArgumentVector $ArgumentVector -GitOperation:$GitOperation
        while (-not $capture.Process.HasExited -or -not $capture.OutputTask.IsCompleted -or -not $capture.ErrorTask.IsCompleted) {
            if ($interactive -and (Test-GPushOperationCancelled)) { throw [OperationCanceledException]::new('Operation cancelled by user.') }
            if ($interactive -and $ProgressFile) { Write-GPushTransferProgress -Destination $ProgressFile -ExpectedBytes $ExpectedBytes -Timer $timer }
            Start-Sleep -Milliseconds 100
        }
        $capture.Process.WaitForExit()
        return [PSCustomObject]@{ ExitCode=$capture.Process.ExitCode; Stdout=$capture.OutputTask.GetAwaiter().GetResult(); Stderr=$capture.ErrorTask.GetAwaiter().GetResult() }
    } finally {
        if ($capture) { Stop-GPushNativeCapture $capture }
        if ($ProgressFile) { Write-Progress -Id 45 -Activity 'Downloading update package' -Completed }
        if ($interactive) { [Console]::TreatControlCAsInput = $previous }
    }
}

function Receive-GPushUpdateFile {
    param([string]$Uri,[string]$Destination,[switch]$UseWebRequest,[long]$ExpectedBytes=0)

    $separator = if ($Uri.Contains('?')) { '&' } else { '?' }
    $downloadUri = $Uri + $separator + 'gpush_nocache=' + [guid]::NewGuid().ToString('N')
    $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop }
    $showTransfer = $Destination -match '\.(zip|tar\.gz)$'
    $interactive = -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
    $ProgressPreference = 'Continue'
    if ($curl -and -not $UseWebRequest) {
        $arguments = @('--fail','--location','--silent','--show-error','--connect-timeout','30','--max-time','300','--header','Cache-Control: no-cache, no-store','--header','Pragma: no-cache','--user-agent',"GPush/$ScriptVersion",'--output',$Destination,'--',$downloadUri)
        $progressFile = if ($showTransfer) { $Destination } else { '' }
        $result = Invoke-GPushNativeCapture -Executable $curl.Source -ArgumentVector $arguments -ProgressFile $progressFile -ExpectedBytes $ExpectedBytes
        if ($result.ExitCode -eq 0 -and (Test-Path -LiteralPath $Destination) -and (Get-Item -LiteralPath $Destination).Length -gt 0) { return }
        Write-Warn 'curl.exe download failed; trying PowerShell.'
        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop }
    }

    $headers = @{ 'User-Agent' = "GPush/$ScriptVersion"; 'Cache-Control' = 'no-cache, no-store'; 'Pragma' = 'no-cache' }
    if (-not $interactive) {
        Invoke-WebRequest -Uri $downloadUri -OutFile $Destination -UseBasicParsing -Headers $headers -TimeoutSec 300 -ErrorAction Stop
    } else {
        # Keep the fallback in its own PowerShell process so cancelling it does not stop GPush.
        $previous = [Console]::TreatControlCAsInput
        $job = $null; $timer = [Diagnostics.Stopwatch]::StartNew()
        try {
            [Console]::TreatControlCAsInput = $true
            $job = Start-Job -ScriptBlock {
                param($RequestUri,$Target,$RequestHeaders)
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $RequestUri -OutFile $Target -UseBasicParsing -Headers $RequestHeaders -TimeoutSec 300 -ErrorAction Stop
            } -ArgumentList $downloadUri,$Destination,$headers -ErrorAction Stop
            while ($job.State -in @('NotStarted','Running')) {
                if (Test-GPushOperationCancelled) { throw [OperationCanceledException]::new('Operation cancelled by user.') }
                if ($showTransfer) { Write-GPushTransferProgress -Destination $Destination -ExpectedBytes $ExpectedBytes -Timer $timer }
                Start-Sleep -Milliseconds 100
            }
            Receive-Job -Job $job -ErrorAction Stop | Out-Null
            if ($job.State -ne 'Completed') { throw 'PowerShell download failed.' }
        } finally {
            if ($job) {
                if ($job.State -in @('NotStarted','Running')) { Stop-Job -Job $job -ErrorAction SilentlyContinue }
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
            if ($showTransfer) { Write-Progress -Id 45 -Activity 'Downloading update package' -Completed }
            [Console]::TreatControlCAsInput = $previous
        }
    }
    if (-not (Test-Path -LiteralPath $Destination) -or (Get-Item -LiteralPath $Destination).Length -eq 0) { throw 'Download did not produce a non-empty file.' }
}

function Test-GPushDownloadedPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackagePath,
        [Parameter(Mandatory = $true)]
        $Release,
        [Parameter(Mandatory = $true)]
        $PackageAsset
    )

    $checksumAsset = Get-GPushChecksumAsset `
        -Release $Release `
        -PackageName ([string]$PackageAsset.name)

    if ($null -eq $checksumAsset) {
        Write-Err "No SHA-256 asset published. Update cancelled."
        return $false
    }

    $checksumFile = Join-Path ([System.IO.Path]::GetDirectoryName($PackagePath)) "checksum.txt"

    try {
        Receive-GPushUpdateFile -Uri $checksumAsset.browser_download_url -Destination $checksumFile

        $checksumText = Get-Content -Path $checksumFile -Raw -ErrorAction Stop
        $expected = $null

        foreach ($line in ($checksumText -split "`r?`n")) {
            $hashMatch = [regex]::Match($line, '(?i)^\s*([a-f0-9]{64})(?:\s+\*?(.+?))?\s*$')
            if (-not $hashMatch.Success) { continue }

            $listedName = $hashMatch.Groups[2].Value
            if ($listedName.StartsWith('./')) { $listedName = $listedName.Substring(2) }
            if ($listedName -and $listedName -cne [string]$PackageAsset.name) { continue }
            if ($checksumAsset.name -match '(?i)^sha256sums' -and -not $listedName) { continue }

            $expected = $hashMatch.Groups[1].Value.ToLowerInvariant()
            break
        }

        if ([string]::IsNullOrWhiteSpace($expected)) {
            Write-Err "No usable SHA-256 value for this package. Update cancelled."
            return $false
        }

        $actual = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()

        if ($actual -ne $expected) {
            Write-Err "Downloaded package checksum does not match the published SHA-256."
            Write-KeyValue "Expected" $expected ([ConsoleColor]::DarkGray)
            Write-KeyValue "Actual" $actual ([ConsoleColor]::Red)
            return $false
        }

        return $true
    }
    catch {
        if ($_.Exception -is [OperationCanceledException]) { throw }
        Write-Err "Checksum verification could not be completed. Update cancelled."
        Write-Dim $_.Exception.Message
        return $false
    }
}

function Show-GPushUpdateStatus {
    param(
        [Parameter(Mandatory = $true)]
        $Release
    )

    $latestText = [string]$Release.tag_name
    $installedVersion = ConvertTo-GPushVersion -Value $ScriptVersion
    $latestVersion = ConvertTo-GPushVersion -Value $latestText

    Write-Section "GPush Update"
    Write-KeyValue "Installed" $ScriptVersion
    Write-KeyValue "Latest" $latestText
    Write-KeyValue "Channel" "stable"

    if ($null -eq $latestVersion -or $null -eq $installedVersion) {
        Write-Warn "Could not compare version numbers."
        return $false
    }

    Write-Host ""

    if ($latestVersion -gt $installedVersion) {
        Write-Warn "Update available: $ScriptVersion -> $latestText"
        return $true
    }

    if ($latestVersion -eq $installedVersion) {
        Write-Ok "GPush is up to date."
        return $false
    }

    Write-Dim "Installed version is newer than the latest stable release."
    return $false
}

function Backup-GPushInstallation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentScript
    )

    if (-not (Test-Path $GPushBackupDir)) {
        New-Item -ItemType Directory -Path $GPushBackupDir -Force | Out-Null
    }

    $backupName = "v$ScriptVersion-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    $backupPath = Join-Path $GPushBackupDir $backupName
    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null

    Copy-Item -Path $CurrentScript -Destination (Join-Path $backupPath "gp.ps1") -Force

    $metadata = [ordered]@{
        version = $ScriptVersion
        createdAt = (Get-Date).ToString("o")
        originalPath = $CurrentScript
    }

    $metadata |
        ConvertTo-Json -Depth 4 |
        Set-Content -Path (Join-Path $backupPath "backup.json") -Encoding UTF8

    return $backupPath
}

function Install-GPushRelease {
    param(
        [Parameter(Mandatory = $true)]
        $Release
    )

    if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or -not (Test-Path $PSCommandPath)) {
        Write-Err "GPush cannot determine the path of the currently running script."
        Write-Dim "Run the installed gp.ps1 directly or reinstall GPush once."
        return 1
    }

    $asset = Get-GPushWindowsReleaseAsset -Release $Release
    if ($null -eq $asset) {
        Write-Err "Latest release does not contain a Windows ZIP package."
        Write-Dim "Expected a release asset whose name contains 'windows' and ends in .zip."
        return 1
    }

    $latestVersion = ConvertTo-GPushVersion -Value ([string]$Release.tag_name)
    $installedVersion = ConvertTo-GPushVersion -Value $ScriptVersion

    if ($null -eq $latestVersion -or $null -eq $installedVersion) {
        Write-Err "Could not parse the installed or release version."
        return 1
    }

    if ($latestVersion -le $installedVersion) {
        Write-Ok "GPush is already up to date."
        return 0
    }

    Write-Section "Install update"
    Write-KeyValue "From" $ScriptVersion
    Write-KeyValue "To" ([string]$Release.tag_name) ([ConsoleColor]::Green)
    Write-KeyValue "Package" ([string]$asset.name)
    Write-Host ""

    if (-not (Confirm-GPushAction -Prompt "Download and install this update?")) {
        Write-Warn "Update cancelled."
        return 0
    }

    $ProgressPreference = 'Continue'
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("gpush-update-" + [guid]::NewGuid().ToString("N"))
    $packagePath = Join-Path $tempRoot ([string]$asset.name)
    $extractPath = Join-Path $tempRoot "package"

    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

        Write-Progress -Id 44 -Activity 'GPush update' -Status 'Preparing download'
        $verified = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            Write-Progress -Id 44 -Activity 'GPush update' -Status "Downloading $($asset.name)"
            try {
                Receive-GPushUpdateFile -Uri $asset.browser_download_url -Destination $packagePath -UseWebRequest:($attempt -eq 2) -ExpectedBytes ([long]$asset.size)
                Write-Progress -Id 44 -Activity 'GPush update' -Status 'Verifying package integrity'
                
                if (Test-GPushDownloadedPackage -PackagePath $packagePath -Release $Release -PackageAsset $asset) {
                    $verified = $true
                    break
                }
            }
            catch {
                if ($_.Exception -is [OperationCanceledException]) { throw }
                Write-Warn "Download attempt failed: $($_.Exception.Message)"
            }
            if ($attempt -lt 3) { Write-Warn "Retrying with a fresh download URL." }
        }
        if (-not $verified) {
            Write-Err "Update cancelled: no verified package after three attempts."
            return 1
        }

        Write-Progress -Id 44 -Activity 'GPush update' -Status 'Extracting verified package'
        Expand-Archive -Path $packagePath -DestinationPath $extractPath -Force

        $candidateScripts = @(
            Get-ChildItem -Path $extractPath -Filter "gp.ps1" -File -Recurse -ErrorAction SilentlyContinue
        )

        if ($candidateScripts.Count -eq 0) {
            Write-Err "The release package does not contain gp.ps1."
            return 1
        }

        # Prefer the shallowest gp.ps1 if a package happens to contain examples/tests.
        $newScript = $candidateScripts |
            Sort-Object { $_.FullName.Split([IO.Path]::DirectorySeparatorChar).Count } |
            Select-Object -First 1

        $newContent = Get-Content -Path $newScript.FullName -Raw -ErrorAction Stop
        if ($newContent -notmatch '\$ScriptVersion\s*=\s*"([^"]+)"') {
            Write-Err "The downloaded gp.ps1 does not expose a ScriptVersion."
            return 1
        }

        $packageVersionText = $Matches[1]
        $packageVersion = ConvertTo-GPushVersion -Value $packageVersionText

        if ($null -eq $packageVersion -or $packageVersion -ne $latestVersion) {
            Write-Err "Release package version does not match the GitHub release."
            Write-KeyValue "Release" ([string]$Release.tag_name)
            Write-KeyValue "Package" $packageVersionText
            return 1
        }

        Write-Progress -Id 44 -Activity 'GPush update' -Status 'Creating rollback backup'
        $backupPath = Backup-GPushInstallation -CurrentScript $PSCommandPath
        Write-Progress -Id 44 -Activity 'GPush update' -Status 'Installing update'

        
        Copy-Item -Path $newScript.FullName -Destination $PSCommandPath -Force

        Write-Progress -Id 44 -Activity 'GPush update' -Completed
        Write-Ok "GPush updated successfully. SHA-256 verified."
        Write-Dim "Rollback backup: $backupPath"
        Write-KeyValue "Previous" $ScriptVersion
        Write-KeyValue "Current" $packageVersionText ([ConsoleColor]::Green)
        Write-Dim "Restart the current PowerShell command before using the new version."
        Write-Host ""
        return 0
    }
    catch {
        if ($_.Exception -is [OperationCanceledException]) { Write-Warn 'Operation cancelled by user.'; return 130 }
        Write-Err "GPush update failed."
        Write-Dim $_.Exception.Message
        return 1
    }
    finally {
        Write-Progress -Id 44 -Activity 'GPush update' -Completed
        if (Test-Path $tempRoot) {
            try { [System.IO.Directory]::Delete($tempRoot, $true) } catch { Write-Dim "Temporary update cleanup failed." }
        }
    }
}

function Restore-GPushBackup {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or -not (Test-Path $PSCommandPath)) {
        Write-Err "GPush cannot determine the installed script path."
        return 1
    }

    if (-not (Test-Path $GPushBackupDir)) {
        Write-Warn "No GPush backup exists."
        return 0
    }

    $backups = @(
        Get-ChildItem -Path $GPushBackupDir -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    )

    if ($backups.Count -eq 0) {
        Write-Warn "No GPush backup exists."
        return 0
    }

    $backup = $backups[0]
    $backupScript = Join-Path $backup.FullName "gp.ps1"

    if (-not (Test-Path $backupScript)) {
        Write-Err "Newest backup is incomplete: $($backup.FullName)"
        return 1
    }

    $backupVersion = "unknown"
    $backupContent = Get-Content -Path $backupScript -Raw -ErrorAction SilentlyContinue
    if ($backupContent -match '\$ScriptVersion\s*=\s*"([^"]+)"') {
        $backupVersion = $Matches[1]
    }

    Write-Section "GPush Rollback"
    Write-KeyValue "Current" $ScriptVersion
    Write-KeyValue "Restore" $backupVersion ([ConsoleColor]::Yellow)
    Write-KeyValue "Backup" $backup.FullName ([ConsoleColor]::DarkGray)
    Write-Host ""

    if (-not (Confirm-GPushAction -Prompt "Restore this GPush backup?")) {
        Write-Warn "Rollback cancelled."
        return 0
    }

    try {
        Copy-Item -Path $backupScript -Destination $PSCommandPath -Force
        Write-Ok "Rollback completed."
        Write-Dim "Restart the current PowerShell command before using the restored version."
        Write-Host ""
        return 0
    }
    catch {
        Write-Err "Rollback failed."
        Write-Dim $_.Exception.Message
        return 1
    }
}

function Invoke-GPushUpdateCommand {
    param([object[]]$Arguments, [switch]$OfferInstall)

    $action = if (@($Arguments).Count -gt 0) {
        ([string]$Arguments[0]).ToLowerInvariant()
    }
    else {
        "install"
    }

    if ($action -notin @("check", "install", "rollback")) {
        Write-Err "Unknown update action: $action"
        Write-Dim "Use: gp update [check|install|rollback]"
        return 2
    }

    Show-Banner

    if ($action -eq "rollback") {
        return (Restore-GPushBackup)
    }

    $release = Get-GPushLatestRelease
    if ($null -eq $release) {
        return 1
    }

    $hasUpdate = Show-GPushUpdateStatus -Release $release

    if ($action -eq "check" -and -not ($OfferInstall -and $hasUpdate)) {
        if ($hasUpdate) {
            Write-Dim "Run 'gp update' to install."
        }
        Write-Host ""
        return 0
    }

    if (-not $hasUpdate) {
        Write-Host ""
        return 0
    }

    return (Install-GPushRelease -Release $release)
}

function Read-GPushRepositoryCacheEarly {
    if (-not (Test-Path $CacheFile)) {
        return @()
    }

    try {
        $raw = Get-Content -Path $CacheFile -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop

        $result = @()

        foreach ($entry in @($raw)) {
            if ($null -eq $entry) {
                continue
            }

            # Normal cache shape:
            #   { Name: "...", Path: "..." }
            if ($entry.Name -isnot [System.Array] -and
                $entry.Path -isnot [System.Array]) {

                $name = [string]$entry.Name
                $path = [string]$entry.Path

                if (-not [string]::IsNullOrWhiteSpace($name) -and
                    -not [string]::IsNullOrWhiteSpace($path) -and
                    (Test-Path $path) -and
                    (Test-Path (Join-Path $path ".git"))) {

                    $result += [PSCustomObject]@{
                        Name = $name
                        Path = $path
                    }
                }

                continue
            }

            # Compatibility with an older/broken projected cache shape where
            # Name[] and Path[] ended up on one object.
            $names = @($entry.Name)
            $paths = @($entry.Path)
            $count = [Math]::Min($names.Count, $paths.Count)

            for ($i = 0; $i -lt $count; $i++) {
                $name = [string]$names[$i]
                $path = [string]$paths[$i]

                if (-not [string]::IsNullOrWhiteSpace($name) -and
                    -not [string]::IsNullOrWhiteSpace($path) -and
                    (Test-Path $path) -and
                    (Test-Path (Join-Path $path ".git"))) {

                    $result += [PSCustomObject]@{
                        Name = $name
                        Path = $path
                    }
                }
            }
        }

        return @(
            $result |
                Sort-Object Path -Unique |
                Sort-Object Name, Path
        )
    }
    catch {
        return @()
    }
}


function Get-GPushProjectRepository {
    param([string]$Search)

    # No explicit project: use the current Git repository when possible.
    if ([string]::IsNullOrWhiteSpace($Search)) {
        $currentRoot = (& git rev-parse --show-toplevel 2>$null) -join ""
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($currentRoot)) {
            return [PSCustomObject]@{
                Name = Split-Path $currentRoot.Trim() -Leaf
                Path = $currentRoot.Trim()
            }
        }

        Write-Err "No project was specified and the current directory is not a Git repository."
        return $null
    }

    $resolvedSearch = Resolve-GPushAlias -Search $Search

    # Explicit path has priority and does not require the cache.
    $expandedPath = Expand-GPushPath -Path $resolvedSearch
    if (Test-Path $expandedPath -PathType Container) {
        $resolvedPath = (Resolve-Path $expandedPath).Path
        return [PSCustomObject]@{
            Name = Split-Path $resolvedPath -Leaf
            Path = $resolvedPath
        }
    }

    if (-not (Test-Path $CacheFile)) {
        Write-Err "Repository cache is missing."
        Write-Dim "Run 'gp --refresh' first."
        return $null
    }

    $cached = @(Read-GPushRepositoryCacheEarly)

    if ($cached.Count -eq 0) {
        Write-Err "Repository cache is empty or contains no usable Git repositories."
        Write-Dim "Cache: $CacheFile"
        Write-Dim "Run 'gp --refresh' only if the configured search roots are accessible."
        return $null
    }

    $matches = @($cached | Where-Object { $_.Name -ieq $resolvedSearch })
    if ($matches.Count -eq 0) {
        $matches = @($cached | Where-Object { $_.Name -ilike "$resolvedSearch*" })
    }
    if ($matches.Count -eq 0) {
        $matches = @($cached | Where-Object { $_.Name -ilike "*$resolvedSearch*" -or $_.Path -ilike "*$resolvedSearch*" })
    }

    if ($matches.Count -eq 0) {
        Write-Err "Project '$Search' was not found."
        return $null
    }

    if ($matches.Count -gt 1) {
        Write-Warn "Multiple projects match '$Search':"
        for ($i = 0; $i -lt $matches.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $matches[$i].Name) -ForegroundColor White
            Write-Dim ("      " + $matches[$i].Path)
        }

        $choice = Read-Host "Choose project number"
        $number = 0
        if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $matches.Count) {
            Write-Err "Invalid project selection."
            return $null
        }

        return $matches[$number - 1]
    }

    return $matches[0]
}

function Get-GPushProjectInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $types = New-Object System.Collections.Generic.List[string]
    $manifest = New-Object System.Collections.Generic.List[string]

    if (Test-Path (Join-Path $Path "Cargo.toml")) {
        $types.Add("Rust")
        $manifest.Add("Cargo.toml")
    }

    $solutions = @(Get-ChildItem -Path $Path -Filter "*.sln" -File -ErrorAction SilentlyContinue)
    $csProjects = @(Get-ChildItem -Path $Path -Filter "*.csproj" -File -ErrorAction SilentlyContinue)
    if ($solutions.Count -gt 0 -or $csProjects.Count -gt 0) {
        $types.Add(".NET")
        if ($solutions.Count -gt 0) {
            $manifest.Add($solutions[0].Name)
        }
        elseif ($csProjects.Count -gt 0) {
            $manifest.Add($csProjects[0].Name)
        }
    }

    if (Test-Path (Join-Path $Path "package.json")) {
        $types.Add("Node")
        $manifest.Add("package.json")
    }

    if (Test-Path (Join-Path $Path "pyproject.toml")) {
        $types.Add("Python")
        $manifest.Add("pyproject.toml")
    }
    elseif (Test-Path (Join-Path $Path "requirements.txt")) {
        $types.Add("Python")
        $manifest.Add("requirements.txt")
    }

    if (Test-Path (Join-Path $Path "CMakeLists.txt")) {
        $types.Add("C/C++")
        $manifest.Add("CMakeLists.txt")
    }

    if ($types.Count -eq 0) {
        $types.Add("Generic")
    }

    $branch = "-"
    Push-Location $Path
    try {
        $branchResult = (& git branch --show-current 2>$null) -join ""
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($branchResult)) {
            $branch = $branchResult.Trim()
        }
    }
    finally {
        Pop-Location
    }

    return [PSCustomObject]@{
        Types = @($types)
        Manifest = @($manifest)
        Branch = $branch
    }
}

function Get-GPushNodeRunner {
    param([string]$Path)

    if (Test-Path (Join-Path $Path "pnpm-lock.yaml")) {
        return "pnpm"
    }

    if (Test-Path (Join-Path $Path "yarn.lock")) {
        return "yarn"
    }

    return "npm"
}

function Test-GPushNodeScript {
    param(
        [string]$Path,
        [string]$Name
    )

    try {
        $package = Get-Content -Path (Join-Path $Path "package.json") -Raw | ConvertFrom-Json
        return (
            $null -ne $package.scripts -and
            $null -ne $package.scripts.PSObject.Properties[$Name]
        )
    }
    catch {
        return $false
    }
}

function Invoke-GPushExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,
        [string[]]$Arguments = @()
    )

    $command = Get-Command $Executable -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        Write-Err "Required command was not found: $Executable"
        return 127
    }

    Write-Host ""
    Write-Info ("[PROJECT] " + $Executable + " " + ($Arguments -join " "))
    & $Executable @Arguments
    return $LASTEXITCODE
}

function Invoke-GPushProjectAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [Parameter(Mandatory = $true)]
        $Repository
    )

    $path = [string]$Repository.Path
    $info = Get-GPushProjectInfo -Path $path

    Show-Banner
    Write-Section "Project"
    Write-KeyValue "Name" ([string]$Repository.Name)
    Write-KeyValue "Path" $path ([ConsoleColor]::DarkGray)
    Write-KeyValue "Type" (($info.Types -join " + "))
    Write-KeyValue "Manifest" $(if ($info.Manifest.Count -gt 0) { $info.Manifest -join ", " } else { "-" })
    Write-KeyValue "Git branch" $info.Branch ([ConsoleColor]::Magenta)

    if ($Action -eq "info") {
        Write-Section "Available"
        Write-Dim "  info    Detect project type and useful metadata."
        Write-Dim "  build   Build using the detected toolchain."
        Write-Dim "  test    Run project tests."
        Write-Dim "  run     Run the project when a safe default can be detected."
        Write-Dim "  open    Open the project directory in File Explorer."
        Write-Dim "  shell   Open a PowerShell window in the project directory."
        Write-Host ""
        return 0
    }

    if ($Action -eq "open") {
        try {
            Start-Process explorer.exe -ArgumentList @($path) -ErrorAction Stop
            Write-Ok "Opened in File Explorer."
            return 0
        }
        catch {
            Write-Err "Could not open File Explorer."
            Write-Dim $_.Exception.Message
            return 1
        }
    }

    if ($Action -eq "shell") {
        try {
            Start-Process powershell.exe -WorkingDirectory $path -ErrorAction Stop
            Write-Ok "Opened PowerShell in project directory."
            return 0
        }
        catch {
            Write-Err "Could not open PowerShell."
            Write-Dim $_.Exception.Message
            return 1
        }
    }

    Push-Location $path
    try {
        # Priority is intentional for mixed repositories. A root Cargo.toml means
        # the repository's primary build is Rust, followed by .NET, Node, Python,
        # and CMake. "project info" still displays every detected type.
        if ($info.Types -contains "Rust") {
            switch ($Action) {
                "build" { return (Invoke-GPushExternalCommand "cargo" @("build")) }
                "test"  { return (Invoke-GPushExternalCommand "cargo" @("test")) }
                "run"   { return (Invoke-GPushExternalCommand "cargo" @("run")) }
            }
        }

        if ($info.Types -contains ".NET") {
            $target = if ($info.Manifest.Count -gt 0) { $info.Manifest[0] } else { $null }
            $args = @($Action)
            if ($target) {
                $args += $target
            }

            switch ($Action) {
                "build" { return (Invoke-GPushExternalCommand "dotnet" $args) }
                "test"  { return (Invoke-GPushExternalCommand "dotnet" $args) }
                "run" {
                    $runArgs = @("run")
                    if ($target -and $target -like "*.csproj") {
                        $runArgs += @("--project", $target)
                    }
                    return (Invoke-GPushExternalCommand "dotnet" $runArgs)
                }
            }
        }

        if ($info.Types -contains "Node") {
            $runner = Get-GPushNodeRunner -Path $path

            switch ($Action) {
                "build" {
                    if (-not (Test-GPushNodeScript -Path $path -Name "build")) {
                        Write-Err "package.json does not define a 'build' script."
                        return 1
                    }
                    return (Invoke-GPushExternalCommand $runner @("run", "build"))
                }
                "test" {
                    if (-not (Test-GPushNodeScript -Path $path -Name "test")) {
                        Write-Err "package.json does not define a 'test' script."
                        return 1
                    }
                    return (Invoke-GPushExternalCommand $runner @("test"))
                }
                "run" {
                    if (Test-GPushNodeScript -Path $path -Name "dev") {
                        return (Invoke-GPushExternalCommand $runner @("run", "dev"))
                    }
                    if (Test-GPushNodeScript -Path $path -Name "start") {
                        return (Invoke-GPushExternalCommand $runner @("start"))
                    }

                    Write-Err "No 'dev' or 'start' script was found in package.json."
                    return 1
                }
            }
        }

        if ($info.Types -contains "Python") {
            $python = if (Get-Command python -ErrorAction SilentlyContinue) { "python" } elseif (Get-Command py -ErrorAction SilentlyContinue) { "py" } else { $null }

            if (-not $python) {
                Write-Err "Python was not found in PATH."
                return 127
            }

            switch ($Action) {
                "build" {
                    if (Test-Path (Join-Path $path "pyproject.toml")) {
                        return (Invoke-GPushExternalCommand $python @("-m", "build"))
                    }
                    return (Invoke-GPushExternalCommand $python @("-m", "compileall", "."))
                }
                "test" {
                    return (Invoke-GPushExternalCommand $python @("-m", "pytest"))
                }
                "run" {
                    foreach ($candidate in @("main.py", "app.py")) {
                        if (Test-Path (Join-Path $path $candidate)) {
                            return (Invoke-GPushExternalCommand $python @($candidate))
                        }
                    }

                    Write-Err "No default Python entry point (main.py or app.py) was found."
                    return 1
                }
            }
        }

        if ($info.Types -contains "C/C++") {
            switch ($Action) {
                "build" {
                    $configure = Invoke-GPushExternalCommand "cmake" @("-S", ".", "-B", "build")
                    if ($configure -ne 0) {
                        return $configure
                    }
                    return (Invoke-GPushExternalCommand "cmake" @("--build", "build"))
                }
                "test" {
                    return (Invoke-GPushExternalCommand "ctest" @("--test-dir", "build", "--output-on-failure"))
                }
                "run" {
                    Write-Err "A generic CMake project does not have a safe automatic run target."
                    Write-Dim "Run the built executable directly or add a project-specific launcher later."
                    return 1
                }
            }
        }

        Write-Err "Action '$Action' is not available for the detected project type."
        return 1
    }
    finally {
        Pop-Location
    }
}

function Invoke-GPushProjectCommand {
    param([object[]]$Arguments)

    $argsList = @($Arguments)
    $action = if ($argsList.Count -gt 0) {
        ([string]$argsList[0]).ToLowerInvariant()
    }
    else {
        "info"
    }

    if ($action -notin @("info", "build", "test", "run", "open", "shell")) {
        Write-Err "Unknown project action: $action"
        Write-Dim "Use: gp project info|build|test|run|open|shell [project]"
        return 2
    }

    if ($argsList.Count -gt 2) {
        Write-Err "Project command accepts at most one project name/path."
        Write-Dim "Use: gp project $action [project]"
        return 2
    }

    $search = if ($argsList.Count -eq 2) { [string]$argsList[1] } else { $null }
    $repository = Get-GPushProjectRepository -Search $search

    if ($null -eq $repository) {
        return 1
    }

    Save-GPushRecentRepository -Repository $repository
    return (Invoke-GPushProjectAction -Action $action -Repository $repository)
}



# ============================================================
# POWERSHELL TAB COMPLETION
# ============================================================

function global:Get-GPushCompletionRepositoryNames {
    $items = New-Object System.Collections.Generic.List[string]

    $configDir = Join-Path $env:LOCALAPPDATA "GPush"
    $cacheFile = Join-Path $configDir "repos.json"
    $configFile = Join-Path $configDir "config.json"

    if (Test-Path $cacheFile) {
        try {
            $raw = Get-Content -Path $cacheFile -Raw -ErrorAction Stop |
                ConvertFrom-Json -ErrorAction Stop

            foreach ($entry in @($raw)) {
                if ($null -eq $entry) {
                    continue
                }

                # Normal cache shape: one object per repository.
                if ($entry.Name -isnot [System.Array]) {
                    $name = [string]$entry.Name

                    if (-not [string]::IsNullOrWhiteSpace($name)) {
                        $items.Add($name)
                    }

                    continue
                }

                # PowerShell 5.1 can occasionally surface a projected object
                # whose Name property itself contains the repository array.
                foreach ($name in @($entry.Name)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$name)) {
                        $items.Add([string]$name)
                    }
                }
            }
        }
        catch {
            # Completion must never break the shell.
        }
    }

    if (Test-Path $configFile) {
        try {
            $config = Get-Content -Path $configFile -Raw -ErrorAction Stop |
                ConvertFrom-Json -ErrorAction Stop

            if ($null -ne $config.aliases) {
                foreach ($property in $config.aliases.PSObject.Properties) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$property.Name)) {
                        $items.Add([string]$property.Name)
                    }
                }
            }
        }
        catch {
            # Aliases are optional for completion.
        }
    }

    return @($items | Sort-Object -Unique)
}


function global:Get-GPushCompletionCommonPrefix {
    param([string[]]$Values)

    $items = @($Values)
    if ($items.Count -eq 0) {
        return ""
    }

    $prefix = [string]$items[0]

    foreach ($item in @($items | Select-Object -Skip 1)) {
        $value = [string]$item
        $limit = [Math]::Min($prefix.Length, $value.Length)
        $i = 0

        while (
            $i -lt $limit -and
            [char]::ToLowerInvariant($prefix[$i]) -eq
            [char]::ToLowerInvariant($value[$i])
        ) {
            $i++
        }

        $prefix = $prefix.Substring(0, $i)

        if ($prefix.Length -eq 0) {
            break
        }
    }

    return $prefix
}

function global:Get-GPushCompletionContext {
    param(
        [AllowEmptyString()]
        [string]$Line = "",
        [int]$Cursor = 0
    )

    $emptyResult = [PSCustomObject]@{
        Handle = $false
        Values = @()
        Label = ""
        Prefix = ""
        TokenStart = $Cursor
        TokenLength = 0
        InsertLeadingSpace = $false
    }

    if ([string]::IsNullOrEmpty($Line)) {
        return $emptyResult
    }

    $beforeCursor = $Line.Substring(0, [Math]::Min($Cursor, $Line.Length))

    if ($beforeCursor -notmatch '^\s*gp(?:\s|$)') {
        return $emptyResult
    }

    $body = $beforeCursor -replace '^\s*gp\s*', ''
    $endsWithSpace = $body -match '\s$'

    $tokens = @()
    if (-not [string]::IsNullOrWhiteSpace($body)) {
        $tokens = @($body.Trim() -split '\s+')
    }

    $completed = @($tokens)
    $prefix = ""
    $insertLeadingSpace = $false

    if (-not $endsWithSpace -and $tokens.Count -gt 0) {
        $prefix = [string]$tokens[$tokens.Count - 1]

        if ($tokens.Count -eq 1) {
            $completed = @()
        }
        else {
            $completed = @($tokens | Select-Object -First ($tokens.Count - 1))
        }
    }

    # Completion must replace the WHOLE token around the cursor, not
    # only the prefix to the left of the cursor.
    #
    # Example:
    #   gp project info TestovaniModemu
    #                   ^ cursor here
    #
    # Pressing Tab must replace TestovaniModemu, not insert a new project
    # before it.
    $tokenStart = $Cursor - $prefix.Length
    $tokenEnd = $Cursor

    # If the cursor is inside / at the beginning of an existing token,
    # include the token suffix to the right of the cursor as well.
    while (
        $tokenEnd -lt $Line.Length -and
        -not [char]::IsWhiteSpace($Line[$tokenEnd])
    ) {
        $tokenEnd++
    }

    $tokenLength = [Math]::Max(0, $tokenEnd - $tokenStart)

    $topLevel = @(
        "overview", "health", "stats", "history", "watch", "changes", "detail", "commit", "diff", "branches", "menu", "activity", "settings", "github", "repo", "branch", "tag", "remote", "stash", "cache", "config",
        "alias", "favorite", "fav", "favorites", "all", "project",
        "clone", "recent", "update", "completion", "help", "version",
        "add", "remove", "set", "reset"
    )

    $actions = @{
        "repo"       = @("status", "diff", "log", "open", "fetch", "pull", "sync")
        "branch"     = @("list", "new", "switch", "delete", "prune", "graph")
        "tag"        = @("list", "create", "push", "delete", "release")
        "remote"     = @("list", "add", "set-url", "remove")
        "stash"      = @("push", "list", "pop")
        "cache"      = @("list", "refresh", "add")
        "config"     = @("show", "path", "doctor", "add", "remove", "set", "reset")
        "alias"      = @("list", "set", "remove")
        "favorite"   = @("list", "add", "remove")
        "fav"        = @("list", "add", "remove")
        "all"        = @("status", "fetch", "sync", "push", "dry-run")
        "project"    = @("info", "build", "test", "run", "open", "shell")
        "update"     = @("check", "install", "rollback")
        "completion" = @("install", "status", "mode", "uninstall")
    }

    $allConfigKeys = @(
        "search-root", "protected-branch", "ignored-directory",
        "default-remote", "large-file-threshold"
    )

    $listConfigKeys = @(
        "search-root", "protected-branch", "ignored-directory"
    )

    $scalarConfigKeys = @(
        "default-remote", "large-file-threshold"
    )

    $repositories = @(Get-GPushCompletionRepositoryNames)

    function New-Result {
        param(
            [string[]]$Values,
            [string]$Label
        )

        $matches = @(
            $Values |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_) -and
                    (
                        [string]::IsNullOrWhiteSpace($prefix) -or
                        ([string]$_).StartsWith(
                            $prefix,
                            [System.StringComparison]::OrdinalIgnoreCase
                        )
                    )
                } |
                Sort-Object -Unique
        )

        return [PSCustomObject]@{
            Handle = $true
            Values = $matches
            Label = $Label
            Prefix = $prefix
            TokenStart = $tokenStart
            TokenLength = $tokenLength
            InsertLeadingSpace = $insertLeadingSpace
        }
    }

    if ($completed.Count -eq 0 -and
        -not [string]::IsNullOrWhiteSpace($prefix) -and
        $topLevel -contains $prefix.ToLowerInvariant()) {

        $completed = @($prefix.ToLowerInvariant())
        $prefix = ""
        $tokenStart = $Cursor
        $tokenEnd = $Cursor

        # Skip whitespace between the exact command and the next argument.
        while (
            $tokenEnd -lt $Line.Length -and
            [char]::IsWhiteSpace($Line[$tokenEnd])
        ) {
            $tokenEnd++
        }

        if ($tokenEnd -lt $Line.Length) {
            $tokenStart = $tokenEnd

            while (
                $tokenEnd -lt $Line.Length -and
                -not [char]::IsWhiteSpace($Line[$tokenEnd])
            ) {
                $tokenEnd++
            }

            $tokenLength = $tokenEnd - $tokenStart
            $insertLeadingSpace = $true
        }
        else {
            $tokenStart = $Cursor
            $tokenLength = 0
            $insertLeadingSpace = $true
        }
    }

    if ($completed.Count -eq 0) {
        return (New-Result -Values (@($topLevel) + @($repositories)) -Label "Commands / repositories")
    }

    $command = ([string]$completed[0]).ToLowerInvariant()
    $rest = @($completed | Select-Object -Skip 1)

    if (
        -not [string]::IsNullOrWhiteSpace($prefix) -and
        $actions.ContainsKey($command) -and
        @($actions[$command] | Where-Object {
            [string]::Equals(
                [string]$_,
                [string]$prefix,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }).Count -gt 0
    ) {
        $rest = @($rest) + @($prefix.ToLowerInvariant())
        $prefix = ""
        $tokenStart = $Cursor
        $tokenEnd = $Cursor

        # Move to the actual next token if one already exists to the right.
        while (
            $tokenEnd -lt $Line.Length -and
            [char]::IsWhiteSpace($Line[$tokenEnd])
        ) {
            $tokenEnd++
        }

        if ($tokenEnd -lt $Line.Length) {
            $tokenStart = $tokenEnd

            while (
                $tokenEnd -lt $Line.Length -and
                -not [char]::IsWhiteSpace($Line[$tokenEnd])
            ) {
                $tokenEnd++
            }

            $tokenLength = $tokenEnd - $tokenStart
            $insertLeadingSpace = $true
        }
        else {
            $tokenStart = $Cursor
            $tokenLength = 0
            $insertLeadingSpace = $true
        }
    }

    if ($command -eq "project") {
        if ($rest.Count -eq 0) {
            return (New-Result -Values $actions["project"] -Label "Actions")
        }

        if ($rest.Count -eq 1 -and
            ([string]$rest[0]).ToLowerInvariant() -in @(
                "info", "build", "test", "run", "open", "shell"
            )) {
            return (New-Result -Values $repositories -Label "Projects")
        }

        return (New-Result -Values @() -Label "Projects")
    }

    if ($command -eq "changes" -and $rest.Count -eq 0) {
        return (New-Result -Values $repositories -Label "Projects")
    }
    if ($command -eq "all" -and $rest.Count -eq 1 -and $rest[0] -eq "status") {
        return (New-Result -Values @("--json", "--dirty", "--ahead", "--behind") -Label "Filters")
    }
    if ($actions.ContainsKey($command)) {
        if ($rest.Count -eq 0) {
            return (New-Result -Values $actions[$command] -Label "Actions")
        }

        if ($rest.Count -eq 1 -and
            $command -in @("repo", "branch", "tag", "remote", "stash")) {
            return (New-Result -Values $repositories -Label "Projects")
        }
    }

    if ($command -eq "add" -and $rest.Count -eq 0) {
        return (New-Result -Values $allConfigKeys -Label "Configuration keys")
    }

    if ($command -eq "remove" -and $rest.Count -eq 0) {
        return (New-Result -Values $listConfigKeys -Label "Configuration keys")
    }

    if ($command -eq "set" -and $rest.Count -eq 0) {
        return (New-Result -Values $scalarConfigKeys -Label "Configuration keys")
    }

    if ($command -eq "reset" -and $rest.Count -eq 0) {
        return (New-Result -Values $allConfigKeys -Label "Configuration keys")
    }

    if ($command -eq "completion" -and $rest.Count -eq 1) {
        $completionAction = ([string]$rest[0]).ToLowerInvariant()

        if ($completionAction -in @("mode", "install")) {
            return (New-Result `
                -Values @("memory", "write", "auto", "off") `
                -Label "Completion modes")
        }
    }

    if ($command -eq "config") {
        if ($rest.Count -eq 0) {
            return (New-Result -Values $actions["config"] -Label "Config actions")
        }

        if ($rest.Count -eq 1) {
            switch (([string]$rest[0]).ToLowerInvariant()) {
                "add"    { return (New-Result -Values $allConfigKeys -Label "Configuration keys") }
                "remove" { return (New-Result -Values $listConfigKeys -Label "Configuration keys") }
                "set"    { return (New-Result -Values $scalarConfigKeys -Label "Configuration keys") }
                "reset"  { return (New-Result -Values $allConfigKeys -Label "Configuration keys") }
            }
        }
    }

    return (New-Result -Values @() -Label "")
}

$global:GPushCompletionCycle = $null

function global:Reset-GPushCompletionCycle {
    $global:GPushCompletionCycle = $null
}

function global:Try-GPushCompletionCycle {
    param(
        [string]$Line,
        [int]$Direction
    )

    $state = $global:GPushCompletionCycle
    if ($null -eq $state) {
        return $false
    }

    if (-not [string]::Equals(
        [string]$state.ExpectedLine,
        [string]$Line,
        [System.StringComparison]::Ordinal
    )) {
        Reset-GPushCompletionCycle
        return $false
    }

    $values = @($state.Values)
    if ($values.Count -eq 0) {
        Reset-GPushCompletionCycle
        return $false
    }

    $index = [int]$state.Index + $Direction
    if ($index -ge $values.Count) { $index = 0 }
    elseif ($index -lt 0) { $index = $values.Count - 1 }

    $replacement = [string]$values[$index]

    [Microsoft.PowerShell.PSConsoleReadLine]::Replace(
        [int]$state.TokenStart,
        [int]$state.CurrentLength,
        $replacement
    )

    $newLine = $Line.Remove(
        [int]$state.TokenStart,
        [int]$state.CurrentLength
    ).Insert(
        [int]$state.TokenStart,
        $replacement
    )

    $global:GPushCompletionCycle = [PSCustomObject]@{
        ExpectedLine = $newLine
        Values = $values
        Index = $index
        TokenStart = [int]$state.TokenStart
        CurrentLength = $replacement.Length
    }

    return $true
}

function global:Invoke-GPushTabCompletion {
    param(
        $Key,
        $Arg,
        [int]$Direction = 1
    )

    $line = ""
    $cursor = 0

    try {
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState(
            [ref]$line,
            [ref]$cursor
        )

        if ([string]::IsNullOrEmpty($line) -or
            $line -notmatch '^\s*gp(?:\s|$)') {
            Reset-GPushCompletionCycle
            if ($Direction -lt 0) {
                [Microsoft.PowerShell.PSConsoleReadLine]::TabCompletePrevious($Key, $Arg)
            }
            else {
                [Microsoft.PowerShell.PSConsoleReadLine]::TabCompleteNext($Key, $Arg)
            }
            return
        }

        if (Try-GPushCompletionCycle -Line $line -Direction $Direction) {
            return
        }

        $context = Get-GPushCompletionContext -Line $line -Cursor $cursor
    }
    catch {
        Reset-GPushCompletionCycle
        return
    }

    if (-not $context.Handle) {
        Reset-GPushCompletionCycle
        return
    }

    $values = @($context.Values)
    if ($values.Count -eq 0) {
        Reset-GPushCompletionCycle
        return
    }

    $leading = if (
        $context.InsertLeadingSpace -and
        [int]$context.TokenLength -eq 0
    ) {
        " "
    }
    else {
        ""
    }

    if ($values.Count -eq 1) {
        Reset-GPushCompletionCycle
        $replacement = $leading + [string]$values[0]
        [Microsoft.PowerShell.PSConsoleReadLine]::Replace(
            [int]$context.TokenStart,
            [int]$context.TokenLength,
            $replacement
        )
        return
    }

    $common = Get-GPushCompletionCommonPrefix -Values $values
    if ($common.Length -gt ([string]$context.Prefix).Length) {
        Reset-GPushCompletionCycle
        $replacement = $leading + $common
        [Microsoft.PowerShell.PSConsoleReadLine]::Replace(
            [int]$context.TokenStart,
            [int]$context.TokenLength,
            $replacement
        )
        return
    }

    # Multiple candidates with no longer common prefix:
    # cycle them directly in the current command line. Never print anything.
    $ordered = @($values | Sort-Object -Unique)
    $index = if ($Direction -lt 0) { $ordered.Count - 1 } else { 0 }
    $replacement = $leading + [string]$ordered[$index]

    [Microsoft.PowerShell.PSConsoleReadLine]::Replace(
        [int]$context.TokenStart,
        [int]$context.TokenLength,
        $replacement
    )

    $expectedLine = $line.Remove(
        [int]$context.TokenStart,
        [int]$context.TokenLength
    ).Insert(
        [int]$context.TokenStart,
        $replacement
    )

    $cycleValues = @($ordered | ForEach-Object { $leading + [string]$_ })

    $global:GPushCompletionCycle = [PSCustomObject]@{
        ExpectedLine = $expectedLine
        Values = $cycleValues
        Index = $index
        TokenStart = [int]$context.TokenStart
        CurrentLength = $replacement.Length
    }
}


function Get-GPushCompletionProfilePath {
    $profilePath = $PROFILE.CurrentUserCurrentHost

    if ([string]::IsNullOrWhiteSpace([string]$profilePath)) {
        $profilePath = $PROFILE
    }

    return [string]$profilePath
}

function Get-GPushCompletionProfileMode {
    $profilePath = Get-GPushCompletionProfilePath

    if (-not (Test-Path $profilePath)) {
        return $null
    }

    try {
        $content = Get-Content -Path $profilePath -Raw -ErrorAction Stop

        if ($content -match '(?m)^\s*# GPush-Completion-Mode:\s*(memory|write|auto|off)\s*$') {
            return $matches[1].ToLowerInvariant()
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-GPushCompletionSelectedMode {
    $runtimeRequested = [string]$global:GPushCompletionRequestedMode

    if ($runtimeRequested -in @("memory", "write", "auto", "off")) {
        return $runtimeRequested
    }

    $profileMode = Get-GPushCompletionProfileMode

    if ($profileMode -in @("write", "auto")) {
        return $profileMode
    }

    # Safe default: no disk/profile writes.
    return "memory"
}

function New-GPushCompletionProfileBlock {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("write", "auto")]
        [string]$Mode
    )

    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw "GPush cannot determine the current gp.ps1 path."
    }

    $escapedPath = $PSCommandPath.Replace("'", "''")

    return @"
# >>> GPush completion >>>
# GPush-Completion-Mode: $Mode
& '$escapedPath' completion bootstrap $Mode
# <<< GPush completion <<<
"@
}

function Set-GPushCompletionProfileMode {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("write", "auto")]
        [string]$Mode
    )

    $profilePath = Get-GPushCompletionProfilePath
    $profileDir = Split-Path $profilePath -Parent

    try {
        if (-not (Test-Path $profileDir)) {
            New-Item -ItemType Directory -Path $profileDir -Force -ErrorAction Stop | Out-Null
        }

        if (-not (Test-Path $profilePath)) {
            New-Item -ItemType File -Path $profilePath -Force -ErrorAction Stop | Out-Null
        }

        $profileText = Get-Content -Path $profilePath -Raw -ErrorAction SilentlyContinue
        if ($null -eq $profileText) {
            $profileText = ""
        }

        $block = New-GPushCompletionProfileBlock -Mode $Mode
        $pattern = '(?s)\r?\n?# >>> GPush completion >>>.*?# <<< GPush completion <<<\r?\n?'

        if ($profileText -match '# >>> GPush completion >>>') {
            $profileText = [regex]::Replace(
                $profileText,
                $pattern,
                "`r`n$block`r`n"
            )
        }
        else {
            if ($profileText.Length -gt 0 -and -not $profileText.EndsWith("`n")) {
                $profileText += "`r`n"
            }

            $profileText += "`r`n$block`r`n"
        }

        Set-Content `
            -Path $profilePath `
            -Value $profileText `
            -Encoding UTF8 `
            -ErrorAction Stop

        return $true
    }
    catch {
        $script:GPushCompletionProfileError = $_.Exception.Message
        return $false
    }
}

function Remove-GPushCompletionProfileBlock {
    $profilePath = Get-GPushCompletionProfilePath
    $script:GPushCompletionProfileError = $null

    if (-not (Test-Path $profilePath)) {
        return $true
    }

    try {
        $profileText = Get-Content -Path $profilePath -Raw -ErrorAction Stop

        if ($profileText -notmatch '# >>> GPush completion >>>') {
            return $true
        }

        $pattern = '(?s)\r?\n?# >>> GPush completion >>>.*?# <<< GPush completion <<<\r?\n?'
        $profileText = [regex]::Replace($profileText, $pattern, "`r`n")

        Set-Content `
            -Path $profilePath `
            -Value $profileText.TrimEnd() `
            -Encoding UTF8 `
            -ErrorAction Stop

        return $true
    }
    catch {
        $script:GPushCompletionProfileError = $_.Exception.Message
        return $false
    }
}

function Disable-GPushRuntimeCompletion {
    try {
        Set-PSReadLineKeyHandler -Key Tab -Function TabCompleteNext
        Set-PSReadLineKeyHandler -Key Shift+Tab -Function TabCompletePrevious
    }
    catch {
        # A missing PSReadLine API must not break normal GPush commands.
    }

    $global:GPushCompletionCycle = $null
    $global:GPushRuntimeCompletionVersion = $null
    $global:GPushRuntimeTabHandler = $null
    $global:GPushCompletionActiveMode = "off"

    return 0
}

function Enable-GPushRuntimeCompletion {
    param(
        [ValidateSet("memory", "write", "auto")]
        [string]$ActiveMode = "memory"
    )

    try {
        Set-PSReadLineKeyHandler `
            -Key Tab `
            -BriefDescription "GPushTabComplete" `
            -LongDescription "GPush in-line completion" `
            -ScriptBlock {
                param($key, $arg)
                Invoke-GPushTabCompletion $key $arg 1
            }

        Set-PSReadLineKeyHandler `
            -Key Shift+Tab `
            -BriefDescription "GPushTabCompletePrevious" `
            -LongDescription "GPush previous in-line completion" `
            -ScriptBlock {
                param($key, $arg)
                Invoke-GPushTabCompletion $key $arg -1
            }

        $global:GPushRuntimeCompletionVersion = $ScriptVersion
        $global:GPushRuntimeTabHandler = "GPushTabComplete"
        $global:GPushCompletionActiveMode = $ActiveMode
        return 0
    }
    catch {
        Write-Err "GPush could not activate PowerShell completion."
        Write-Dim $_.Exception.Message
        return 1
    }
}

function Install-GPushPowerShellCompletion {
    param(
        [ValidateSet("memory", "write", "auto", "off")]
        [string]$Mode
    )

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        $Mode = Get-GPushCompletionSelectedMode
    }

    $Mode = $Mode.ToLowerInvariant()
    $global:GPushCompletionRequestedMode = $Mode
    $script:GPushCompletionProfileError = $null

    switch ($Mode) {
        "memory" {
            $profileRemoved = Remove-GPushCompletionProfileBlock
            $result = Enable-GPushRuntimeCompletion -ActiveMode "memory"

            if ($result -ne 0) {
                return $result
            }

            Show-Banner
            Write-Section "PowerShell completion"
            Write-Ok "GPush Tab completion is active for this PowerShell session."
            Write-KeyValue "Selected mode" "memory"
            Write-KeyValue "Active mode" "memory"
            Write-KeyValue "Persistence" "None"
            Write-KeyValue "Default" "memory"

            if (-not $profileRemoved) {
                Write-Warn "A previous persistent profile block could not be removed."
                Write-Dim $script:GPushCompletionProfileError
            }

            Write-Host ""
            return 0
        }

        "write" {
            $profileWritten = Set-GPushCompletionProfileMode -Mode "write"
            $result = Enable-GPushRuntimeCompletion -ActiveMode $(if ($profileWritten) { "write" } else { "memory" })

            if ($result -ne 0) {
                return $result
            }

            Show-Banner
            Write-Section "PowerShell completion"
            Write-KeyValue "Selected mode" "write"
            Write-KeyValue "Active mode" $(if ($profileWritten) { "write" } else { "memory" })
            Write-KeyValue "Persistence" $(if ($profileWritten) { "PowerShell profile" } else { "Unavailable" })
            Write-KeyValue "Default" "memory"

            if ($profileWritten) {
                Write-Ok "Persistent completion was installed."
                Write-Dim "New PowerShell sessions will activate GPush completion automatically."
                Write-Host ""
                return 0
            }

            Write-Warn "Persistent profile write was blocked. Runtime completion remains active in memory."
            Write-Dim $script:GPushCompletionProfileError
            Write-Host ""
            return 1
        }

        "auto" {
            $profileWritten = Set-GPushCompletionProfileMode -Mode "auto"
            $activeMode = if ($profileWritten) { "auto" } else { "memory" }

            $result = Enable-GPushRuntimeCompletion -ActiveMode $activeMode
            if ($result -ne 0) {
                return $result
            }

            Show-Banner
            Write-Section "PowerShell completion"
            Write-KeyValue "Selected mode" "auto"
            Write-KeyValue "Active mode" $activeMode
            Write-KeyValue "Persistence" $(if ($profileWritten) { "PowerShell profile" } else { "Memory fallback" })
            Write-KeyValue "Default" "memory"

            if ($profileWritten) {
                Write-Ok "Auto mode selected. Persistent profile activation is available."
            }
            else {
                Write-Warn "Profile write was unavailable. Auto mode fell back to memory."
                Write-Dim $script:GPushCompletionProfileError
            }

            Write-Host ""
            return 0
        }

        "off" {
            $profileRemoved = Remove-GPushCompletionProfileBlock
            $null = Disable-GPushRuntimeCompletion

            Show-Banner
            Write-Section "PowerShell completion"
            Write-KeyValue "Selected mode" "off"
            Write-KeyValue "Active mode" "off"
            Write-KeyValue "Persistence" "Disabled"
            Write-KeyValue "Default" "memory"

            if ($profileRemoved) {
                Write-Ok "GPush completion is disabled."
            }
            else {
                Write-Warn "Runtime completion was disabled, but the persistent profile block could not be removed."
                Write-Dim $script:GPushCompletionProfileError
            }

            Write-Host ""
            return $(if ($profileRemoved) { 0 } else { 1 })
        }
    }
}

function Invoke-GPushCompletionBootstrap {
    param(
        [ValidateSet("write", "auto")]
        [string]$Mode
    )

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        $Mode = "write"
    }

    $global:GPushCompletionRequestedMode = $Mode
    return (Enable-GPushRuntimeCompletion -ActiveMode $Mode)
}

function Ensure-GPushPowerShellCompletion {
    param([switch]$Quiet)

    $selectedMode = Get-GPushCompletionSelectedMode

    if ($selectedMode -eq "off") {
        $null = Disable-GPushRuntimeCompletion
        return
    }

    $runtimeMatches = [string]::Equals(
        [string]$global:GPushRuntimeCompletionVersion,
        [string]$ScriptVersion,
        [System.StringComparison]::Ordinal
    )

    $handlerMatches = [string]::Equals(
        [string]$global:GPushRuntimeTabHandler,
        "GPushTabComplete",
        [System.StringComparison]::Ordinal
    )

    $functionAvailable = (
        $null -ne (Get-Command Invoke-GPushTabCompletion -CommandType Function -ErrorAction SilentlyContinue)
    )

    if ($runtimeMatches -and $handlerMatches -and $functionAvailable) {
        return
    }

    $activeMode = if ($selectedMode -in @("write", "auto")) {
        $selectedMode
    }
    else {
        "memory"
    }

    $result = Enable-GPushRuntimeCompletion -ActiveMode $activeMode

    if (-not $Quiet -and $result -eq 0) {
        Write-Dim "GPush runtime completion activated ($activeMode)."
    }
}

function Remove-GPushPowerShellCompletion {
    $global:GPushCompletionRequestedMode = "off"
    $profileRemoved = Remove-GPushCompletionProfileBlock
    $null = Disable-GPushRuntimeCompletion

    Show-Banner
    Write-Section "PowerShell completion"
    Write-KeyValue "Active mode" "off"
    Write-KeyValue "Profile block" $(if ($profileRemoved) { "Removed" } else { "Could not remove" })

    if (-not $profileRemoved) {
        Write-Warn "The persistent profile block could not be removed."
        Write-Dim $script:GPushCompletionProfileError
    }
    else {
        Write-Ok "GPush completion was removed."
    }

    Write-Host ""
    return $(if ($profileRemoved) { 0 } else { 1 })
}

function Show-GPushCompletionMode {
    $selectedMode = Get-GPushCompletionSelectedMode
    $activeMode = [string]$global:GPushCompletionActiveMode

    if ([string]::IsNullOrWhiteSpace($activeMode)) {
        $activeMode = "not active"
    }

    Show-Banner
    Write-Section "PowerShell completion mode"
    Write-KeyValue "Selected" $selectedMode
    Write-KeyValue "Active" $activeMode
    Write-KeyValue "Default" "memory"
    Write-KeyValue "Available" "memory | write | auto | off"
    Write-Host ""

    return 0
}

function Show-GPushCompletionStatus {
    $gpCommand = Get-Command gp -ErrorAction SilentlyContinue
    $completionFunction = Get-Command Invoke-GPushTabCompletion `
        -CommandType Function `
        -ErrorAction SilentlyContinue

    $selectedMode = Get-GPushCompletionSelectedMode
    $activeMode = [string]$global:GPushCompletionActiveMode
    $profileMode = Get-GPushCompletionProfileMode
    $profilePath = Get-GPushCompletionProfilePath

    if ([string]::IsNullOrWhiteSpace($activeMode)) {
        $activeMode = "not active"
    }

    $runtimeMatches = [string]::Equals(
        [string]$global:GPushRuntimeCompletionVersion,
        [string]$ScriptVersion,
        [System.StringComparison]::Ordinal
    )

    $handlerMatches = [string]::Equals(
        [string]$global:GPushRuntimeTabHandler,
        "GPushTabComplete",
        [System.StringComparison]::Ordinal
    )

    $functionAvailable = $null -ne $completionFunction

    $healthy = if ($selectedMode -eq "off") {
        -not $handlerMatches
    }
    else {
        $runtimeMatches -and $handlerMatches -and $functionAvailable
    }

    Show-Banner
    Write-Section "PowerShell completion"
    Write-KeyValue "Health" $(if ($healthy) { "OK" } else { "Needs attention" }) `
        $(if ($healthy) { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow })

    Write-Section "Mode"
    Write-KeyValue "Selected" $selectedMode
    Write-KeyValue "Active" $activeMode
    Write-KeyValue "Default" "memory"
    Write-KeyValue "Profile mode" $(if ($profileMode) { $profileMode } else { "-" })

    Write-Section "Runtime"
    Write-KeyValue "PowerShell" $PSVersionTable.PSVersion.ToString()
    Write-KeyValue "Edition" ([string]$PSVersionTable.PSEdition)
    Write-KeyValue "Process" ([string]$PID)

    Write-Section "Binding"
    Write-KeyValue "gp type" $(if ($null -ne $gpCommand) { [string]$gpCommand.CommandType } else { "Missing" })
    Write-KeyValue "Tab" $(if ($handlerMatches) { "GPushTabComplete" } else { "Default PowerShell" })
    Write-KeyValue "Handler fn" $(if ($functionAvailable) { "Available" } else { "Missing" })
    Write-KeyValue "Behavior" "Inline cycle"
    Write-KeyValue "Shift+Tab" $(if ($handlerMatches) { "Previous candidate" } else { "Default PowerShell" })
    Write-KeyValue "Console output" "Disabled"
    Write-KeyValue "Runtime" $(if ($runtimeMatches) { $ScriptVersion } else { "-" })

    Write-Section "Persistence"
    Write-KeyValue "Profile" $profilePath ([ConsoleColor]::DarkGray)
    Write-KeyValue "Profile block" $(if ($profileMode) { "Installed" } else { "Not installed" })
    Write-KeyValue "Profile writes" $(switch ($selectedMode) {
        "write" { "Required" }
        "auto" { "Try + fallback" }
        default { "Disabled" }
    })
    Write-KeyValue "Completion file" "Not used"

    Write-Section "Data"
    Write-KeyValue "Config" $ConfigFile ([ConsoleColor]::DarkGray)
    Write-KeyValue "Cache" $CacheFile ([ConsoleColor]::DarkGray)

    if (-not $healthy -and $selectedMode -ne "off") {
        Write-Host ""
        Write-Dim "Repair current session: gp completion install"
    }

    Write-Host ""
    return 0
}

function Invoke-GPushCompletionCommand {
    param([object[]]$Arguments)

    $argsList = @($Arguments)
    $action = if ($argsList.Count -gt 0) {
        ([string]$argsList[0]).ToLowerInvariant()
    }
    else {
        "status"
    }

    switch ($action) {
        "install" {
            if ($argsList.Count -gt 2) {
                Write-Err "Use: gp completion install [memory|write|auto|off]"
                return 2
            }

            $mode = if ($argsList.Count -eq 2) {
                ([string]$argsList[1]).ToLowerInvariant()
            }
            else {
                Get-GPushCompletionSelectedMode
            }

            if ($mode -notin @("memory", "write", "auto", "off")) {
                Write-Err "Unknown completion mode: $mode"
                Write-Dim "Use: memory | write | auto | off"
                return 2
            }

            return (Install-GPushPowerShellCompletion -Mode $mode)
        }

        "status" {
            if ($argsList.Count -ne 1) {
                Write-Err "Command 'gp completion status' does not accept additional arguments."
                return 2
            }

            return (Show-GPushCompletionStatus)
        }

        "mode" {
            if ($argsList.Count -eq 1) {
                return (Show-GPushCompletionMode)
            }

            if ($argsList.Count -ne 2) {
                Write-Err "Use: gp completion mode [memory|write|auto|off]"
                return 2
            }

            $mode = ([string]$argsList[1]).ToLowerInvariant()

            if ($mode -notin @("memory", "write", "auto", "off")) {
                Write-Err "Unknown completion mode: $mode"
                Write-Dim "Use: memory | write | auto | off"
                return 2
            }

            return (Install-GPushPowerShellCompletion -Mode $mode)
        }

        "bootstrap" {
            if ($argsList.Count -ne 2) {
                return 2
            }

            $mode = ([string]$argsList[1]).ToLowerInvariant()

            if ($mode -notin @("write", "auto")) {
                return 2
            }

            return (Invoke-GPushCompletionBootstrap -Mode $mode)
        }

        "uninstall" {
            if ($argsList.Count -ne 1) {
                Write-Err "Command 'gp completion uninstall' does not accept additional arguments."
                return 2
            }

            return (Remove-GPushPowerShellCompletion)
        }

        default {
            Write-Err "Unknown completion command: $action"

            $knownActions = @("install", "status", "mode", "uninstall")
            $best = $null
            $bestDistance = [int]::MaxValue

            foreach ($candidate in $knownActions) {
                $distance = Get-GPushEditDistance -Left $action -Right $candidate

                if ($distance -lt $bestDistance) {
                    $bestDistance = $distance
                    $best = $candidate
                }
            }

            if ($bestDistance -le 2) {
                Write-Dim "Did you mean: gp completion $best"
            }

            Write-Dim "Use: gp completion install [mode] | status | mode [mode] | uninstall"
            return 2
        }
    }
}


function Get-GPushEditDistance {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Left,
        [Parameter(Mandatory = $true)]
        [string]$Right
    )

    $a = $Left.ToLowerInvariant()
    $b = $Right.ToLowerInvariant()

    $previous = New-Object 'int[]' ($b.Length + 1)
    $current = New-Object 'int[]' ($b.Length + 1)

    for ($j = 0; $j -le $b.Length; $j++) {
        $previous[$j] = $j
    }

    for ($i = 1; $i -le $a.Length; $i++) {
        $current[0] = $i

        for ($j = 1; $j -le $b.Length; $j++) {
            $cost = if ($a[$i - 1] -eq $b[$j - 1]) { 0 } else { 1 }
            $delete = $previous[$j] + 1
            $insert = $current[$j - 1] + 1
            $replace = $previous[$j - 1] + $cost
            $current[$j] = [Math]::Min([Math]::Min($delete, $insert), $replace)
        }

        $tmp = $previous
        $previous = $current
        $current = $tmp
    }

    return $previous[$b.Length]
}

function Get-GPushCommandSuggestion {
    param([Parameter(Mandatory = $true)][string]$Value)

    $normalized = $Value.Trim().ToLowerInvariant()

    $special = @{
        "tags" = "gp tag list [project]"
        "branches" = "gp branch list [project]"
        "remotes" = "gp remote list [project]"
        "aliases" = "gp alias list"
        "completition" = "gp completion install"
        "competion" = "gp completion install"
    }

    if ($special.ContainsKey($normalized)) {
        return $special[$normalized]
    }

    $commands = @(
        "overview", "health", "stats", "history", "watch", "changes", "detail", "commit", "diff", "branches", "menu", "activity", "settings", "github", "repo", "branch", "tag", "remote", "stash", "cache", "config",
        "alias", "favorite", "favorites", "fav", "all", "project",
        "clone", "recent", "update", "completion", "help", "version",
        "add", "remove", "set", "reset"
    )

    $best = $null
    $bestDistance = [int]::MaxValue

    foreach ($candidate in $commands) {
        $distance = Get-GPushEditDistance -Left $normalized -Right $candidate

        if ($distance -lt $bestDistance) {
            $bestDistance = $distance
            $best = $candidate
        }
    }

    $maxDistance = if ($normalized.Length -le 4) { 1 } else { 2 }

    if ($bestDistance -gt $maxDistance) {
        return $null
    }

    if ($best -eq "completion") {
        return "gp completion install"
    }

    return "gp $best ..."
}

function Test-GPushKnownRepositoryToken {
    param([Parameter(Mandatory = $true)][string]$Value)

    $resolved = Resolve-GPushAlias -Search $Value

    if (Test-Path $resolved -PathType Container) {
        return $true
    }

    if (-not (Test-Path $CacheFile)) {
        return $false
    }

    try {
        $repos = @(Read-GPushRepositoryCacheEarly)

        return @(
            $repos |
                Where-Object {
                    $_.Name -ieq $resolved -or
                    $_.Name -ilike "$resolved*" -or
                    $_.Path -ilike "*$resolved*"
                }
        ).Count -gt 0
    }
    catch {
        return $false
    }
}


# ============================================================
# V4 COMMAND ROUTER
# ============================================================

function ConvertFrom-GPushSubcommand {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
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
    # Always keep the remainder as a real array. PowerShell may unwrap
    # a single value returned from an if-expression into a scalar string;
    # indexing that scalar would turn e.g. "list" into the character "l".
    $rest = @($inputArgs | Select-Object -Skip 1)

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
            $tail = @($rest | Select-Object -Skip 1)

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
            $tail = @($rest | Select-Object -Skip 1)

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
            $tail = @($rest | Select-Object -Skip 1)

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
            $tail = @($rest | Select-Object -Skip 1)

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
            $tail = @($rest | Select-Object -Skip 1)

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
            $tail = @($rest | Select-Object -Skip 1)

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
            $tail = @($rest | Select-Object -Skip 1)

            switch ($action) {
                "show" {
                    if ($tail.Count -gt 0) {
                        Write-Err "Command 'gp config show' does not accept arguments."
                        exit 2
                    }
                    return @("--config")
                }
                "path" {
                    if ($tail.Count -gt 0) {
                        Write-Err "Command 'gp config path' does not accept arguments."
                        exit 2
                    }
                    return @("--config-path")
                }
                "doctor" {
                    if ($tail.Count -gt 0) {
                        Write-Err "Command 'gp config doctor' does not accept arguments."
                        exit 2
                    }
                    return @("--doctor")
                }
                { $_ -in @("add", "remove", "set") } {
                    if ($tail.Count -ne 2) {
                        Write-Err "Command 'gp config $action' requires a key and a value."
                        Write-GPushConfigEditUsage
                        exit 2
                    }

                    $exitCode = Invoke-GPushConfigEdit `
                        -Action $action `
                        -Key ([string]$tail[0]) `
                        -Value ([string]$tail[1])
                    exit $exitCode
                }
                "reset" {
                    if ($tail.Count -ne 1) {
                        Write-Err "Command 'gp config reset' requires exactly one key."
                        Write-GPushConfigEditUsage
                        exit 2
                    }

                    $exitCode = Invoke-GPushConfigEdit `
                        -Action $action `
                        -Key ([string]$tail[0])
                    exit $exitCode
                }
                default {
                    Write-Err "Unknown config command: $action"
                    Write-Dim "Use: gp config show|path|doctor|add|remove|set|reset ..."
                    exit 2
                }
            }
        }

        "alias" {
            if ($rest.Count -eq 0) {
                return @("--aliases")
            }

            $action = ([string]$rest[0]).ToLowerInvariant()
            $tail = @($rest | Select-Object -Skip 1)

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

        { $_ -in @("favorite", "favorites", "fav") } {
            if ($rest.Count -eq 0) {
                return @("--favorites")
            }

            $action = ([string]$rest[0]).ToLowerInvariant()
            $tail = @($rest | Select-Object -Skip 1)

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

        "project" {
            if ($rest.Count -eq 0) {
                return @("--project", "info")
            }

            $action = ([string]$rest[0]).ToLowerInvariant()
            $tail = @($rest | Select-Object -Skip 1)

            if ($action -notin @("info", "build", "test", "run", "open", "shell")) {
                Write-Err "Unknown project action: $action"
                Write-Dim "Use: gp project info|build|test|run|open|shell [project]"
                exit 2
            }

            if ($tail.Count -gt 1) {
                Write-Err "Project command accepts at most one project name/path."
                Write-Dim "Use: gp project $action [project]"
                exit 2
            }

            return Join-GPushArgs @("--project", $action) $tail
        }

        "all" {
            if ($rest.Count -eq 0 -or ([string]$rest[0]).StartsWith("-")) {
                return Join-GPushArgs @("--all", "--sync", "--cached") $rest
            }
            $action = ([string]$rest[0]).ToLowerInvariant()
            $tail = @($rest | Select-Object -Skip 1)
            switch ($action) {
                "status" { return Join-GPushArgs @("--all", "--status", "--cached") $tail }
                "fetch"  { return Join-GPushArgs @("--all", "--fetch", "--cached") $tail }
                "sync"   { return Join-GPushArgs @("--all", "--sync", "--cached") $tail }
                "push"   { return Join-GPushArgs @("--all", "--bulk-push", "--cached") $tail }
                default {
                    Write-Err "Unknown all command: $action"
                    Write-Dim 'Use: gp all [status|fetch|sync|push]'
                    exit 2
                }
            }
        }

        { $_ -in @("add", "remove", "set") } {
            if ($rest.Count -ne 2) {
                Write-Err "Command 'gp $command' requires a configuration key and a value."
                Write-GPushConfigEditUsage
                exit 2
            }

            $exitCode = Invoke-GPushConfigEdit `
                -Action $command `
                -Key ([string]$rest[0]) `
                -Value ([string]$rest[1])
            exit $exitCode
        }

        "reset" {
            if ($rest.Count -ne 1) {
                Write-Err "Command 'gp reset' requires exactly one configuration key."
                Write-GPushConfigEditUsage
                exit 2
            }

            $exitCode = Invoke-GPushConfigEdit `
                -Action "reset" `
                -Key ([string]$rest[0])
            exit $exitCode
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

        "update" {
            return Join-GPushArgs @("--update") $rest
        }

        "completion" {
            $exitCode = Invoke-GPushCompletionCommand -Arguments $rest
            exit $exitCode
        }

        "help" {
            if ($rest.Count -gt 0) {
                Write-Err "Command 'gp help' does not accept arguments."
                exit 2
            }
            return @("--help")
        }

        "version" {
            if ($rest.Count -gt 0) {
                Write-Err "Command 'gp version' does not accept arguments."
                exit 2
            }
            return @("--version")
        }

        default {
            # Keep the classic shortcut:
            #   gp Project "commit message"
            #
            # But if the first token looks like a typo of a known GPush command
            # and does not resolve to a known repository, fail early with a useful hint.
            if (-not (Test-GPushKnownRepositoryToken -Value $first)) {
                $suggestion = Get-GPushCommandSuggestion -Value $first

                if (-not [string]::IsNullOrWhiteSpace($suggestion)) {
                    Write-Err "Unknown command: $first"
                    Write-Dim "Did you mean: $suggestion"

                    if ($command -in @("tags", "branches", "remotes", "aliases")) {
                        Write-Dim "Legacy flags must start with '--'."
                    }

                    exit 2
                }
            }

            return $inputArgs
        }
    }
}

# ============================================================
# ARGUMENT PARSING
# ============================================================

# Load and normalize config before any command is evaluated. This also
# upgrades older config.json files in memory with newly introduced fields
# such as aliases and favorites while preserving existing user settings.
Initialize-GPushConfig

# PowerShell completion is self-installing/self-repairing.
# Default mode is memory-only. Persistent modes are opt-in via
# `gp completion mode write|auto`.
# Explicit `gp completion ...` commands manage their own completion state and
# must not trigger the automatic bootstrap before the command is evaluated.
# Memory completion is the safe default and activates automatically on the
# first GPush invocation in each PowerShell session. Users do NOT need to run
# `gp completion install memory`.
#
# Only completion commands that intentionally MODIFY the completion mode/state
# skip the automatic bootstrap. Read-only commands such as
# `gp completion status` and `gp completion mode` still activate the default
# memory mode before reporting their state.
$completionAction = if (
    $RawArguments.Count -ge 2 -and
    [string]::Equals(
        [string]$RawArguments[0],
        "completion",
        [System.StringComparison]::OrdinalIgnoreCase
    )
) {
    ([string]$RawArguments[1]).ToLowerInvariant()
}
else {
    ""
}

$skipCompletionBootstrap = (
    $RawArguments.Count -ge 1 -and
    [string]::Equals(
        [string]$RawArguments[0],
        "completion",
        [System.StringComparison]::OrdinalIgnoreCase
    ) -and
    (
        $completionAction -in @("install", "uninstall", "bootstrap") -or
        (
            $completionAction -eq "mode" -and
            $RawArguments.Count -ge 3
        )
    )
)

if (-not $skipCompletionBootstrap -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
    $null = Ensure-GPushPowerShellCompletion -Quiet
}

$VisualMode = ''
$VisualTail = @()
if ($RawArguments.Count -eq 0) { $VisualMode = 'menu' }
if ($RawArguments.Count -gt 0) {
    if ($RawArguments[0] -in @('overview','health','stats','history','watch','changes','detail','commit','diff','branches','menu','activity','settings','github')) {
        $VisualMode = [string]$RawArguments[0]; $VisualTail = @($RawArguments | Select-Object -Skip 1)
    } elseif ($RawArguments.Count -ge 2 -and $RawArguments[0] -eq 'branch' -and $RawArguments[1] -eq 'graph') {
        $VisualMode = 'graph'; $VisualTail = @($RawArguments | Select-Object -Skip 2)
    } elseif ($RawArguments.Count -eq 2 -and $RawArguments[0] -eq 'all' -and $RawArguments[1] -eq 'dry-run') {
        $VisualMode = 'dry-run'
    } elseif ($RawArguments.Count -eq 3 -and $RawArguments[0] -eq 'all' -and $RawArguments[1] -eq 'status' -and $RawArguments[2] -in @('--json','--dirty','--ahead','--behind')) {
        $VisualMode = [string]$RawArguments[2]
    }
}
if ($VisualMode) { $RawArguments = @('--all','--status','--cached') }
$tokens = @(if ($RawArguments.Count -gt 0) {
    ConvertFrom-GPushSubcommand -Arguments $RawArguments
})

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
$ProjectMode = $false
$UpdateMode = $false
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
$BulkPush = $false
$BulkCommitMessage = ""

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
            "--bulk-push" { $BulkPush = $true }
            "--aliases"       { $AliasesOnly = $true }
            "--alias-set"     { $AliasSet = $true }
            "--alias-remove"  { $AliasRemove = $true }
            "--favorite"      { $FavoriteAdd = $true }
            "--unfavorite"    { $FavoriteRemove = $true }
            "--favorites"     { $FavoritesOnly = $true }
            "--recent"        { $RecentOnly = $true }
            "--open"          { $OpenRepo = $true }
            "--clone"         { $CloneRepo = $true }
            "--project"       { $ProjectMode = $true }
            "--update"        { $UpdateMode = $true }
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
    $BulkPush -or
    $ListRepos -or $Refresh -or $AddRepo -or $AllRepos -or
    $AliasesOnly -or $AliasSet -or $AliasRemove -or $FavoriteAdd -or $FavoriteRemove -or
    $FavoritesOnly -or $RecentOnly -or $OpenRepo -or $CloneRepo -or $ProjectMode -or $UpdateMode -or
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

if ($AllRepos -and ($ProjectMode -or $UpdateMode)) {
    Write-Err "Bulk operations cannot be combined with project or update mode."
    exit 2
}

if ($ProjectMode -and $UpdateMode) {
    Write-Err "Options --project and --update cannot be used together."
    exit 2
}

if ($ProjectMode) {
    if ($positionals.Count -lt 1 -or $positionals.Count -gt 2) {
        Write-Err "Project mode requires an action and optionally one project."
        Write-Dim "Use: gp --project <info|build|test|run|open|shell> [project]"
        exit 2
    }

    $projectArgs = @($positionals)
    $exitCode = Invoke-GPushProjectCommand -Arguments $projectArgs
    exit $exitCode
}

if ($UpdateMode) {
    if ($positionals.Count -gt 1) {
        Write-Err "Update mode accepts at most one action."
        Write-Dim "Use: gp --update [check|install|rollback]"
        exit 2
    }

    $updateArgs = @($positionals)
    $exitCode = Invoke-GPushUpdateCommand -Arguments $updateArgs
    exit $exitCode
}

if ($BulkPush -and -not $AllRepos) {
    Write-Err "--bulk-push requires --all."
    exit 2
}

if ($AllRepos) {
    if (@(@($StatusOnly, $FetchOnly, $SyncOnly, $BulkPush) | Where-Object { $_ }).Count -gt 1 -or $ProjectMode -or $UpdateMode) {
        Write-Err "Choose only one bulk operation."
        exit 2
    }
    if ($BulkPush) {
        $BulkCommitMessage = ($positionals -join " ").Trim()
        if ([string]::IsNullOrWhiteSpace($BulkCommitMessage)) {
            Write-Err 'Use: gp all push "Commit message"'
            exit 2
        }
        $positionals = @()
    }
    elseif ($positionals.Count -gt 0) {
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

    $verb = $Arguments[0]
    if ($verb -eq '--literal-pathspecs' -and $Arguments.Count -gt 1) { $verb = $Arguments[1] }
    if ($script:GPushInteractiveWorkspace -and $verb -in @('fetch','push','pull','merge','commit','add','clone','switch','checkout','stash')) {
        $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $captureResult = Invoke-GPushNativeCapture -Executable $gitCommand.Source -ArgumentVector $Arguments -GitOperation
        $output = @(foreach ($stream in @($captureResult.Stdout,$captureResult.Stderr)) { if ($stream.Length) { $stream.TrimEnd([char[]]"`r`n") -split "`r?`n" } })
        $exitCode = $captureResult.ExitCode
        $global:LASTEXITCODE = $exitCode
    } else {
        $output = & git @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }

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

    $unstaged = Get-GitOutput -Arguments @("-c", "core.quotePath=false", "diff", "--name-only", "--diff-filter=ACMRTUXB") -AllowFailure
    if ($unstaged.Success) {
        $paths += @($unstaged.Lines)
    }

    $staged = Get-GitOutput -Arguments @("-c", "core.quotePath=false", "diff", "--cached", "--name-only", "--diff-filter=ACMRTUXB") -AllowFailure
    if ($staged.Success) {
        $paths += @($staged.Lines)
    }

    $untracked = Get-GitOutput -Arguments @("-c", "core.quotePath=false", "ls-files", "--others", "--exclude-standard") -AllowFailure
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

        # Flatten nested arrays from older/broken cache versions.
        if ($entry -is [System.Array]) {
            $normalized += @(ConvertTo-RepositoryList -InputObject $entry)
            continue
        }

        if ($null -eq $entry.PSObject.Properties['Name'] -or
            $null -eq $entry.PSObject.Properties['Path']) {
            continue
        }

        $names = @($entry.Name)
        $paths = @($entry.Path)

        # Windows PowerShell 5.1 can sometimes surface JSON/cache data as one
        # object whose Name and Path properties are arrays. Normalize that
        # shape back into one repository object per Name/Path pair.
        if ($names.Count -gt 1 -or $paths.Count -gt 1) {
            if ($names.Count -ne $paths.Count) {
                continue
            }

            for ($i = 0; $i -lt $names.Count; $i++) {
                $name = [string]$names[$i]
                $path = [string]$paths[$i]

                if (-not [string]::IsNullOrWhiteSpace($name) -and
                    -not [string]::IsNullOrWhiteSpace($path)) {
                    $normalized += [PSCustomObject]@{
                        Name = $name
                        Path = $path
                    }
                }
            }

            continue
        }

        $name = [string]$entry.Name
        $path = [string]$entry.Path

        if (-not [string]::IsNullOrWhiteSpace($name) -and
            -not [string]::IsNullOrWhiteSpace($path)) {
            $normalized += [PSCustomObject]@{
                Name = $name
                Path = $path
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
                (Test-Path -LiteralPath $_.Path) -and
                (Test-Path -LiteralPath (Join-Path $_.Path ".git"))
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
    param($Repos, [string]$Search)
    if ([string]::IsNullOrWhiteSpace($Search)) { return @() }
    $Search = Resolve-GPushAlias -Search $Search
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    $repoMatches = @($Repos | Where-Object { [string]::Equals([string]$_.Path, $Search, $comparison) })
    if ($repoMatches.Count) { return $repoMatches }
    $repoMatches = @($Repos | Where-Object { [string]::Equals([string]$_.Name, $Search, $comparison) })
    if ($repoMatches.Count) { return $repoMatches }
    $repoMatches = @($Repos | Where-Object { ([string]$_.Name).StartsWith($Search, $comparison) })
    if ($repoMatches.Count) { return $repoMatches }
    $repoMatches = @($Repos | Where-Object { ([string]$_.Name).IndexOf($Search, $comparison) -ge 0 })
    if ($repoMatches.Count) { return $repoMatches }
    return @($Repos | Where-Object { ([string]$_.Path).IndexOf($Search, $comparison) -ge 0 })
}

function Select-Repository {
    param(
        $Repos,
        [string]$Search,
        [switch]$QuietNotFound
    )

    if ([string]::IsNullOrWhiteSpace($Search)) {
        $repoList = @(ConvertTo-RepositoryList -InputObject $Repos)
        $favoriteQuick = @()
        $recentQuick = @()
        $favoritePaths = @{}

        # Favorites are persistent and user-curated. Keep them in their own
        # section so the quick picker stays predictable between runs.
        foreach ($favoritePath in @($FavoriteRepositories)) {
            if ([string]::IsNullOrWhiteSpace([string]$favoritePath)) { continue }

            $match = $repoList | Where-Object {
                [string]::Equals([string]$_.Path, [string]$favoritePath, [System.StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1

            if ($null -ne $match) {
                $key = ([System.IO.Path]::GetFullPath([string]$match.Path)).ToLowerInvariant()
                $favoritePaths[$key] = $true
                $favoriteQuick += $match
            }
        }

        # Recent is intentionally limited to five entries. Repositories already
        # pinned as favorites are omitted here to avoid duplicate menu entries.
        foreach ($recent in @(Get-GPushRecentRepositories)) {
            if ($recentQuick.Count -ge 5) { break }

            $match = $repoList | Where-Object {
                [string]::Equals([string]$_.Path, [string]$recent.Path, [System.StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1

            if ($null -ne $match) {
                $key = ([System.IO.Path]::GetFullPath([string]$match.Path)).ToLowerInvariant()
                if (-not $favoritePaths.ContainsKey($key)) {
                    $recentQuick += $match
                }
            }
        }

        $quickRepos = @()
        foreach ($item in $recentQuick) {
            $quickRepos += [PSCustomObject]@{ Repository = $item; Source = "recent" }
        }
        foreach ($item in $favoriteQuick) {
            $quickRepos += [PSCustomObject]@{ Repository = $item; Source = "favorite" }
        }

        if ($quickRepos.Count -gt 0) {
            Write-Host ""
            Write-Host "Quick repositories" -ForegroundColor Cyan
            Write-Dim "  Choose a number, or type any repository name/search."

            $number = 1

            if ($recentQuick.Count -gt 0) {
                Write-Host ""
                Write-Host "  Recent" -ForegroundColor Yellow
                foreach ($item in $recentQuick) {
                    Write-Host ("  [{0}] " -f $number) -NoNewline -ForegroundColor DarkGray
                    Write-Host $item.Name -ForegroundColor White
                    Write-Dim ("      " + $item.Path)
                    $number++
                }
            }

            if ($favoriteQuick.Count -gt 0) {
                Write-Host ""
                Write-Host "  Favorites" -ForegroundColor Magenta
                foreach ($item in $favoriteQuick) {
                    Write-Host ("  [{0}] " -f $number) -NoNewline -ForegroundColor DarkGray
                    Write-Host $item.Name -ForegroundColor White
                    Write-Dim ("      " + $item.Path)
                    $number++
                }
            }

            Write-Host ""
            Write-Dim "  Manage favorites: gp favorite add|remove|list <project>"
            $selection = Read-Host "Project / number"
            $selectedNumber = 0

            if ([int]::TryParse($selection, [ref]$selectedNumber) -and
                $selectedNumber -ge 1 -and $selectedNumber -le $quickRepos.Count) {
                return $quickRepos[$selectedNumber - 1].Repository
            }

            if ([string]::IsNullOrWhiteSpace($selection)) {
                Write-Err "No project selected."
                return $null
            }

            $Search = $selection.Trim()
        }
        else {
            $Search = Read-Host "Project"
            if ([string]::IsNullOrWhiteSpace($Search)) {
                Write-Err "No project selected."
                return $null
            }
        }
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

    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        Write-Err 'Ambiguous repository. Specify the exact path.'
        return $null
    }
    $labels = @($repoMatches | ForEach-Object { "$($_.Name)  |  $($_.Path)" })
    $picked = @(Select-GPushWorkspaceRows -Title 'Select repository' -Rows $labels)
    if ($picked.Count) { return $repoMatches[$picked[0]] }
    return $null

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
        LastCommit = "-"
        Compared = $false
        Ahead = 0
        Behind = 0
        Sync = "Unknown"
        FetchOk = $true
        Valid = $true
        Detached = $false
        RemoteBranchExists = $false
    }

    Push-Location -LiteralPath $Repository.Path -ErrorAction Stop
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

        $commitResult = Get-GitOutput -Arguments @("log", "-1", "--format=%s") -AllowFailure
        if ($commitResult.Success -and $commitResult.Text.Trim()) {
            $snapshot.LastCommit = $commitResult.Text.Trim()
        }

        $statusResult = Get-GitOutput -Arguments @("status", "--short", "--untracked-files=all") -AllowFailure
        if ($statusResult.Success) {
            $changed = @($statusResult.Lines | Where-Object { $_ -ne $null })
            $snapshot.DirtyCount = $changed.Count
            $snapshot.Worktree = if ($changed.Count -eq 0) { "clean" } else { "dirty ($($changed.Count))" }
        }
        else {
            $snapshot.Worktree = "unknown"
        }

        $remote = Get-GPushRemoteForCurrentRepository
        if (-not $snapshot.Detached) {
            $tracking = Get-GitOutput -Arguments @("config", "--get", "branch.$($snapshot.Branch).remote") -AllowFailure
            if ($tracking.Success) {
                if ($tracking.Text.Trim() -eq ".") {
                    $snapshot.Sync = "Unsupported local upstream"
                    return [PSCustomObject]$snapshot
                }
                $remote = $tracking.Text.Trim()
            }
        }
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
            $configuredMerge = Get-GitOutput -Arguments @("config", "--get", "branch.$($snapshot.Branch).merge") -AllowFailure
            if ($configuredMerge.Success -and $configuredMerge.Text.Trim()) {
                $snapshot.Sync = "Missing upstream"
                return [PSCustomObject]$snapshot
            }
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

            if (-not $countResult.Success -or $parts.Count -lt 2) {
                return [PSCustomObject]$snapshot
            }
            $snapshot.Compared = $true
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

    $commitText = Limit-GPushTableText -Text ([string]$Snapshot.LastCommit) -Width 34
    $behindText = if ($Snapshot.Compared) { [string]$Snapshot.Behind } else { "-" }
    $aheadText = if ($Snapshot.Compared) { [string]$Snapshot.Ahead } else { "-" }
    $repoText = Limit-GPushTableText -Text ([string]$Snapshot.Repository) -Width 20
    $branchText = Limit-GPushTableText -Text ([string]$Snapshot.Branch) -Width 18
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

    Write-Host ("  {0,-20} {1,-18} " -f $repoText, $branchText) -NoNewline -ForegroundColor White
    Write-Host ("{0,-34} " -f $commitText) -NoNewline -ForegroundColor Gray
    Write-Host ("{0,6} | {1,-5} " -f $behindText, $aheadText) -NoNewline -ForegroundColor $syncColor
    Write-Host ("{0,-12} " -f $worktreeText) -NoNewline -ForegroundColor $worktreeColor
    Write-Host ("{0,-23} " -f $syncText) -NoNewline -ForegroundColor $syncColor
    Write-Host $resultText -ForegroundColor $resultColor
}

function Invoke-GPushAllSync {
    param(
        [Parameter(Mandatory = $true)]
        $Repository,
        [switch]$AllowProtectedBranches,
        [string]$CommitMessage = "",
        [switch]$PushOnly
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

    if ($state.Worktree -eq "unknown" -or $state.Sync -in @("Unknown", "Missing upstream", "Unsupported local upstream")) {
        return [PSCustomObject]@{ Snapshot = $state; Result = "FAIL unknown state" }
    }

    if ($PushOnly -and $state.Behind -gt 0) {
        return [PSCustomObject]@{ Snapshot = $state; Result = "SKIP behind; synchronize first" }
    }

    if ($state.DirtyCount -gt 0 -and -not $CommitMessage -and -not $PushOnly) {
        return [PSCustomObject]@{ Snapshot = $state; Result = "SKIP dirty" }
    }

    if ($state.Ahead -gt 0 -and $state.Behind -gt 0) {
        return [PSCustomObject]@{ Snapshot = $state; Result = "MANUAL diverged" }
    }

    $requiresPush = (
        $state.Ahead -gt 0 -or ($state.DirtyCount -gt 0 -and -not $PushOnly) -or
        $state.Sync -eq "New remote branch"
    )

    if ($requiresPush -and
        ((Test-ProtectedBranch -Branch $state.Branch) -or
         ($state.Upstream -ne "-" -and (Test-ProtectedBranch -Branch (($state.Upstream -replace ("^" + [regex]::Escape($state.Remote) + "/"), "") -replace " \(not tracking\)$", "")))) -and
        -not $AllowProtectedBranches) {
        return [PSCustomObject]@{ Snapshot = $state; Result = "PROTECTED skip" }
    }

    Push-Location -LiteralPath $Repository.Path -ErrorAction Stop
    try {
        foreach ($marker in @("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer", "BISECT_START")) {
            $markerPath = Get-GitPath $marker
            if (-not $markerPath -or (Test-Path -LiteralPath $markerPath)) {
                return [PSCustomObject]@{ Snapshot = $state; Result = "SKIP git operation" }
            }
        }
        $conflicts = Get-GitOutput -Arguments @("diff", "--name-only", "--diff-filter=U") -AllowFailure
        if (-not $conflicts.Success -or $conflicts.Text.Trim()) {
            return [PSCustomObject]@{ Snapshot = $state; Result = "SKIP conflicts" }
        }
        if ($state.DirtyCount -gt 0 -and -not $PushOnly) {
            if ($state.Behind -gt 0) {
                return [PSCustomObject]@{ Snapshot = $state; Result = "MANUAL dirty/behind" }
            }
            $risk = Get-RiskyFiles
            if ($risk.Sensitive.Count -gt 0 -or $risk.Large.Count -gt 0) {
                return [PSCustomObject]@{ Snapshot = $state; Result = "SKIP risky files" }
            }
            $add = Get-GitOutput -Arguments @("add", "-A") -AllowFailure
            if (-not $add.Success) {
                return [PSCustomObject]@{ Snapshot = $state; Result = "FAIL add" }
            }
            $commit = Get-GitOutput -Arguments @("commit", "-m", $CommitMessage) -AllowFailure
            if (-not $commit.Success) {
                return [PSCustomObject]@{ Snapshot = $state; Result = "FAIL commit" }
            }
            $state = Get-GPushRepositorySnapshot -Repository $Repository
            if ($state.Worktree -ne "clean" -or $state.Sync -eq "Unknown") {
                return [PSCustomObject]@{ Snapshot = $state; Result = "SKIP after commit" }
            }
        }

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
                $merge = Get-GitOutput -Arguments @("config", "--get", "branch.$($state.Branch).merge") -AllowFailure
                if (-not $merge.Success -or $merge.Text.Trim() -notmatch '^refs/heads/') {
                    return [PSCustomObject]@{ Snapshot = $state; Result = "FAIL upstream" }
                }
                @("push", $state.Remote, "HEAD:$($merge.Text.Trim())")
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
        [ValidateSet("status", "fetch", "sync", "push")]
        [string]$Mode = "status",
        [switch]$AllowProtectedBranches,
        [string]$CommitMessage = ""
    )

    Write-Section "All repositories"

    if ($Mode -eq "status") {
        Write-Dim "  Dashboard uses local/cached remote refs. Use 'gp --all --fetch' for fresh remote state."
    }
    elseif ($Mode -eq "fetch") {
        Write-Dim "  Fetching every repository before displaying status."
    }
    elseif ($Mode -eq "push") {
        Write-Warn "  Bulk commit and sync: risky, conflicting and diverged repositories are skipped."
    }
    else {
        Write-Warn "  Safe bulk sync: dirty/diverged repositories are skipped; no automatic rebase is performed."
    }

    Write-Host ""
    Write-Host ("  {0,-20} {1,-18} {2,-34} {3,6} | {4,-5} {5,-12} {6,-23} {7}" -f "Repository", "Branch", "Last commit", "Behind", "Ahead", "Worktree", "Sync", "Result") -ForegroundColor DarkGray
    Write-Host ("  {0}" -f ("-" * 140)) -ForegroundColor DarkGray

    $bulkTimer = [Diagnostics.Stopwatch]::StartNew()
    $total = 0
    $clean = 0
    $dirty = 0
    $issues = 0
    $changed = 0

    foreach ($repository in @($Repositories | Sort-Object Name, Path)) {
        $total++

        try {
        if ($Mode -in @("sync", "push")) {
            $syncResult = Invoke-GPushAllSync -Repository $repository -AllowProtectedBranches:$AllowProtectedBranches -CommitMessage $CommitMessage
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
                if (-not $state.Valid) { "FAIL invalid repo" } elseif ($state.Remote -eq "-") { "SKIP no remote" } elseif ($state.FetchOk) { "OK fetched" } else { "FAIL fetch" }
            }
            else {
                ""
            }

            if (-not $state.Valid -or -not $state.FetchOk -or $state.Detached -or
                $state.Sync -in @("No remote", "Unknown", "Missing upstream", "Unsupported local upstream") -or $state.Worktree -eq "unknown" -or
                ($state.Ahead -gt 0 -and $state.Behind -gt 0)) {
                $issues++
            }
        }

        }
        catch {
            if ($_.Exception -is [OperationCanceledException]) { throw }
            $issues++
            Write-Err "  $($repository.Name): $($_.Exception.Message)"
            continue
        }

        if ($state.DirtyCount -gt 0) {
            $dirty++
        }
        elseif ($state.Worktree -eq "clean") {
            $clean++
        }

        Write-GPushAllRow -Snapshot $state -Result $result
        if ($Mode -in @('sync','push')) {
            Show-GPushVisualBar -Done $total -Total @($Repositories).Count
            Write-Dim ("  Elapsed: {0:F1}s" -f $bulkTimer.Elapsed.TotalSeconds)
            try { Add-Content -LiteralPath (Join-Path $ConfigDir 'history.log') -Value ("{0:o} {1} {2} {3}" -f (Get-Date),$Mode,$result,$repository.Path) -ErrorAction Stop } catch { Write-Dim 'History unavailable.' }
        }
    }

    Write-Separator
    Write-KeyValue "Repositories" ([string]$total)
    Write-KeyValue "Clean" ([string]$clean) ([ConsoleColor]::Green)
    Write-KeyValue "Dirty" ([string]$dirty) $(if ($dirty -gt 0) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green })

    if ($Mode -in @("sync", "push")) {
        Write-KeyValue "Changed" ([string]$changed) $(if ($changed -gt 0) { [ConsoleColor]::Green } else { [ConsoleColor]::DarkGray })
    }

    Write-KeyValue "Attention" ([string]$issues) $(if ($issues -gt 0) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green })
    Write-Host ""
    return $(if ($issues -gt 0) { 1 } else { 0 })
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
        Write-Dim "  Add one with: gp favorite add <project>"
    }
    else {
        $cachedFavorites = @(Get-GPushCache)

        foreach ($favorite in $FavoriteRepositories) {
            $matchedFavorite = $cachedFavorites | Where-Object {
                [string]::Equals([string]$_.Path, [string]$favorite, [System.StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1

            $favoriteName = if ($null -ne $matchedFavorite) {
                [string]$matchedFavorite.Name
            }
            else {
                Split-Path ([string]$favorite) -Leaf
            }

            Write-Host ("  {0,-28}" -f $favoriteName) -NoNewline -ForegroundColor White
            Write-Host $favorite -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Dim "  Add:     gp favorite add <project>"
    Write-Dim "  Remove:  gp favorite remove <project>"
    Write-Dim "  Shortcut: gp fav ..."
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

if (-not $AllRepos -and $UtilityMode -and [string]::IsNullOrWhiteSpace($Project)) {
    $currentRepo = & git rev-parse --show-toplevel 2>$null

    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($currentRepo)) {
        $DirectRepositoryPath = $currentRepo.Trim()
    }
}

# ============================================================
# LOAD REPOSITORIES
# ============================================================

function Get-GPushVisualSnapshots {
    foreach ($repository in @(Get-GPushCache | Sort-Object Name, Path)) {
        try { Get-GPushRepositorySnapshot -Repository $repository }
        catch { Write-Warning "Cannot inspect $($repository.Name): $($_.Exception.Message)" }
    }
}

function Show-GPushVisualStatus {
    param([string]$Mode)
    $states = @(Get-GPushVisualSnapshots)
    if ($Mode -eq '--json') {
        $rows = @($states | ForEach-Object {
            [PSCustomObject]@{ repository=$_.Repository; branch=$_.Branch; lastCommit=$_.LastCommit; behind=$(if ($_.Compared) {$_.Behind} else {$null}); ahead=$(if ($_.Compared) {$_.Ahead} else {$null}); dirtyCount=$_.DirtyCount; sync=$_.Sync; path=$_.Path }
        })
        ConvertTo-Json -InputObject $rows -Depth 4
        return
    }
    $compact = $false
    if (-not [Console]::IsOutputRedirected) { try { $compact = [Console]::WindowWidth -lt 120 } catch {} }
    if ($compact) { Write-Host ('{0,-16} {1,-12} {2,-20} {3,5} | {4,-5} {5}' -f 'Repository','Branch','Last commit','Behind','Ahead','Worktree') }
    else { Write-Host ('{0,-20} {1,-18} {2,-34} {3,6} | {4,-5} {5,-12} {6}' -f 'Repository','Branch','Last commit','Behind','Ahead','Worktree','Sync') }
    foreach ($state in $states) {
        if ($Mode -eq '--dirty' -and $state.DirtyCount -eq 0) { continue }
        if ($Mode -eq '--ahead' -and (-not $state.Compared -or $state.Ahead -eq 0)) { continue }
        if ($Mode -eq '--behind' -and (-not $state.Compared -or $state.Behind -eq 0)) { continue }
        if ($compact) {
            $behind = if ($state.Compared) { $state.Behind } else { '-' }
            $ahead = if ($state.Compared) { $state.Ahead } else { '-' }
            Write-Host ('{0,-16} {1,-12} {2,-20} {3,5} | {4,-5} {5}' -f (Limit-GPushTableText -Text $state.Repository -Width 16),(Limit-GPushTableText -Text $state.Branch -Width 12),(Limit-GPushTableText -Text $state.LastCommit -Width 20),$behind,$ahead,$state.Worktree)
        } else { Write-GPushAllRow -Snapshot $state }
        if ($Mode -eq 'dry-run') {
            $plan = if ($state.Worktree -ne 'clean') {'SKIP dirty or unknown'} elseif (-not $state.Compared) {'CHECK upstream'} elseif ($state.Ahead -gt 0 -and $state.Behind -gt 0) {'SKIP diverged'} elseif ($state.Ahead -gt 0) {'PUSH candidate (subject to protection)'} elseif ($state.Behind -gt 0) {'FAST-FORWARD candidate'} else {'No action'}
            Write-Dim "  $plan"
        }
    }
    if ($Mode -in @('overview','health')) {
        $clean = @($states | Where-Object { $_.Sync -eq 'Up to date' -and $_.Worktree -eq 'clean' }).Count
        Write-Section 'Clean and synchronized'
        Show-GPushVisualBar -Done $clean -Total $states.Count
    }
}

# Porcelain v2 combines branch, upstream, divergence and worktree in one local call.
function Get-GPushOverviewLocalState {
    param($Repository)
    $state = [ordered]@{ Repository=$Repository.Name; Path=$Repository.Path; Branch='-'; LastCommit='-'; Compared=$false; Ahead=0; Behind=0; DirtyCount=0; Worktree='unknown'; Sync='Inspection failed' }
    $status = Get-GitOutput -Arguments @('-C', $Repository.Path, '--no-optional-locks', 'status', '--porcelain=v2', '--branch', '--untracked-files=all') -AllowFailure
    if (-not $status.Success) { return [PSCustomObject]$state }
    $upstream = $null
    $unborn = $false
    foreach ($line in $status.Lines) {
        $line = [string]$line
        if ($line -match '^# branch\.head (.*)$') { $state.Branch = $Matches[1] }
        elseif ($line -match '^# branch\.oid \(initial\)$') { $unborn = $true }
        elseif ($line -match '^# branch\.upstream (.*)$') { $upstream = $Matches[1] }
        elseif ($line -match '^# branch\.ab \+(\d+) -(\d+)$') {
            $state.Ahead = [int]$Matches[1]; $state.Behind = [int]$Matches[2]; $state.Compared = $true
        }
        elseif ($line -match '^[12u?] ') { $state.DirtyCount++ }
    }
    $state.Worktree = if ($state.DirtyCount -eq 0) { 'clean' } else { "dirty ($($state.DirtyCount))" }
    if (-not $unborn) {
        $commit = Get-GitOutput -Arguments @('-C', $Repository.Path, 'log', '-1', '--format=%s') -AllowFailure
        if ($commit.Success) { $state.LastCommit = $commit.Text.Trim() }
    }
    $state.Sync = if ($unborn) { 'No commits' } elseif ($state.Branch -eq '(detached)') { 'Detached HEAD' } elseif (-not $upstream) { 'No tracking upstream' } elseif (-not $state.Compared) { 'Unknown upstream status' } elseif ($state.Ahead -eq 0 -and $state.Behind -eq 0) { 'Up to date' } else { "$($state.Ahead) ahead / $($state.Behind) behind" }
    return [PSCustomObject]$state
}

# Overview snapshots are loaded only on startup or an explicit action.
function Save-GPushWorkspaceSnapshot {
    param([object[]]$States)
    $file=Join-Path $CacheDir 'workspace-status.json'
    $temp="$file.$PID.tmp"
    try {
        $States | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temp -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $temp -Destination $file -Force -ErrorAction Stop
    } catch { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}
function Get-GPushSavedWorkspaceSnapshot {
    param([object[]]$Repositories)
    try {
        $rows=@(Get-Content -LiteralPath (Join-Path $CacheDir 'workspace-status.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
        if ($rows.Count -ne $Repositories.Count) { return }
        for ($i=0; $i -lt $rows.Count; $i++) { if ($rows[$i].Path -ne $Repositories[$i].Path) { return } }
        return $rows
    } catch { return }
}
function Get-GPushOverviewStates {
    param([object[]]$Repositories, [switch]$Fetch, [switch]$UseCache)
    if ($UseCache -and -not $Fetch) {
        $saved=@(Get-GPushSavedWorkspaceSnapshot $Repositories)
        if ($saved.Count -eq $Repositories.Count -and $saved.Count) { return $saved }
    }
    $ProgressPreference='Continue'
    $activity=if ($Fetch) {'Fetching repositories'} else {'Refreshing local repository status'}
    $states=New-Object 'System.Collections.Generic.List[object]'
    $git=(Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $interactive=-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
    $previous=$false; $jobs=@(); $completed=0
    try {
        if ($interactive) { $previous=[Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput=$true }
        if ($interactive) { Write-Progress -Id 42 -Activity $activity -Status 'Starting local inspection' -PercentComplete 0 }
        for ($i=0; $i -lt $Repositories.Count; $i+=4) {
            $jobs=@()
            for ($j=$i; $j -lt [Math]::Min($i+4,$Repositories.Count); $j++) {
                $repo=$Repositories[$j]
                if ($Fetch) {
                    $states.Add((Get-GPushRepositorySnapshot -Repository $repo -Fetch)); $completed++
                    if ($interactive) { Write-Progress -Id 42 -Activity $activity -Status "$completed / $($Repositories.Count)" -PercentComplete ([int](100*$completed/$Repositories.Count)) }
                    continue
                }
                $state=[PSCustomObject]@{Repository=$repo.Name;Path=$repo.Path;Branch='-';LastCommit='-';Compared=$false;Ahead=0;Behind=0;DirtyCount=0;Worktree='unknown';Sync='Inspection failed'}
                $states.Add($state)
                $status=$null; $log=$null
                try {
                    $status=Start-GPushNativeCapture -Executable $git -ArgumentVector @('-C',[string]$repo.Path,'--no-optional-locks','status','--porcelain=v2','--branch','--untracked-files=all')
                    $log=Start-GPushNativeCapture -Executable $git -ArgumentVector @('-C',[string]$repo.Path,'log','-1','--format=%s')
                    $jobs+= [PSCustomObject]@{State=$state;Status=$status;Log=$log;Done=$false}
                } catch { Stop-GPushNativeCapture $status; Stop-GPushNativeCapture $log; $completed++ }
            }
            while (@($jobs | Where-Object {-not $_.Done}).Count) {
                if ($interactive -and (Test-GPushOperationCancelled)) { throw [OperationCanceledException]::new('Operation cancelled by user.') }
                if ($interactive) { Write-Progress -Id 42 -Activity $activity -Status "$completed / $($Repositories.Count) repositories" -PercentComplete ([int](100*$completed/[Math]::Max(1,$Repositories.Count))) -CurrentOperation 'Ctrl+C: cancel' }
                foreach ($job in $jobs) {
                    if ($job.Done -or -not $job.Status.Process.HasExited -or -not $job.Log.Process.HasExited -or -not $job.Status.OutputTask.IsCompleted -or -not $job.Log.OutputTask.IsCompleted) { continue }
                    $st=$job.State; $unborn=$false; $upstream=$false
                    if ($job.Status.Process.ExitCode -eq 0) {
                        foreach ($line in ($job.Status.OutputTask.GetAwaiter().GetResult() -split "`r?`n")) {
                            if ($line -match '^# branch\.head (.*)$') {$st.Branch=$Matches[1]}
                            elseif ($line -match '^# branch\.oid \(initial\)$') {$unborn=$true}
                            elseif ($line -match '^# branch\.upstream ') {$upstream=$true}
                            elseif ($line -match '^# branch\.ab \+(\d+) -(\d+)$') {$st.Ahead=[int]$Matches[1];$st.Behind=[int]$Matches[2];$st.Compared=$true}
                            elseif ($line -match '^[12u?] ') {$st.DirtyCount++}
                        }
                        $st.Worktree=if ($st.DirtyCount) {"dirty ($($st.DirtyCount))"} else {'clean'}
                        $st.Sync=if ($unborn) {'No commits'} elseif ($st.Branch -eq '(detached)') {'Detached HEAD'} elseif (-not $upstream) {'No tracking upstream'} elseif (-not $st.Compared) {'Unknown upstream status'} elseif ($st.Ahead -eq 0 -and $st.Behind -eq 0) {'Up to date'} else {"$($st.Ahead) ahead / $($st.Behind) behind"}
                        if ($job.Log.Process.ExitCode -eq 0) {$st.LastCommit=$job.Log.OutputTask.GetAwaiter().GetResult().Trim()}
                    }
                    $job.Done=$true; $completed++; Stop-GPushNativeCapture $job.Status; Stop-GPushNativeCapture $job.Log
                }
                if (@($jobs | Where-Object {-not $_.Done}).Count) {Start-Sleep -Milliseconds 40}
            }
        }
    } finally {
        foreach ($job in $jobs) {if (-not $job.Done) {Stop-GPushNativeCapture $job.Status; Stop-GPushNativeCapture $job.Log}}
        if ($interactive) {Write-Progress -Id 42 -Activity $activity -Completed; [Console]::TreatControlCAsInput=$previous}
    }
    return $states.ToArray()
}
function Show-GPushHealthScreen {
    $repos=@(Get-GPushCache | Sort-Object Name,Path)
    if (-not $repos.Count) {Write-Warn 'No cached repositories.';return}
    $states=@(Get-GPushOverviewStates -Repositories $repos -UseCache)
    Save-GPushWorkspaceSnapshot $states
    while ($true) {
        $issues=@($states | Where-Object {$_.Sync -ne 'Up to date' -or $_.Worktree -ne 'clean'})
        $clean=$states.Count-$issues.Count
        $labels=@(foreach ($issue in $issues) {"$($issue.Repository)  |  $($issue.Sync) / $($issue.Worktree)"}) + @('Refresh local status','Back')
        $choice=@(Select-GPushWorkspaceRows -Title "Workspace health / $clean of $($states.Count) synchronized" -Rows $labels)
        if (-not $choice.Count -or $choice[0] -eq $issues.Count+1) {return}
        if ($choice[0] -eq $issues.Count) {Clear-Host;$states=@(Get-GPushOverviewStates -Repositories $repos)}
        else {
            $path=$issues[$choice[0]].Path
            for ($i=0;$i -lt $repos.Count;$i++) {if ($repos[$i].Path -eq $path) {Show-GPushMenuRepository $repos[$i] | Out-Host; $states[$i]=Get-GPushOverviewLocalState $repos[$i];break}}
        }
        Save-GPushWorkspaceSnapshot $states
    }
}

function Show-GPushOverviewFrame {
    param([object[]]$States, [int]$Selected)
    Clear-Host
    Write-Info "  GPUSH / $ScriptVersion"
    $width = 100; $height = 25
    try { $width = [Console]::WindowWidth; $height = [Console]::WindowHeight } catch {}
    $page = [Math]::Max(1, $height - 12)
    $first = [Math]::Max(0, [Math]::Min($Selected - [int][Math]::Floor($page / 2), $States.Count - $page))
    $last = [Math]::Min($States.Count, $first + $page)
    $clean = @($States | Where-Object { $_.Sync -eq 'Up to date' -and $_.Worktree -eq 'clean' }).Count
    Write-Info ("Workspace overview | {0} repositories | {1} clean and synchronized" -f $States.Count, $clean)
    Write-Dim 'Saved local snapshot | R refresh | F/A fetch remote references'
    $rw = [Math]::Max(8, [Math]::Min(24, [int]($width / 4)))
    $bw = [Math]::Max(8, [Math]::Min(18, [int]($width / 6)))
    $cw = [Math]::Max(8, $width - $rw - $bw - 32)
    $format = "{0} {1,-$rw} {2,-$bw} {3,-$cw} {4,6} | {5,-5} {6}"
    Write-Dim ($format -f ' ', 'Repository', 'Branch', 'Last commit', 'Behind', 'Ahead', 'Worktree')
    for ($i=$first; $i -lt $last; $i++) {
        $state = $States[$i]
        $behind = if ($state.Compared) { $state.Behind } else { '-' }
        $ahead = if ($state.Compared) { $state.Ahead } else { '-' }
        $marker = if ($i -eq $Selected) { '>' } else { ' ' }
        $line = $format -f $marker, (Limit-GPushTableText $state.Repository $rw), (Limit-GPushTableText $state.Branch $bw), (Limit-GPushTableText $state.LastCommit $cw), $behind, $ahead, $state.Worktree
        $line = Limit-GPushTableText $line ([Math]::Max(1, $width-1))
        if ($i -eq $Selected) { Write-Host $line -ForegroundColor White -BackgroundColor DarkCyan }
        elseif ($state.Sync -eq 'Up to date' -and $state.Worktree -eq 'clean') { Write-Ok $line }
        else { Write-Host $line -ForegroundColor Yellow }
    }
    Write-Dim ("{0}/{1} | {2}" -f ($Selected+1), $States.Count, $States[$Selected].Sync)
    Write-Dim '[Up/Down] Select  [Enter] Repository menu  [F] Fetch  [A] Fetch all'
    Write-Dim '[R] Refresh local  [S] Sync  [Q] Quit'
}

# Workspace screens share the existing Git safety and configuration helpers.
function Write-GPushWorkspaceHistory {
    param([string]$Action,[string]$Path)
    try { Add-Content -LiteralPath (Join-Path $ConfigDir 'history.log') -Value ('{0} {1} {2}' -f (Get-Date -Format o),$Action,$Path) -Encoding UTF8 -ErrorAction Stop } catch { Write-Dim 'History unavailable.' }
}
# Read control keys only while waiting for UI input; restore console mode before Git runs.
function Read-GPushWorkspaceKey {
    $previous = [Console]::TreatControlCAsInput
    try {
        [Console]::TreatControlCAsInput = $true
        while ($true) {
            $key = [Console]::ReadKey($true)
            if ($key.KeyChar -ne [char]3) { return $key }
            Write-Host ''
            Write-Warn 'Exit GPush?'
            Write-Host '[Y, Enter, Ctrl+C] - Yes' -ForegroundColor Green -NoNewline
            Write-Host '    |   ' -ForegroundColor DarkGray -NoNewline
            Write-Host '[N, ESC] - No' -ForegroundColor Red
            do { $answer = [Console]::ReadKey($true) } until ($answer.KeyChar -eq [char]3 -or $answer.Key -in @('Y','Enter','N','Escape'))
            if ($answer.KeyChar -eq [char]3 -or $answer.Key -in @('Y','Enter')) { exit 130 }
            # Return a harmless key to redraw the calling screen after cancellation.
            return [ConsoleKeyInfo]::new([char]0,[ConsoleKey]::F24,$false,$false,$false)
        }
    } finally { [Console]::TreatControlCAsInput = $previous }
}
function Wait-GPushWorkspace {
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return }
    Write-Host ''
    Write-Dim 'Esc  Back    Ctrl+C  Exit'
    while ((Read-GPushWorkspaceKey).Key -ne 'Escape') { }
}
# Shared keyboard picker; all rows are cached for the lifetime of the screen.
function Select-GPushWorkspaceRows {
    param([string]$Title, [string[]]$Rows, [switch]$Multiple, [scriptblock]$TestKeyReader)
    if ($Rows.Count -eq 0) { return }
    if (-not $TestKeyReader -and ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)) { Write-Warn 'Interactive selection requires a terminal.'; return }
    $selected = 0; $query = ''; $marks = @{}
    $firstFrame = $true
    $previousFrameCount = 0
    $previousWidth = 0
    $previousHeight = 0
    $frameTop = 0
    $descriptions = @('Browse cached repository status','Commit, push and manage projects','Sync or fetch multiple repositories','Find, add and refresh projects','Commits and development activity','Inspect synchronization health','Review recent GPush operations','Configure remotes and safety rules','Check, install or roll back updates','View classic command syntax','Return to your terminal')
    while ($true) {
        $visible = @(for ($i=0; $i -lt $Rows.Count; $i++) {
            if ($Rows[$i].IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $i }
        })
        if ($selected -ge $visible.Count) { $selected = 0 }
        if (-not $TestKeyReader) {
            $width = [Math]::Max(1,[Math]::Min(110,[Console]::WindowWidth-1))
            $contentWidth = [Math]::Max(1,$width-4)
            $repoColumn = 0
            if ($Title -eq 'Select repository') {
                foreach ($row in $Rows) {
                    $repoColumn = [Math]::Max($repoColumn, (($row -split '  \|  ',2)[0]).Length)
                }
                $repoColumn = [Math]::Min([Math]::Max(10,$repoColumn),[Math]::Max(10,[int]($contentWidth*0.35)))
            }
            $limit = [Math]::Max(1,[Console]::WindowHeight-13)
            $start = [int]([Math]::Floor($selected / $limit) * $limit)
            $rule = [string][char]0x2500 * $width
            if ($firstFrame -or $previousWidth -ne [Console]::WindowWidth -or $previousHeight -ne [Console]::WindowHeight) {
                Clear-Host; $firstFrame=$false; $previousFrameCount=0
                $previousWidth=[Console]::WindowWidth; $previousHeight=[Console]::WindowHeight
                $frameTop=[Console]::CursorTop
            }
            else { try { [Console]::SetCursorPosition(0,$frameTop) } catch { Clear-Host; $frameTop=[Console]::CursorTop; $previousFrameCount=0 } }
            $frame = New-Object 'System.Collections.Generic.List[object]'
            $frame.Add(@{Text="  GPUSH  /  $ScriptVersion"; Color='Cyan'})
            $screenTitle = if ($Title.EndsWith(' / Main menu')) { 'Interactive workspace' } else { $Title }
            $frame.Add(@{Text=('  '+($screenTitle -replace '[\x00-\x1f\x7f]','?')); Color='White'})
            $frame.Add(@{Text=$rule; Color='DarkGray'})
            $filterText = if ($query) { $query } else { 'type to search' }
            $frame.Add(@{Text="  FILTER  $filterText    |    $($visible.Count) / $($Rows.Count)"; Color='DarkGray'})
            if ($repoColumn -gt 0) { $frame.Add(@{Text=('    '+('Repository'.PadRight($repoColumn))+'  |  Path');Color='DarkGray'}) } else { $frame.Add(@{Text='';Color='White'}) }
            for ($i=$start; $i -lt [Math]::Min($start+$limit,$visible.Count); $i++) {
                $index=$visible[$i]
                $mark=if ($Multiple) { if ($marks[$index]) {'[x] '} else {'[ ] '} } else {''}
                $rowText=$Rows[$index]
                if ($repoColumn -gt 0) {
                    $parts=$rowText -split '  \|  ',2
                    if ($parts.Count -eq 2) { $rowText=(Limit-GPushTableText $parts[0] $repoColumn).PadRight($repoColumn)+'  |  '+$parts[1] }
                }
                $line=$mark+($rowText -replace '[\x00-\x1f\x7f]','?')
                if ($Title.EndsWith(' / Main menu') -and $width -ge 76) {
                    $line=('{0,-34} {1}' -f (Limit-GPushTableText $line 34),$descriptions[$index])
                }
                $line=Limit-GPushTableText $line $contentWidth
                if ($i -eq $selected) { $frame.Add(@{Text=('  > '+$line);Color='Black';Selected=$true}) }
                else { $frame.Add(@{Text=('    '+$line);Color='White'}) }
            }
            if (-not $visible.Count) { $frame.Add(@{Text='  No matching items.';Color='Yellow'}) }
            $frame.Add(@{Text='';Color='White'})
            $frame.Add(@{Text=$rule;Color='DarkGray'})
            $positionText=if ($visible.Count) { "  POSITION  $($selected+1) / $($visible.Count)" } else { '  No matches' }
            if ($Multiple) { $positionText += "    |    MARKED  $(@($marks.Values | Where-Object { $_ }).Count)" }
            $frame.Add(@{Text=$positionText;Color='Cyan'})
            $frame.Add(@{Text='  Up/Down Navigate  Enter Select  Esc Back  Ctrl+C Exit';Color='DarkGray'})
            $hint=if ($Multiple) {'  Space Mark  A All visible  X Clear  / Search  Enter Confirm'} else {'  Type to filter    Backspace  Clear character'}
            $frame.Add(@{Text=$hint;Color='DarkGray'})
            $paintWidth=$width
            foreach ($entry in $frame) {
                $text=(Limit-GPushTableText $entry.Text $width).PadRight($paintWidth)
                if ($entry.Selected) { Write-Host $text -ForegroundColor Black -BackgroundColor Cyan }
                else { Write-Host $text -ForegroundColor $entry.Color }
            }
            # Erase rows left behind by a shorter filtered list without clearing the screen.
            if ($null -ne $previousFrameCount) {
                for ($j=$frame.Count; $j -lt $previousFrameCount; $j++) { Write-Host (' ' * $paintWidth) }
            }
            $previousFrameCount=$frame.Count
        }
        $key = if ($TestKeyReader) { & $TestKeyReader } else { (Read-GPushWorkspaceKey) }
        if ($null -eq $key) { return }
        switch ($key.Key) {
            Escape { return }
            UpArrow { if ($visible.Count) { $selected = ($selected + $visible.Count - 1) % $visible.Count } }
            DownArrow { if ($visible.Count) { $selected = ($selected + 1) % $visible.Count } }
            Spacebar { if ($Multiple) { if ($visible.Count) { $index=$visible[$selected]; $marks[$index] = -not $marks[$index] } } else { $query+=' '; $selected=0 } }
            A { if ($Multiple) { foreach ($index in $visible) { $marks[$index]=$true } } else { $query+=$key.KeyChar; $selected=0 } }
            X { if ($Multiple) { $marks=@{} } else { $query+=$key.KeyChar; $selected=0 } }
            Backspace { if ($query.Length) { $query=$query.Substring(0,$query.Length-1); $selected=0 } }
            Enter {
                if ($Multiple) {
                    $chosen = @(for ($i=0; $i -lt $Rows.Count; $i++) { if ($marks[$i]) { $i } })
                    if ($chosen.Count) { return $chosen }
                    if ($visible.Count) { return $visible[$selected] }
                } elseif ($visible.Count) { return $visible[$selected] }
            }
            default { if ($key.KeyChar -eq '/') { $query=[string](Read-Host 'Search (empty resets)'); $selected=0; $firstFrame=$true } elseif (-not $Multiple -and -not [char]::IsControl($key.KeyChar)) { $query+=$key.KeyChar; $selected=0 } }
        }
    }
}
function Show-GPushWorkspaceLines {
    param([string]$Title,[string[]]$Lines)
    $offset=0
    while ($true) {
        $page=[Math]::Max(1,[Console]::WindowHeight-8)
        $last=[Math]::Min($offset+$page,$Lines.Count)
        Clear-Host; Write-Section $Title
        for ($i=$offset; $i -lt $last; $i++) { Write-Host $Lines[$i] }
        Write-Dim "Lines $($offset+1)-$last / $($Lines.Count) | Up/Down: scroll | Esc: back"
        switch ((Read-GPushWorkspaceKey).Key) {
            Escape { return }

            UpArrow { if ($offset -gt 0) { $offset-- } }
            DownArrow { if ($offset+$page -lt $Lines.Count) { $offset++ } }
        }
    }
}
# Read exact Git filenames, not display-quoted names or newline-separated text.
function Get-GPushWorkspacePaths {
    param([string]$Path, [ValidateSet('staged','tracked','untracked')][string]$Mode)
    $arguments = switch ($Mode) {
        'staged' { 'diff --cached --no-renames --name-only -z --' }
        'tracked' { 'diff --no-renames --name-only -z --' }
        'untracked' { 'ls-files --others --exclude-standard -z' }
    }
    $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $git.Source
    $info.Arguments = $arguments
    $info.WorkingDirectory = $Path
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Cannot start Git.' }
        $errorTask = $process.StandardError.ReadToEndAsync()
        $raw = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Cannot inspect ${Mode} files: $errorText" }
        foreach ($file in $raw.Split([char]0)) { if ($file.Length -gt 0) { $file } }
    } finally { $process.Dispose() }
}
function Show-GPushWorkspaceDiff {
    param($Repository)
    $color = if ($script:GPushNoColor -or $env:NO_COLOR -or [Console]::IsOutputRedirected) {'never'} else {'always'}
    $staged = @(Get-GPushWorkspacePaths -Path $Repository.Path -Mode staged)
    $tracked = @(Get-GPushWorkspacePaths -Path $Repository.Path -Mode tracked)
    $untracked = @(Get-GPushWorkspacePaths -Path $Repository.Path -Mode untracked)
    $files = @($staged + $tracked + $untracked | Sort-Object -Unique -CaseSensitive)
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        & git -C $Repository.Path --no-pager diff --no-ext-diff --no-textconv "--color=$color" --cached -- | ForEach-Object { Write-Host $_ }
        & git -C $Repository.Path --no-pager diff --no-ext-diff --no-textconv "--color=$color" -- | ForEach-Object { Write-Host $_ }
        $untracked | ForEach-Object { Write-Host "Untracked: $_" }
        return
    }
    if (-not $files.Count) { Write-Ok 'No changes.'; Wait-GPushWorkspace; return }
    $rows = @(foreach ($file in $files) {
        $flag = if ($untracked -ccontains $file) { '?' } elseif (($staged -ccontains $file) -and ($tracked -ccontains $file)) { 'S+M' } elseif ($staged -ccontains $file) { 'S' } else { 'M' }
        "[$flag] $file"
    })
    while ($true) {
        $picked = @(Select-GPushWorkspaceRows -Title "Diff / $($Repository.Name)" -Rows $rows)
        if (-not $picked.Count) { return }
        $file = $files[$picked[0]]
        $lines = @()
        if ($untracked -ccontains $file) {
            $empty = [System.IO.Path]::GetTempFileName()
            try {
                $lines = @(& git -C $Repository.Path --no-pager diff --no-index --no-ext-diff --no-textconv "--color=$color" -- $empty (Join-Path $Repository.Path $file))
                if ($LASTEXITCODE -gt 1) { Write-Err 'Cannot read untracked file.'; Wait-GPushWorkspace; continue }
            } finally { [System.IO.File]::Delete($empty) }
        } else {
            if ($staged -ccontains $file) {
                $lines += '--- Staged changes ---'
                $lines += @(& git -C $Repository.Path --literal-pathspecs --no-pager diff --no-ext-diff --no-textconv "--color=$color" --cached -- $file)
                if ($LASTEXITCODE -ne 0) { Write-Err 'Cannot read staged diff.'; Wait-GPushWorkspace; continue }
            }
            if ($tracked -ccontains $file) {
                $lines += '--- Working tree changes ---'
                $lines += @(& git -C $Repository.Path --literal-pathspecs --no-pager diff --no-ext-diff --no-textconv "--color=$color" -- $file)
                if ($LASTEXITCODE -ne 0) { Write-Err 'Cannot read working tree diff.'; Wait-GPushWorkspace; continue }
            }
        }
        if (-not $lines.Count) { $lines = @('No changes remain in this file. Return and reopen the diff to refresh.') }
        Show-GPushWorkspaceLines -Title "Diff / $file" -Lines $lines
    }
}
function Invoke-GPushWorkspaceCommit {
    param($Repository)
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { Write-Err 'Interactive terminal required.'; return }
    Push-Location -LiteralPath $Repository.Path
    try {
        foreach ($marker in @('MERGE_HEAD','CHERRY_PICK_HEAD','REVERT_HEAD','rebase-merge','rebase-apply','sequencer','BISECT_START')) {
            $markerPath = (& git rev-parse --git-path $marker) -join ''
            if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $markerPath)) { Write-Err 'Git operation in progress or inspection failed.'; return }
        }
        & git symbolic-ref --quiet HEAD | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Err 'Detached HEAD.'; return }
        $indexBefore = (& git write-tree) -join ''
        if ($LASTEXITCODE -ne 0) { Write-Err 'Cannot inspect staging area.'; return }
        $staged = @(Get-GPushWorkspacePaths -Path $Repository.Path -Mode staged)
        $tracked = @(Get-GPushWorkspacePaths -Path $Repository.Path -Mode tracked)
        $untracked = @(Get-GPushWorkspacePaths -Path $Repository.Path -Mode untracked)
        $files = @($tracked + $staged + $untracked | Sort-Object -Unique -CaseSensitive)
        if ($files.Count -eq 0) { Write-Ok 'No changes.'; return }
        $rows = @(foreach ($file in $files) {
            $flag = if ($untracked -ccontains $file) { '?' } elseif (($staged -ccontains $file) -and ($tracked -ccontains $file)) { 'S+M' } elseif ($staged -ccontains $file) { 'S' } else { 'M' }
            "[$flag] $file"
        })
        $picked = @(Select-GPushWorkspaceRows -Title "Commit manager / $($Repository.Name)" -Rows $rows -Multiple)
        if (-not $picked.Count) { return }
        $chosen = @($picked | ForEach-Object { $files[$_] })
        foreach ($file in $chosen) {
            if (Test-SensitivePath -Path $file) { Write-Err "Risky file: $file"; return }
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                if ((Get-Item -LiteralPath $file).Length -ge ([long]$LargeFileThresholdMB * 1MB)) { Write-Err "Large file: $file"; return }
            }
        }
        Write-Section "Selected files ($($chosen.Count))"
        foreach ($file in $chosen) { Write-Host ('  ' + ($file -replace '[\x00-\x1f\x7f]','?')) }
        $message = Read-Host 'Commit message'
        if ([string]::IsNullOrWhiteSpace($message)) { return }
        if (-not (Confirm-GPushAction -Prompt 'Commit selected working-tree versions? Other staged files stay staged.')) { return }
        $indexNow = (& git write-tree) -join ''
        if ($LASTEXITCODE -ne 0 -or $indexNow -ne $indexBefore) { Write-Err 'Staging area changed. Restart commit manager.'; return }
        $newFiles = @($chosen | Where-Object { $untracked -ccontains $_ })
        if ($newFiles.Count) {
            $addResult = Get-GitOutput -Arguments (@('--literal-pathspecs','add','--') + $newFiles) -AllowFailure
            $addResult.Lines | ForEach-Object { Write-Host $_ }
            if (-not $addResult.Success) { return }
        }
        $commitResult = Get-GitOutput -Arguments (@('--literal-pathspecs','commit','--only','-m',$message,'--') + $chosen) -AllowFailure
        $commitResult.Lines | ForEach-Object { Write-Host $_ }
        if (-not $commitResult.Success) { return }
        Write-GPushWorkspaceHistory commit $Repository.Path
        if (Confirm-GPushAction -Prompt 'Push committed changes now (leave other files untouched)?') {
            $allow = Confirm-GPushAction -Prompt 'Allow pushing to protected branches? (main/master/release)'
            $result = Invoke-GPushAllSync -Repository $Repository -PushOnly -AllowProtectedBranches:$allow
            Write-GPushAllRow -Snapshot $result.Snapshot -Result $result.Result
            Write-GPushWorkspaceHistory "sync $($result.Result)" $Repository.Path
        }
    } finally { Pop-Location }
}
function Show-GPushWorkspaceBranches {
    param($Repository)
    while ($true) {
        Write-Section "Branches / $($Repository.Name)"
        & git -C $Repository.Path branch -vv | ForEach-Object { Write-Host $_ }
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return }
        Write-Dim '[N] New  [S] Switch  [D] Delete merged  [G] Graph  [Q/Esc] Back'
        $key=(Read-GPushWorkspaceKey)
        if ($key.Key -eq 'Escape') { return }
        $action=[string]$key.KeyChar
        if ($action -eq 'q') { return }
        if ($action -eq 'g') { & git -C $Repository.Path --no-pager log --graph --all --decorate --oneline -n 40 | ForEach-Object { Write-Host $_ }; Wait-GPushWorkspace; continue }
        if ($action -notin @('n','s','d')) { continue }
        if ($action -eq 'n') { $branch = Read-Host 'Branch name' } else {
            $branches = @(& git -C $Repository.Path for-each-ref '--format=%(refname:short)' refs/heads)
            $picked = @(Select-GPushWorkspaceRows -Title 'Select local branch' -Rows $branches)
            if (-not $picked.Count) { continue }
            $branch = $branches[$picked[0]]
        }
        if (-not $branch -or $branch.StartsWith('-')) { continue }
        & git check-ref-format --branch $branch | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Err 'Invalid branch name.'; continue }
        if ($action -eq 'd' -and (Test-ProtectedBranch -Branch $branch)) { Write-Warn 'Protected branch.'; continue }
        if (-not (Confirm-GPushAction -Prompt "Perform branch action $action on $branch?")) { continue }
        switch ($action) {
            'n' { & git -C $Repository.Path switch -c $branch | ForEach-Object { Write-Host $_ } }
            's' { & git -C $Repository.Path switch $branch | ForEach-Object { Write-Host $_ } }
            'd' { & git -C $Repository.Path branch -d -- $branch | ForEach-Object { Write-Host $_ } }
        }
        if ($LASTEXITCODE -eq 0) { Write-GPushWorkspaceHistory "branch-$action" $Repository.Path }
    }
}
function Show-GPushWorkspaceGitHub {
    param($Repository)
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Write-Err 'Install GitHub CLI (gh) and run gh auth login.'; return }
    Push-Location -LiteralPath $Repository.Path
    try {
        & gh repo view | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { return }
        & gh issue list --limit 5 | ForEach-Object { Write-Host $_ }
        & gh pr list --limit 5 | ForEach-Object { Write-Host $_ }
        & gh release list --limit 5 | ForEach-Object { Write-Host $_ }
        & gh run list --limit 5 | ForEach-Object { Write-Host $_ }
    } finally { Pop-Location }
}
function Show-GPushWorkspaceDetail {
    param($Repository)
    while ($true) {
        if (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) { Clear-Host }
        Write-Section "Repository detail / $($Repository.Name)"
        Write-Dim $Repository.Path
        & git -C $Repository.Path status --short --branch | ForEach-Object { Write-Host $_ }
        & git -C $Repository.Path --no-pager log -5 '--format=%h  %s  (%ar)' | ForEach-Object { Write-Host $_ }
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return }
        Write-Dim '[C] Commit  [D] Diff  [B] Branches  [F] Fetch  [S] Sync  [G] GitHub  [Q/Esc] Back'
        $key = (Read-GPushWorkspaceKey)
        if ($key.Key -eq 'Escape') { return }
        $action = [string]$key.KeyChar
        try {
        switch ($action) {
            'c' { Invoke-GPushWorkspaceCommit $Repository; Wait-GPushWorkspace }
            'd' { Show-GPushWorkspaceDiff $Repository }
            'b' { Show-GPushWorkspaceBranches $Repository }
            'f' {
                $state = @(Get-GPushOverviewStates -Repositories @($Repository) -Fetch)[0]
                $result = if (-not $state.Valid) { 'FAIL inspection' } elseif ($state.Remote -eq '-') { 'SKIP no remote' } elseif ($state.FetchOk) { 'OK fetched' } else { 'FAIL fetch' }
                Write-GPushAllRow -Snapshot $state -Result $result
                Write-GPushWorkspaceHistory "fetch $result" $Repository.Path
                Wait-GPushWorkspace
            }
            's' { if (Confirm-GPushAction -Prompt 'Synchronize repository?') { $result = Invoke-GPushAllSync -Repository $Repository; Write-GPushAllRow -Snapshot $result.Snapshot -Result $result.Result; Write-GPushWorkspaceHistory "sync $($result.Result)" $Repository.Path }; Wait-GPushWorkspace }
            'g' { Show-GPushWorkspaceGitHub $Repository; Wait-GPushWorkspace }
            'q' { return }
        }
        } catch {
            if ($_.Exception -is [OperationCanceledException]) { Write-Warn 'Operation cancelled by user.'; Wait-GPushWorkspace } else { throw }
        }
    }
}
function Show-GPushWorkspaceSettings {
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { Show-GPushConfig; return }
    $keys = @('default-remote','large-file-threshold','search-root','protected-branch','ignored-directory')
    while ($true) {
        $picked = @(Select-GPushWorkspaceRows -Title 'Settings' -Rows $keys)
        if (-not $picked.Count) { return }
        $key = $keys[$picked[0]]
        Show-GPushConfig
        $action = 'set'; $value = ''
        if ($key -notin @('default-remote','large-file-threshold')) {
            $action = Read-Host 'Action [add/remove/reset]'
            if ($action -notin @('add','remove','reset')) { continue }
        }
        if ($action -ne 'reset') { $value = Read-Host 'Value (empty cancels)'; if (-not $value) { continue } }
        if (Confirm-GPushAction -Prompt 'Save configuration?') { $null = Invoke-GPushConfigEdit -Action $action -Key $key -Value $value }
        Wait-GPushWorkspace
    }
}
function Show-GPushWorkspaceActivity {
    Write-Section 'Workspace activity / latest 30 operations'
    $historyFile = Join-Path $ConfigDir 'history.log'
    if (-not (Test-Path $historyFile)) { Write-Dim 'No operations recorded yet.'; return }
    foreach ($line in @(Get-Content $historyFile -Tail 30)) {
        $parts = $line -split ' ',3
        if ($parts.Count -lt 3) { Write-Dim $line; continue }
        Write-Host $parts[0] -ForegroundColor DarkGray -NoNewline
        Write-Host ('  {0,-14} ' -f $parts[1]) -ForegroundColor Cyan -NoNewline
        Write-Host $parts[2]
    }
}
function Select-GPushMenuRepository {
    $repositories = @(Get-GPushCache | Sort-Object @{Expression={if ($FavoriteRepositories -contains $_.Path) {0} else {1}}},Name,Path)
    if (-not $repositories.Count) {
        Write-Warn 'No cached repositories. Open Repository cache > Refresh first.'
        Wait-GPushWorkspace
        return
    }
    $labels = @($repositories | ForEach-Object { $mark=if ($FavoriteRepositories -contains $_.Path) {[string][char]0x2605+' '} else {''}; "$mark$($_.Name)  |  $($_.Path)" })
    $picked = @(Select-GPushWorkspaceRows -Title 'Select repository' -Rows $labels)
    if ($picked.Count) { return $repositories[$picked[0]] }
}
function Show-GPushMenuRepositoryTools {
    param($Repository)
    $path = $Repository.Path
    $labels = @('Commit all changes (classic workflow)','List tags','Create annotated tag','Push tag','List remotes','Add remote','Change remote URL','Remove remote','List stashes','Stash changes','Restore latest stash','Project info','Build project','Test project','Run project','Open project shell','Back')
    while ($true) {
        $picked = @(Select-GPushWorkspaceRows -Title "Repository tools / $($Repository.Name)" -Rows $labels)
        if (-not $picked.Count -or $picked[0] -eq 16) { return }
        Clear-Host
        try {
        switch ($picked[0]) {
            0 { $message = Read-Host 'Commit message (empty cancels)'; if ($message -and (Confirm-GPushAction -Prompt 'Commit all changes and push using classic workflow?')) { $arguments = @($path, '--', $message); & $PSCommandPath @arguments } }
            1 { & $PSCommandPath tag list $path }
            { $_ -in @(2,3) } {
                $name = Read-Host 'Tag name (empty cancels)'
                if ($name -and -not $name.StartsWith('-')) {
                    if ($_ -eq 2) { $message = Read-Host 'Tag message'; if (Confirm-GPushAction -Prompt "Create tag $name?") { & $PSCommandPath tag create $path $name $message } }
                    elseif (Confirm-GPushAction -Prompt "Push tag $name?") { & $PSCommandPath tag push $path $name }
                }
            }
            4 { & $PSCommandPath remote list $path }
            { $_ -in @(5,6,7) } {
                $name = Read-Host 'Remote name (empty cancels)'
                if ($name -and -not $name.StartsWith('-')) {
                    if ($_ -eq 7) { & $PSCommandPath remote remove $path $name }
                    else {
                        $url = Read-Host 'Remote URL (empty cancels)'
                        if ($url -and -not $url.StartsWith('-')) {
                            if ($_ -eq 5) { if (Confirm-GPushAction -Prompt "Add remote $name?") { & $PSCommandPath remote add $path $name $url } }
                            else { & $PSCommandPath remote set-url $path $name $url }
                        }
                    }
                }
            }
            8 { & $PSCommandPath stash list $path }
            9 { if (Confirm-GPushAction -Prompt 'Stash tracked and untracked changes?') { & $PSCommandPath stash push $path } }
            10 { if (Confirm-GPushAction -Prompt 'Apply and remove latest stash?') { & $PSCommandPath stash pop $path } }
            11 { & $PSCommandPath project info $path }
            12 { if (Confirm-GPushAction -Prompt 'Build this project?') { & $PSCommandPath project build $path } }
            13 { if (Confirm-GPushAction -Prompt 'Run project tests?') { & $PSCommandPath project test $path } }
            14 { if (Confirm-GPushAction -Prompt 'Run this project?') { & $PSCommandPath project run $path } }
            15 { & $PSCommandPath project shell $path }
        }
        } catch {
            if ($_.Exception -is [OperationCanceledException]) { Write-Warn 'Operation cancelled by user.' } else { Write-Err $_.Exception.Message }
        }
        Wait-GPushWorkspace
    }
}
function Show-GPushMenuRepository {
    param($Repository)
    $labels = @('Commit selected files','Sync / push existing commits','Fetch remote references','Status and recent commits','Browse diff','Manage branches','Commit graph','GitHub information','Open repository folder','More repository tools','Push committed changes only','Back')
    :repositoryMenu while ($true) {
        $picked = @(Select-GPushWorkspaceRows -Title "Repository / $($Repository.Name)" -Rows $labels)
        if (-not $picked.Count) { return }
        Clear-Host
        try {
        switch ($picked[0]) {
            0 { Invoke-GPushWorkspaceCommit $Repository }
            1 {
                if (Confirm-GPushAction -Prompt 'Synchronize this repository?') {
                    $allow = Confirm-GPushAction -Prompt 'Allow pushing to protected branches as well?'
                    $result = Invoke-GPushAllSync -Repository $Repository -AllowProtectedBranches:$allow
                    Write-GPushAllRow -Snapshot $result.Snapshot -Result $result.Result
                    Write-GPushWorkspaceHistory "sync $($result.Result)" $Repository.Path
                }
            }
            2 {
                $state = @(Get-GPushOverviewStates -Repositories @($Repository) -Fetch)[0]
                $result = if (-not $state.Valid) { 'FAIL inspection' } elseif ($state.Remote -eq '-') { 'SKIP no remote' } elseif ($state.FetchOk) { 'OK fetched' } else { 'FAIL fetch' }
                Write-GPushAllRow -Snapshot $state -Result $result
                Write-GPushWorkspaceHistory "fetch $result" $Repository.Path
            }
            3 { Show-GPushWorkspaceDetail $Repository; continue repositoryMenu }
            4 { Show-GPushWorkspaceDiff $Repository; continue repositoryMenu }
            5 { Show-GPushWorkspaceBranches $Repository; continue repositoryMenu }
            6 { & git -C $Repository.Path --no-pager log --graph --all --decorate --oneline -n 40 | ForEach-Object { Write-Host $_ } }
            7 { Show-GPushWorkspaceGitHub $Repository }
            8 { Invoke-Item -LiteralPath $Repository.Path }
            9 { Show-GPushMenuRepositoryTools $Repository; continue repositoryMenu }
            10 {
                if (Confirm-GPushAction -Prompt 'Push existing commits without changing working tree?') {
                    $allow = Confirm-GPushAction -Prompt 'Allow pushing to protected branches?'
                    $result = Invoke-GPushAllSync -Repository $Repository -PushOnly -AllowProtectedBranches:$allow
                    Write-GPushAllRow -Snapshot $result.Snapshot -Result $result.Result
                    Write-GPushWorkspaceHistory "push $($result.Result)" $Repository.Path
                }
            }
            11 { return }
        }
        } catch {
            if ($_.Exception -is [OperationCanceledException]) { Write-Warn 'Operation cancelled by user.' } else { Write-Err $_.Exception.Message }
        }
        Wait-GPushWorkspace
    }
}
function Show-GPushMenuBulk {
    $labels = @('Repository status (local)','Fetch all repositories','Synchronize all repositories','Commit and synchronize all repositories','Preview synchronization (dry-run)','Back')
    while ($true) {
        $picked = @(Select-GPushWorkspaceRows -Title 'Bulk operations' -Rows $labels)
        if (-not $picked.Count -or $picked[0] -eq 5) { return }
        $repositories = @(Get-GPushCache | Sort-Object Name, Path)
        if (-not $repositories.Count) { Write-Warn 'No cached repositories. Refresh the cache first.'; Wait-GPushWorkspace; continue }
        Clear-Host
        try {
        switch ($picked[0]) {
            0 { $null = Show-GPushAllRepositories -Repositories $repositories -Mode status }
            1 { if (Confirm-GPushAction -Prompt 'Fetch all cached repositories?') { $null = Show-GPushAllRepositories -Repositories $repositories -Mode fetch } }
            { $_ -in @(2,3) } {
                $message = ''; $mode = 'sync'
                if ($_ -eq 3) { $message = Read-Host 'Commit message (empty cancels)'; if ([string]::IsNullOrWhiteSpace($message)) { break }; $mode = 'push' }
                if (Confirm-GPushAction -Prompt 'Operate on all cached repositories?') {
                    $allow = Confirm-GPushAction -Prompt 'Allow pushing to protected branches as well?'
                    $null = Show-GPushAllRepositories -Repositories $repositories -Mode $mode -CommitMessage $message -AllowProtectedBranches:$allow
                }
            }
            4 { Show-GPushVisualStatus 'dry-run' }
        }
        } catch {
            if ($_.Exception -is [OperationCanceledException]) { Write-Warn 'Operation cancelled by user.' } else { Write-Err $_.Exception.Message }
        }
        Wait-GPushWorkspace
    }
}
function Show-GPushFavoritesManager {
    while ($true) {
        $repos=@(Get-GPushCache | Sort-Object Name,Path)
        $labels=@(foreach ($repo in $repos) {if ($FavoriteRepositories -contains $repo.Path) {"[x] $($repo.Name)  |  $($repo.Path)"} else {"[ ] $($repo.Name)  |  $($repo.Path)"}}) + @('Back')
        $picked=@(Select-GPushWorkspaceRows -Title 'Favorites / Enter toggles, saved immediately' -Rows $labels)
        if (-not $picked.Count -or $picked[0] -ge $repos.Count) {return}
        $path=$repos[$picked[0]].Path
        if ($FavoriteRepositories -contains $path) {$script:FavoriteRepositories=@($FavoriteRepositories | Where-Object {$_ -ne $path})}
        else {$script:FavoriteRepositories=@($FavoriteRepositories)+@($path)}
        Save-GPushConfig
    }
}
function Show-GPushSearchRoots {
    $candidates=@((Join-Path $HOME 'Projects'),(Join-Path $HOME 'Documents/Project'),(Join-Path $HOME 'source/repos'),(Join-Path $HOME 'dev'),(Join-Path $HOME 'code'))
    $candidates+=@(Get-GPushCache | ForEach-Object {Split-Path -Parent $_.Path})
    $paths=@(foreach ($path in ($candidates | Sort-Object -Unique)) {
        if (-not $path -or $path -eq $HOME -or -not (Test-Path -LiteralPath $path -PathType Container)) {continue}
        $covered=$false
        foreach ($root in $SearchRoots) {if ($path -eq $root -or $path.StartsWith($root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {$covered=$true}}
        if (-not $covered) {$path}
    })
    $labels=@($paths | ForEach-Object {"Add suggested root  |  $_"})+@('Enter custom directory','Back')
    $picked=@(Select-GPushWorkspaceRows -Title 'Search roots / suggestions' -Rows $labels)
    if (-not $picked.Count -or $picked[0] -eq $paths.Count+1) {return}
    $path=if ($picked[0] -eq $paths.Count) {Read-Host 'Directory'} else {$paths[$picked[0]]}
    if ($path -and (Test-Path -LiteralPath $path -PathType Container) -and (Confirm-GPushAction -Prompt "Add search root $path?")) {$null=Invoke-GPushConfigEdit -Action add -Key search-root -Value $path}
}
function Show-GPushMenuCache {
    $labels = @('List repositories','Refresh cache (scan search roots)','Add repository path','Recent repositories','Favorites','Clone repository','Search roots','Back')
    while ($true) {
        $picked = @(Select-GPushWorkspaceRows -Title 'Repository cache' -Rows $labels)
        if (-not $picked.Count -or $picked[0] -eq 7) { return }
        Clear-Host
        try {
        switch ($picked[0]) {
            0 { & $PSCommandPath cache list }
            1 { if (Confirm-GPushAction -Prompt 'Scan configured search roots?') { & $PSCommandPath cache refresh } }
            2 { $path = Read-Host 'Repository path (empty cancels)'; if ($path) { & $PSCommandPath cache add $path } }
            3 { & $PSCommandPath recent }
            4 { Show-GPushFavoritesManager; continue }
            5 { $url = Read-Host 'Clone URL (empty cancels)'; if ($url -and -not $url.StartsWith('-') -and (Confirm-GPushAction -Prompt 'Clone repository?')) { & $PSCommandPath clone $url } }
            6 { Show-GPushSearchRoots }
        }
        } catch {
            if ($_.Exception -is [OperationCanceledException]) { Write-Warn 'Operation cancelled by user.' } else { Write-Err $_.Exception.Message }
        }
        Wait-GPushWorkspace
    }
}
function Show-GPushMenuUpdate {
    while ($true) {
        $picked = @(Select-GPushWorkspaceRows -Title 'Software update' -Rows @('Check for updates','Install update','Restore previous version','Back'))
        if (-not $picked.Count -or $picked[0] -eq 3) { return }
        Clear-Host
        $actions = @('check','install','rollback')
        $null = Invoke-GPushUpdateCommand -Arguments @($actions[$picked[0]]) -OfferInstall
        Wait-GPushWorkspace
    }
}
function Show-GPushWorkspaceMenu {
    $labels = @('Workspace overview','Repositories / commit and push','Bulk operations','Repository cache','Development statistics','Workspace health','Activity history','Settings','Software update','Help / CLI commands','Exit')
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { Show-Help; return }
    while ($true) {
        $picked = @(Select-GPushWorkspaceRows -Title "GPush $ScriptVersion / Main menu" -Rows $labels)
        if (-not $picked.Count -or $picked[0] -eq 10) { return }
        try {
            Clear-Host
            switch ($picked[0]) {
                0 { $null = Invoke-GPushVisualCommand -Mode 'overview' -Tail @() }
                1 { $repository = Select-GPushMenuRepository; if ($repository) { Show-GPushMenuRepository $repository } }
                2 { Show-GPushMenuBulk }
                3 { Show-GPushMenuCache }
                4 { Show-GPushStatsScreen }
                5 { Show-GPushHealthScreen }
                6 { Show-GPushWorkspaceActivity; Wait-GPushWorkspace }
                7 { Show-GPushWorkspaceSettings }
                8 { Show-GPushMenuUpdate }
                9 { Show-Help; Wait-GPushWorkspace }
            }
        } catch { if ($_.Exception -is [OperationCanceledException]) { Write-Warn 'Operation cancelled by user.' } else { Write-Err $_.Exception.Message }; Wait-GPushWorkspace }
    }
}
function Resolve-GPushWorkspaceRepository {
    param([string[]]$Tail)
    $query = $Tail -join ' '
    if (-not $query) {
        $query = (& git rev-parse --show-toplevel 2>$null) -join ''
        if (-not $query) { return Select-GPushMenuRepository }
    }
    $query = Resolve-GPushAlias -Search $query
    if (Test-Path -LiteralPath $query -PathType Container) {
        $root = (& git -C $query rev-parse --show-toplevel 2>$null) -join ''
        if ($LASTEXITCODE -eq 0 -and $root) {
            return [PSCustomObject]@{Name=(Split-Path -Leaf $root);Path=$root}
        }
    }
    $repositories = @(Get-GPushCache)
    $matches = @(Get-RepositoryMatches -Repos $repositories -Search $query)
    if ($matches.Count -eq 1) { return $matches[0] }
    if ($matches.Count -gt 1 -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
        $labels = @($matches | ForEach-Object { "$($_.Name)  |  $($_.Path)" })
        $picked = @(Select-GPushWorkspaceRows -Title 'Select repository' -Rows $labels)
        if ($picked.Count) { return $matches[$picked[0]] }
        return
    }
    Write-Err 'Specify one cached repository name or path.'
}

function Get-GPushStatsData {
    param([ValidateSet('7','30','90','365')][int]$Period=30,[switch]$Refresh)
    $repositories = @(Get-GPushCache)
    $signature = ($repositories.Path -join '|')
    $statsDirectory=Join-Path $CacheDir 'activity'
    New-Item -ItemType Directory -Path $statsDirectory -Force | Out-Null
    $identity=(& git config --global --get user.name 2>$null) -join ''
    if (-not $identity) {$identity='unknown'}
    if ($null -eq $script:GPushStatsCache) { $script:GPushStatsCache = @{} }
    $cached = $script:GPushStatsCache[$Period]
    $statsFile=Join-Path $statsDirectory "summary-$Period.clixml"
    if (-not $cached -and -not $Refresh) {try {$cached=Import-Clixml -LiteralPath $statsFile -ErrorAction Stop} catch {}}
    if (-not $Refresh -and $cached -and $cached.Signature -ceq $signature -and ((Get-Date)-$cached.At).TotalSeconds -lt 60) { return $cached }
    $counts = New-Object 'System.Collections.Generic.List[object]'
    $days = @{}; $total=0; $added=0L; $removed=0L; $unavailable=0; $completed=0
    $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $interactive = -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
    $previous = $false; $ProgressPreference = 'Continue'
    $jobs = @()
    try {
        if ($interactive) { $previous=[Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput=$true }
        for ($i=0; $i -lt $repositories.Count; $i+=4) {
            $jobs = @()
            $last = [Math]::Min($i+4,$repositories.Count)
            for ($j=$i; $j -lt $last; $j++) {
                $repo=$repositories[$j]
                try {
                    $capture=Start-GPushNativeCapture -Executable $gitCommand.Source -ArgumentVector @('-C',[string]$repo.Path,'log','--no-color',"--since=$Period days ago",'--format=@GP:%as','--numstat','HEAD')
                    $jobs += [PSCustomObject]@{ Repository=$repo; Capture=$capture; Done=$false }
                } catch { $unavailable++; $completed++ }
            }
            while (@($jobs | Where-Object { -not $_.Done }).Count -gt 0) {
                if ($interactive -and (Test-GPushOperationCancelled)) { throw [OperationCanceledException]::new('Operation cancelled by user.') }
                if ($interactive) { Write-Progress -Id 43 -Activity 'Loading development activity' -Status ("$completed of $($repositories.Count) repositories") -PercentComplete ([int][Math]::Floor(100*$completed/[Math]::Max(1,$repositories.Count))) -CurrentOperation 'Ctrl+C: cancel' }
                foreach ($job in $jobs) {
                    if ($job.Done -or -not $job.Capture.Process.HasExited -or -not $job.Capture.OutputTask.IsCompleted -or -not $job.Capture.ErrorTask.IsCompleted) { continue }
                    $job.Capture.Process.WaitForExit()
                    if ($job.Capture.Process.ExitCode -eq 0) {
                        $count=0
                        foreach ($line in ($job.Capture.OutputTask.GetAwaiter().GetResult() -split "`r?`n")) {
                            if ($line -match '^@GP:(\d{4}-\d{2}-\d{2})$') { $day=$Matches[1]; $count++; $days[$day]=1+[int]$days[$day] }
                            elseif ($line -match '^(\d+)\t(\d+)\t') { $added += [long]$Matches[1]; $removed += [long]$Matches[2] }
                        }
                        $total += $count; $counts.Add([PSCustomObject]@{Name=$job.Repository.Name; Count=$count})
                    } else { $unavailable++ }
                    $job.Done=$true; $completed++
                    Stop-GPushNativeCapture $job.Capture
                }
                if (@($jobs | Where-Object { -not $_.Done }).Count) { Start-Sleep -Milliseconds 60 }
            }
        }
    } finally {
        foreach ($job in $jobs) { if (-not $job.Done) { Stop-GPushNativeCapture $job.Capture } }
        Write-Progress -Id 43 -Activity 'Loading development activity' -Completed
        if ($interactive) { [Console]::TreatControlCAsInput=$previous }
    }
    $data=[PSCustomObject]@{ Signature=$signature; At=(Get-Date); Counts=@($counts.ToArray()); Days=$days; Total=$total; Added=$added; Removed=$removed; Unavailable=$unavailable; Identity=$identity }
    try {$data | Export-Clixml -LiteralPath $statsFile -ErrorAction Stop} catch {}
    $script:GPushStatsCache[$Period]=$data
    return $data
}

function Show-GPushStats {
    param([int]$Period=30,[switch]$ShowAll,[switch]$Refresh)
    $data=Get-GPushStatsData -Period $Period -Refresh:$Refresh
    $cols=100
    if (-not [Console]::IsOutputRedirected) { $cols=[Console]::WindowWidth }
    $nameWidth=[Math]::Max(10,[Math]::Min(24,[int][Math]::Floor($cols/3)))
    $barWidth=[Math]::Max(4,[Math]::Min(28,$cols-$nameWidth-16))
    Write-Host "  GPUSH  /  $ScriptVersion" -ForegroundColor Cyan
    Write-Section "  Development activity / $Period days"
    Write-Dim "  Workspace: $($data.Identity) | All authors (local HEAD histories)"
    Write-Dim ('  '+([string][char]0x2500 * [Math]::Max(1,[Math]::Min(100,$cols-3))))
    Write-Host ('  Commits  {0:N0}    ' -f $data.Total) -ForegroundColor Cyan -NoNewline
    Write-Host ('+{0:N0} added    ' -f $data.Added) -ForegroundColor Green -NoNewline
    Write-Host ('-{0:N0} removed' -f $data.Removed) -ForegroundColor Red
    Write-Host ''; Write-Dim (('  {0,-'+$nameWidth+'}  {1,-'+$barWidth+'}  {2}') -f 'Repository','Activity','Commits')
    $maximum=[Math]::Max(1,[int]($data.Counts | Measure-Object Count -Maximum).Maximum)
    $active=@($data.Counts | Where-Object { $ShowAll -or $_.Count -gt 0 } | Sort-Object -Property @{Expression='Count';Descending=$true},@{Expression='Name';Descending=$false})
    foreach ($item in $active) {
        $filled=[int][Math]::Floor($barWidth*$item.Count/$maximum)
        if ($item.Count -gt 0 -and $filled -eq 0) { $filled=1 }
        Write-Host ('  '+(Limit-GPushTableText $item.Name $nameWidth).PadRight($nameWidth)+'  ') -NoNewline
        if ($script:GPushNoColor -or $env:NO_COLOR -or [Console]::IsOutputRedirected) {
            Write-Host (([string][char]0x2588 * $filled)+([string][char]0x2591 * ($barWidth-$filled))) -NoNewline
        } else {
            if ($filled -gt 0) { Write-Host (' ' * $filled) -BackgroundColor DarkCyan -NoNewline }
            if ($filled -lt $barWidth) { Write-Host (' ' * ($barWidth-$filled)) -BackgroundColor Black -NoNewline }
        }
        Write-Host ('  {0,5}' -f $item.Count)
    }
    if ($data.Counts.Count -gt $active.Count) { Write-Dim "  $($data.Counts.Count-$active.Count) inactive repositories hidden" }
    if ($data.Unavailable -gt 0) { Write-Warn "  $($data.Unavailable) repositories could not be inspected (including empty histories)." }
    $heatDays=[Math]::Min([Math]::Min(30,$Period),[Math]::Max(1,[int][Math]::Floor(($cols-3)/3)))
    Write-Host ''; Write-Dim "  Daily activity (oldest first; last $heatDays days)"
    Write-Host '  ' -NoNewline
    for ($i=$heatDays-1; $i -ge 0; $i--) {
        $n=[int]$data.Days[(Get-Date).AddDays(-$i).ToString('yyyy-MM-dd')]
        if ($script:GPushNoColor -or $env:NO_COLOR -or [Console]::IsOutputRedirected) { Write-Host "$([Math]::Min(9,$n)) " -NoNewline }
        else { $color=if ($n -eq 0) {'DarkGray'} elseif ($n -lt 3) {'DarkGreen'} elseif ($n -lt 6) {'Green'} else {'Cyan'}; Write-Host '  ' -BackgroundColor $color -NoNewline; Write-Host ' ' -NoNewline }
    }
    Write-Host ''; Write-Dim '  Low activity -> high activity'
    Write-Dim ("  Local snapshot: {0:HH:mm:ss} (60s persistent cache)" -f $data.At)
}

function Show-GPushStatsScreen {
    $periods=@(7,30,90,365); $index=1; $showAll=$false; $refresh=$false
    while ($true) {
        Clear-Host
        try { Show-GPushStats -Period $periods[$index] -ShowAll:$showAll -Refresh:$refresh }
        catch { if ($_.Exception -is [OperationCanceledException]) { Write-Warn 'Operation cancelled by user.' } else { Write-Err $_.Exception.Message }; Wait-GPushWorkspace; return }
        $refresh=$false
        Write-Host ''; Write-Dim '  Left/Right Range  A Show/hide inactive  R Refresh  Esc Back'
        switch ((Read-GPushWorkspaceKey).Key) {
            Escape { return }
            LeftArrow { $index=($index+3)%4 }
            RightArrow { $index=($index+1)%4 }
            A { $showAll=-not $showAll }
            R { $refresh=$true }
        }
    }
}

function Invoke-GPushVisualCommand {
    param([string]$Mode, [string[]]$Tail)
    if ($Mode -in @('menu','overview','detail','commit','branches','diff','github') -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) { $script:GPushInteractiveWorkspace=$true }
    switch ($Mode) {
        { $_ -in @('detail','commit','diff','branches','github') } {
            $repository = Resolve-GPushWorkspaceRepository -Tail $Tail
            if (-not $repository) { return 2 }
            switch ($Mode) {
                'detail' { Show-GPushWorkspaceDetail $repository }
                'commit' { Invoke-GPushWorkspaceCommit $repository }
                'diff' { Show-GPushWorkspaceDiff $repository }
                'branches' { Show-GPushWorkspaceBranches $repository }
                'github' { Show-GPushWorkspaceGitHub $repository }
            }
        }
        'menu' { Show-GPushWorkspaceMenu | Out-Host }
        'settings' { Show-GPushWorkspaceSettings }
        'activity' { Show-GPushWorkspaceActivity }
        'overview' {
            if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { Show-GPushVisualStatus 'overview'; return 0 }
            $repositories = @(Get-GPushCache | Sort-Object Name, Path)
            if ($repositories.Count -eq 0) { Write-Warn 'Run gp cache refresh first.'; return 1 }
            Clear-Host
            Show-Banner
            $states = @(Get-GPushOverviewStates -Repositories $repositories -UseCache)
            Save-GPushWorkspaceSnapshot $states
            $selected = 0
            while ($true) {
                Show-GPushOverviewFrame -States $states -Selected $selected
                $repository = $repositories[$selected]
                $key = (Read-GPushWorkspaceKey).Key
                try {
                switch ($key) {
                    'Q' { return 0 }
                    'Escape' { return 0 }
                    'UpArrow' { $selected = ($selected + $repositories.Count - 1) % $repositories.Count }
                    'DownArrow' { $selected = ($selected + 1) % $repositories.Count }
                    'Enter' {
                        Show-GPushMenuRepository $repository | Out-Host
                        $states[$selected] = Get-GPushOverviewLocalState -Repository $repository
                    }
                    'R' {
                        $states = @(Get-GPushOverviewStates -Repositories $repositories)
                    }
                    'A' {
                        if (Confirm-GPushAction -Prompt 'Fetch all cached repositories?') {
                            $states = @(Get-GPushOverviewStates -Repositories $repositories -Fetch)
                        }
                    }
                    'F' {
                        $states[$selected] = @(Get-GPushOverviewStates -Repositories @($repository) -Fetch)[0]
                    }
                    'S' {
                        if (Confirm-GPushAction -Prompt 'Synchronize selected repository (no commit)?') {
                            try {
                                $allow = Confirm-GPushAction -Prompt 'Allow pushing to protected branches as well?'
                                $result = Invoke-GPushAllSync -Repository $repository -AllowProtectedBranches:$allow
                                Write-GPushAllRow -Snapshot $result.Snapshot -Result $result.Result
                            } catch { Write-Warn $_.Exception.Message }
                            $states[$selected] = @(Get-GPushOverviewStates -Repositories @($repository))[0]
                            Wait-GPushWorkspace
                        }
                    }
                }
                if ($key -in @('R','A','F','S','Enter')) { Save-GPushWorkspaceSnapshot $states }
                } catch {
                    if ($_.Exception -is [OperationCanceledException]) { Write-Warn 'Operation cancelled by user.'; Wait-GPushWorkspace }
                    else { throw }
                }
            }
        }
        'health' { if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { Show-GPushVisualStatus 'health' } else { Show-GPushHealthScreen } }
        'history' {
            $historyFile = Join-Path $ConfigDir 'history.log'
            if (Test-Path $historyFile) { Get-Content $historyFile -Tail 30 } else { Write-Dim 'No bulk operations recorded yet.' }
        }
        'watch' {
            $interval = 10
            if ($Tail.Count -gt 0 -and (-not [int]::TryParse($Tail[0], [ref]$interval) -or $interval -lt 1)) { return 2 }
            if ([Console]::IsOutputRedirected) { Show-GPushVisualStatus 'overview'; return 0 }
            while ($true) { Clear-Host; Show-GPushVisualStatus 'overview'; Start-Sleep -Seconds $interval }
        }
        'stats' {
            $period=30
            if ($Tail.Count -gt 0 -and ((-not [int]::TryParse($Tail[0],[ref]$period)) -or $period -notin @(7,30,90,365))) { Write-Err 'Use gp stats [7|30|90|365].'; return 2 }
            try { Show-GPushStats -Period $period } catch { if ($_.Exception -is [OperationCanceledException]) { Write-Warn 'Operation cancelled by user.'; return 130 }; throw }
        }
        { $_ -in @('graph','changes') } {
            if ($Tail.Count -eq 0) { $path = (& git rev-parse --show-toplevel 2>$null) -join ''; if ($LASTEXITCODE -ne 0) { Write-Err 'Specify a cached repository.'; return 2 } }
            else {
                $query = Resolve-GPushAlias -Search ($Tail -join ' ')
                $matches = @(Get-GPushCache | Where-Object { $_.Name -eq $query -or $_.Path -eq $query })
                if ($matches.Count -ne 1) { Write-Err 'Specify one exact cached repository name or path.'; return 2 }
                $path = $matches[0].Path
            }
            if ($Mode -eq 'graph') { $color = if ($script:GPushNoColor -or $env:NO_COLOR -or [Console]::IsOutputRedirected) {'never'} else {'always'}; & git -C $path log --graph --all --decorate --oneline -n 40 "--color=$color" | ForEach-Object { Write-Host $_ }; return $LASTEXITCODE }
            else { & git -C $path status --short | ForEach-Object { Write-Host $_ }; if ($LASTEXITCODE -ne 0) { return $LASTEXITCODE }; & git -C $path diff --stat HEAD | ForEach-Object { Write-Host $_ }; return $LASTEXITCODE }
        }
        default { Show-GPushVisualStatus $Mode }
    }
    return 0
}

if ($VisualMode) {
    if (-not (Test-GitCommand)) { Write-Err 'Git was not found in PATH.'; exit 1 }
    # JSON and history must use the success stream without mixing in a numeric result.
    if ($VisualMode -eq '--json') { Show-GPushVisualStatus '--json'; exit 0 }
    if ($VisualMode -eq 'history') { $historyFile = Join-Path $ConfigDir 'history.log'; if (Test-Path $historyFile) { Get-Content $historyFile -Tail 30 }; exit 0 }
    try { $visualResult = @(Invoke-GPushVisualCommand -Mode $VisualMode -Tail $VisualTail) } catch { if ($_.Exception -is [OperationCanceledException]) { Write-Warn 'Operation cancelled by user.'; exit 130 }; throw }
    if ($visualResult.Count -gt 1) { $visualResult[0..($visualResult.Count-2)] | Write-Output }
    exit ([int]$visualResult[-1])
}

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
    $allMode = if ($BulkPush) {
        "push"
    }
    elseif ($SyncOnly) {
        "sync"
    }
    elseif ($FetchOnly) {
        "fetch"
    }
    else {
        "status"
    }

    if ($BulkPush) {
        Write-KeyValue "Repositories" ([string]$repos.Count)
        Write-KeyValue "Commit message" $BulkCommitMessage
        if (-not (Confirm-GPushAction -Prompt "Commit and synchronize cached repositories?")) {
            Write-Warn "Bulk push cancelled."
            exit 0
        }
    }
    $bulkExitCode = Show-GPushAllRepositories `
        -Repositories $repos `
        -Mode $allMode `
        -CommitMessage $BulkCommitMessage `
        -AllowProtectedBranches:$AllowProtected

    exit $bulkExitCode
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

# Conflict detection must use stdout only. Git may emit harmless warnings
# (for example LF/CRLF conversion notices) on stderr; those are not conflicts.
$conflictOutput = @(& git diff --name-only --diff-filter=U 2>$null)
$conflictExitCode = $LASTEXITCODE

if ($conflictExitCode -ne 0) {
    Write-Err "  x Could not verify unresolved conflicts."
    Write-Warn "Run 'git status' and resolve any repository problems before using GPush."
    exit 1
}

$conflicts = @(
    $conflictOutput |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

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
