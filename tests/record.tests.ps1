# Tests of dot_local\bin\record.ps1, against a made-up origin, chezmoi source,
# run folder and checks script. Nothing here reaches GitHub or changes sophon.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\record.tests.ps1
#   pwsh       -NoProfile -File tests\record.tests.ps1
#
# Run it both ways, elevated: record.ps1 refuses a session that is not, and it
# has to work under Windows PowerShell 5.1 and pwsh 7. record.ps1 is started
# with the PowerShell this file was started with. TESTING.md says where this
# fits.
#
# Each case prints "ok" or "FAIL". The exit code is 1 if any case failed.

param(
    # The script under test. Left out: the one in this checkout.
    [string]$Record = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dot_local\bin\record.ps1')
)

$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) "record-tests-$PID"
$shell = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
$utf8 = New-Object Text.UTF8Encoding $false
$today = Get-Date -Format 'yyyy-MM-dd'
$passed = 0
$failed = 0

# git, quietly, in one of the made-up repositories. Identity and config come
# from the environment, so nothing of the machine's own git setup is used.
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@example.invalid'
$env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@example.invalid'
$env:GIT_CONFIG_NOSYSTEM = '1'
function G {
    $dir = $args[0]
    $rest = @($args | Select-Object -Skip 1)
    $before = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = @(& git -C $dir -c core.autocrlf=false @rest 2>&1 | ForEach-Object { "$_" }) } finally { $ErrorActionPreference = $before }
    ($out -join "`n").Trim()
}

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:passed++; Write-Host "ok    $Name" }
    else { $script:failed++; Write-Host "FAIL  $Name"; if ($Detail) { Write-Host $Detail } }
}

