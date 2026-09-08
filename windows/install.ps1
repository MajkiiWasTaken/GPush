param(
    [string[]]$SearchRoot,
    [switch]$Force
)

$InstallerVersion = "4.0.1"

[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding           = [System.Text.UTF8Encoding]::new($false)

$AuthorName = "Michal " + [char]0x0160 + "vr" + [char]0x010D + "ek"
$ErrorActionPreference = "Stop"

function Write-Step([string]$Text) { Write-Host "[*] $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "[+] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "[!] $Text" -ForegroundColor Yellow }
function Write-Fail([string]$Text) { Write-Host "[-] $Text" -ForegroundColor Red }

Write-Host ""
Write-Host "GPush installer " -NoNewline -ForegroundColor Cyan
Write-Host $InstallerVersion -ForegroundColor DarkGray
Write-Host "Made by " -NoNewline -ForegroundColor DarkGray
Write-Host $AuthorName -ForegroundColor Magenta
Write-Host "GitHub  " -NoNewline -ForegroundColor DarkGray
Write-Host "https://github.com/MajkiiWasTaken" -ForegroundColor Blue
Write-Host ""

$SourceScript = Join-Path $PSScriptRoot "gp.ps1"
if (-not (Test-Path $SourceScript)) {
    Write-Fail "gp.ps1 was not found next to install.ps1."
    Write-Host "Expected: $SourceScript" -ForegroundColor DarkGray
    exit 1
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Fail "Git was not found in PATH."
    Write-Host "Install Git first and run this installer again." -ForegroundColor DarkGray
    exit 1
}
Write-Ok "Git detected: $((git --version) -join ' ')"

$InstallDir = Join-Path $env:LOCALAPPDATA "GPush\bin"
$TargetScript = Join-Path $InstallDir "gp.ps1"
$ConfigDir = Join-Path $env:LOCALAPPDATA "GPush"
$ConfigFile = Join-Path $ConfigDir "config.json"
$CacheFile = Join-Path $ConfigDir "repos.json"

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
Copy-Item -LiteralPath $SourceScript -Destination $TargetScript -Force
Write-Ok "Installed GPush script."
Write-Host "    $TargetScript" -ForegroundColor DarkGray

# Load existing configuration so aliases/favorites and custom settings survive upgrades.
$existingConfig = $null
if (Test-Path $ConfigFile) {
    try {
        $existingConfig = Get-Content -Path $ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        Write-Ok "Existing configuration detected; custom settings will be preserved."
    }
    catch {
        Write-Warn "Existing config.json is invalid and cannot be preserved."
        if (-not $Force) {
            $answer = Read-Host "Replace it with a new configuration? [y/N]"
            if ($answer -notmatch '^(?i:y|yes)$') {
                Write-Fail "Installation cancelled to protect the existing config."
                exit 1
            }
        }
    }
}

if (-not $SearchRoot -or $SearchRoot.Count -eq 0) {
    if ($existingConfig -and $existingConfig.searchRoots -and @($existingConfig.searchRoots).Count -gt 0) {
        $SearchRoot = @($existingConfig.searchRoots)
    }
    else {
        $candidates = @(
            (Join-Path $HOME "Documents\Project"),
            (Join-Path $HOME "Documents\Projects"),
            (Join-Path $HOME "Documents"),
            (Join-Path $HOME "source\repos")
        ) | Select-Object -Unique

        $existingRoots = @($candidates | Where-Object { Test-Path $_ })
        if ($existingRoots.Count -gt 0) {
            Write-Host ""
            Write-Step "Detected possible repository directories:"
            for ($i = 0; $i -lt $existingRoots.Count; $i++) {
                Write-Host "  [$($i + 1)] $($existingRoots[$i])" -ForegroundColor White
            }
            Write-Host ""
            $answer = Read-Host "Use all detected directories? [Y/n]"
            if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^(?i:y|yes)$') {
                $SearchRoot = $existingRoots
            }
        }

        if (-not $SearchRoot -or $SearchRoot.Count -eq 0) {
            Write-Host ""
            Write-Host "Enter directories containing Git repositories." -ForegroundColor White
            Write-Host "Separate multiple paths with a semicolon (;)." -ForegroundColor DarkGray
            $entered = Read-Host "Repository paths"
            if (-not [string]::IsNullOrWhiteSpace($entered)) {
                $SearchRoot = @(
                    $entered.Split(';') |
                        ForEach-Object { $_.Trim().Trim('"') } |
                        Where-Object { $_ }
                )
            }
        }
    }
}

if (-not $SearchRoot -or $SearchRoot.Count -eq 0) {
    Write-Fail "No repository search directory was configured."
    exit 1
}

