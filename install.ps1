param(
    [string[]]$SearchRoot,
    [switch]$Force
)

$InstallerVersion = "3.1.2"

[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding           = [System.Text.UTF8Encoding]::new($false)

# Keep non-ASCII author characters independent of source-file encoding.
$AuthorName = "Michal " + [char]0x0160 + "vr" + [char]0x010D + "ek"

$ErrorActionPreference = "Stop"

function Write-Step([string]$Text) {
    Write-Host "[*] $Text" -ForegroundColor Cyan
}

function Write-Ok([string]$Text) {
    Write-Host "[+] $Text" -ForegroundColor Green
}

function Write-Warn([string]$Text) {
    Write-Host "[!] $Text" -ForegroundColor Yellow
}

function Write-Fail([string]$Text) {
    Write-Host "[-] $Text" -ForegroundColor Red
}

Write-Host ""
Write-Host "GPush installer " -NoNewline -ForegroundColor Cyan
Write-Host $InstallerVersion -ForegroundColor DarkGray
Write-Host "Made by " -NoNewline -ForegroundColor DarkGray
Write-Host $AuthorName -ForegroundColor Magenta
Write-Host ""

$ScriptPath = Join-Path $PSScriptRoot "gp.ps1"

if (-not (Test-Path $ScriptPath)) {
    Write-Fail "gp.ps1 was not found next to install.ps1."
    Write-Host "Expected: $ScriptPath" -ForegroundColor DarkGray
    exit 1
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Fail "Git was not found in PATH."
    Write-Host "Install Git first and run this installer again."
    exit 1
}

Write-Ok "Git detected: $((git --version) -join ' ')"

$ConfigDir  = Join-Path $env:LOCALAPPDATA "GPush"
$ConfigFile = Join-Path $ConfigDir "config.json"

if (-not (Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
}

# Pick useful defaults when no search root was supplied.
if (-not $SearchRoot -or $SearchRoot.Count -eq 0) {
    $candidates = @(
        (Join-Path $HOME "Documents\Projects"),
        (Join-Path $HOME "Documents\Work"),
        (Join-Path $HOME "source\repos")
    )

    $existing = @($candidates | Where-Object { Test-Path $_ })

    if ($existing.Count -gt 0) {
        Write-Host ""
        Write-Step "Detected possible repository directories:"
        for ($i = 0; $i -lt $existing.Count; $i++) {
            Write-Host "  [$($i + 1)] $($existing[$i])" -ForegroundColor White
        }

        Write-Host ""
        $answer = Read-Host "Use these directories? [Y/n]"

        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^(y|yes)$') {
            $SearchRoot = $existing
        }
    }

    if (-not $SearchRoot -or $SearchRoot.Count -eq 0) {
        Write-Host ""
        Write-Host "Enter directories containing your Git repositories." -ForegroundColor White
        Write-Host "Separate multiple paths with a semicolon (;)." -ForegroundColor DarkGray
        $entered = Read-Host "Repository paths"

        if (-not [string]::IsNullOrWhiteSpace($entered)) {
            $SearchRoot = @(
                $entered.Split(";") |
                    ForEach-Object { $_.Trim().Trim('"') } |
                    Where-Object { $_ }
            )
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

    try {
        $fullPath = [System.IO.Path]::GetFullPath($expanded)
    }
    catch {
        Write-Warn "Skipping invalid path: $root"
        continue
    }

    if (-not (Test-Path $fullPath)) {
        $create = Read-Host "Directory does not exist: '$fullPath'. Create it? [y/N]"
        if ($create -match '^(y|yes)$') {
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

$config = [ordered]@{
    SearchRoots = $resolvedRoots
}

$config |
    ConvertTo-Json -Depth 4 |
    Set-Content -Path $ConfigFile -Encoding UTF8

Write-Ok "Configuration saved."
Write-Host "    $ConfigFile" -ForegroundColor DarkGray

if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

$beginMarker = "# >>> GPush >>>"
$endMarker   = "# <<< GPush <<<"

$profileBlock = @"
$beginMarker
Remove-Item Alias:gp -Force -ErrorAction SilentlyContinue
function Global:gp {
    & "$ScriptPath" @args
}
$endMarker
"@

$currentProfile = ""
if (Test-Path $PROFILE) {
    $currentProfile = Get-Content -Path $PROFILE -Raw -ErrorAction SilentlyContinue
}

$escapedBegin = [regex]::Escape($beginMarker)
$escapedEnd   = [regex]::Escape($endMarker)
$pattern      = "(?s)$escapedBegin.*?$escapedEnd"

if ($currentProfile -match $pattern) {
    $updatedProfile = [regex]::Replace($currentProfile, $pattern, $profileBlock)
    Set-Content -Path $PROFILE -Value $updatedProfile -Encoding UTF8
    Write-Ok "Existing GPush profile entry updated."
}
else {
    Add-Content -Path $PROFILE -Value "`r`n$profileBlock`r`n" -Encoding UTF8
    Write-Ok "GPush command added to the PowerShell profile."
}

# Remove stale repository cache so the first run uses the new configuration.
$CacheFile = Join-Path $ConfigDir "repos.json"
if (Test-Path $CacheFile) {
    Remove-Item $CacheFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Step "Configured repository roots:"
foreach ($root in $resolvedRoots) {
    Write-Host "  $root" -ForegroundColor Green
}

Write-Host ""
Write-Ok "Installation complete."
Write-Host ""
Write-Host "Reload the current terminal:" -ForegroundColor White
Write-Host "  . `$PROFILE" -ForegroundColor Cyan
Write-Host ""
Write-Host "Then try:" -ForegroundColor White
Write-Host "  gp --help" -ForegroundColor Green
Write-Host "  gp --list" -ForegroundColor Green
Write-Host ""
