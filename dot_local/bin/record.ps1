# Record a certification as an annotated tag on the commit it certifies.
#
#   & "$HOME\.local\bin\record.ps1"                       # record the newest run
#   & "$HOME\.local\bin\record.ps1" -DryRun               # show the tag, create nothing
#   & "$HOME\.local\bin\record.ps1" -Reason "<one line>"  # a trigger no commit records
#   & "$HOME\.local\bin\record.ps1" -Log <run folder>     # record another run
#   & "$HOME\.local\bin\record.ps1" -Commit <sha>         # a commit other than main's tip
#
# A certification has two halves: recertify.ps1 rebuilds the certification VM
# from its clean checkpoint, and recertify-checks.ps1 passes on sophon with the
# same commit applied. This script checks that both halves are about the same
# commit, runs the second half, and writes the result into a tag named
#
#   certified/<yyyy-MM-dd>-<short commit>
#
# on that commit. Nothing is typed by hand, no file changes, and no pull
# request is needed. A tag that exists always means a full certification.
#
# It then moves the branch `stable` to that commit. A rebuild clones stable, so
# a rebuilt machine gets a commit only once it is certified. stable only moves
# forward, and the tag and the branch are pushed together or not at all.
#
# Run it on sophon, elevated, after `chezmoi update` has applied the commit
# there: at the desktop from an elevated terminal, or over ssh, where the
# session is elevated already. sophon's chezmoi source follows main: it is the
# one machine this repo configures, so it takes a commit before it is
# certified, because the second half of a certification is the checks passing
# on it. The tag is made in that source, and pushed with sophon's deploy key.
# "Deploy key" in the README says how that is set up.
#
# WHAT STOPS IT, with no tag made:
#
#   - this machine is not sophon, or the session is not elevated
#   - the run was not CERTIFIED
#   - the commit is not on origin/main, or already has a certified/ tag
#   - stable holds a commit that is not a commit of main
#   - the tree of the commit is not the tree the VM built
#   - the chezmoi source on sophon is at another commit, or has uncommitted
#     changes, or `chezmoi status` is not empty, before the checks or after
#   - this session cannot push to GitHub
#   - a check fails on sophon, or the checks do not run to their end
#
# The tree comparison is what lets a branch run count. A rebase merge gives the
# commits new SHAs, so the commit on main is never the commit a branch run
# built. It is the same content when the trees are equal, and only then.
#
# THE CHECKS CHANGE THE MACHINE. Two of them are not read-only, as the head of
# recertify-checks.ps1 says: one makes again any Ruby toolchain link it finds
# wrong, and one builds a gem into a temporary folder and deletes it. On a
# healthy machine neither leaves anything behind.
#
# It runs under Windows PowerShell 5.1 and pwsh 7. tests\record.tests.ps1 in
# the repository runs it against a made-up origin; see TESTING.md.

param(
    # The folder of the run to record, as recertify.ps1 names it at its end.
    # Left out: the newest folder under -CertRoot that holds a result.
    [string]$Log,
    # The commit to certify. Left out: the tip of origin/main.
    [string]$Commit,
    # One line, for a trigger that is in no commit: a Windows feature update,
    # a new checkpoint, or a second run of a commit that has not changed.
    [string]$Reason,
    # Show the tag and stop. Nothing is created and nothing is pushed.
    [switch]$DryRun,

    # Where recertify.ps1 puts its runs.
    [string]$CertRoot = (Join-Path $HOME 'cert'),

    # The rest are for tests\record.tests.ps1, which points the script at a
    # made-up source, a stand-in for the checks and another machine's name.
    # With -SourceDir, chezmoi is not asked anything.
    [string]$SourceDir,
    [string]$ChecksScript = (Join-Path $HOME '.local\bin\recertify-checks.ps1'),
    [string]$ComputerName = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'

# The machines whose result a tag may record: the ones this repo configures,
# which is sophon alone. Anything else is a machine this repo was never
# applied to as itself, such as the certification VM.
$recordHosts = @('sophon')

function Write-Step { param([string]$Text) Write-Host ''; Write-Host ">> $Text" }

function Stop-Record {
    param([string]$Text)
    Write-Host ''
    Write-Host "STOPPED: $Text"
    Write-Host '   No tag was made.'
    exit 1
}

# Run git and give back its exit code and its output as text. Windows
# PowerShell turns anything a program writes to stderr into an error when it
# is redirected, and with $ErrorActionPreference = 'Stop' that ends the script
# on git's ordinary progress messages. So the preference is relaxed for the
# one call, and what comes back is strings.
#
# No param block, on purpose. With one, PowerShell reads git's own options as
# the function's: `cat-file -e` would be taken for -ErrorAction. Without one,
# everything given lands in $args as it was written.
function Invoke-Git {
    $gitArguments = $args
    $before = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $script:source @gitArguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $before
    }
    [pscustomobject]@{ Code = $code; Output = $output; Text = ($output -join "`n").Trim() }
}