$resolvedRoots = @()
foreach ($root in $SearchRoot) {
    $expanded = [Environment]::ExpandEnvironmentVariables($root)
    if ($expanded.StartsWith('$HOME', [System.StringComparison]::OrdinalIgnoreCase)) {
        $suffix = $expanded.Substring(5) -replace '^[\\/]+', ''
        $expanded = if ([string]::IsNullOrWhiteSpace($suffix)) { $HOME } else { Join-Path $HOME $suffix }
    }

    try { $fullPath = [System.IO.Path]::GetFullPath($expanded) }
    catch { Write-Warn "Skipping invalid path: $root"; continue }

    if (-not (Test-Path $fullPath)) {
        $create = if ($Force) { 'y' } else { Read-Host "Directory does not exist: '$fullPath'. Create it? [y/N]" }
        if ($create -match '^(?i:y|yes)$') {
            New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
        }
        else {
            Write-Warn "Skipping: $fullPath"
            continue
        }
    }
    $resolvedRoots += $fullPath
}
$resolvedRoots = @($resolvedRoots | Sort-Object -Unique)

if ($resolvedRoots.Count -eq 0) {
    Write-Fail "No valid repository directories remain."
    exit 1
}

# v4 config schema. Preserve existing values where possible.
$ignoredDirectories = @("node_modules","bin","obj",".venv","venv","target","packages",".vs",".idea")
$protectedBranches = @("main","master","release/*")
$largeFileThresholdMB = 25
$defaultRemote = "origin"
$aliases = @{}
$favorites = @()

if ($existingConfig) {
    if ($existingConfig.ignoredDirectories) { $ignoredDirectories = @($existingConfig.ignoredDirectories) }
    if ($existingConfig.protectedBranches) { $protectedBranches = @($existingConfig.protectedBranches) }
    if ($existingConfig.largeFileThresholdMB) { $largeFileThresholdMB = [int]$existingConfig.largeFileThresholdMB }
    if ($existingConfig.defaultRemote) { $defaultRemote = [string]$existingConfig.defaultRemote }
    if ($existingConfig.aliases) {
        foreach ($p in $existingConfig.aliases.PSObject.Properties) { $aliases[$p.Name] = [string]$p.Value }
    }
    if ($existingConfig.favorites) { $favorites = @($existingConfig.favorites) }
}

$config = [ordered]@{
    searchRoots = @($resolvedRoots)
    ignoredDirectories = @($ignoredDirectories)
    protectedBranches = @($protectedBranches)
    largeFileThresholdMB = $largeFileThresholdMB
    defaultRemote = $defaultRemote
    aliases = $aliases
    favorites = @($favorites)
}

$config | ConvertTo-Json -Depth 8 | Set-Content -Path $ConfigFile -Encoding UTF8
Write-Ok "Configuration saved."
Write-Host "    $ConfigFile" -ForegroundColor DarkGray

# Install a stable global gp function into the active PowerShell profile.
if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

$beginMarker = "# >>> GPush >>>"
$endMarker   = "# <<< GPush <<<"
$profileBlock = @"
$beginMarker
Remove-Item Alias:gp -Force -ErrorAction SilentlyContinue
function Global:gp {
    & "$TargetScript" @args
}
$endMarker
"@

$currentProfile = if (Test-Path $PROFILE) { Get-Content -Path $PROFILE -Raw -ErrorAction SilentlyContinue } else { "" }
$pattern = "(?s)$([regex]::Escape($beginMarker)).*?$([regex]::Escape($endMarker))"
if ($currentProfile -match $pattern) {
    $updatedProfile = [regex]::Replace($currentProfile, $pattern, $profileBlock)
    Set-Content -Path $PROFILE -Value $updatedProfile -Encoding UTF8
    Write-Ok "Existing GPush profile entry updated."
}
else {
    Add-Content -Path $PROFILE -Value "`r`n$profileBlock`r`n" -Encoding UTF8
    Write-Ok "GPush command added to the PowerShell profile."
}

# Cache may refer to repos outside newly selected roots; rebuild it on first run.
if (Test-Path $CacheFile) { Remove-Item $CacheFile -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Step "Configured repository roots:"
foreach ($root in $resolvedRoots) { Write-Host "  $root" -ForegroundColor Green }

Write-Host ""
Write-Ok "Installation complete."
Write-Host "Reload the current terminal:" -ForegroundColor White
Write-Host "  . `$PROFILE" -ForegroundColor Cyan
Write-Host ""
Write-Host "Then try:" -ForegroundColor White
Write-Host "  gp --version" -ForegroundColor Green
Write-Host "  gp help" -ForegroundColor Green
Write-Host "  gp config doctor" -ForegroundColor Green
Write-Host ""
