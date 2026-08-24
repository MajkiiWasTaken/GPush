$ScriptPath = Join-Path $PSScriptRoot "gp.ps1"

if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

$profileEntry = @"

# GitPush
Remove-Item Alias:gp -Force -ErrorAction SilentlyContinue

function Global:gp {
    & "$ScriptPath" @args
}
"@

$currentProfile = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue

if ($currentProfile -notmatch "# GitPush") {
    Add-Content -Path $PROFILE -Value $profileEntry
    Write-Host "GitPush added to PowerShell profile." -ForegroundColor Green
}
else {
    Write-Host "GitPush is already installed." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Reload your profile with:" -ForegroundColor Cyan
Write-Host ". `$PROFILE"