$shaPattern = '^[0-9a-f]{40}$'

if ($recordHosts -notcontains $ComputerName.ToLowerInvariant()) {
    Stop-Record "This machine is $ComputerName. A certification is recorded on: $($recordHosts -join ', ')."
}

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) {
    Stop-Record 'This session is not elevated. The checks read sshd''s settings, which needs administrator rights.'
}

if ($PSBoundParameters.ContainsKey('Reason')) {
    if ([string]::IsNullOrWhiteSpace($Reason) -or $Reason -match "[`r`n]") {
        Stop-Record 'The reason has to be one line of text, and not empty.'
    }
}

# --- 1. The clean-machine result, from the folder of a recertify.ps1 run -----

if (-not $Log) {
    # The newest folder that holds a result. A folder's name starts with the
    # time its run began, so the names sort by time. ~\cert can hold other
    # things, and a run that never reached its verdict has no result.
    $runs = @(Get-ChildItem -Path $CertRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{8}-\d{6}-' -and (Test-Path (Join-Path $_.FullName 'result.json')) } |
        Sort-Object Name)
    if (-not $runs) { Stop-Record "No run with a result in $CertRoot. Run recertify.ps1 first." }
    $Log = $runs[-1].FullName
}
$resultFile = Join-Path $Log 'result.json'
if (-not (Test-Path $resultFile)) {
    Stop-Record "$Log has no result.json. The run did not finish, or it was made by a recertify.ps1 from before record.ps1 existed."
}

Write-Step "Reading the clean-machine result from $Log"
try {
    $result = Get-Content $resultFile -Raw | ConvertFrom-Json
} catch {
    Stop-Record "Could not read ${resultFile}: $($_.Exception.Message)"
}

if ($result.verdict -ne 'CERTIFIED') { Stop-Record "That run was $($result.verdict). Only a CERTIFIED run is recorded." }
if ("$($result.commit)" -notmatch $shaPattern -or "$($result.tree)" -notmatch $shaPattern) {
    Stop-Record 'The result does not name the commit and the tree the VM built.'
}
if (-not $result.branch) { Stop-Record 'The result does not name the branch the VM built.' }
if (-not $result.machine) { Stop-Record 'The result does not describe the VM.' }
$cleanPassed = [int]$result.checksPassed
$cleanTotal = [int]$result.checksTotal
if ($cleanTotal -lt 1 -or $cleanPassed -ne $cleanTotal) {
    Stop-Record "The result reports $cleanPassed of $cleanTotal checks passed in the VM."
}

Write-Host "   The VM built $($result.branch) at $($result.commit)"
Write-Host "   Tree $($result.tree)"
Write-Host "   $cleanPassed of $cleanTotal checks passed"

# --- 2. The commit to certify ------------------------------------------------

if ($SourceDir) {
    $script:source = $SourceDir
} else {
    if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) { Stop-Record 'chezmoi not found.' }
    $script:source = "$(chezmoi source-path)".Trim()
    if ($LASTEXITCODE -ne 0 -or -not $script:source) { Stop-Record "Could not ask chezmoi for its source path (exit $LASTEXITCODE)." }
}
if (-not (Test-Path (Join-Path $script:source '.git'))) {
    Stop-Record "The chezmoi source at $($script:source) is not a git checkout."
}

# A push must fail when it has no credential, and not wait for a password
# nobody is watching for.
$env:GIT_TERMINAL_PROMPT = '0'