# A new origin, a chezmoi source cloned from it, an empty cert folder and the
# stand-in for the checks.
function New-Fixture {
    if (Test-Path $root) { Remove-Item $root -Recurse -Force }
    New-Item -ItemType Directory -Path $root, "$root\cert" | Out-Null
    # Through G, like every git call here: Windows PowerShell makes an error
    # of anything git writes to stderr, and cloning an empty repository warns.
    [void](G $root init -q --bare -b main "$root\origin")
    [void](G $root clone -q "$root\origin" "$root\source")
    [IO.File]::WriteAllText("$root\source\file", "one`n", $utf8)
    [void](G "$root\source" add -A); [void](G "$root\source" commit -q -m one); [void](G "$root\source" push -q origin main)
    # The stand-in. RECORD_TEST_MODE picks how the checks end.
    [IO.File]::WriteAllText("$root\checks.ps1", @'
param([string]$OutFile)
$mode = $env:RECORD_TEST_MODE
if ($mode -eq 'dies') { Write-Host 'partway'; exit 0 }
if ($mode -eq 'dirty') { [IO.File]::WriteAllText((Join-Path $env:RECORD_TEST_SOURCE 'stray'), 'x') }
if ($mode -eq 'moved') { & git -C $env:RECORD_TEST_SOURCE commit -q --allow-empty -m moved 2>$null | Out-Null }
$second = ($mode -ne 'fail')
$results = @(
    [pscustomobject]@{ name = 'first';  pass = $true;   expect = 'a'; found = 'a' },
    [pscustomobject]@{ name = 'second'; pass = $second; expect = 'b'; found = 'c' }
)
[IO.File]::WriteAllText($OutFile, (ConvertTo-Json -InputObject $results), (New-Object Text.UTF8Encoding $false))
Write-Host 'the stand-in checks ran'
if ($second) { exit 0 } else { exit 1 }
'@, $utf8)
}

function Head { param([string]$Rev = 'HEAD') G "$root\source" rev-parse $Rev }

# The folder of a run, as recertify.ps1 leaves it.
function New-Run {
    param([string]$Stamp, [string]$Branch, [string]$Commit, [string]$Tree,
          [string]$Verdict = 'CERTIFIED', [int]$Passed = 17, [int]$Total = 17, [switch]$NoResult)
    $dir = Join-Path "$root\cert" "$Stamp-$($Branch -replace '[^\w.-]', '-')"
    New-Item -ItemType Directory -Path $dir | Out-Null
    if (-not $NoResult) {
        $result = [ordered]@{ verdict = $Verdict; repo = 'x/y'; branch = $Branch; commit = $Commit; tree = $Tree
            machine = 'VM test-cert from checkpoint clean, Windows 11 Test build 1, user certuser, computer TEST'
            checksPassed = $Passed; checksTotal = $Total; started = $Stamp }
        [IO.File]::WriteAllText((Join-Path $dir 'result.json'), ($result | ConvertTo-Json), $utf8)
    }
    $dir
}

# Run record.ps1 and give back its exit code and everything it printed.
function Invoke-Record {
    $extra = @($args)
    # sophon, unless the case names another machine.
    if ($extra -notcontains '-ComputerName') { $extra += '-ComputerName', 'sophon' }
    $before = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $shell -NoProfile -ExecutionPolicy Bypass -File $Record -SourceDir "$root\source" -CertRoot "$root\cert" `
            -ChecksScript "$root\checks.ps1" @extra 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $before }
    [pscustomobject]@{ Code = $code; Text = ($out -join "`n") }
}

function Origin-Tags { G "$root\origin" tag -l 'certified/*' }
function Origin-Stable {
    $sha = G "$root\origin" rev-parse --verify --quiet refs/heads/stable
    if ($sha -match '^[0-9a-f]{40}$') { $sha } else { 'none' }
}
function Add-Commit {
    param([string]$Text)
    [IO.File]::WriteAllText("$root\source\file", "$Text`n", $utf8)
    [void](G "$root\source" commit -q -am $Text); [void](G "$root\source" push -q origin main)
}

try {
    # --- a run of main: the dry run, then the record ------------------------
    New-Fixture
    $c = Head; $t = Head 'HEAD^{tree}'; $s = $c.Substring(0, 7)
    [IO.File]::WriteAllText("$root\cert\a-stray-file.reg", 'x', $utf8)
    [void](New-Run '20260101-000000' 'not-finished' $c $t -NoResult)
    [void](New-Run '20260101-000001' 'main' $c $t)
    $r = Invoke-Record -DryRun
    Check 'dry run: shows the tag on the commit' ($r.Code -eq 0 -and $r.Text -match [regex]::Escape("certified/$today-$s -> $c")) $r.Text
    Check 'dry run: both results' ($r.Text -match 'Clean-machine result: 17 of 17 checks passed' -and $r.Text -match 'Real-hardware result: 2 of 2 checks passed') $r.Text
    Check 'dry run: machine, host, built from, tree' ($r.Text -match 'Machine: +VM test-cert' -and $r.Text -match 'Host: +sophon, ' -and $r.Text -match 'Built from: +main' -and $r.Text -match "Tree: +$t") $r.Text
    Check 'dry run: no Triggered by line without -Reason' ($r.Text -notmatch 'Triggered by')
    Check 'dry run: says stable will be created' ($r.Text -match 'no stable branch yet')
    Check 'dry run: makes no tag and no stable' ((Origin-Tags) -eq '' -and (Origin-Stable) -eq 'none' -and (G "$root\source" tag -l) -eq '')
    Check 'the newest run with a result is the one read' ($r.Text -match '20260101-000001-main')

    $r = Invoke-Record -Reason 'a test'
    Check 'a run of main is recorded' ($r.Code -eq 0 -and $r.Text -match 'RECORDED') $r.Text
    Check 'the tag is on origin, annotated, on the commit' ((G "$root\origin" cat-file -t "certified/$today-$s") -eq 'tag' -and (G "$root\origin" rev-parse "certified/$today-$s^{commit}") -eq $c)
    Check 'the message has the reason' ((G "$root\origin" tag -n99 -l 'certified/*') -match 'Triggered by: a test')
    Check 'the first record creates stable at the commit' ((Origin-Stable) -eq $c)
    $r = Invoke-Record
    Check 'stops: the commit is already recorded' ($r.Code -eq 1 -and $r.Text -match 'already recorded') $r.Text

    # --- stable moves forward, and stays for an older commit ----------------
    Add-Commit 'two'; $c2 = Head; $t2 = Head 'HEAD^{tree}'
    Add-Commit 'three'; $c3 = Head; $t3 = Head 'HEAD^{tree}'
    [void](New-Run '20260103-000000' 'main' $c3 $t3)
    $r = Invoke-Record
    Check 'a later record moves stable forward' ($r.Code -eq 0 -and (Origin-Stable) -eq $c3) $r.Text
    [void](G "$root\source" reset -q --hard $c2)
    $older = New-Run '20260102-000000' 'main' $c2 $t2
    $r = Invoke-Record -Commit $c2 -Log $older
    Check 'an older commit is tagged and stable stays ahead' ($r.Code -eq 0 -and $r.Text -match 'at or ahead of this commit' -and (Origin-Stable) -eq $c3) $r.Text
    [void](G "$root\source" reset -q --hard $c3)

    # --- a branch run, then a rebase merge: same tree, new commit -----------
    New-Fixture
    [void](G "$root\source" switch -q -c topic)
    [IO.File]::WriteAllText("$root\source\file", "two`n", $utf8); [void](G "$root\source" commit -q -am two)
    $bc = Head; $bt = Head 'HEAD^{tree}'
    [void](G "$root\source" switch -q main)
    $env:GIT_COMMITTER_DATE = '2030-01-01T00:00:00'; [void](G "$root\source" cherry-pick topic); $env:GIT_COMMITTER_DATE = $null
    $mc = Head; [void](G "$root\source" push -q origin main)
    [void](New-Run '20260201-000000' 'topic' $bc $bt)
    $r = Invoke-Record
    Check 'the test made a merge with a new commit' ($bc -ne $mc)
    Check 'a branch run tags the commit on main' ($r.Code -eq 0 -and (G "$root\origin" rev-parse "certified/$today-$($mc.Substring(0, 7))^{commit}") -eq $mc) $r.Text
    Check 'and names the branch and its commit' ($r.Text -match "Built from: +branch topic at $($bc.Substring(0, 7))") $r.Text

    # --- what stops it ------------------------------------------------------
    New-Fixture
    $c = Head; $t = Head 'HEAD^{tree}'
    $r = Invoke-Record -ComputerName elsewhere
    Check 'stops: another machine' ($r.Code -eq 1 -and $r.Text -match 'This machine is elsewhere') $r.Text
    $r = Invoke-Record
    Check 'stops: no run with a result' ($r.Code -eq 1 -and $r.Text -match 'No run with a result') $r.Text
    $r = Invoke-Record -Log (New-Run '20260301-000000' 'main' $c $t -NoResult)
    Check 'stops: the run named has no result' ($r.Code -eq 1 -and $r.Text -match 'has no result.json') $r.Text
    $r = Invoke-Record -Log (New-Run '20260302-000000' 'main' $c $t -Verdict 'NOT CERTIFIED' -Passed 16)
    Check 'stops: NOT CERTIFIED' ($r.Code -eq 1 -and $r.Text -match 'was NOT CERTIFIED') $r.Text
    $r = Invoke-Record -Log (New-Run '20260303-000000' 'main' $c $t -Passed 16)
    Check 'stops: a check failed in the VM' ($r.Code -eq 1 -and $r.Text -match '16 of 17 checks passed in the VM') $r.Text
    $r = Invoke-Record -Log (New-Run '20260304-000000' 'main' $c '4b825dc642cb6eb9a060e54bf8d69288fbee4904')
    Check 'stops: trees differ' ($r.Code -eq 1 -and $r.Text -match 'trees differ') $r.Text
    $good = New-Run '20260305-000000' 'main' $c $t

    [IO.File]::WriteAllText("$root\source\file", "edited`n", $utf8)
    $r = Invoke-Record -Log $good
    Check 'stops: a modified file in the source' ($r.Code -eq 1 -and $r.Text -match 'has uncommitted changes') $r.Text
    [void](G "$root\source" checkout -q -- file)
    [IO.File]::WriteAllText("$root\source\stray", 'x', $utf8)
    $r = Invoke-Record -Log $good
    Check 'stops: an untracked file in the source' ($r.Code -eq 1 -and $r.Text -match 'has uncommitted changes') $r.Text
    Remove-Item "$root\source\stray"

    $env:RECORD_TEST_SOURCE = "$root\source"
    $env:RECORD_TEST_MODE = 'fail'; $r = Invoke-Record -Log $good
    Check 'stops: a check fails on sophon' ($r.Code -eq 1 -and $r.Text -match 'checks failed on sophon: 1 of 2 passed') $r.Text
    $env:RECORD_TEST_MODE = 'dies'; $r = Invoke-Record -Log $good
    Check 'stops: the checks do not reach their end' ($r.Code -eq 1 -and $r.Text -match 'did not run to their end') $r.Text
    $env:RECORD_TEST_MODE = 'dirty'; $r = Invoke-Record -Log $good
    Check 'stops: the source gains a file while the checks run' ($r.Code -eq 1 -and $r.Text -match 'changed while this script ran') $r.Text
    Remove-Item "$root\source\stray" -ErrorAction SilentlyContinue
    $env:RECORD_TEST_MODE = 'moved'; $r = Invoke-Record -Log $good
    Check 'stops: the source moves to another commit while the checks run' ($r.Code -eq 1 -and $r.Text -match 'changed while this script ran') $r.Text
    [void](G "$root\source" reset -q --hard origin/main)
    $env:RECORD_TEST_MODE = $null

    $r = Invoke-Record -Log $good -Reason ' '
    Check 'stops: an empty reason' ($r.Code -eq 1 -and $r.Text -match 'one line of text') $r.Text
    $r = Invoke-Record -Log $good -Reason "two`nlines"
    Check 'stops: a reason of two lines' ($r.Code -eq 1 -and $r.Text -match 'one line of text') $r.Text

    [void](G "$root\source" remote set-url --push origin "$root\nowhere")
    $r = Invoke-Record -Log $good
    Check 'stops before the checks when the push cannot work' ($r.Code -eq 1 -and $r.Text -match 'cannot push the tag and stable' -and $r.Text -notmatch 'Running the checks') $r.Text
    [void](G "$root\source" remote set-url --push origin "$root\origin")

    [void](G "$root\source" switch -q -c side); [IO.File]::WriteAllText("$root\source\file", "side`n", $utf8); [void](G "$root\source" commit -q -am side)
    $side = Head; [void](G "$root\source" switch -q main)
    $r = Invoke-Record -Log $good -Commit $side
    Check 'stops: a commit that is not on main' ($r.Code -eq 1 -and $r.Text -match 'is not on origin/main') $r.Text

    # stable off main, ahead of the commit; and a branch that only ends in its name
    [void](G "$root\source" push -q origin "${side}:refs/heads/stable")
    $r = Invoke-Record -Log $good
    Check 'stops: stable is ahead of the commit but off main' ($r.Code -eq 1 -and $r.Text -match 'not a commit of main' -and $r.Text -notmatch 'Running the checks') $r.Text
    [void](G "$root\origin" update-ref -d refs/heads/stable)
    [void](G "$root\source" push -q origin "${c}:refs/heads/x/refs/heads/stable")
    $r = Invoke-Record -Log $good -DryRun
    Check 'a branch named x/refs/heads/stable is not taken for stable' ($r.Code -eq 0 -and $r.Text -match 'no stable branch yet') $r.Text

    # the source behind the commit, on main and on stable
    Add-Commit 'next'; $n = Head; $nt = Head 'HEAD^{tree}'
    $next = New-Run '20260306-000000' 'main' $n $nt
    [void](G "$root\source" reset -q --hard $c)
    $r = Invoke-Record -Log $next
    Check 'stops: the source is behind, and says chezmoi update' ($r.Code -eq 1 -and $r.Text -match 'Run: chezmoi update') $r.Text
    [void](G "$root\source" switch -q -c stable)
    $r = Invoke-Record -Log $next
    Check 'stops: the source follows stable, and says how to follow main' ($r.Code -eq 1 -and $r.Text -match 'follows stable' -and $r.Text -match 'switch main') $r.Text

    Check 'after every stop, origin has no tag' ((Origin-Tags) -eq '') (Origin-Tags)
} finally {
    $env:RECORD_TEST_MODE = $null; $env:RECORD_TEST_SOURCE = $null
    if (Test-Path $root) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "$passed passed, $failed failed"
if ($failed) { exit 1 }
exit 0
