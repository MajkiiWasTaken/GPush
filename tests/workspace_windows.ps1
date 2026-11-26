$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows/gp.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }

# Load only the functions under test, without running the installed CLI.
foreach ($name in @('Select-GPushWorkspaceRows','Get-GPushWorkspacePaths','Resolve-GPushAlias','Get-RepositoryMatches','ConvertTo-GPushNativeArgument','Start-GPushNativeCapture','Stop-GPushNativeCapture','Test-GPushOperationCancelled','Invoke-GPushNativeCapture','Get-GPushStatsData')) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$RepositoryAliases = @{}

function Test-Selection {
    param([string[]]$Keys, [string]$Expected, [switch]$Multiple)
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    foreach ($name in $Keys) {
        $character = if ($name -eq 'Spacebar') { [char]32 } elseif ($name.Length -eq 1) { [char]$name } else { [char]0 }
        $queue.Enqueue([PSCustomObject]@{Key=$name;KeyChar=$character})
    }
    $reader = { if ($queue.Count) { $queue.Dequeue() } else { throw 'Unexpected request for another key.' } }.GetNewClosure()
    $actual = @(Select-GPushWorkspaceRows -Title 'Test' -Rows @('alpha','beta','gamma') -Multiple:$Multiple -TestKeyReader $reader)
    if (($actual -join ',') -ne $Expected) { throw "Selection mismatch: expected '$Expected', got '$($actual -join ',')'" }
}

Test-Selection -Keys @('Enter') -Expected '0'
Test-Selection -Keys @('DownArrow','Enter') -Expected '1'
Test-Selection -Keys @('UpArrow','Enter') -Expected '2'
Test-Selection -Keys @('UpArrow','DownArrow','Enter') -Expected '0'
Test-Selection -Keys @('b','Enter') -Expected '1'
Test-Selection -Keys @('z','Backspace','DownArrow','Enter') -Expected '1'
Test-Selection -Keys @('Escape') -Expected ''
Test-Selection -Keys @('Enter') -Expected '0' -Multiple
Test-Selection -Keys @('Spacebar','DownArrow','Spacebar','Enter') -Expected '0,1' -Multiple
Test-Selection -Keys @('A','DownArrow','Spacebar','Enter') -Expected '0,2' -Multiple
Test-Selection -Keys @('A','X','DownArrow','Enter') -Expected '1' -Multiple
Test-Selection -Keys @('Spacebar','Escape') -Expected '' -Multiple
Write-Host 'PASS Windows keyboard selection, filtering, marking and cancellation.'

$repos = @(
    [PSCustomObject]@{Name='Repo [test]';Path='C:\projects\Repo [test]'},
    [PSCustomObject]@{Name='Repo t';Path='C:\projects\Repo t'}
)
$matched = @(Get-RepositoryMatches -Repos $repos -Search 'Repo [')
if ($matched.Count -ne 1 -or $matched[0].Name -ne 'Repo [test]') { throw 'Literal repository search failed.' }
$matched = @(Get-RepositoryMatches -Repos $repos -Search $repos[0].Path)
if ($matched.Count -ne 1 -or $matched[0].Name -ne 'Repo [test]') { throw 'Exact repository path matching failed.' }
Write-Host 'PASS literal repository matching.'

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('gpush-test-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($root) | Out-Null
try {
    & git -C $root init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Git init failed.' }
    $filename = ([string][char]0x010D) + ' [test].txt'
    [System.IO.File]::WriteAllText((Join-Path $root $filename), 'test')
    $untracked = @(Get-GPushWorkspacePaths -Path $root -Mode untracked)
    if ($untracked.Count -ne 1 -or $untracked[0] -cne $filename) { throw 'Raw filename inspection failed.' }
    & git -C $root --literal-pathspecs add -- $filename
    if ($LASTEXITCODE -ne 0) { throw 'Git add failed.' }
    $staged = @(Get-GPushWorkspacePaths -Path $root -Mode staged)
    if ($staged.Count -ne 1 -or $staged[0] -cne $filename) { throw 'Staged filename inspection failed.' }
    Write-Host 'PASS Unicode and bracket filenames, staged and untracked.'
    $gitPath = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    $native = Invoke-GPushNativeCapture -Executable $gitPath -ArgumentVector @('-c','core.quotePath=false','-C',$root,'--literal-pathspecs','ls-files','--',$filename)
    if ($native.ExitCode -ne 0 -or $native.Stdout.Trim() -cne $filename) { throw 'Native process literal filename handling failed.' }
    & git -C $root -c 'user.name=GPush CI' -c 'user.email=gpush@example.invalid' commit -m 'Test activity' --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Git commit failed.' }
    $script:TestStatsRepository = [PSCustomObject]@{Name='Stats test';Path=$root}
    function Get-GPushCache { return $script:TestStatsRepository }
    $first = Get-GPushStatsData -Period 30 -Refresh
    $second = Get-GPushStatsData -Period 30
    if ($first.Total -ne 1 -or $first.Added -ne 1 -or $first.Unavailable -ne 0 -or $first.At -ne $second.At) { throw 'Statistics calculation or cache failed.' }
    Write-Host 'PASS Windows native process argument handling and statistics cache.' 
} finally {
    for ($attempt=1; $attempt -le 3; $attempt++) {
        try { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop }; break }
        catch { if ($attempt -eq 3) { throw }; Start-Sleep -Milliseconds (200*$attempt) }
    }
}
exit 0