Write-Step 'Fetching main and the certified/ tags from origin'
$fetch = Invoke-Git fetch --quiet origin '+refs/heads/main:refs/remotes/origin/main' 'refs/tags/certified/*:refs/tags/certified/*'
if ($fetch.Code -ne 0) { Stop-Record "Could not fetch from origin.`n$($fetch.Text)" }

$wanted = if ($Commit) { $Commit } else { 'origin/main' }
$resolved = Invoke-Git rev-parse --verify --quiet "$wanted^{commit}"
if ($resolved.Code -ne 0 -or $resolved.Text -notmatch $shaPattern) { Stop-Record "Not a commit: $wanted" }
$commitSha = $resolved.Text
if ((Invoke-Git merge-base --is-ancestor $commitSha origin/main).Code -ne 0) {
    Stop-Record "$commitSha is not on origin/main. Only a commit on main is certified."
}
$short = $commitSha.Substring(0, 7)
Write-Host "   The commit to certify is $commitSha"

$existing = (Invoke-Git tag --points-at $commitSha --list 'certified/*').Text
if ($existing) { Stop-Record "$short is already recorded: $existing" }

$today = Get-Date -Format 'yyyy-MM-dd'
$tag = "certified/$today-$short"

# Where stable is on origin, and whether this commit moves it.
#
# stable is the branch a rebuild clones. It only ever moves forward, to a
# commit this script has just tagged, so it should always be a commit of main
# that is behind the one being recorded. Three cases are fine: there is no
# stable yet and this creates it, stable is behind and moves here, or stable
# is already at or ahead of this commit (an older commit recorded with
# -Commit) and is left alone. Anything else, a stable that is not a commit of
# main above all, means stable has been pushed to by hand, and the script
# stops before it adds to that.
#
# The ref is spelled out in full, and the answer is still filtered for the one
# line whose ref is exactly that. ls-remote matches the end of a ref, so
# refs/heads/stable also returns a branch that is itself named
# x/refs/heads/stable, and lists it first.
$remote = Invoke-Git ls-remote --heads origin refs/heads/stable
if ($remote.Code -ne 0) { Stop-Record "Could not ask origin where stable is.`n$($remote.Text)" }
$stableAt = ''
foreach ($line in $remote.Output) {
    $parts = $line -split '\s+'
    if ($parts.Count -ge 2 -and $parts[1] -eq 'refs/heads/stable') { $stableAt = $parts[0] }
}
$moveStable = $true
if (-not $stableAt) {
    Write-Host '   There is no stable branch yet. Recording this creates it.'
} elseif ($stableAt -notmatch $shaPattern) {
    Stop-Record "Could not read where stable is from: $($remote.Text)"
} elseif ((Invoke-Git cat-file -e "$stableAt^{commit}").Code -ne 0) {
    Stop-Record "stable is at $stableAt, a commit this checkout does not have. It is not on main."
} elseif ((Invoke-Git merge-base --is-ancestor $stableAt origin/main).Code -ne 0) {
    # Asked before stable is compared with this commit. A commit on a branch
    # that was made from main's tip is ahead of this one and is still not a
    # commit of main: without this it would pass as "at or ahead".
    Stop-Record "stable is at $stableAt, which is not a commit of main.`n   stable should hold only commits of main. Find out who moved it before recording."
} elseif ($stableAt -eq $commitSha -or (Invoke-Git merge-base --is-ancestor $commitSha $stableAt).Code -eq 0) {
    $moveStable = $false
    Write-Host "   stable is at $($stableAt.Substring(0, 7)), at or ahead of this commit. It stays there."
} elseif ((Invoke-Git merge-base --is-ancestor $stableAt $commitSha).Code -eq 0) {
    Write-Host "   stable is at $($stableAt.Substring(0, 7)) and will move to $short."
} else {
    Stop-Record "stable is at $stableAt, which is neither behind nor ahead of $short."
}

# What gets pushed: the tag, and stable when it moves.
#
# Two lists, because the tag does not exist until step 7. The dry run in step
# 5 has only the commit to offer for the tag's name. The real push names the
# tag itself: pushing the commit to refs/tags/ would make a tag on origin that
# has no message, in place of the annotated one made here.
$pushCheckRefs = @("${commitSha}:refs/tags/$tag")
$pushRefs = @("refs/tags/${tag}:refs/tags/$tag")
if ($moveStable) {
    $pushCheckRefs += "${commitSha}:refs/heads/stable"
    $pushRefs += "${commitSha}:refs/heads/stable"
}

# --- 3. The trees -------------------------------------------------------------

$tree = (Invoke-Git rev-parse "$commitSha^{tree}").Text
if ($tree -ne $result.tree) {
    Stop-Record ("The trees differ, so the VM did not build what is at $short.`n" +
        "   Tree of ${short}:      $tree`n" +
        "   Tree the VM built: $($result.tree)`n" +
        '   Certify main: recertify.ps1')
}

# --- 4. The chezmoi source on sophon ------------------------------------------

# The source is at the commit, with nothing uncommitted anywhere in it and
# nothing untracked, and chezmoi has nothing left to apply. chezmoi applies
# the files, not the commit: an edited winget-packages.json, applied, gives a
# machine the checks pass for a tree the VM never built. And a source that is
# at the commit but not applied means the checks would run against whatever
# an earlier commit left.
#
# Asked twice: here, and again just before the tag is made. The checks take
# minutes. A `chezmoi update` in that time would have them check a newer
# commit, and the result would be recorded against this one.
function Test-Source {
    param([string]$When)

    $head = (Invoke-Git rev-parse HEAD).Text
    if ($head -ne $commitSha) {
        # Say what to do about it. A source on stable cannot get there with
        # an update: stable does not have the commit until this script has run.
        $branch = (Invoke-Git symbolic-ref --quiet --short HEAD).Text
        if ($branch -eq 'stable') {
            $advice = "The source here follows stable, which gets the commit only when it is recorded.`n" +
                "   sophon's source has to follow main to record:`n" +
                '     chezmoi git -- fetch origin; chezmoi git -- switch main; chezmoi update'
        } else {
            $advice = 'Run: chezmoi update'
        }
        Stop-Record "The chezmoi source on sophon is at $head, not $commitSha.$When`n   The checks here would be about another commit. $advice"
    }
    $changes = (Invoke-Git status --porcelain).Text
    if ($changes) {
        Stop-Record "The chezmoi source at $($script:source) has uncommitted changes:$When`n$changes`n   What is applied on sophon is then not what is at $short."
    }
    if (-not $SourceDir) {
        $pending = "$(chezmoi status)".Trim()
        # The exit code first. A chezmoi status that failed prints nothing to
        # read here, and nothing is also what it prints when all is applied.
        if ($LASTEXITCODE -ne 0) {
            Stop-Record "chezmoi status failed (exit $LASTEXITCODE), so whether everything is applied is not known.$When"
        }
        if ($pending) {
            Stop-Record "chezmoi has changes it has not applied:$When`n$pending`n   Run: chezmoi apply"
        }
    }
}
Test-Source ''

# --- 5. Whether the tag can be pushed, before the slow part -------------------

Write-Step "Checking that $tag can be pushed"
$check = Invoke-Git push --dry-run --atomic origin @pushCheckRefs
if ($check.Code -ne 0) {
    $what = if ($moveStable) { 'the tag and stable' } else { 'the tag' }
    Stop-Record "This session cannot push $what to origin:`n$($check.Text)"
}

# --- 6. The checks on sophon ---------------------------------------------------

$os = Get-CimInstance Win32_OperatingSystem
$hostText = "$ComputerName, $($os.Caption) build $($os.BuildNumber)"
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$hostLog = Join-Path $Log "host-checks-$stamp.log"
$hostJson = Join-Path $Log "host-checks-$stamp.json"

if (-not (Test-Path $ChecksScript)) { Stop-Record "$ChecksScript is missing: chezmoi has not written it." }

# A new shell, with the profile, as the head of recertify-checks.ps1 asks:
# several checks are about what a new shell sees. pwsh 7 where there is one.
# From pwsh, the pwsh this is: over ssh a bare `pwsh` can be the Store alias,
# which an ssh session cannot start.
if ($PSVersionTable.PSEdition -eq 'Core') {
    $shell = Join-Path $PSHOME 'pwsh.exe'
} else {
    $found = Get-ChildItem (Join-Path $HOME '.local\opt') -Filter 'pwsh.exe' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName | Select-Object -Last 1
    $shell = if ($found) { $found.FullName } else { 'powershell.exe' }
}

Write-Step "Running the checks on $ComputerName. Transcript: $hostLog"
$before = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $shell -NoLogo -ExecutionPolicy Bypass -File $ChecksScript -OutFile $hostJson 2>&1 |
        ForEach-Object { "$_" } | Tee-Object -FilePath $hostLog
    $checksExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $before
}

# Never trust the exit code alone. The results file is what says the checks
# reached their end, and each check in it says whether it passed.
if (-not (Test-Path $hostJson)) { Stop-Record "The checks did not run to their end on $ComputerName. See $hostLog" }
try {
    # Windows PowerShell hands a JSON array on as one object. Piping it
    # through ForEach-Object makes it a list in both PowerShells.
    $hostChecks = @((Get-Content $hostJson -Raw | ConvertFrom-Json) | ForEach-Object { $_ })
} catch {
    Stop-Record "Could not read the checks' results: $($_.Exception.Message). See $hostLog"
}
$hostTotal = $hostChecks.Count
$hostPassed = @($hostChecks | Where-Object { $_.pass -eq $true }).Count
if ($hostTotal -lt 1 -or $hostPassed -ne $hostTotal -or $checksExit -ne 0) {
    Stop-Record "The checks failed on ${ComputerName}: $hostPassed of $hostTotal passed, exit $checksExit. See $hostLog"
}

# --- 7. The tag ---------------------------------------------------------------

Test-Source "`n   It changed while this script ran, so the checks' result above may be for another commit."

$builtFrom = if ($result.branch -eq 'main') { 'main' } else { "branch $($result.branch) at $("$($result.commit)".Substring(0, 7))" }

$message = @(
    "Certified $short on $today"
    ''
    "Clean-machine result: $cleanPassed of $cleanTotal checks passed"
    "Real-hardware result: $hostPassed of $hostTotal checks passed"
    ''
    "Machine:      $($result.machine)"
    "Host:         $hostText"
    "Built from:   $builtFrom"
    "Tree:         $tree"
)
if ($PSBoundParameters.ContainsKey('Reason')) { $message += "Triggered by: $Reason" }

Write-Step 'The tag'
Write-Host "   $tag -> $commitSha"
if ($moveStable) { Write-Host "   stable -> $commitSha" }
Write-Host ''
foreach ($line in $message) { Write-Host "   $line" }

if ($DryRun) {
    Write-Host ''
    Write-Host 'Dry run: no tag was made and nothing was pushed.'
    exit 0
}

# On the commit, by name: the tag must not depend on any checkout staying
# where it is. --no-sign, because these tags are not signed whatever
# tag.gpgSign says. The message goes through a file without a byte-order mark,
# which git would otherwise keep as the first character of the tag.
$messageFile = Join-Path ([IO.Path]::GetTempPath()) "record-$stamp-$PID.txt"
[IO.File]::WriteAllText($messageFile, (($message -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
try {
    $made = Invoke-Git tag --annotate --no-sign --file $messageFile $tag $commitSha
} finally {
    Remove-Item $messageFile -ErrorAction SilentlyContinue
}
if ($made.Code -ne 0) { Stop-Record "Could not create the tag $tag.`n$($made.Text)" }

# That one tag, by name, never --tags, and stable with it when it moves.
# --atomic: both arrive or neither does, so stable is never at a commit that
# has no tag. Without --force, so stable can only move forward.
$pushed = Invoke-Git push --atomic origin @pushRefs
if ($pushed.Code -ne 0) {
    [void](Invoke-Git tag --delete $tag)
    Stop-Record "Could not push $tag. The local tag was removed, so this can be run again.`n$($pushed.Text)"
}

Write-Host ''
Write-Host "RECORDED: $tag on $short"
Write-Host "   git tag -n99 -l '$tag'"
if ($moveStable) { Write-Host "   stable is now at $short. A rebuild gets that commit." }
exit 0
